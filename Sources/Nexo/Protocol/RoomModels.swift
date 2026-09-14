//
//  RoomModels.swift
//  Nexo
//

import Foundation

// MARK: - RoomID

/// Logical identifier for a room, independent of transport: it doesn't derive
/// from a Bonjour endpoint or a specific connection, so it survives
/// reconnects and can travel inside messages.
public struct RoomID: Hashable, Codable, Sendable, Identifiable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    /// Reconstructs a `RoomID` published in a TXT record or a message.
    public init?(string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.rawValue = uuid
    }

    public var id: UUID { rawValue }
    public var description: String { rawValue.uuidString }

    /// Short form for debugging or as a human-readable room code.
    public var shortCode: String {
        String(rawValue.uuidString.prefix(8))
    }
}

// MARK: - RoomRole

public enum RoomRole: String, Codable, Sendable {
    /// Authority for the room: admits members, closes it, arbitrates activities.
    case host
    case guest
}

// MARK: - RoomAccessPolicy

public enum RoomAccessPolicy: String, Codable, Sendable, CaseIterable {
    /// Any peer that discovers the room joins directly.
    case open
    /// The host must approve every join request.
    case approval

    public var localizedTitle: String {
        switch self {
        case .open: "Abierta"
        case .approval: "Con aprobación"
        }
    }
}

// MARK: - RoomFeatures

/// Capabilities active in a given room.
///
/// This is what makes the model flexible: a chat-only room, a game-only room
/// and a mixed room are the same entity with different flags.
public struct RoomFeatures: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let chat = RoomFeatures(rawValue: 1 << 0)
    public static let activities = RoomFeatures(rawValue: 1 << 1)
    public static let fileTransfer = RoomFeatures(rawValue: 1 << 2)

    public static let chatOnly: RoomFeatures = [.chat, .fileTransfer]
    public static let gameOnly: RoomFeatures = [.activities]
    public static let full: RoomFeatures = [.chat, .activities, .fileTransfer]

    public var hasChat: Bool { contains(.chat) }
    public var hasActivities: Bool { contains(.activities) }
    public var hasFileTransfer: Bool { contains(.fileTransfer) }
}

// MARK: - RoomMember

public struct RoomMember: Codable, Hashable, Sendable, Identifiable {
    /// Stable identity of the remote installation, not a transport ID.
    public let applicationID: String
    public let displayName: String
    public let role: RoomRole

    public var id: String { applicationID }

    public init(applicationID: String, displayName: String, role: RoomRole) {
        self.applicationID = applicationID
        self.displayName = displayName
        self.role = role
    }

    public var isHost: Bool { role == .host }
}

// MARK: - RoomDescriptor

/// Transportable description of a room. Contains no Network framework types.
public struct RoomDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let id: RoomID
    public var name: String
    /// Application identity of the host that created and governs it.
    public let hostApplicationID: String
    public var features: RoomFeatures
    /// Primary intended activity. A game room declares this so discovery can
    /// filter by game without connecting.
    public var activityKind: ActivityKind?
    public var accessPolicy: RoomAccessPolicy
    public var memberCount: Int
    /// `nil` means no limit declared by the product.
    public var capacity: Int?
    public let protocolVersion: UInt8

    public init(
        id: RoomID = RoomID(),
        name: String,
        hostApplicationID: String,
        features: RoomFeatures,
        activityKind: ActivityKind? = nil,
        accessPolicy: RoomAccessPolicy = .open,
        memberCount: Int = 1,
        capacity: Int? = nil,
        protocolVersion: UInt8 = P2PProtocolInfo.currentVersion
    ) {
        self.id = id
        self.name = name
        self.hostApplicationID = hostApplicationID
        self.features = features
        self.activityKind = activityKind
        self.accessPolicy = accessPolicy
        self.memberCount = memberCount
        self.capacity = capacity
        self.protocolVersion = protocolVersion
    }

    public var isFull: Bool {
        guard let capacity else { return false }
        return memberCount >= capacity
    }

    public var requiresApproval: Bool { accessPolicy == .approval }
}

// MARK: - RoomAccessState

/// State of the local user's relationship with a room.
public enum RoomAccessState: Equatable, Sendable {
    /// Discovered but not requested.
    case available
    /// Request sent, awaiting the host's decision.
    case awaitingApproval
    case joined
    /// The physical connection to the host is suspended (e.g. backgrounded).
    case suspended
    /// Retrying to recover membership.
    case reconnecting
    /// The host rejected entry or removed the member.
    case rejected(reason: String)
    /// The room closed or the host disappeared.
    case closed(reason: String)

    public var isUsable: Bool { self == .joined }
}

// MARK: - RoomJoinRequest

/// A pending join request. Scoped per room, not global: a host can have
/// several rooms with independent queues.
public struct RoomJoinRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let roomID: RoomID
    public let applicationID: String
    public let displayName: String
    public let receivedAt: Date

    public init(
        id: UUID = UUID(),
        roomID: RoomID,
        applicationID: String,
        displayName: String,
        receivedAt: Date = Date()
    ) {
        self.id = id
        self.roomID = roomID
        self.applicationID = applicationID
        self.displayName = displayName
        self.receivedAt = receivedAt
    }
}

// MARK: - DiscoveredRoom

/// A room advertised by a nearby peer, not yet joined. Combines the published
/// descriptor with the transport identifier needed to connect.
public struct DiscoveredRoom: Identifiable, Sendable, Equatable {
    public let descriptor: RoomDescriptor
    /// Peer advertising the room. May be the host or a member relaying it.
    public let advertisedBy: TransportPeerID
    public let hostDisplayName: String
    public let discoveredAt: Date

    public var id: RoomID { descriptor.id }
    public var name: String { descriptor.name }
    public var features: RoomFeatures { descriptor.features }
    public var activityKind: ActivityKind? { descriptor.activityKind }
}
