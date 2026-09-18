//
//  P2PFrame.swift
//  Nexo
//

import Foundation

// MARK: - P2PFrame

/// The unit that actually travels over the socket.
///
/// A flat struct with a `kind` and optional bodies instead of an enum with
/// associated values, so the JSON has a single layer and control bodies never
/// end up nested or base64-encoded.
public struct P2PFrame: Codable, Sendable {

    public enum Kind: String, Codable, Sendable {
        /// Identity and capability exchange.
        case hello
        /// An application envelope, already routable by room.
        case envelope
        /// Orderly close, so the peer doesn't have to wait out a timeout.
        case goodbye
    }

    public let kind: Kind
    public var hello: HelloBody?
    public var envelope: RoomEnvelope?
    public var goodbye: GoodbyeBody?

    // MARK: Factories

    public static func hello(_ body: HelloBody) -> P2PFrame {
        P2PFrame(kind: .hello, hello: body)
    }

    public static func envelope(_ envelope: RoomEnvelope) -> P2PFrame {
        P2PFrame(kind: .envelope, envelope: envelope)
    }

    public static func goodbye(reason: String) -> P2PFrame {
        P2PFrame(kind: .goodbye, goodbye: GoodbyeBody(reason: reason))
    }
}

// MARK: - HelloBody

/// Identity declared by the peer.
///
/// There's no authentication: `applicationID` is self-declared by the remote
/// and nobody verifies it. Enough to identify and deduplicate peers on a
/// trusted local network, but it doesn't stop a peer from impersonating another.
public struct HelloBody: Codable, Sendable {
    public let protocolVersion: UInt8
    public let minimumProtocolVersion: UInt8
    public let applicationID: String
    public let displayName: String
    public let certificateFingerprint: String?
    public let capabilities: [P2PCapability]

    public init(
        applicationID: String,
        displayName: String,
        certificateFingerprint: String? = nil,
        protocolVersion: UInt8 = P2PProtocolInfo.currentVersion,
        minimumProtocolVersion: UInt8 = P2PProtocolInfo.minimumVersion,
        capabilities: Set<P2PCapability> = P2PProtocolInfo.capabilities
    ) {
        self.protocolVersion = protocolVersion
        self.minimumProtocolVersion = minimumProtocolVersion
        self.applicationID = applicationID
        self.displayName = displayName
        self.certificateFingerprint = certificateFingerprint
        self.capabilities = Array(capabilities)
    }
}

// MARK: - GoodbyeBody

public struct GoodbyeBody: Codable, Sendable {
    public let reason: String
}
