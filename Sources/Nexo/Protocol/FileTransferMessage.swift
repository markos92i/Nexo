import Foundation

// MARK: - FileTransferMessage

/// Mensajes del canal `.fileTransfer`.
///
/// El contenido nunca viaja dentro de un `ChatMessage`: el chat solo lleva
/// metadatos y el ID de transferencia, y el archivo llega por esta secuencia de chunks.
public enum FileTransferMessage: Codable, Sendable, Equatable {
    case offer(FileOffer)
    case accept(FileTransferControl)
    case reject(FileTransferRejection)
    case cancel(FileTransferRejection)
    /// Confirmación del receptor cada `transferWindowChunks` chunks. Es el
    /// mecanismo de backpressure: el emisor no avanza la ventana sin ella.
    case acknowledge(FileTransferAcknowledgement)
    case chunk(FileChunk)
    case completed(FileTransferControl)
}

// MARK: - FileOffer

public struct FileOffer: Codable, Sendable, Identifiable, Hashable {
    public let transferID: UUID
    /// Mensaje de chat al que se adjunta esta transferencia, si vino del chat.
    public let messageID: UUID?
    public let roomID: RoomID
    public let fileName: String
    public let mimeType: String
    public let fileSize: Int64
    /// SHA-256 hex del contenido completo.
    public let checksum: String
    public let chunkCount: Int
    public let chunkSize: Int

    public var id: UUID { transferID }

    public var isImage: Bool { mimeType.hasPrefix("image/") }

    public init(
        transferID: UUID,
        messageID: UUID?,
        roomID: RoomID,
        fileName: String,
        mimeType: String,
        fileSize: Int64,
        checksum: String,
        chunkCount: Int,
        chunkSize: Int
    ) {
        self.transferID = transferID
        self.messageID = messageID
        self.roomID = roomID
        self.fileName = fileName
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.checksum = checksum
        self.chunkCount = chunkCount
        self.chunkSize = chunkSize
    }
}

// MARK: - FileChunk

public struct FileChunk: Codable, Sendable, Equatable {
    public let transferID: UUID
    public let index: Int
    public let data: Data

    public init(transferID: UUID, index: Int, data: Data) {
        self.transferID = transferID
        self.index = index
        self.data = data
    }
}

// MARK: - Payloads de control

public struct FileTransferControl: Codable, Sendable, Equatable {
    public let transferID: UUID
    public let roomID: RoomID

    public init(transferID: UUID, roomID: RoomID) {
        self.transferID = transferID
        self.roomID = roomID
    }
}

public struct FileTransferRejection: Codable, Sendable, Equatable {
    public let transferID: UUID
    public let roomID: RoomID
    public let reason: DisconnectReason

    public init(transferID: UUID, roomID: RoomID, reason: DisconnectReason) {
        self.transferID = transferID
        self.roomID = roomID
        self.reason = reason
    }
}

public struct FileTransferAcknowledgement: Codable, Sendable, Equatable {
    public let transferID: UUID
    public let roomID: RoomID
    /// Índice del último chunk que el receptor escribió en disco.
    public let receivedThroughIndex: Int

    public init(transferID: UUID, roomID: RoomID, receivedThroughIndex: Int) {
        self.transferID = transferID
        self.roomID = roomID
        self.receivedThroughIndex = receivedThroughIndex
    }
}

// MARK: - FileTransferError

/// Fallos en la transferencia de archivos. Es `Codable` para poder viajar en el
/// protocolo (p. ej. dentro de una razón de rechazo).
public enum FileTransferError: Error, Codable, Sendable, Equatable {
    case featureUnavailable
    case tooLarge(Int64)
    case checksumMismatch
    case cancelled
    case unsupportedType(String)
    case writeFailed(DisconnectReason)
    case incomplete
    case bufferOverflow
    case resourceLimit
    case timedOut
    case invalidOffer
    case binaryStreamsUnsupported
}

/// Una entrega mixta no es una entrega correcta a toda la sala.
public enum FileTransferRecipientOutcome: Sendable, Equatable {
    case pending
    case completed
    case rejected(DisconnectReason)
}

// MARK: - FileTransferLimits

public enum FileTransferLimits {
    public static let maximumOpenTransfers = 16
    public static let maximumOpenTransfersPerPeer = 4
    public static let maximumStoredTransfers = 256
    public static let maximumReservedBytes: Int64 = 200 * 1024 * 1024
    public static let maximumReservedBytesPerPeer: Int64 = 75 * 1024 * 1024
    public static let maximumTerminalStates = 128
    public static let inactivityTimeout: Duration = .seconds(60)
}
