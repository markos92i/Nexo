//
//  TransportModels.swift
//  Nexo
//

import Foundation

// MARK: - TransportPeerID

/// Ephemeral endpoint identity within the transport. Changes between
/// sessions and must never be used as a domain identity.
public struct TransportPeerID: Hashable, Codable, Sendable, Identifiable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var id: String { rawValue }
    public var description: String { rawValue }
}

// MARK: - PeerAdvertisement

/// A Bonjour advertisement from a nearby device, read from the TXT record
/// before opening any connection. Lets rooms be listed without connecting to
/// every peer.
public struct PeerAdvertisement: Identifiable, Sendable, Equatable {
    public let endpointID: TransportPeerID
    public let applicationID: String?
    public let displayName: String
    public let protocolVersion: UInt8
    /// Rooms advertised in TXT. May be a subset of all hosted rooms.
    public let rooms: [RoomDescriptor]
    /// Real total of hosted rooms, even if not all fit in TXT.
    public let totalRoomCount: Int

    public var id: TransportPeerID { endpointID }

    public var isCompatible: Bool { P2PProtocolInfo.isCompatible(remoteVersion: protocolVersion) }

    public var hasUndisclosedRooms: Bool { totalRoomCount > rooms.count }
}

// MARK: - ConnectedPeer

/// A peer with a completed handshake. From here on the system identifies it
/// by `applicationID`, never by the connection identifier.
public struct ConnectedPeer: Identifiable, Sendable, Hashable {
    public let applicationID: String
    public let displayName: String
    public let protocolVersion: UInt8
    public let capabilities: Set<P2PCapability>
    /// Concrete connection instance. Changes on every reconnect; used to
    /// discard events from a connection that's already been replaced.
    public let connectionSessionID: UUID

    public var id: String { applicationID }

    public func supports(_ capability: P2PCapability) -> Bool {
        capabilities.contains(capability)
    }
}

// MARK: - ConnectivityLifecycle

/// Global transport state.
public enum ConnectivityLifecycle: String, Sendable, Equatable {
    case idle
    case active
    /// The app moved to background: rooms are kept, connections are not.
    case suspended
    case reconnecting
    case disconnected
}

// MARK: - PeerTransportEvent

/// Physical transport events.
///
/// Every event carries the `epoch` in effect when it was generated. A
/// `stop()` increments the epoch, so events queued before it are discarded
/// unambiguously.
public enum PeerTransportEvent: Sendable {
    case advertisementFound(PeerAdvertisement, epoch: UInt64)
    case advertisementUpdated(PeerAdvertisement, epoch: UInt64)
    case advertisementLost(TransportPeerID, epoch: UInt64)
    case peerConnected(ConnectedPeer, epoch: UInt64)
    case peerDisconnected(applicationID: String, reason: String?, epoch: UInt64)
    case received(RoomEnvelope, from: ConnectedPeer, epoch: UInt64)
    case lifecycleChanged(ConnectivityLifecycle, epoch: UInt64)
}

// MARK: - P2PTransportError

public enum P2PTransportError: Error, LocalizedError, Sendable, Equatable {
    case peerNotDiscovered
    case notConnected
    case handshakeTimedOut
    case handshakeFailed(String)
    case incompatibleProtocol(UInt8)
    case envelopeTooLarge(Int)
    case transportStopped
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .peerNotDiscovered:
            "El dispositivo ya no está visible en la red local."
        case .notConnected:
            "No hay conexión activa con el dispositivo."
        case .handshakeTimedOut:
            "El dispositivo no completó la conexión a tiempo."
        case .handshakeFailed(let reason):
            reason
        case .incompatibleProtocol(let version):
            "La versión del protocolo del otro dispositivo (\(version)) no es compatible."
        case .envelopeTooLarge(let bytes):
            "El mensaje ocupa \(bytes) bytes y supera el límite permitido."
        case .transportStopped:
            "La conectividad se ha detenido."
        case .connectionFailed(let reason):
            reason
        }
    }
}

// MARK: - AdvertisementRecord

/// Content the transport publishes in the Bonjour TXT record.
///
/// Bonjour limits each entry to 255 bytes and the whole record to a bit over
/// 1 KB, so rooms are serialized in a compact format and only the first few
/// are advertised. `RoomCoordinator` responds with the full directory when a
/// peer requests it after the handshake.
public struct AdvertisementRecord: Sendable, Equatable {
    public var applicationID: String
    public var displayName: String
    public var rooms: [RoomDescriptor]
    public var totalRoomCount: Int

    public init(
        applicationID: String,
        displayName: String,
        rooms: [RoomDescriptor] = [],
        totalRoomCount: Int = 0
    ) {
        self.applicationID = applicationID
        self.displayName = displayName
        self.rooms = rooms
        self.totalRoomCount = totalRoomCount
    }

    // MARK: TXT encoding

    private enum Key {
        static let version = "v"
        static let applicationID = "aid"
        static let displayName = "dn"
        static let roomCount = "rc"
        static func room(_ index: Int) -> String { "r\(index)" }
    }

    /// Serializes the advertisement into key/value pairs for the TXT record.
    public var txtDictionary: [String: String] {
        var dictionary: [String: String] = [
            Key.version: String(P2PProtocolInfo.currentVersion),
            Key.applicationID: applicationID,
            // The device name is user-set and can be long or carry emoji.
            // Clamped in bytes to stay under the TXT entry limit, or Bonjour
            // would drop the advertisement entirely.
            Key.displayName: Self.clamped(displayName, maximumBytes: 200),
            Key.roomCount: String(totalRoomCount)
        ]

        for (index, room) in rooms.prefix(P2PLimits.advertisedRoomLimit).enumerated() {
            dictionary[Key.room(index)] = CompactRoom(room).encoded
        }

        return dictionary
    }

