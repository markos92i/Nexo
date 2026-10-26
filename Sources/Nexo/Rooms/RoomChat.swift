import Foundation

// MARK: - RoomChat

/// Chat de una sala concreta.
///
/// Solo existe si la sala declara `RoomFeatures.chat`, así que una sala solo-juego
/// no carga historial ni UI de chat. El historial se guarda a través de un
/// `MessageStore` (efímero por defecto); la deduplicación y el recorte de ventana
/// son política de dominio y viven aquí.
@NexoActor
public final class RoomChat {

    public let roomID: RoomID

    // MARK: - Estado

    public var messages: [ChatMessage] { store.messages(for: roomID) }
    /// Transferencias vivas asociadas a mensajes de este chat.
    public private(set) var transfers: [UUID: FileTransferState] = [:]

    private let store: any MessageStore
    private let membership: RoomMembership
    private let outbox: RoomOutbox
    private let identity: LocalIdentity
    /// Se llama tras cualquier cambio visible para que la sala republique su
    /// snapshot. El chat no tiene flujo propio: los mensajes viajan por los
    /// canales de chat y transferencia, y la sala agrega ambos.
    var onChange: (@NexoActor () -> Void)?
    /// IDs ya vistos: el mismo mensaje puede llegar otra vez por replay. Se
    /// mantiene aparte de la ventana visible para que un replay viejo no
    /// reinserte un mensaje ya descartado.
    private var seenMessageIDs: Set<UUID> = []
    private var seenMessageDates: [UUID: Date] = [:]

    // MARK: - Init

    init(
        roomID: RoomID,
        store: any MessageStore,
        outbox: RoomOutbox,
        identity: LocalIdentity,
        membership: RoomMembership
    ) {
        self.roomID = roomID
        self.store = store
        self.membership = membership
        self.outbox = outbox
        self.identity = identity
        // Reconstruye el índice de dedup a partir de lo ya almacenado.
        for message in store.messages(for: roomID) {
            seenMessageIDs.insert(message.id)
            seenMessageDates[message.id] = message.timestamp
        }
    }

    // MARK: - Envío

    public func send(text: String) {
        send(text: text, invitation: nil)
    }

    /// Publica texto o una invitación a actividad. La actividad debe haberla
    /// creado ya el coordinador, que sigue siendo la autoridad de sus
    /// participantes y su estado.
    public func send(text: String, invitation: ChatActivityInvitation?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || invitation != nil else { return }
        if let invitation, invitation.roomID != roomID { return }

        let message = ChatMessage(
            roomID: roomID,
            senderDeviceID: identity.deviceID,
            senderDisplayName: identity.displayName,
            body: String(trimmed.prefix(4_000)),
            invitation: invitation
        )

        append(message)
        outbox.send(message, channel: .chat, to: remoteRecipients())
        onChange?()
    }

    /// Publica el mensaje que acompaña a un adjunto. El contenido lo mueve
    /// `FileTransferService` por su propio canal.
    public func send(attachment: ChatAttachment, caption: String) {
        let message = ChatMessage(
            roomID: roomID,
            senderDeviceID: identity.deviceID,
            senderDisplayName: identity.displayName,
            body: String(caption.prefix(4_000)),
            kind: .attachment,
            attachment: attachment
        )

        if append(message), transfers[attachment.transferID] == nil {
            transfers[attachment.transferID] = .accepted
        }
        outbox.send(message, channel: .chat, to: remoteRecipients())
        onChange?()
    }

    // MARK: - Recepción

