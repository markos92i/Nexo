import Foundation

// MARK: - TransportError

/// Fallos en la capa de transporte física.
public enum TransportError: Error, Sendable, Equatable {
    case peerNotDiscovered
    case notConnected
    case handshakeTimedOut
    case handshakeFailed(DisconnectReason)
    case incompatibleProtocol(UInt8)
    case envelopeTooLarge(Int)
    case transportStopped
    case connectionFailed(DisconnectReason)

    /// Razón de corte equivalente, para cruzar a capas superiores o a la UI.
    var disconnectReason: DisconnectReason {
        switch self {
        case .peerNotDiscovered, .notConnected: .peerDisconnected
        case .handshakeTimedOut: .handshakeTimedOut
        case .handshakeFailed(let reason), .connectionFailed(let reason): reason
        case .incompatibleProtocol(let version): .incompatibleProtocol(version)
        case .envelopeTooLarge(let size): .envelopeTooLarge(size)
        case .transportStopped: .transportStopped
        }
    }
}

// MARK: - RoomError

/// Fallos en operaciones de sala expuestas al consumidor.
public enum RoomError: Error, Sendable, Equatable {
    case roomNotFound
    case roomFull
    case notAMember
    case notHost
    case featureUnavailable(RoomFeatures)
    case activityUnsupported(ActivityKind)
    case peerUnavailable
    case joinRejected(DisconnectReason)
    case joinTimedOut
    case activityNotFound
    case activityAlreadyRunning
    case incompatibleProtocol(UInt8)
    case transportFailure(DisconnectReason)
}

// MARK: - IdentityError

/// Fallos al crear o recuperar la identidad local del dispositivo.
public enum IdentityError: Error, Sendable, Equatable {
    case incompleteKeychainState
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case invalidStoredData
}

// Nota: `FileTransferError` se define junto a los mensajes de transferencia en
// Transfer/FileTransferMessage.swift (fase 6), por quedar más cohesionado con su
// dominio y ser `Codable` para viajar en el protocolo.
