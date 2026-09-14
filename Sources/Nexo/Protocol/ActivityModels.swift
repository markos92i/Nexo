//
//  ActivityModels.swift
//  Nexo
//

import Foundation

// MARK: - ActivityID

/// Identifies one activity instance within a room. A room can host several
/// live activities, and a rematch gets a new ID.
public struct ActivityID: Hashable, Codable, Sendable, Identifiable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var id: UUID { rawValue }
    public var description: String { rawValue.uuidString }
}

// MARK: - ActivityKind

/// Open identifier for an activity type.
///
/// Nexo ships none: each game declares its own `static let` in its own module,
/// e.g. `extension ActivityKind { static let sudoku = ActivityKind("sudoku") }`.
/// Title, icon and other presentation metadata belong in the app's catalog,
/// never here.
public struct ActivityKind: RawRepresentable, Hashable, Codable, Sendable, Identifiable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var id: String { rawValue }
}

// MARK: - ActivityState

public enum ActivityState: String, Codable, Sendable {
    case lobby
    case running
    /// Finished; the UI shows the result before it's torn down.
    case finished
    case cancelled
}

// MARK: - ActivityDescriptor

/// Transportable description of an activity.
public struct ActivityDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let id: ActivityID
    public let roomID: RoomID
    public let kind: ActivityKind
    /// Authority for this activity. May differ from the room's host.
    public let hostApplicationID: String
    public var participantIDs: Set<String>
    public var state: ActivityState
    /// `true` if open to the whole room, so members who join later are
    /// auto-admitted while still `.lobby`. `false` if the host hand-picked
    /// the participants.
    public let admitsRoomMembers: Bool
    /// `true` if only one instance of this kind can be active at a time in the
    /// room (a game). `false` if it can run alongside any other active
    /// activity (e.g. chat).
    public let isExclusive: Bool

    public init(
        id: ActivityID = ActivityID(),
        roomID: RoomID,
        kind: ActivityKind,
        hostApplicationID: String,
        participantIDs: Set<String>,
        state: ActivityState = .lobby,
        admitsRoomMembers: Bool = true,
        isExclusive: Bool = true
    ) {
        self.id = id
        self.roomID = roomID
        self.kind = kind
        self.hostApplicationID = hostApplicationID
        self.participantIDs = participantIDs
        self.state = state
        self.admitsRoomMembers = admitsRoomMembers
        self.isExclusive = isExclusive
    }

    /// Lenient decoding for peers that don't send the newer fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ActivityID.self, forKey: .id)
        roomID = try container.decode(RoomID.self, forKey: .roomID)
        kind = try container.decode(ActivityKind.self, forKey: .kind)
        hostApplicationID = try container.decode(String.self, forKey: .hostApplicationID)
        participantIDs = try container.decode(Set<String>.self, forKey: .participantIDs)
        state = try container.decode(ActivityState.self, forKey: .state)
        admitsRoomMembers = try container.decodeIfPresent(Bool.self, forKey: .admitsRoomMembers) ?? true
        isExclusive = try container.decodeIfPresent(Bool.self, forKey: .isExclusive) ?? true
    }

    public func includes(_ applicationID: String) -> Bool {
        participantIDs.contains(applicationID)
    }

    public var isActive: Bool { state == .lobby || state == .running }
}
