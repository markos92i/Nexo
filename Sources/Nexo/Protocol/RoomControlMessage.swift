//
//  RoomControlMessage.swift
//  Nexo
//

import Foundation

// MARK: - RoomControlMessage

/// Messages on the `.control` channel. Govern the directory, room membership
/// and activity lifecycle.
///
/// Approving entry to a room and accepting participation in an activity are
/// distinct operations with distinct messages.
public enum RoomControlMessage: Codable, Sendable {

    // MARK: Directory

    /// Response with the sender's full room catalog. The TXT record only fits
    /// a few, so the real directory is requested after the handshake.
    case roomDirectory(RoomDirectoryPayload)
    case roomDirectoryRequest

    // MARK: Membership

    case joinRoomRequest(JoinRoomRequestPayload)
    case joinRoomAccepted(JoinRoomAcceptedPayload)
    case joinRoomRejected(JoinRoomRejectedPayload)
    case leaveRoom(LeaveRoomPayload)
    case roomMembershipChanged(RoomMembershipPayload)
    /// Authoritative snapshot sent by the host when a connection is restored.
    case roomResume(RoomResumePayload)
    /// Chat history, sent in chunks to complete the short resume snapshot.
    case chatHistory(ChatHistoryPayload)
    case roomClosed(RoomClosedPayload)

    // MARK: Activities

    case activityStarted(ActivityLifecyclePayload)
    case activityInvite(ActivityLifecyclePayload)
    case activityJoinRequest(ActivityMembershipPayload)
    case activityJoinAccepted(ActivityLifecyclePayload)
    case activityJoinRejected(ActivityRejectionPayload)
    case activityLeft(ActivityMembershipPayload)
    case activityEnded(ActivityEndedPayload)
}

// MARK: - Directory Payloads

public struct RoomDirectoryPayload: Codable, Sendable {
    public let hostDisplayName: String
    public let rooms: [RoomDescriptor]
}

// MARK: - Membership Payloads

public struct JoinRoomRequestPayload: Codable, Sendable {
    public let roomID: RoomID
    public let displayName: String
}

public struct JoinRoomAcceptedPayload: Codable, Sendable {
    public let descriptor: RoomDescriptor
    public let members: [RoomMember]
    /// Activities already live in the room, so the newcomer can join or at
    /// least see them.
    public let activities: [ActivityDescriptor]
}

public struct JoinRoomRejectedPayload: Codable, Sendable {
    public let roomID: RoomID
    public let reason: String
}

public struct LeaveRoomPayload: Codable, Sendable {
    public let roomID: RoomID
}

public struct RoomMembershipPayload: Codable, Sendable {
    public let descriptor: RoomDescriptor
    public let members: [RoomMember]
}

/// Authoritative room state used to recover a connection that was down. The
/// host is the single source of truth for membership and activities.
public struct RoomResumePayload: Codable, Sendable {
    public let descriptor: RoomDescriptor
    public let members: [RoomMember]
    public let activities: [ActivityDescriptor]
    public let chatMessages: [ChatMessage]
}

/// A chunk of chat history. `roomID` is deliberately repeated inside the
/// payload to validate content in addition to the control envelope.
public struct ChatHistoryPayload: Codable, Sendable {
    public let roomID: RoomID
    public let messages: [ChatMessage]
}

public struct RoomClosedPayload: Codable, Sendable {
    public let roomID: RoomID
    public let reason: String
}

// MARK: - Activity Payloads

public struct ActivityLifecyclePayload: Codable, Sendable {
    public let descriptor: ActivityDescriptor
}

public struct ActivityMembershipPayload: Codable, Sendable {
    public let roomID: RoomID
    public let activityID: ActivityID
    public let displayName: String
}

public struct ActivityRejectionPayload: Codable, Sendable {
    public let roomID: RoomID
    public let activityID: ActivityID
    public let reason: String
}

public struct ActivityEndedPayload: Codable, Sendable {
    public let roomID: RoomID
    public let activityID: ActivityID
    public let reason: String
}

// MARK: - Errors

public enum RoomError: Error, LocalizedError, Sendable, Equatable {
    case roomNotFound
    case roomFull
    case notAMember
    case notHost
    case featureUnavailable(String)
    case peerUnavailable
    case joinRejected(String)
    case joinTimedOut
    case activityNotFound
    case activityAlreadyRunning
    case incompatibleProtocol(UInt8)
    case transportFailure(String)

    public var errorDescription: String? {
        switch self {
        case .roomNotFound:
            "La sala ya no está disponible."
        case .roomFull:
            "La sala está completa."
        case .notAMember:
            "No perteneces a esta sala."
        case .notHost:
            "Solo el anfitrión puede hacer esto."
        case .featureUnavailable(let feature):
            "Esta sala no admite \(feature)."
        case .peerUnavailable:
            "No se ha podido contactar con el dispositivo."
        case .joinRejected(let reason):
            reason
        case .joinTimedOut:
            "El anfitrión no ha respondido a tiempo."
        case .activityNotFound:
            "La partida ya no está activa."
        case .activityAlreadyRunning:
            "Ya hay una partida en curso en esta sala."
        case .incompatibleProtocol(let version):
            "La versión del protocolo del otro dispositivo (\(version)) no es compatible."
        case .transportFailure(let reason):
            reason
        }
    }
}
