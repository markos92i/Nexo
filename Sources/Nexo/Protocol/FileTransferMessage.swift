//
//  FileTransferMessage.swift
//  Nexo
//

import Foundation

// MARK: - FileTransferMessage

/// Messages on the `.fileTransfer` channel.
///
/// Content never travels inside a `ChatMessage`: chat only carries metadata
/// and the transfer ID, and the file itself arrives through this chunk sequence.
public enum FileTransferMessage: Codable, Sendable, Equatable {
    case offer(FileOffer)
    case accept(FileTransferControl)
    case reject(FileTransferRejection)
    case cancel(FileTransferRejection)
    /// Receiver acknowledgement every `transferWindowChunks` chunks. This is
    /// the backpressure mechanism: the sender won't advance the window without it.
    case acknowledge(FileTransferAcknowledgement)
    case chunk(FileChunk)
    case completed(FileTransferControl)
}

// MARK: - FileOffer

public struct FileOffer: Codable, Sendable, Identifiable, Hashable {
    public let transferID: UUID
    /// Chat message this transfer is attached to, if it came from chat.
    public let messageID: UUID?
    public let roomID: RoomID
    public let fileName: String
    public let mimeType: String
    public let fileSize: Int64
    /// Hex SHA-256 of the full content.
    public let checksum: String
    public let chunkCount: Int
    public let chunkSize: Int

    public var id: UUID { transferID }

    public var isImage: Bool { mimeType.hasPrefix("image/") }
}

// MARK: - FileChunk

public struct FileChunk: Codable, Sendable, Equatable {
    public let transferID: UUID
    public let index: Int
    public let data: Data
}

// MARK: - Control payloads

public struct FileTransferControl: Codable, Sendable, Equatable {
    public let transferID: UUID
    public let roomID: RoomID
}

public struct FileTransferRejection: Codable, Sendable, Equatable {
    public let transferID: UUID
    public let roomID: RoomID
    public let reason: NexoReason
}

public struct FileTransferAcknowledgement: Codable, Sendable, Equatable {
    public let transferID: UUID
    public let roomID: RoomID
    /// Index of the last chunk the receiver wrote to disk.
    public let receivedThroughIndex: Int
}

// MARK: - FileTransferState

public enum FileTransferState: Codable, Sendable, Equatable {
    case offered
    case accepted
    case transferring(progress: Double)
    case completed(url: URL)
    case failed(NexoReason)
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

public enum FileTransferError: Error, Codable, Sendable, Equatable {
    case tooLarge(Int64)
    case checksumMismatch
    case cancelled
    case unsupportedType(String)
    case writeFailed(NexoReason)
    case incomplete
    case bufferOverflow
    case resourceLimit
    case timedOut
}

/// A mixed delivery is not a successful delivery to the whole room.
public enum FileTransferRecipientOutcome: Sendable, Equatable {
    case pending
    case completed
    case rejected(NexoReason)
}

public enum FileTransferLimits {
    public static let maximumOpenTransfers = 16
    public static let maximumOpenTransfersPerPeer = 4
    public static let maximumStoredTransfers = 256
    public static let maximumReservedBytes: Int64 = 200 * 1024 * 1024
    public static let maximumReservedBytesPerPeer: Int64 = 75 * 1024 * 1024
    public static let maximumTerminalStates = 128
    public static let inactivityTimeout: Duration = .seconds(60)
}
