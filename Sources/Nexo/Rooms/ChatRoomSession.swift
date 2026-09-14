//
//  ChatRoomSession.swift
//  Project Dark
//
//  Created by Marcos del Castillo Camacho on 11/09/2026.
//

import Foundation

// MARK: - ChatMessageKind

public enum ChatMessageKind: String, Codable, Sendable {
    case text
    /// Aviso generado localmente (entradas, salidas, cierre de sala).
    case systemInfo
    /// Mensaje con un adjunto. El contenido llega por el canal de transferencia.
    case attachment
}

// MARK: - ChatActivityInvitation

/// Referencia a una actividad ya creada que se presenta como una invitación en
/// el chat. El anuncio de control sigue siendo la autoridad de la actividad;
/// este payload solo permite conservarla y representarla como una burbuja.
public struct ChatActivityInvitation: Codable, Sendable, Hashable {
    public let activityID: ActivityID
    public let roomID: RoomID
    public let kind: ActivityKind

    public init(activityID: ActivityID, roomID: RoomID, kind: ActivityKind) {
        self.activityID = activityID
        self.roomID = roomID
        self.kind = kind
    }
}

// MARK: - ChatAttachment

/// Metadatos del adjunto que viajan en el mensaje de chat.
///
/// El contenido **no** viaja aquí: solo la descripción y el `transferID` con el
/// que emparejar los chunks del canal `.fileTransfer`.
public struct ChatAttachment: Codable, Sendable, Hashable {
    public let transferID: UUID
    public let fileName: String
    public let mimeType: String
    public let fileSize: Int64
    public let checksum: String

    public init(transferID: UUID, fileName: String, mimeType: String, fileSize: Int64, checksum: String) {
        self.transferID = transferID
        self.fileName = fileName
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.checksum = checksum
    }

    public var isImage: Bool { mimeType.hasPrefix("image/") }
}

// MARK: - ChatMessage

public struct ChatMessage: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let roomID: RoomID
    public let senderApplicationID: String
    public var senderDisplayName: String
    public var body: String
    public let kind: ChatMessageKind
    public var attachment: ChatAttachment?
    /// Invitación opcional. Al ser opcional, los mensajes de peers antiguos
    /// siguen decodificando como mensajes de texto normales.
    public var invitation: ChatActivityInvitation?
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        roomID: RoomID,
        senderApplicationID: String,
        senderDisplayName: String,
        body: String,
        kind: ChatMessageKind = .text,
        attachment: ChatAttachment? = nil,
        invitation: ChatActivityInvitation? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.roomID = roomID
        self.senderApplicationID = senderApplicationID
        self.senderDisplayName = senderDisplayName
        self.body = body
        self.kind = kind
        self.attachment = attachment
        self.invitation = invitation
        self.timestamp = timestamp
    }

    public var isSystem: Bool { kind == .systemInfo }

    public static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool { lhs.id == rhs.id }

    // MARK: Factories

    public static func system(roomID: RoomID, body: String) -> ChatMessage {
        ChatMessage(
            roomID: roomID,
            senderApplicationID: "system",
            senderDisplayName: "Sistema",
            body: body,
            kind: .systemInfo
        )
    }
}

// MARK: - ChatRoomSession

/// Chat de una room concreta.
///
/// Solo existe si la room declara `RoomFeatures.chat`, así que una room de solo
/// juego no arrastra historial ni UI de chat.
@MainActor
@Observable
public final class ChatRoomSession {

    public let roomID: RoomID

    // MARK: - Estado

    public private(set) var messages: [ChatMessage] = []
    /// Transferencias vivas asociadas a mensajes de este chat.
    public private(set) var transfers: [UUID: FileTransferState] = [:]

    private let outbox: RoomOutbox
    private let identity: LocalP2PIdentity
    /// Identificadores ya vistos: el mismo mensaje puede llegar por reenvío.
    /// Se conserva independientemente de la ventana visual para que un replay
    /// antiguo no vuelva a insertar un mensaje ya descartado de `messages`.
    /// Los IDs que ya no son visibles se conservan solo durante la ventana de
    /// recuperación y hasta el límite del journal.
    private var seenMessageIDs: Set<UUID> = []
    private var seenMessageDates: [UUID: Date] = [:]

    // MARK: - Init

    public init(roomID: RoomID, outbox: RoomOutbox, identity: LocalP2PIdentity) {
        self.roomID = roomID
        self.outbox = outbox
        self.identity = identity
    }

    // MARK: - Envío

    public func send(text: String) {
        send(text: text, invitation: nil)
    }

    /// Publica un texto o una invitación de actividad. La actividad debe haberse
    /// creado previamente por el coordinador, que sigue siendo la autoridad
    /// para sus participantes y estado.
    public func send(text: String, invitation: ChatActivityInvitation?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || invitation != nil else { return }
        if let invitation, invitation.roomID != roomID { return }

        let message = ChatMessage(
            roomID: roomID,
            senderApplicationID: identity.applicationID,
            senderDisplayName: identity.displayName,
            body: String(trimmed.prefix(4_000)),
            invitation: invitation
        )

        append(message)
        outbox.send(message, channel: .chat)
    }

