import Foundation

// MARK: - RoomNotice

/// Avisos de dominio emitidos por la capa de salas para superficies de UI
/// globales de la app (p. ej. una bandeja de solicitudes o invitaciones).
public enum RoomNotice: Sendable {
    case joinRequest(JoinRequestNotice)
    case activityInvitation(ActivityInvitationNotice)
    case roomClosed(RoomClosedNotice)
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
