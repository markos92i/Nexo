//
//  RoomActivity.swift
//  Nexo
//

import Foundation

// MARK: - RoomActivity

/// An activity is something that happens *inside* a room, not a room of its own.
///
/// The transport and `RoomCoordinator` treat its payload as opaque: each
/// activity defines and decodes its own messages. Adding a new game never
/// touches a lower layer.
@NexoActor
public protocol RoomActivity: AnyObject {

    var descriptor: ActivityDescriptor { get }

    /// Payload on the `.activity` channel addressed to this activity.
    func receive(payload: Data, from member: RoomMember)

    /// A participant joins or leaves the activity without leaving the room.
    func participantDidJoin(_ member: RoomMember)
    func participantDidLeave(_ member: RoomMember)

    /// The activity ends. Only the activity is destroyed; the room and its
    /// other activities stay alive.
    func activityDidEnd(reason: NexoReason)

    /// Applies an updated descriptor received from the host.
    func apply(descriptor: ActivityDescriptor)

    /// Called whenever the descriptor changes, so the room that owns the
    /// activity can republish its snapshot.
    var onDescriptorChange: (@NexoActor () -> Void)? { get set }
}

public extension RoomActivity {
    var id: ActivityID { descriptor.id }
    var kind: ActivityKind { descriptor.kind }
    var roomID: RoomID { descriptor.roomID }

    func isHost(_ applicationID: String) -> Bool {
        descriptor.hostApplicationID == applicationID
    }
}

// MARK: - ActivityContext

/// Everything an activity needs to function, already scoped to its room.
public struct ActivityContext {
    public let descriptor: ActivityDescriptor
    public let identity: LocalP2PIdentity
    /// The room's sender. The activity always sends with its own `activityID`.
    public let outbox: RoomOutbox
    /// Live room members, resolved on every query.
    public let members: @NexoActor () -> [RoomMember]
    /// Ends this activity through its owning room, removing it from the
    /// session and notifying its participants. `nil` when no room owns it.
    public let endActivity: (@NexoActor (NexoReason) -> Void)?

    /// `true` if the local user is authoritative for this activity.
    public var isLocalHost: Bool {
        descriptor.hostApplicationID == identity.applicationID
    }

    /// Activity participants excluding the local user. `descriptor` is passed
    /// in because it can change as new members join an open activity.
    @NexoActor
    public func participants(for descriptor: ActivityDescriptor) -> [RoomMember] {
        members().filter {
            descriptor.includes($0.applicationID) && $0.applicationID != identity.applicationID
        }
    }
}

// MARK: - RoomActivityRegistry

/// Factory of activities by kind.
///
/// This is the extension point for future games: register a factory at
/// launch, and `RoomCoordinator` can instantiate the right activity on
/// `activityStarted` without knowing about any concrete game.
@NexoActor
public final class RoomActivityRegistry {

    public typealias Factory = @NexoActor (ActivityContext) -> any RoomActivity

    private var factories: [ActivityKind: Factory] = [:]

    public init() {}

    // MARK: - Public API

    public func register(_ kind: ActivityKind, factory: @escaping Factory) {
        factories[kind] = factory
    }

    public func isRegistered(_ kind: ActivityKind) -> Bool {
        factories[kind] != nil
    }

    /// Instantiates the described activity, or `nil` if this build doesn't
    /// know it (e.g. a newer peer proposes a game this build lacks).
    public func makeActivity(for context: ActivityContext) -> (any RoomActivity)? {
        factories[context.descriptor.kind]?(context)
    }
}
