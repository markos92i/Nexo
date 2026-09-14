//
//  FileTransferMessage.swift
//  Project Dark
//
//  Created by Marcos del Castillo Camacho on 11/09/2026.
//

import Foundation

// MARK: - FileTransferMessage

/// Mensajes del canal `.fileTransfer`.
///
/// El contenido nunca viaja dentro de un `ChatMessage`: el chat solo transporta
/// los metadatos y el identificador de la transferencia, y el fichero llega por
/// esta secuencia de chunks.
public enum FileTransferMessage: Codable, Sendable {
    case offer(FileOffer)
    case accept(FileTransferControl)
    case reject(FileTransferRejection)
    case cancel(FileTransferRejection)
    /// Confirmación del receptor cada `transferWindowChunks` chunks. Es el
    /// mecanismo de backpressure: el emisor no adelanta la ventana sin ella.
    case acknowledge(FileTransferAcknowledgement)
    case chunk(FileChunk)
    case completed(FileTransferControl)
}

// MARK: - FileOffer

public struct FileOffer: Codable, Sendable, Identifiable, Hashable {
    public let transferID: UUID
    /// Mensaje de chat al que se asocia la transferencia, si viene del chat.
    public let messageID: UUID?
    public let roomID: RoomID
    public let fileName: String
    public let mimeType: String
    public let fileSize: Int64
    /// SHA-256 en hexadecimal del contenido completo.
    public let checksum: String
    public let chunkCount: Int
    public let chunkSize: Int

    public var id: UUID { transferID }

    public var isImage: Bool { mimeType.hasPrefix("image/") }
}

// MARK: - FileChunk

public struct FileChunk: Codable, Sendable {
    public let transferID: UUID
    public let index: Int
    public let data: Data
}

// MARK: - Control payloads

public struct FileTransferControl: Codable, Sendable {
    public let transferID: UUID
    public let roomID: RoomID
}

public struct FileTransferRejection: Codable, Sendable {
    public let transferID: UUID
    public let roomID: RoomID
    public let reason: String
}

public struct FileTransferAcknowledgement: Codable, Sendable {
    public let transferID: UUID
    public let roomID: RoomID
    /// Índice del último chunk escrito en disco por el receptor.
    public let receivedThroughIndex: Int
}

// MARK: - FileTransferState

public enum FileTransferState: Sendable, Equatable {
    case offered
    case accepted
    case transferring(progress: Double)
    case completed(url: URL)
    case failed(String)
    case cancelled

    public var progress: Double {
        switch self {
        case .offered: 0
        case .accepted: 0
        case .transferring(let progress): progress
        case .completed: 1
        case .failed, .cancelled: 0
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        case .offered, .accepted, .transferring: false
        }
    }
}

// MARK: - FileTransferError

public enum FileTransferError: Error, LocalizedError, Sendable {
    case tooLarge(Int64)
    case checksumMismatch
    case cancelled
    case unsupportedType(String)
    case writeFailed(String)
    case incomplete

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let size):
            let limit = ByteCountFormatter.string(fromByteCount: P2PLimits.maximumTransferBytes, countStyle: .file)
            let actual = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            return "El archivo pesa \(actual) y el límite es \(limit)."
        case .checksumMismatch:
            return "El archivo recibido está corrupto."
        case .cancelled:
            return "Transferencia cancelada."
        case .unsupportedType(let mime):
            return "No se admite el tipo de archivo \(mime)."
        case .writeFailed(let reason):
            return reason
        case .incomplete:
            return "La transferencia se interrumpió antes de terminar."
        }
    }
}
