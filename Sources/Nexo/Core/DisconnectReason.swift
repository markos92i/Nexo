import Foundation

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
