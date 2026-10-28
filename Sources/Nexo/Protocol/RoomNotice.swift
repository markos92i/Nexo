import Foundation

// MARK: - RoomNotice

/// Avisos de dominio emitidos por la capa de salas para superficies de UI
/// globales de la app (p. ej. una bandeja de solicitudes o invitaciones).
public enum RoomNotice: Sendable {
    case joinRequest(JoinRequestNotice)
    /// La solicitud salió de la cola: se respondió (en esta u otra pantalla), el
    /// invitado la retiró, se desconectó o la sala se cerró. La UI que la
    /// mostraba debe retirarla.
    case joinRequestResolved(JoinRequestNotice)
    case activityInvitation(ActivityInvitationNotice)
    case roomClosed(RoomClosedNotice)
}

extension RoomNotice {
    /// Sala a la que se refiere el aviso.
    public var roomID: RoomID {
        switch self {
        case .joinRequest(let notice), .joinRequestResolved(let notice): notice.roomID
        case .activityInvitation(let notice): notice.roomID
        case .roomClosed(let notice): notice.roomID
        }
    }
}

// MARK: - Payloads

public struct JoinRequestNotice: Sendable, Equatable {
    public let requestID: UUID
    public let roomID: RoomID
    public let displayName: String

    public init(requestID: UUID, roomID: RoomID, displayName: String) {
        self.requestID = requestID
        self.roomID = roomID
        self.displayName = displayName
    }
}

public struct ActivityInvitationNotice: Sendable, Equatable {
    public let activityID: ActivityID
    public let roomID: RoomID
    public let kind: ActivityKind
    public let hostDisplayName: String

    public init(activityID: ActivityID, roomID: RoomID, kind: ActivityKind, hostDisplayName: String) {
        self.activityID = activityID
        self.roomID = roomID
        self.kind = kind
        self.hostDisplayName = hostDisplayName
    }
}

public struct RoomClosedNotice: Sendable, Equatable {
    public let roomID: RoomID
    public let reason: DisconnectReason

    public init(roomID: RoomID, reason: DisconnectReason) {
        self.roomID = roomID
        self.reason = reason
    }
}
