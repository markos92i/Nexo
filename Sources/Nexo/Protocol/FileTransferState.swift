import Foundation

// MARK: - FileTransferState

/// Estado observable de una transferencia de archivo.
public enum FileTransferState: Codable, Sendable, Equatable {
    case offered
    case accepted
    case transferring(progress: Double)
    case completed(url: URL)
    case failed(DisconnectReason)
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
