//
//  LocalP2PIdentity.swift
//  Nexo
//

import Foundation

// MARK: - LocalP2PIdentity

/// Observable local identity. The display name is user-editable and
/// propagates to the Bonjour TXT record and outgoing messages.
///
/// `applicationID` is the consumer's responsibility: it's not a credential,
/// it's sent as-is in `hello` and nobody verifies it, so it's good for
/// identifying and deduplicating peers, not for authorizing against a
/// malicious one.
@MainActor
@Observable
public final class LocalP2PIdentity {

    public let applicationID: String
    public var displayName: String

    public init(applicationID: String, displayName: String) {
        self.applicationID = applicationID
        self.displayName = displayName
    }

    public func member(role: RoomRole) -> RoomMember {
        RoomMember(applicationID: applicationID, displayName: displayName, role: role)
    }
}