    public func receive(payload: Data, from member: RoomMember) {
        guard var message = try? WireCoder.decode(ChatMessage.self, from: payload) else { return }

        // El emisor declarado debe coincidir con el peer que la sala conoce, y el
        // mensaje debe pertenecer a esta sala. Los avisos de sistema son locales.
        guard message.senderDeviceID == member.deviceID,
              message.roomID == roomID,
              message.kind != .systemInfo else { return }

        // Un mensaje de texto no puede llevar metadatos de adjunto, y un mensaje
        // de adjunto debe declarar su oferta. Invitación y adjunto son excluyentes.
        if message.kind == .attachment {
            guard message.attachment != nil, message.invitation == nil else { return }
        } else {
            guard message.attachment == nil else { return }
        }

        // La invitación es solo una referencia visual. Si apunta a otra sala,
        // conserva el texto pero descarta la acción.
        if let invitation = message.invitation, invitation.roomID != roomID {
            message.invitation = nil
        }

        // El nombre visible es el que la sala conoce, no el que el peer embebió.
        message.senderDisplayName = member.displayName
        message.body = String(message.body.prefix(4_000))
        guard append(message) else { return }

        if let attachment = message.attachment, transfers[attachment.transferID] == nil {
            transfers[attachment.transferID] = .offered
        }
        onChange?()
    }

    /// Fusiona el historial enviado por el host durante el resume. La
    /// deduplicación por UUID hace seguro combinarlo con el replay.
    public func merge(messages: [ChatMessage]) -> Bool {
        var didChange = false

        for original in messages where original.roomID == roomID && original.kind != .systemInfo {
            var message = original
            message.body = String(message.body.prefix(4_000))
            if let invitation = message.invitation, invitation.roomID != roomID {
                message.invitation = nil
            }

            guard append(message) else { continue }
            didChange = true

            if let attachment = message.attachment, transfers[attachment.transferID] == nil {
                transfers[attachment.transferID] = .offered
            }
        }

        if didChange { onChange?() }
        return didChange
    }

    // MARK: - Transferencias

    public func updateTransfer(_ transferID: UUID, state: FileTransferState) {
        transfers[transferID] = state
        onChange?()
    }

    public func transferState(for transferID: UUID) -> FileTransferState? {
        transfers[transferID]
    }

    public func clearHistory() {
        store.clear(roomID)
        seenMessageIDs.removeAll()
        seenMessageDates.removeAll()
        transfers.removeAll()
        onChange?()
    }

    // MARK: - Helpers privados

    private func remoteRecipients() -> [DeviceID] {
        membership.members
            .filter { $0.deviceID != identity.deviceID }
            .map(\.deviceID)
    }

    @discardableResult
    private func append(_ message: ChatMessage) -> Bool {
        pruneSeenMessageIDs()
        guard seenMessageIDs.insert(message.id).inserted else { return false }
        seenMessageDates[message.id] = Date()

        var current = store.messages(for: roomID)
        let index = current.firstIndex {
            $0.timestamp > message.timestamp
                || ($0.timestamp == message.timestamp && $0.id.uuidString > message.id.uuidString)
        } ?? current.endIndex
        current.insert(message, at: index)

        if current.count > Limits.chatHistoryLimit {
            current.removeFirst(current.count - Limits.chatHistoryLimit)
            let visibleTransfers = Set(current.compactMap(\.attachment?.transferID))
            transfers = transfers.filter { visibleTransfers.contains($0.key) }
        }
        store.replaceAll(current, for: roomID)
        pruneSeenMessageIDs()
        return true
    }

    private func pruneSeenMessageIDs() {
        let visibleIDs = Set(store.messages(for: roomID).map(\.id))
        let cutoff = Date().addingTimeInterval(-Limits.recoveryJournalRetention)
        let expiredIDs = seenMessageDates.compactMap { id, date in
            !visibleIDs.contains(id) && date < cutoff ? id : nil
        }

        for id in expiredIDs {
            seenMessageDates.removeValue(forKey: id)
            seenMessageIDs.remove(id)
        }

        let nonVisibleEntries = seenMessageDates.filter { id, _ in !visibleIDs.contains(id) }
        let excessCount = nonVisibleEntries.count - Limits.recoveryJournalLimit
        guard excessCount > 0 else { return }

        let oldestIDs = nonVisibleEntries
            .sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key.uuidString < rhs.key.uuidString
            }
            .prefix(excessCount)
            .map(\.key)

        for id in oldestIDs {
            seenMessageDates.removeValue(forKey: id)
            seenMessageIDs.remove(id)
        }
    }
}
