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
    /// New room authority elected after the previous host became unreachable.
    case roomHostChanged(RoomHostChangedPayload)
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

// MARK: - Directory Payloads

public struct RoomDirectoryPayload: Codable, Sendable {
    public let hostDisplayName: String
    public let rooms: [RoomDescriptor]
}

// MARK: - Membership Payloads

public struct JoinRoomRequestPayload: Codable, Sendable {
    public let roomID: RoomID
    public let displayName: String
    public let avatar: String?
    /// Echoed by the host; a reply must never complete a later join attempt.
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
    /// Activities already live in the room, so the newcomer can join or at
    /// least see them.
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
    public let reason: NexoReason
    public let requestID: UUID?

    public init(roomID: RoomID, reason: NexoReason, requestID: UUID? = nil) {
        self.roomID = roomID
        self.reason = reason
        self.requestID = requestID
    }
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

public struct RoomHostChangedPayload: Codable, Sendable {
    public let failedHostApplicationID: String
    /// Members between the failed host and elected host that were unavailable
    /// to the elected peer when it made the choice.
    public let skippedApplicationIDs: [String]
    public let descriptor: RoomDescriptor
    public let members: [RoomMember]
    public let activities: [ActivityDescriptor]

    public init(
        failedHostApplicationID: String,
        skippedApplicationIDs: [String],
        descriptor: RoomDescriptor,
        members: [RoomMember],
        activities: [ActivityDescriptor]
    ) {
        self.failedHostApplicationID = failedHostApplicationID
        self.skippedApplicationIDs = skippedApplicationIDs
        self.descriptor = descriptor
        self.members = members
        self.activities = activities
    }
}

/// A chunk of chat history. `roomID` is deliberately repeated inside the
/// payload to validate content in addition to the control envelope.
public struct ChatHistoryPayload: Codable, Sendable {
    public let roomID: RoomID
    public let messages: [ChatMessage]
}

public struct RoomClosedPayload: Codable, Sendable {
    public let roomID: RoomID
    public let reason: NexoReason
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
    public let reason: NexoReason
}

public struct ActivityEndedPayload: Codable, Sendable {
    public let roomID: RoomID
    public let activityID: ActivityID
    public let reason: NexoReason
}

// MARK: - Errors

public enum RoomError: Error, Sendable, Equatable {
    case roomNotFound
    case roomFull
    case notAMember
    case notHost
    case featureUnavailable(RoomFeatures)
    case activityUnsupported(ActivityKind)
    case peerUnavailable
    case joinRejected(NexoReason)
    case joinTimedOut
    case activityNotFound
    case activityAlreadyRunning
    case incompatibleProtocol(UInt8)
    case transportFailure(NexoReason)
}