    /// Truncates a string to a UTF-8 byte budget without splitting a character.
    private static func clamped(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }

        var result = ""
        var usedBytes = 0

        for character in value {
            let size = String(character).utf8.count
            guard usedBytes + size <= maximumBytes else { break }
            result.append(character)
            usedBytes += size
        }

        return result
    }

    /// Reconstructs an advertisement read from a remote TXT record.
    public static func advertisement(
        from txt: [String: String],
        endpointID: TransportPeerID,
        fallbackName: String
    ) -> PeerAdvertisement {
        let version = txt[Key.version].flatMap { UInt8($0) } ?? 0
        let displayName = txt[Key.displayName]?.isEmpty == false
            ? txt[Key.displayName]!
            : fallbackName

        var rooms: [RoomDescriptor] = []
        for index in 0..<P2PLimits.advertisedRoomLimit {
            guard let encoded = txt[Key.room(index)],
                  let compact = CompactRoom(encoded: encoded) else { continue }
            rooms.append(compact.descriptor(protocolVersion: version))
        }

        return PeerAdvertisement(
            endpointID: endpointID,
            applicationID: txt[Key.applicationID],
            displayName: displayName,
            protocolVersion: version,
            rooms: rooms,
            totalRoomCount: txt[Key.roomCount].flatMap { Int($0) } ?? rooms.count
        )
    }
}

// MARK: - CompactRoom

/// Compact encoding of a `RoomDescriptor` for the TXT record.
///
/// Format: `id|features|policy|members|capacity|activityKind|hostID|name`.
/// The name goes last and percent-escaped, so a `|` inside it never breaks parsing.
private struct CompactRoom {
    public let id: RoomID
    public let name: String
    public let hostApplicationID: String
    public let features: RoomFeatures
    public let accessPolicy: RoomAccessPolicy
    public let memberCount: Int
    public let capacity: Int?
    public let activityKind: ActivityKind?

    private static let separator: Character = "|"
    private static let allowedNameCharacters = CharacterSet.alphanumerics.union(.whitespaces)

    /// Bonjour limits each TXT entry to 255 bytes, counting `key=value`. A
    /// few are reserved for the key (`r0`) and the equals sign.
    private static let maximumEntryBytes = 250

    public init(_ descriptor: RoomDescriptor) {
        self.id = descriptor.id
        self.name = descriptor.name
        self.hostApplicationID = descriptor.hostApplicationID
        self.features = descriptor.features
        self.accessPolicy = descriptor.accessPolicy
        self.memberCount = descriptor.memberCount
        self.capacity = descriptor.capacity
        self.activityKind = descriptor.activityKind
    }

    public var encoded: String {
        // The name goes last and percent-escaped, so a `|` inside it never
        // breaks parsing.
        let fixedFields = [
            id.rawValue.uuidString,
            String(features.rawValue),
            accessPolicy.rawValue,
            String(memberCount),
            capacity.map(String.init) ?? "",
            activityKind?.rawValue ?? "",
            hostApplicationID
        ]

        let prefix = fixedFields.joined(separator: String(Self.separator))
            + String(Self.separator)

        // Trimming is done on already-escaped bytes, not characters: an
        // accented or emoji character can take 6-12 bytes once escaped, and
        // going over budget would make Bonjour drop the entry and the room
        // wouldn't be advertised.
        let budget = Self.maximumEntryBytes - prefix.utf8.count
        return prefix + Self.escapedName(name, maximumBytes: budget)
    }

    /// Escapes the name within a byte budget, without splitting a character.
    private static func escapedName(_ name: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }

        var result = ""
        var usedBytes = 0

        for character in name {
            guard let escaped = String(character)
                .addingPercentEncoding(withAllowedCharacters: allowedNameCharacters)
            else { continue }

            let size = escaped.utf8.count
            guard usedBytes + size <= maximumBytes else { break }

            result += escaped
            usedBytes += size
        }

        return result
    }

    public init?(encoded: String) {
        // `omittingEmptySubsequences: false` keeps empty fields, which are
        // meaningful (no capacity limit, room without an activity).
        let fields = encoded.split(
            separator: Self.separator,
            omittingEmptySubsequences: false
        ).map(String.init)

        guard fields.count == 8,
              let roomID = RoomID(string: fields[0]),
              let rawFeatures = UInt16(fields[1]),
              let policy = RoomAccessPolicy(rawValue: fields[2]),
              let memberCount = Int(fields[3]) else { return nil }

        self.id = roomID
        self.features = RoomFeatures(rawValue: rawFeatures)
        self.accessPolicy = policy
        self.memberCount = memberCount
        self.capacity = Int(fields[4])
        self.activityKind = ActivityKind(rawValue: fields[5])
        self.hostApplicationID = fields[6]
        self.name = fields[7].removingPercentEncoding ?? fields[7]
    }

    public func descriptor(protocolVersion: UInt8) -> RoomDescriptor {
        RoomDescriptor(
            id: id,
            name: name,
            hostApplicationID: hostApplicationID,
            features: features,
            activityKind: activityKind,
            accessPolicy: accessPolicy,
            memberCount: memberCount,
            capacity: capacity,
            protocolVersion: protocolVersion
        )
    }
}
