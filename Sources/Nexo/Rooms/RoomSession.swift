//
//  RoomSession.swift
//  Nexo
//

import Foundation

// MARK: - RoomSession

/// A live room: members, chat and activities.
///
/// Survives navigation across the room list, chat, a game's lobby, the game
/// itself and its result. Leaving an activity destroys the activity, not the session.
@MainActor
@Observable
public final class RoomSession: Identifiable {

    // MARK: - Identity

    public let roomID: RoomID
    public private(set) var descriptor: RoomDescriptor

    /// `nonisolated` because `roomID` is immutable: reading the session's
    /// identity off the main actor can't race.
    public nonisolated var id: RoomID { roomID }

    // MARK: - State

    public private(set) var members: [RoomMember] = []
    public private(set) var accessState: RoomAccessState
    /// Pending approval requests. Scoped per room: a host can govern several
    /// rooms with independent queues.
    public private(set) var pendingJoinRequests: [RoomJoinRequest] = []
    /// Live activities, indexed by ID.
    public private(set) var activities: [ActivityID: any RoomActivity] = [:]

    public let chat: ChatRoomSession?

    private let identity: LocalP2PIdentity
    private let outbox: RoomOutbox

    // MARK: - Derived

    public var isLocalHost: Bool { descriptor.hostApplicationID == identity.applicationID }
    public var localRole: RoomRole { isLocalHost ? .host : .guest }
    public var features: RoomFeatures { descriptor.features }
    public var name: String { descriptor.name }

    public var host: RoomMember? {
        members.first { $0.applicationID == descriptor.hostApplicationID }
    }

    /// Members other than the local user.
    public var remoteMembers: [RoomMember] {
        members.filter { $0.applicationID != identity.applicationID }
    }

    /// The primary activity for a UI that only shows one game at a time.
    /// Ignores non-exclusive ones (e.g. chat), which can run alongside it.
    public var primaryActivity: (any RoomActivity)? {
        activities.values.first { $0.descriptor.isActive && $0.descriptor.isExclusive }
            ?? activities.values.first { $0.descriptor.isExclusive }
    }

    public var canStartActivity: Bool {
        features.hasActivities
            && activities.values.allSatisfy { !$0.descriptor.isActive || !$0.descriptor.isExclusive }
    }

    // MARK: - Init

    public init(
        descriptor: RoomDescriptor,
        identity: LocalP2PIdentity,
        outbox: RoomOutbox,
        accessState: RoomAccessState,
        members: [RoomMember] = []
    ) {
        self.roomID = descriptor.id
        self.descriptor = descriptor
        self.identity = identity
        self.outbox = outbox
        self.accessState = accessState
        self.members = members
        // Indexed here too so `contains` is reliable before the first membership update.
        self.memberCache = Self.index(members)
        self.chat = descriptor.features.hasChat
            ? ChatRoomSession(roomID: descriptor.id, outbox: outbox, identity: identity)
            : nil
    }

    // MARK: - Membership

    public func apply(descriptor: RoomDescriptor) {
        self.descriptor = descriptor
    }

    public func apply(members: [RoomMember]) {
        // This list comes from a remote peer and isn't authenticated: it may
        // contain duplicate identities. Deduplicate before indexing, since
        // `Dictionary(uniqueKeysWithValues:)` aborts on repeated keys.
        let sanitized = Self.deduplicate(members)

        let previous = Set(self.members.map(\.applicationID))
        let updated = Set(sanitized.map(\.applicationID))

        self.members = sanitized
        self.descriptor.memberCount = sanitized.count

        for member in sanitized
        where !previous.contains(member.applicationID)
            && member.applicationID != identity.applicationID {
            chat?.memberDidJoin(member)
        }

        for applicationID in previous.subtracting(updated)
        where applicationID != identity.applicationID {
            guard let member = memberSnapshot(applicationID) else { continue }
            chat?.memberDidLeave(member)
            notifyActivitiesOfDeparture(member)
        }

        memberCache = Self.index(sanitized)
    }

    public func setAccessState(_ state: RoomAccessState) {
        accessState = state
    }

    public func member(_ applicationID: String) -> RoomMember? {
        memberCache[applicationID]
    }

    public func contains(_ applicationID: String) -> Bool {
        memberCache[applicationID] != nil
    }

    // MARK: - Join requests

    public func enqueueJoinRequest(_ request: RoomJoinRequest) -> Bool {
        guard !pendingJoinRequests.contains(where: { $0.applicationID == request.applicationID }) else {
            return false
        }
        pendingJoinRequests.append(request)
        return true
    }

    public func removeJoinRequest(_ id: UUID) -> RoomJoinRequest? {
        guard let index = pendingJoinRequests.firstIndex(where: { $0.id == id }) else { return nil }
        return pendingJoinRequests.remove(at: index)
    }

    public func removeJoinRequests(for applicationID: String) {
        pendingJoinRequests.removeAll { $0.applicationID == applicationID }
    }

    // MARK: - Activities

    public func register(_ activity: any RoomActivity) {
        activities[activity.descriptor.id] = activity
    }

    public func activity(_ id: ActivityID) -> (any RoomActivity)? {
        activities[id]
    }

    public func activity(ofKind kind: ActivityKind) -> (any RoomActivity)? {
        activities.values.first { $0.descriptor.kind == kind && $0.descriptor.isActive }
    }

    public func removeActivity(_ id: ActivityID, reason: String) {
        guard let activity = activities.removeValue(forKey: id) else { return }
        activity.activityDidEnd(reason: reason)
    }

    public func removeAllActivities(reason: String) {
        let current = activities
        activities.removeAll()
        for activity in current.values {
            activity.activityDidEnd(reason: reason)
        }
    }

    /// Removes only the activities no longer present in the host's
    /// authoritative snapshot, keeping the rest and their state.
    public func removeActivities(notIncludedIn activeIDs: Set<ActivityID>, reason: String) {
        let staleIDs = activities.keys.filter { !activeIDs.contains($0) }
        for activityID in staleIDs {
            removeActivity(activityID, reason: reason)
        }
    }

    /// Context to instantiate an activity scoped to this room.
    public func makeActivityContext(for descriptor: ActivityDescriptor) -> ActivityContext {
        ActivityContext(
            descriptor: descriptor,
            identity: identity,
            outbox: outbox,
            members: { [weak self] in self?.members ?? [] }
        )
    }

    // MARK: - Private Helpers

    private var memberCache: [String: RoomMember] = [:]

    private func memberSnapshot(_ applicationID: String) -> RoomMember? {
        memberCache[applicationID]
    }

    private func notifyActivitiesOfDeparture(_ member: RoomMember) {
        for activity in activities.values where activity.descriptor.includes(member.applicationID) {
            activity.participantDidLeave(member)
        }
    }

    /// Keeps the first occurrence of each identity.
    private static func deduplicate(_ members: [RoomMember]) -> [RoomMember] {
        var seen: Set<String> = []
        return members.filter { seen.insert($0.applicationID).inserted }
    }

    private static func index(_ members: [RoomMember]) -> [String: RoomMember] {
        var index: [String: RoomMember] = [:]
        for member in members where index[member.applicationID] == nil {
            index[member.applicationID] = member
        }
        return index
    }
}