    /// Publica el mensaje que acompaña a un adjunto. El contenido lo mueve
    /// `FileTransferService` por su propio canal.
    public func send(attachment: ChatAttachment, caption: String) {
        let message = ChatMessage(
            roomID: roomID,
            senderApplicationID: identity.applicationID,
            senderDisplayName: identity.displayName,
            body: String(caption.prefix(4_000)),
            kind: .attachment,
            attachment: attachment
        )

        append(message)
        transfers[attachment.transferID] = .accepted
        outbox.send(message, channel: .chat)
    }

    // MARK: - Recepción

    public func receive(payload: Data, from member: RoomMember) {
        guard var message = try? P2PCoder.decode(ChatMessage.self, from: payload) else { return }

        // El emisor declarado debe coincidir con el peer conocido por la room,
        // y el mensaje debe pertenecer a esta room.
        guard message.senderApplicationID == member.applicationID,
              message.roomID == roomID else { return }

        // Un mensaje normal no puede transportar metadatos de adjunto, y un
        // mensaje de adjunto debe declarar la oferta que lo acompaña. Una
        // invitación y un adjunto tampoco son la misma clase de mensaje.
        if message.kind == .attachment {
            guard message.attachment != nil, message.invitation == nil else { return }
        } else {
            guard message.attachment == nil else { return }
        }

        // La invitación es solo una referencia visual. Si llega apuntando a
        // otra room, se conserva el texto pero se descarta la acción.
        if let invitation = message.invitation, invitation.roomID != roomID {
            message.invitation = nil
        }

        // El nombre visible es el que conoce la room, no el que venga incrustado
        // en el payload enviado por el peer.
        message.senderDisplayName = member.displayName
        message.body = String(message.body.prefix(4_000))
        append(message)

        if let attachment = message.attachment {
            transfers[attachment.transferID] = .offered
        }
    }

    /// Mezcla el historial enviado por el host durante la reanudación. La
    /// deduplicación por UUID hace que sea seguro combinarlo con el replay.
    public func merge(messages: [ChatMessage]) -> Bool {
        var didChange = false

        for original in messages where original.roomID == roomID {
            var message = original
            message.body = String(message.body.prefix(4_000))
            if let invitation = message.invitation, invitation.roomID != roomID {
                message.invitation = nil
            }

            guard append(message) else { continue }
            didChange = true

            if let attachment = message.attachment {
                transfers[attachment.transferID] = .offered
            }
        }

        return didChange
    }

    // MARK: - Sistema y presencia

    public func appendSystemMessage(_ body: String) {
        append(.system(roomID: roomID, body: body))
    }

    public func memberDidJoin(_ member: RoomMember) {
        appendSystemMessage("\(member.displayName) se ha unido.")
    }

    public func memberDidLeave(_ member: RoomMember) {
        appendSystemMessage("\(member.displayName) ha salido.")
    }

    // MARK: - Transferencias

    public func updateTransfer(_ transferID: UUID, state: FileTransferState) {
        transfers[transferID] = state

        guard case .failed(let reason) = state,
              let index = messages.firstIndex(where: { $0.attachment?.transferID == transferID })
        else { return }

        messages[index].body = "No se pudo transferir: \(reason)"
    }

    public func transferState(for transferID: UUID) -> FileTransferState? {
        transfers[transferID]
    }

    public func clearHistory() {
        messages.removeAll()
        seenMessageIDs.removeAll()
        seenMessageDates.removeAll()
        transfers.removeAll()
    }

    // MARK: - Private Helpers

    private func append(_ message: ChatMessage) -> Bool {
        pruneSeenMessageIDs()
        guard seenMessageIDs.insert(message.id).inserted else { return false }
        seenMessageDates[message.id] = Date()
        messages.append(message)
        messages.sort { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        if messages.count > P2PLimits.chatHistoryLimit {
            messages.removeFirst(messages.count - P2PLimits.chatHistoryLimit)
        }
        pruneSeenMessageIDs()
        return true
    }

    private func pruneSeenMessageIDs() {
        let visibleIDs = Set(messages.map(\.id))
        let cutoff = Date().addingTimeInterval(-P2PLimits.recoveryJournalRetention)
        let expiredIDs = seenMessageDates.compactMap { id, date in
            !visibleIDs.contains(id) && date < cutoff ? id : nil
        }

        for id in expiredIDs {
            seenMessageDates.removeValue(forKey: id)
            seenMessageIDs.remove(id)
        }

        let nonVisibleEntries = seenMessageDates.filter { id, _ in
            !visibleIDs.contains(id)
        }
        let excessCount = nonVisibleEntries.count - P2PLimits.recoveryJournalLimit
        guard excessCount > 0 else { return }

        let oldestIDs = nonVisibleEntries
            .sorted { lhs, rhs in
                if lhs.value != rhs.value {
                    return lhs.value < rhs.value
                }
                return lhs.key.uuidString < rhs.key.uuidString
            }
            .prefix(excessCount)
            .map(\.key)

        for id in oldestIDs {
            seenMessageDates.removeValue(forKey: id)
            seenMessageIDs.remove(id)
        }
    }
}
