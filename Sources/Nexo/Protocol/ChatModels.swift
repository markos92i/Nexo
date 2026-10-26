import Foundation

// MARK: - ChatMessageKind

public enum ChatMessageKind: String, Codable, Sendable {
    case text
    /// Aviso de visualización solo-app; nunca se acepta en el historial de sala.
    case systemInfo
    /// Mensaje con adjunto. El contenido llega por el canal de transferencia.
    case attachment
}

// MARK: - ChatActivityInvitation

/// Referencia a una actividad ya creada, presentada como invitación de chat. El
/// anuncio de control sigue siendo la autoridad de la actividad; este payload
/// solo guarda una referencia para renderizarla como burbuja.
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

/// Metadatos de un adjunto que viajan en un mensaje de chat.
///
/// El contenido **no** viaja aquí: solo la descripción y el `transferID` usado
/// para emparejar chunks en el canal `.fileTransfer`.
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
    public let senderDeviceID: DeviceID
    public var senderDisplayName: String
    public var body: String
    public let kind: ChatMessageKind
    public var attachment: ChatAttachment?
    /// Opcional, para que mensajes de peers antiguos sigan decodificando como texto.
    public var invitation: ChatActivityInvitation?
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        roomID: RoomID,
        senderDeviceID: DeviceID,
        senderDisplayName: String,
        body: String,
        kind: ChatMessageKind = .text,
        attachment: ChatAttachment? = nil,
        invitation: ChatActivityInvitation? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.roomID = roomID
        self.senderDeviceID = senderDeviceID
        self.senderDisplayName = senderDisplayName
        self.body = body
        self.kind = kind
        self.attachment = attachment
        self.invitation = invitation
        self.timestamp = timestamp
    }

    public var isSystem: Bool { kind == .systemInfo }

    public static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool { lhs.id == rhs.id }
}
