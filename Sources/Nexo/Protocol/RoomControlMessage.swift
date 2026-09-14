//
//  RoomControlMessage.swift
//  Project Dark
//
//  Created by Marcos del Castillo Camacho on 11/09/2026.
//

import Foundation

// MARK: - RoomControlMessage

/// Mensajes del canal `.control`. Gobiernan el directorio, la membresía de rooms
/// y el ciclo de vida de las actividades.
///
/// La aprobación de entrada a una room y la aceptación de participar en una
/// actividad son operaciones distintas y tienen mensajes distintos.
public enum RoomControlMessage: Codable, Sendable {

    // MARK: Directorio

    /// Respuesta con el catálogo completo de rooms que hospeda el emisor.
    /// El registro TXT solo cabe unas pocas, así que el directorio real se pide
    /// después del handshake.
    case roomDirectory(RoomDirectoryPayload)
    /// Petición explícita del directorio del peer.
    case roomDirectoryRequest

    // MARK: Membresía

    case joinRoomRequest(JoinRoomRequestPayload)
    case joinRoomAccepted(JoinRoomAcceptedPayload)
    case joinRoomRejected(JoinRoomRejectedPayload)
    case leaveRoom(LeaveRoomPayload)
    case roomMembershipChanged(RoomMembershipPayload)
    /// Snapshot autoritativo enviado por el host al restablecer una conexión.
    case roomResume(RoomResumePayload)
    /// Historial de chat, enviado en chunks para completar el snapshot corto.
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
    /// Actividades ya vivas en la room, para que el recién llegado pueda
    /// incorporarse o al menos mostrarlas.
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

/// Estado autoritativo de una room para recuperar una conexión que estuvo caída.
/// El host es la única fuente de verdad de membresía y actividades.
public struct RoomResumePayload: Codable, Sendable {
    public let descriptor: RoomDescriptor
    public let members: [RoomMember]
    public let activities: [ActivityDescriptor]
    public let chatMessages: [ChatMessage]
}

/// Un chunk de historial de chat. El `roomID` se repite deliberadamente dentro
/// del payload para validar el contenido además del envelope de control.
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
