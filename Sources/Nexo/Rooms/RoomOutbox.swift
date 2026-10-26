import Foundation

// MARK: - RoomOutbox

/// Emisor acotado a una sala. La única vía por la que chat, actividades y
/// transferencias envían datos.
///
/// Sustituye a canales singleton: cada consumidor obtiene un `RoomOutbox` ligado
/// a *su* sala, así que no puede escribir en otra y nunca necesita conocer el
/// transporte.
@NexoActor
public final class RoomOutbox {

    public let roomID: RoomID

    private let transport: any Transport
    private let identity: LocalIdentity
    private let isPeerAdmitted: @NexoActor @Sendable (DeviceID) -> Bool

    private var sequence: UInt64 = 0

    private struct JournalEntry {
        var envelope: Envelope
        var recipients: Set<DeviceID>
        var createdAt: Date
    }

    /// Mantiene mensajes recientes durante una ventana corta para que un peer se
    /// ponga al día tras una caída física. El transporte sigue sin saber de salas.
    private var recoveryJournal: [JournalEntry] = []
    private var recoveryJournalBytes = 0

    public init(
        roomID: RoomID,
        transport: any Transport,
        identity: LocalIdentity,
        isPeerAdmitted: @escaping @NexoActor @Sendable (DeviceID) -> Bool
    ) {
        self.roomID = roomID
        self.transport = transport
        self.identity = identity
        self.isPeerAdmitted = isPeerAdmitted
    }

    // MARK: - API pública

    /// Envía un mensaje tipado por el canal indicado.
    ///
    /// Los fallos de codificación se ignoran a propósito: un mensaje mal formado
    /// es un error de programación que no debe tirar la UI, y el transporte ya
    /// reintenta o reporta desconexiones por su cuenta.
    public func send(
        _ message: some Encodable & Sendable,
        channel: Channel,
        activityID: ActivityID? = nil,
        to recipients: [DeviceID],
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

        let targets = recipients.filter { $0 != identity.deviceID }
        guard !targets.isEmpty else { return }

        appendToRecoveryJournal(envelope, recipients: targets)
        for target in targets where isPeerAdmitted(target) {
            transport.enqueue(envelope, to: target)
        }
    }

    /// Reenvía mensajes recientes a un peer que acaba de recuperar su socket. Los
    /// IDs de mensaje se preservan para que el receptor descarte duplicados.
    public func replay(to deviceID: DeviceID) {
        guard isPeerAdmitted(deviceID) else { return }
        pruneRecoveryJournal()
        for entry in recoveryJournal where entry.recipients.contains(deviceID) {
            transport.enqueue(entry.envelope, to: deviceID)
        }
    }

    /// Envía estado voluminoso y reemplazable, como el snapshot de un tablero.
    ///
    /// `coalescingKey` hace que un snapshot pendiente lo reemplace el siguiente en
    /// vez de acumularse, para que nunca quede delante de una orden autoritativa.
    public func sendCoalesced(
        _ message: some Encodable & Sendable,
        channel: Channel,
        activityID: ActivityID? = nil,
        coalescingKey: String,
        to recipients: [DeviceID]
    ) {
        send(
            message,
            channel: channel,
            activityID: activityID,
            to: recipients,
            delivery: .unreliable,
            coalescingKey: coalescingKey
        )
    }

    // MARK: - Journal de recuperación

    private func appendToRecoveryJournal(_ envelope: Envelope, recipients: [DeviceID]) {
        // Las transferencias tienen su propio protocolo de ACK y no deben
        // reinyectar chunks viejos; chat y actividades sí son reanudables.
        guard envelope.channel == .chat || envelope.channel == .activity else { return }
        guard envelope.payload.count <= Limits.maximumEnvelopeBytes else { return }

        pruneRecoveryJournal()
        let recipientSet = Set(recipients)

        if envelope.deliveryMode == .unreliable,
           let coalescingKey = envelope.coalescingKey,
           let index = recoveryJournal.firstIndex(where: {
               $0.envelope.channel == envelope.channel
                   && $0.envelope.activityID == envelope.activityID
                   && $0.envelope.coalescingKey == coalescingKey
                   && $0.recipients == recipientSet
           }) {
            recoveryJournalBytes -= recoveryJournal.remove(at: index).envelope.payload.count
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
        let cutoff = Date().addingTimeInterval(-Limits.recoveryJournalRetention)
        var bytes = 0
        recoveryJournal.removeAll { entry in
            if entry.createdAt < cutoff { return true }
            bytes += entry.envelope.payload.count
            return false
        }
        recoveryJournalBytes = bytes
    }

    private func trimRecoveryJournalIfNeeded() {
        while recoveryJournal.count > Limits.recoveryJournalLimit
                || recoveryJournalBytes > Limits.recoveryJournalBytesLimit,
              let removed = recoveryJournal.first {
            recoveryJournal.removeFirst()
            recoveryJournalBytes -= removed.envelope.payload.count
        }
    }

    // MARK: - Helpers privados

    private func makeEnvelope(
        _ message: some Encodable & Sendable,
        channel: Channel,
        activityID: ActivityID?,
        delivery: DeliveryMode,
        coalescingKey: String?
    ) -> Envelope? {
        sequence &+= 1

        guard let envelope = try? Envelope(
            roomID: roomID,
            activityID: activityID,
            channel: channel,
            senderDeviceID: identity.deviceID,
            message: message,
            deliveryMode: delivery,
            coalescingKey: coalescingKey,
            sequence: sequence
        ), envelope.payload.count <= Limits.maximumEnvelopeBytes else {
            return nil
        }
        return envelope
    }
}
