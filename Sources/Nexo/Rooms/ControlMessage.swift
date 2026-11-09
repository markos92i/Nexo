import Foundation

// MARK: - ControlMessage

/// Mensajes del canal `.control`. Gobiernan el directorio, la membresía de sala
/// y el ciclo de vida de actividades.
///
/// Aprobar la entrada a una sala y aceptar la participación en una actividad son
/// operaciones distintas con mensajes distintos.
public enum ControlMessage: Codable, Sendable {

    // MARK: Directorio

    /// Respuesta con el catálogo completo de salas del emisor. El TXT solo cabe
    /// unas pocas, así que el directorio real se pide tras el handshake.
    case roomDirectory(RoomDirectoryPayload)
    case roomDirectoryRequest

    // MARK: Membresía

    case joinRoomRequest(JoinRoomRequestPayload)
    case joinRoomAccepted(JoinRoomAcceptedPayload)
    case joinRoomRejected(JoinRoomRejectedPayload)
    case leaveRoom(LeaveRoomPayload)
    case roomMembershipChanged(RoomMembershipPayload)
    /// Snapshot autoritativo enviado por el host cuando se restaura una conexión.
    case roomResume(RoomResumePayload)
    /// Nueva autoridad de sala elegida cuando el host anterior se vuelve inalcanzable.
    case roomHostChanged(RoomHostChangedPayload)
    /// Historial de chat, enviado en trozos para completar el snapshot de resume.
    case chatHistory(ChatHistoryPayload)
    case roomClosed(RoomClosedPayload)

    // MARK: Actividades

    case activityStarted(ActivityLifecyclePayload)
    case activityInvite(ActivityLifecyclePayload)
    case activityJoinRequest(ActivityMembershipPayload)
    case activityJoinAccepted(ActivityLifecyclePayload)
    case activityJoinRejected(ActivityRejectionPayload)
    case activityLeft(ActivityMembershipPayload)
    case activityEnded(ActivityEndedPayload)

    var roomID: RoomID? {
        switch self {
        case .roomDirectory, .roomDirectoryRequest: nil
        case .joinRoomRequest(let payload): payload.roomID
        case .joinRoomAccepted(let payload): payload.descriptor.id
        case .joinRoomRejected(let payload): payload.roomID
        case .leaveRoom(let payload): payload.roomID
        case .roomMembershipChanged(let payload): payload.descriptor.id
        case .roomResume(let payload): payload.descriptor.id
        case .roomHostChanged(let payload): payload.descriptor.id
        case .chatHistory(let payload): payload.roomID
        case .roomClosed(let payload): payload.roomID
        case .activityStarted(let payload), .activityInvite(let payload),
             .activityJoinAccepted(let payload): payload.descriptor.roomID
        case .activityJoinRequest(let payload), .activityLeft(let payload): payload.roomID
        case .activityJoinRejected(let payload): payload.roomID
        case .activityEnded(let payload): payload.roomID
        }
    }
}

// MARK: - Payloads de directorio

public struct RoomDirectoryPayload: Codable, Sendable {
    public let hostDisplayName: String
    public let rooms: [RoomDescriptor]

    public init(hostDisplayName: String, rooms: [RoomDescriptor]) {
        self.hostDisplayName = hostDisplayName
        self.rooms = rooms
    }
}

// MARK: - Payloads de membresía

public struct JoinRoomRequestPayload: Codable, Sendable {
    public let roomID: RoomID
    public let displayName: String
    public let avatar: String?
    /// Lo reenvía el host; una respuesta nunca debe completar un intento de join posterior.
    public let requestID: UUID?

    public init(roomID: RoomID, displayName: String, avatar: String? = nil, requestID: UUID? = nil) {
        self.roomID = roomID
        self.displayName = displayName
        self.avatar = avatar
        self.requestID = requestID
    }
}

public struct JoinRoomAcceptedPayload: Codable, Sendable {
    public let descriptor: RoomDescriptor
    public let members: [RoomMember]
    /// Actividades ya vivas en la sala, para que el recién llegado pueda unirse o
    /// al menos verlas.
    public let activities: [ActivityDescriptor]
    public let requestID: UUID?

    public init(
        descriptor: RoomDescriptor,
        members: [RoomMember],
        activities: [ActivityDescriptor],
        requestID: UUID? = nil
    ) {
        self.descriptor = descriptor
        self.members = members
        self.activities = activities
        self.requestID = requestID
    }
}

