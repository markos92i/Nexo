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
    /// El host ya no se anuncia o su anuncio no coincide con la sala.
    case peerUnavailable
    /// No se pudo abrir la conexión con el host.
    case hostUnreachable(DisconnectReason)
    /// La conexión con el host se cortó mientras se esperaba su respuesta.
    case connectionLost
    case joinRejected(DisconnectReason)
    /// El host no respondió a tiempo a la solicitud de entrada.
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

/// Razón por la que una conexión, sala o actividad se corta o rechaza.
///
/// Viaja dentro de mensajes de control y se muestra en la UI, por eso es
/// `Codable`, `Sendable` y `Equatable`.
public enum DisconnectReason: Error, Codable, Sendable, Equatable {
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

    /// Traduce un error arbitrario a una razón de corte, conservando los
    /// `DisconnectReason` y `TransportError` ya tipados.
    public init(error: any Error) {
        switch error {
        case let reason as DisconnectReason:
            self = reason
        case let transport as TransportError:
            self = transport.disconnectReason
        default:
            let nsError = error as NSError
            self = .system(domain: nsError.domain, code: nsError.code)
        }
    }
}
