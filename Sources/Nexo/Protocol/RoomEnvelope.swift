//
//  RoomEnvelope.swift
//  Nexo
//

import Foundation

// MARK: - RoomChannel

/// Logical channel multiplexed over the physical connection.
public enum RoomChannel: String, Codable, Sendable {
    case control
    case chat
    /// Opaque activity payload. The envelope also carries `activityID`.
    case activity
    case fileTransfer
}

// MARK: - DeliveryMode

/// Priority and drop policy for an envelope.
public enum DeliveryMode: String, Codable, Sendable {
    /// Delivered in order, never dropped.
    case reliable
    /// May be dropped if superseded before leaving the queue.
    ///
    /// Network framework over TCP still delivers everything reliably, so this
    /// doesn't relax the socket's guarantee — it enables latest-wins
    /// coalescing in `TransportSendQueue`, so a stale snapshot never sits in
    /// front of an authoritative order.
    case unreliable
}

// MARK: - RoomEnvelope

/// Application-layer transport unit. Every room, chat, activity or transfer
/// message travels inside one of these.
public struct RoomEnvelope: Codable, Sendable, Identifiable {
    public let protocolVersion: UInt8
    public let roomID: RoomID
    public let activityID: ActivityID?
    public let channel: RoomChannel
    public let messageID: UUID
    public let senderApplicationID: String
    /// Per-sender, per-channel sequence. Enables duplicate/out-of-order detection.
    public let sequence: UInt64?
    public let deliveryMode: DeliveryMode
    /// Coalescing key for `.unreliable` envelopes. Two envelopes sharing a key
    /// are interchangeable: the newest replaces the oldest in the queue.
    public let coalescingKey: String?
    public let payload: Data

    public var id: UUID { messageID }

    public init(
        roomID: RoomID,
        activityID: ActivityID? = nil,
        channel: RoomChannel,
        senderApplicationID: String,
        payload: Data,
        deliveryMode: DeliveryMode = .reliable,
        coalescingKey: String? = nil,
        sequence: UInt64? = nil,
        messageID: UUID = UUID(),
        protocolVersion: UInt8 = P2PProtocolInfo.currentVersion
    ) {
        self.protocolVersion = protocolVersion
        self.roomID = roomID
        self.activityID = activityID
        self.channel = channel
        self.messageID = messageID
        self.senderApplicationID = senderApplicationID
        self.sequence = sequence
        self.deliveryMode = deliveryMode
        self.coalescingKey = coalescingKey
        self.payload = payload
    }

    /// Builds an envelope by encoding the channel's typed message.
    public init<Message: Encodable & Sendable>(
        roomID: RoomID,
        activityID: ActivityID? = nil,
        channel: RoomChannel,
        senderApplicationID: String,
        message: Message,
        deliveryMode: DeliveryMode = .reliable,
        coalescingKey: String? = nil,
        sequence: UInt64? = nil
    ) throws {
        self.init(
            roomID: roomID,
            activityID: activityID,
            channel: channel,
            senderApplicationID: senderApplicationID,
            payload: try P2PCoder.encode(message),
            deliveryMode: deliveryMode,
            coalescingKey: coalescingKey,
            sequence: sequence
        )
    }

    /// Decodes the payload as the type expected by the channel.
    public func decodePayload<Message: Decodable>(as type: Message.Type) throws -> Message {
        try P2PCoder.decode(type, from: payload)
    }

    /// Lane this envelope should be queued on. Control and game orders must
    /// never sit behind a large transfer.
    public var lane: TransportLane {
        switch channel {
        case .control: .control
        case .chat: .interactive
        case .activity: deliveryMode == .unreliable ? .bulkState : .interactive
        case .fileTransfer: .transfer
        }
    }
}

// MARK: - TransportLane

/// Logical lanes within one physical connection, in priority order.
public enum TransportLane: Int, Comparable, Sendable, CaseIterable {
    /// Membership and lifecycle. Always first.
    case control = 0
    /// Chat and authoritative game orders.
    case interactive = 1
    /// Bulky, repetitive state, like board snapshots.
    case bulkState = 2
    /// File chunks. Must never block the others.
    case transfer = 3

    public static func < (lhs: TransportLane, rhs: TransportLane) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - P2PCoder

/// Shared coders. Reusing them avoids allocating a `JSONEncoder` per message,
/// which was the dominant cost when broadcasting snapshots to several peers.
public enum P2PCoder {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}