public struct JoinRoomRejectedPayload: Codable, Sendable {
    public let roomID: RoomID
    public let reason: DisconnectReason
    public let requestID: UUID?

    public init(roomID: RoomID, reason: DisconnectReason, requestID: UUID? = nil) {
        self.roomID = roomID
        self.reason = reason
        self.requestID = requestID
    }
}

public struct LeaveRoomPayload: Codable, Sendable {
    public let roomID: RoomID

    public init(roomID: RoomID) {
        self.roomID = roomID
    }
}

public struct RoomMembershipPayload: Codable, Sendable {
    public let descriptor: RoomDescriptor
    public let members: [RoomMember]

    public init(descriptor: RoomDescriptor, members: [RoomMember]) {
        self.descriptor = descriptor
        self.members = members
    }
}

/// Estado autoritativo de sala usado para recuperar una conexión caída. El host
/// es la única fuente de verdad de la membresía y las actividades.
public struct RoomResumePayload: Codable, Sendable {
    public let descriptor: RoomDescriptor
    public let members: [RoomMember]
    public let activities: [ActivityDescriptor]
    public let chatMessages: [ChatMessage]

    public init(
        descriptor: RoomDescriptor,
        members: [RoomMember],
        activities: [ActivityDescriptor],
        chatMessages: [ChatMessage]
    ) {
        self.descriptor = descriptor
        self.members = members
        self.activities = activities
        self.chatMessages = chatMessages
    }
}

public struct RoomHostChangedPayload: Codable, Sendable {
    public let failedHostDeviceID: DeviceID
    /// Miembros entre el host caído y el host elegido que no estaban disponibles
    /// para el peer elegido cuando tomó la decisión.
    public let skippedDeviceIDs: [DeviceID]
    public let descriptor: RoomDescriptor
    public let members: [RoomMember]
    public let activities: [ActivityDescriptor]

    public init(
        failedHostDeviceID: DeviceID,
        skippedDeviceIDs: [DeviceID],
        descriptor: RoomDescriptor,
        members: [RoomMember],
        activities: [ActivityDescriptor]
    ) {
        self.failedHostDeviceID = failedHostDeviceID
        self.skippedDeviceIDs = skippedDeviceIDs
        self.descriptor = descriptor
        self.members = members
        self.activities = activities
    }
}

/// Un trozo de historial de chat. `roomID` se repite dentro del payload a
/// propósito, para validar el contenido además del envelope de control.
public struct ChatHistoryPayload: Codable, Sendable {
    public let roomID: RoomID
    public let messages: [ChatMessage]

    public init(roomID: RoomID, messages: [ChatMessage]) {
        self.roomID = roomID
        self.messages = messages
    }
}

public struct RoomClosedPayload: Codable, Sendable {
    public let roomID: RoomID
    public let reason: DisconnectReason

    public init(roomID: RoomID, reason: DisconnectReason) {
        self.roomID = roomID
        self.reason = reason
    }
}

// MARK: - Payloads de actividad

public struct ActivityLifecyclePayload: Codable, Sendable {
    public let descriptor: ActivityDescriptor

    public init(descriptor: ActivityDescriptor) {
        self.descriptor = descriptor
    }
}

public struct ActivityMembershipPayload: Codable, Sendable {
    public let roomID: RoomID
    public let activityID: ActivityID
    public let displayName: String

    public init(roomID: RoomID, activityID: ActivityID, displayName: String) {
        self.roomID = roomID
        self.activityID = activityID
        self.displayName = displayName
    }
}

public struct ActivityRejectionPayload: Codable, Sendable {
    public let roomID: RoomID
    public let activityID: ActivityID
    public let reason: DisconnectReason

    public init(roomID: RoomID, activityID: ActivityID, reason: DisconnectReason) {
        self.roomID = roomID
        self.activityID = activityID
        self.reason = reason
    }
}

public struct ActivityEndedPayload: Codable, Sendable {
    public let roomID: RoomID
    public let activityID: ActivityID
    public let reason: DisconnectReason

    public init(roomID: RoomID, activityID: ActivityID, reason: DisconnectReason) {
        self.roomID = roomID
        self.activityID = activityID
        self.reason = reason
    }
}
