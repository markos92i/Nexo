//
//  P2PNotice.swift
//  Project Dark
//
//  Domain notices emitted by the P2P layer for app-wide UI surfaces.
//

import Foundation

// MARK: - P2PNotice

public enum P2PNotice: Sendable {
    case joinRequest(P2PJoinRequestNotice)
    case activityInvitation(P2PActivityInvitationNotice)
    case roomClosed(P2PRoomClosedNotice)
}

// MARK: - Payloads

public struct P2PJoinRequestNotice: Sendable, Equatable {
    public let requestID: UUID
    public let roomID: RoomID
    public let displayName: String
}

public struct P2PActivityInvitationNotice: Sendable, Equatable {
    public let activityID: ActivityID
    public let roomID: RoomID
    public let kind: ActivityKind
    public let hostDisplayName: String
}

public struct P2PRoomClosedNotice: Sendable, Equatable {
    public let roomID: RoomID
    public let reason: String
}
