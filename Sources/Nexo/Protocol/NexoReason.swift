//
//  NexoReason.swift
//  Nexo
//

import Foundation

public enum NexoReason: Error, Codable, Sendable, Equatable {
    case leftRoom
    case hostClosed
    case hostRejected
    case roomUnavailable
    case roomFull
    case activityInactive
    case activityAlreadyStarted
    case activityLeft
    case hostConnectionLost
    case sessionEnded
    case identityRejected
    case identityChangeRejected
    case transportStopped
    case connectionClosed
    case binaryStreamsUnsupported
    case peerDisconnected
    case incompleteHello
    case invalidIdentity
    case duplicateConnection
    case senderCancelled
    case receiverCancelled
    case fileReadFailed
    case filePrepareFailed
    case localCopyFailed
    case invalidOffer
    case fileTooLarge(Int64)
    case checksumMismatch
    case connectionFailed
    case handshakeFailed
    case handshakeTimedOut
    case incompatibleProtocol(UInt8)
    case envelopeTooLarge(Int)
    case system(domain: String, code: Int)

    public init(error: any Error) {
        if let reason = error as? NexoReason {
            self = reason
        } else if let error = error as? P2PTransportError {
            switch error {
            case .peerNotDiscovered, .notConnected: self = .peerDisconnected
            case .handshakeTimedOut: self = .handshakeTimedOut
            case .handshakeFailed(let reason), .connectionFailed(let reason): self = reason
            case .incompatibleProtocol(let version): self = .incompatibleProtocol(version)
            case .envelopeTooLarge(let size): self = .envelopeTooLarge(size)
            case .transportStopped: self = .transportStopped
            }
        } else {
            let error = error as NSError
            self = .system(domain: error.domain, code: error.code)
        }
    }
}
