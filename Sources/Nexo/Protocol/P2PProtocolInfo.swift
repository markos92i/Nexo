//
//  P2PProtocolInfo.swift
//  Nexo
//

import Foundation

// MARK: - P2PProtocolInfo

/// Version and capabilities of the application protocol carried over Network
/// framework. Negotiated during the handshake, before any envelope is admitted.
public enum P2PProtocolInfo {

    /// Room resume is part of this version's wire format, so it is not
    /// advertised as compatible with older peers.
    public static let currentVersion: UInt8 = 3
    public static let minimumVersion: UInt8 = 3

    /// Capabilities advertised in `hello`. Lets new features roll out without
    /// breaking older peers: unsupported capabilities are simply not used with them.
    public static let capabilities: Set<P2PCapability> = [
        .rooms,
        .chat,
        .activities,
        .fileTransfer,
        .coalescedSnapshots,
        .binaryStreams,
        .tls
    ]

    /// Must match `NSBonjourServices` in the app's Info.plist.
    public static let serviceType = "_zafir-nearby._tcp"
    public static let quicServiceType = "_zafir-nearby._udp"

    public static func isCompatible(remoteVersion: UInt8) -> Bool {
        remoteVersion >= minimumVersion
    }
}

// MARK: - P2PCapability

public enum P2PCapability: String, Codable, Sendable, CaseIterable {
    case rooms
    case chat
    case activities
    case fileTransfer
    case coalescedSnapshots
    case binaryStreams
    case tls
}

// MARK: - P2PLimits

/// Technical limits. There's no hard cap on participants, but the host still
/// needs protecting from memory pressure, bandwidth, and abusive messages.
public enum P2PLimits {

    public static let maximumEnvelopeBytes = 512 * 1024
    public static let maximumTransferBytes: Int64 = 25 * 1024 * 1024
    public static let transferChunkBytes = 32 * 1024
    /// In-flight chunks before waiting on receiver backpressure.
    public static let transferWindowChunks = 8
    public static let chatHistoryLimit = 500

    /// How long a physical disconnect is still considered recoverable. Also
    /// checked on foreground return, since iOS may suspend execution without
    /// guaranteeing a timer advances.
    public static let temporaryDisconnectGracePeriod: TimeInterval = 60

    /// Retention window for the chat/activity journal used to replay messages
    /// after a physical reconnection.
    public static let recoveryJournalRetention: TimeInterval = 60
    public static let recoveryJournalLimit = 2_000
    public static let recoveryJournalBytesLimit = 4 * 1024 * 1024
    public static let recoveryChatMessageLimit = 100
    public static let recoveryMemberLimit = 256
    public static let recoveryActivityLimit = 64

    /// Rooms advertised in the Bonjour TXT record. The rest are discovered on
    /// connect via `roomDirectory`.
    public static let advertisedRoomLimit = 3

    public static let handshakeTimeout: Duration = .seconds(12)
    public static let joinTimeout: Duration = .seconds(30)
}
