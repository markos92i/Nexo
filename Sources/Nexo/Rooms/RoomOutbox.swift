//
//  RoomOutbox.swift
//  Project Dark
//
//  Created by Marcos del Castillo Camacho on 11/09/2026.
//

import Foundation

// MARK: - RoomOutbox

/// Emisor con ámbito de room. Es la única vía por la que el chat, las
/// actividades y las transferencias envían datos.
///
/// Sustituye a los canales singleton del stack anterior: cada consumidor recibe
/// un `RoomOutbox` ligado a *su* room, así que no puede escribir en otra room ni
/// necesita conocer el transporte.
@MainActor
public final class RoomOutbox {

    public let roomID: RoomID

    private let transport: any PeerTransport
    private let identity: LocalP2PIdentity
    /// Miembros a los que difundir, excluido el usuario local. Se resuelve en
    /// cada envío para que la membresía viva no quede capturada.
    private let recipients: @MainActor () -> [String]

    private var sequence: UInt64 = 0

    private struct JournalEntry {
        var envelope: RoomEnvelope
        var recipients: Set<String>
        var createdAt: Date
    }

    /// Conserva durante un intervalo corto los mensajes que deben ponerse al
    /// día después de una pérdida física. El transporte sigue sin conocer rooms.
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

    /// Envía un mensaje tipado por el canal indicado.
    ///
    /// Los fallos de codificación se ignoran deliberadamente: un mensaje mal
    /// formado es un error de programación que no debe tirar la UI, y el
    /// transporte ya reintenta o notifica la desconexión por su cuenta.
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

    /// Reentrega los mensajes recientes dirigidos a un peer que acaba de
    /// recuperar el socket. Los messageID se conservan para que el receptor
    /// pueda descartar duplicados de forma idempotente.
    public func replay(to applicationID: String) {
        pruneRecoveryJournal()
        for entry in recoveryJournal where entry.recipients.contains(applicationID) {
            transport.enqueue(entry.envelope, to: applicationID)
        }
    }

    /// Envía estado voluminoso y sustituible, como un snapshot de tablero.
    ///
    /// La `coalescingKey` hace que un snapshot pendiente se reemplace por el
    /// siguiente en vez de acumularse, de modo que nunca queda por delante de una
    /// orden autoritativa.
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
        // Las transferencias tienen su propio protocolo de ACK y no deben
        // reinyectar chunks antiguos; chat y actividades sí son reanudables.
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
