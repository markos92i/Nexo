//
//  GenericActivity.swift
//  Nexo
//

import Foundation

// MARK: - GenericActivity

/// Reusable adapter between `RoomActivity` and a typed message enum. Handles
/// decoding, buffering messages that arrive before the UI attaches, and
/// coalesced sending, so a concrete activity is just the message type plus
/// wiring its closures.
@MainActor
@Observable
open class GenericActivity<Message: Codable & Sendable>: RoomActivity {

    public private(set) var descriptor: ActivityDescriptor

    /// `nil` until the UI attaches; incoming messages are buffered until then.
    public var onReceive: ((Message, RoomMember) -> Void)? {
        didSet { flushPendingMessages() }
    }
    public var onParticipantJoin: ((RoomMember) -> Void)?
    public var onParticipantLeave: ((RoomMember) -> Void)?
    public var onEnd: ((String) -> Void)?
    public var onDescriptorUpdate: (() -> Void)?

    public let context: ActivityContext
    private var pendingMessages: [(Message, RoomMember)] = []

    public var isLocalHost: Bool { descriptor.hostApplicationID == context.identity.applicationID }
    public var localDisplayName: String { context.identity.displayName }
    public var localApplicationID: String { context.identity.applicationID }
    public var participants: [RoomMember] { context.participants(for: descriptor) }

    public init(context: ActivityContext) {
        self.context = context
        self.descriptor = context.descriptor
    }

    /// Broadcasts a typed message to the given recipient, or to all participants.
    public func send(_ message: Message, coalescingKey: String? = nil, to member: RoomMember? = nil) {
        let recipients = member.map { [$0.applicationID] } ?? participants.map(\.applicationID)
        guard !recipients.isEmpty else { return }

        if let coalescingKey {
            context.outbox.sendCoalesced(
                message,
                channel: .activity,
                activityID: descriptor.id,
                coalescingKey: coalescingKey,
                to: recipients
            )
        } else {
            context.outbox.send(
                message,
                channel: .activity,
                activityID: descriptor.id,
                to: recipients
            )
        }
    }

    /// Updates activity state. Only takes effect when called by the host.
    public func setState(_ state: ActivityState) {
        guard isLocalHost, descriptor.state != state else { return }
        descriptor.state = state
        onDescriptorUpdate?()
    }

    // MARK: - RoomActivity

    public func receive(payload: Data, from member: RoomMember) {
        guard let message = try? P2PCoder.decode(Message.self, from: payload) else { return }

        guard let onReceive else {
            pendingMessages.append((message, member))
            return
        }

        onReceive(message, member)
    }

    public func participantDidJoin(_ member: RoomMember) {
        descriptor.participantIDs.insert(member.applicationID)
        onParticipantJoin?(member)
    }

    public func participantDidLeave(_ member: RoomMember) {
        descriptor.participantIDs.remove(member.applicationID)
        onParticipantLeave?(member)
    }

    public func activityDidEnd(reason: String) {
        pendingMessages.removeAll()
        onEnd?(reason)
    }

    public func apply(descriptor: ActivityDescriptor) {
        self.descriptor = descriptor
        onDescriptorUpdate?()
    }

    // MARK: - Private Helpers

    private func flushPendingMessages() {
        guard let onReceive, !pendingMessages.isEmpty else { return }

        let buffered = pendingMessages
        pendingMessages.removeAll()

        for entry in buffered {
            onReceive(entry.0, entry.1)
        }
    }
}
