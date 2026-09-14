//
//  RoomOutbox.swift
//  Nexo
//

import Foundation

// MARK: - RoomOutbox

/// Room-scoped sender. The only way chat, activities and transfers send data.
///
/// Replaces singleton channels: every consumer gets a `RoomOutbox` bound to
/// *its* room, so it can't write into another room and never needs to know
/// about the transport.
@MainActor
public final class RoomOutbox {

    public let roomID: RoomID

    private let transport: any PeerTransport
    private let identity: LocalP2PIdentity
    /// Members to broadcast to, excluding the local user. Resolved on every
    /// send so live membership is never captured stale.
    private let recipients: @MainActor () -> [String]

    private var sequence: UInt64 = 0

    private struct JournalEntry {
        var envelope: RoomEnvelope
        var recipients: Set<String>
        var createdAt: Date
    }

    /// Keeps recent messages for a short window so a peer can catch up after
    /// a physical drop. The transport itself still knows nothing about rooms.
    private var recoveryJournal: [JournalEntry] = []
    private var recoveryJournalBytes = 0

    // MARK: - Init

    public init(
        roomID: RoomID,
        transport: any PeerTransport,
        identity: LocalP2PIdentity,
        recipients: @escaping @MainActor () -> [String]
    ) {
        self.roomID = roomID
        self.transport = transport
        self.identity = identity
        self.recipients = recipients
    }

    // MARK: - Public API

    /// Sends a typed message on the given channel.
    ///
    /// Encoding failures are ignored deliberately: a malformed message is a
    /// programming error that shouldn't crash the UI, and the transport
    /// already retries or reports disconnects on its own.
    public func send<Message: Encodable & Sendable>(
        _ message: Message,
        channel: RoomChannel,
        activityID: ActivityID? = nil,
        to applicationIDs: [String]? = nil,
        delivery: DeliveryMode = .reliable,
        coalescingKey: String? = nil
    ) {
        guard let envelope = makeEnvelope(
            message,
            channel: channel,
            activityID: activityID,
            delivery: delivery,
            coalescingKey: coalescingKey
        ) else { return }

        let targets = (applicationIDs ?? recipients())
            .filter { $0 != identity.applicationID }
        guard !targets.isEmpty else { return }

        appendToRecoveryJournal(envelope, recipients: targets)
        for target in targets {
            transport.enqueue(envelope, to: target)
        }
    }

    /// Replays recent messages to a peer that just recovered its socket.
    /// Message IDs are preserved so the receiver can idempotently drop duplicates.
    public func replay(to applicationID: String) {
        pruneRecoveryJournal()
        for entry in recoveryJournal where entry.recipients.contains(applicationID) {
            transport.enqueue(entry.envelope, to: applicationID)
        }
    }

    /// Sends bulky, replaceable state, like a board snapshot.
    ///
    /// `coalescingKey` makes a pending snapshot get replaced by the next one
    /// instead of piling up, so it never sits ahead of an authoritative order.
    public func sendCoalesced<Message: Encodable & Sendable>(
        _ message: Message,
        channel: RoomChannel,
        activityID: ActivityID? = nil,
        coalescingKey: String,
        to applicationIDs: [String]? = nil
    ) {
        send(
            message,
            channel: channel,
            activityID: activityID,
            to: applicationIDs,
            delivery: .unreliable,
            coalescingKey: coalescingKey
        )
    }

    // MARK: - Recovery Journal

    private func appendToRecoveryJournal(_ envelope: RoomEnvelope, recipients: [String]) {
        // Transfers have their own ACK protocol and must not reinject old
        // chunks; chat and activities are resumable.
        guard envelope.channel == .chat || envelope.channel == .activity else { return }
        guard envelope.payload.count <= P2PLimits.maximumEnvelopeBytes else { return }

        pruneRecoveryJournal()
        let recipientSet = Set(recipients)

        if envelope.deliveryMode == .unreliable,
           let coalescingKey = envelope.coalescingKey,
           let index = recoveryJournal.firstIndex(where: {
               $0.envelope.channel == envelope.channel
                   && $0.envelope.activityID == envelope.activityID
                   && $0.envelope.coalescingKey == coalescingKey
           }) {
            recoveryJournalBytes -= recoveryJournal[index].envelope.payload.count
            recoveryJournal[index].envelope = envelope
            recoveryJournal[index].recipients.formUnion(recipientSet)
            recoveryJournal[index].createdAt = Date()
            recoveryJournalBytes += envelope.payload.count
            trimRecoveryJournalIfNeeded()
            return
        }

        recoveryJournal.append(JournalEntry(
            envelope: envelope,
            recipients: recipientSet,
            createdAt: Date()
        ))
        recoveryJournalBytes += envelope.payload.count
        trimRecoveryJournalIfNeeded()
    }

    private func pruneRecoveryJournal() {
        let cutoff = Date().addingTimeInterval(-P2PLimits.recoveryJournalRetention)
        recoveryJournal.removeAll { $0.createdAt < cutoff }
        recoveryJournalBytes = recoveryJournal.reduce(into: 0) { total, entry in
            total += entry.envelope.payload.count
        }
    }

    private func trimRecoveryJournalIfNeeded() {
        while recoveryJournal.count > P2PLimits.recoveryJournalLimit
                || recoveryJournalBytes > P2PLimits.recoveryJournalBytesLimit,
              let removed = recoveryJournal.first {
            recoveryJournal.removeFirst()
            recoveryJournalBytes -= removed.envelope.payload.count
        }
    }

    // MARK: - Private Helpers

    private func makeEnvelope<Message: Encodable & Sendable>(
        _ message: Message,
        channel: RoomChannel,
        activityID: ActivityID?,
        delivery: DeliveryMode,
        coalescingKey: String?
    ) -> RoomEnvelope? {
        sequence &+= 1

        guard let envelope = try? RoomEnvelope(
            roomID: roomID,
            activityID: activityID,
            channel: channel,
            senderApplicationID: identity.applicationID,
            message: message,
            deliveryMode: delivery,
            coalescingKey: coalescingKey,
            sequence: sequence
        ), envelope.payload.count <= P2PLimits.maximumEnvelopeBytes else {
            return nil
        }
        return envelope
    }
}
