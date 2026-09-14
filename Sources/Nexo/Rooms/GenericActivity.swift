//
//  GenericActivity.swift
//  Nexo
//

import Foundation

// MARK: - GenericActivity

/// Adaptador base reutilizable entre `RoomActivity` y un enum de mensajes
/// tipado. Decodifica el payload, guarda los mensajes llegados antes de que la
/// UI esté lista y expone puntos de extensión por closure en vez de un
/// protocolo delegate propio por juego.
@MainActor
@Observable
open class GenericActivity<Message: Codable & Sendable>: RoomActivity {

    public private(set) var descriptor: ActivityDescriptor

    /// Se conecta cuando la UI de la partida está viva. Mientras no lo esté, los
    /// mensajes se guardan: un mensaje autoritativo puede llegar antes de que la
    /// vista aparezca y no debe perderse.
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

    /// Difunde un mensaje tipado a los participantes indicados, o a todos si se omite.
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

    /// Actualiza el estado de la actividad. Solo tiene efecto en el host.
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
