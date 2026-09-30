//
//  NexoPeerVerification.swift
//  Nexo
//

import Foundation
import CryptoKit
import OSLog

// MARK: - NexoPeerVerificationState

/// Identity verification state for a peer.
///
/// Nexo uses a TOFU (Trust On First Use) model similar to SSH:
/// - First connection stores the peer's fingerprint
/// - Subsequent connections verify the fingerprint matches
/// - A fingerprint change is a security alert
public enum NexoPeerVerificationState: String, Sendable, Equatable, CaseIterable {
    /// The peer has never connected before. Its identity is unverified.
    case unknown
    /// The peer connected for the first time and the user accepted its identity.
    /// The connection is encrypted but there is no guarantee the peer is who it claims to be.
    case trustedOnFirstUse
    /// The peer's fingerprint was verified out of band (QR, visual comparison).
    case verified
    /// The peer's fingerprint changed since the last known connection.
    /// This may indicate a MITM attack or that the peer reinstalled the app.
    case identityChanged
}

// MARK: - NexoPeerIdentityInfo

/// Identity info for a peer, for display to the user.
public struct NexoPeerIdentityInfo: Sendable, Equatable, Identifiable {
    /// The peer's Application ID.
    public let applicationID: String
    /// The peer's display name.
    public let displayName: String
    /// SHA-256 fingerprint of the public certificate.
    public let fingerprint: String
    /// Verification state.
    public let verificationState: NexoPeerVerificationState
    /// Date of first connection (if in the trust store).
    public let firstSeenAt: Date?
    /// Date of last successful verification.
    public let lastVerifiedAt: Date?
    
    public var id: String { applicationID }
    
    /// Fingerprint formatted for display (groups of 4 characters).
    public var formattedFingerprint: String {
        NexoFingerprintFormatter.format(fingerprint)
    }
    
    /// Fingerprint rendered as emojis for easy visual comparison.
    public var emojiFingerprint: String {
        NexoFingerprintFormatter.toEmoji(fingerprint)
    }
    
    /// Fingerprint rendered as words for voice verification.
    public var wordFingerprint: String {
        NexoFingerprintFormatter.toWords(fingerprint)
    }
}

// MARK: - NexoFingerprintFormatter

/// Utilities for formatting fingerprints readably.
public enum NexoFingerprintFormatter {
    
    /// Formats a hex fingerprint in groups of 4 characters.
    public static func format(_ fingerprint: String, groupSize: Int = 4, separator: String = " ") -> String {
        var result = ""
        var count = 0
        for char in fingerprint.uppercased() {
            if count > 0 && count % groupSize == 0 {
                result += separator
            }
            result.append(char)
            count += 1
        }
        return result
    }
    
    /// Converts a fingerprint to a sequence of emojis.
    ///
    /// Each pair of hex characters (256 values) maps to one emoji, making
    /// visual comparison easier and less error-prone.
    public static func toEmoji(_ fingerprint: String) -> String {
        let emojis: [Character] = [
            "🍎", "🍊", "🍋", "🍇", "🍓", "🫐", "🍑", "🍒",
            "🥝", "🍍", "🥭", "🥥", "🍌", "🍈", "🍏", "🍐",
            "🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼",
            "🐨", "🐯", "🦁", "🐮", "🐷", "🐸", "🐵", "🐔",
            "🌸", "🌺", "🌻", "🌹", "🌷", "🌼", "💐", "🌾",
            "🍀", "🌿", "🌱", "🌲", "🌳", "🌴", "🌵", "🎋",
            "⭐", "🌙", "☀️", "⛅", "🌈", "❄️", "💧", "🔥",
            "🌊", "⚡", "🌪️", "🌸", "💫", "✨", "🎀", "🎈"
        ]
        
        var result = ""
        let hex = fingerprint.lowercased()
        var index = hex.startIndex
        
        // Take the first 8 bytes (16 hex chars) to generate 8 emojis
        for _ in 0..<8 {
            guard index < hex.endIndex else { break }
            let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            let byteString = String(hex[index..<nextIndex])
            
            if let byte = UInt8(byteString, radix: 16) {
                let emojiIndex = Int(byte) % emojis.count
                result.append(emojis[emojiIndex])
            }
            
            index = nextIndex
        }
        
        return result
    }
    
    /// Converts a fingerprint to a phrase of words.
    ///
    /// Uses a list of short, distinctive words, similar to the
    /// Signal/WhatsApp verification system.
    public static func toWords(_ fingerprint: String) -> String {
        let words = [
            "alfa", "beta", "casa", "dado", "eco", "faro", "gato", "hora",
            "isla", "joya", "kilo", "luna", "mesa", "nube", "oro", "pez",
            "queso", "rosa", "sol", "tren", "uno", "vida", "web", "xilo",
            "yoga", "zona", "azul", "bici", "café", "duna", "este", "flor",
            "gris", "hilo", "iris", "jazz", "koala", "lava", "miel", "nave",
            "ojo", "pino", "quark", "rayo", "seda", "tubo", "uva", "vela",
            "wok", "xeno", "yate", "zinc", "ámbar", "brisa", "cielo", "delta",
            "eco", "fuego", "globo", "humo", "inca", "jade", "karma", "limón"
        ]
        
        var result: [String] = []
        let hex = fingerprint.lowercased()
        var index = hex.startIndex
        
        // Take 6 bytes to generate 6 words
        for _ in 0..<6 {
            guard index < hex.endIndex else { break }
            let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            let byteString = String(hex[index..<nextIndex])
            
            if let byte = UInt8(byteString, radix: 16) {
                let wordIndex = Int(byte) % words.count
                result.append(words[wordIndex])
            }
            
            index = nextIndex
        }
        
        return result.joined(separator: " ")
    }
    
    /// Compares two fingerprints and returns whether they match.
    public static func compare(_ a: String, _ b: String) -> Bool {
        a.lowercased() == b.lowercased()
    }
    
    /// Generates the SHA-256 fingerprint of a public key.
    public static func fingerprint(of publicKey: Data) -> String {
        SHA256.hash(data: publicKey)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - NexoPeerVerificationService

/// Service that manages peer identity verification.
///
/// Implements TOFU (Trust On First Use):
/// 1. First connection: the fingerprint is stored after user acceptance
/// 2. Later connections: the fingerprint is verified to match
/// 3. Fingerprint change: the user is alerted (possible MITM)
///
/// For stronger security, users can verify fingerprints out of band
/// (comparing emojis in person, scanning a QR, etc.) and mark the peer as "verified".
@MainActor
@Observable
public final class NexoPeerVerificationService {
    
    private static let logger = Logger(subsystem: "com.zafir.nexo", category: "verification")
    
    private let trustStore: NexoEnhancedTrustStore
    
    /// Peers with a detected identity change (possible MITM).
    public private(set) var identityChangedPeers: Set<String> = []
    
    /// Callback fired when an identity change is detected.
    public var onIdentityChanged: ((NexoPeerIdentityInfo, String) -> Void)?
    
    public init(applicationID: String) {
        self.trustStore = NexoEnhancedTrustStore(applicationID: applicationID)
    }
    
    // MARK: - Verification API
    
    /// Verifies a connected peer and returns its verification state.
    public func verify(_ peer: ConnectedPeer) -> NexoPeerVerificationState {
        guard let fingerprint = peer.certificateFingerprint else {
            return .unknown
        }
        
        guard let storedRecord = trustStore.record(for: peer.applicationID) else {
            // First time seeing this peer
            return .unknown
        }
        
        // Verify the fingerprint matches the stored record
        guard NexoFingerprintFormatter.compare(fingerprint, storedRecord.fingerprint) else {
            // Alert: fingerprint changed
            Self.logger.warning("Identity changed for peer \(peer.applicationID): expected \(storedRecord.fingerprint.prefix(16))..., got \(fingerprint.prefix(16))...")
            identityChangedPeers.insert(peer.applicationID)
            
            let info = identityInfo(for: peer, state: .identityChanged)
            onIdentityChanged?(info, storedRecord.fingerprint)
            
            return .identityChanged
        }
        
        identityChangedPeers.remove(peer.applicationID)
        trustStore.updateLastSeen(for: peer.applicationID)
        
        return storedRecord.isVerified ? .verified : .trustedOnFirstUse
    }
    
    /// Trusts a peer for the first time (TOFU).
    @discardableResult
    public func trustOnFirstUse(_ peer: ConnectedPeer) -> Bool {
        guard let fingerprint = peer.certificateFingerprint else {
            Self.logger.error("Cannot trust peer without certificate fingerprint")
            return false
        }
        
        return trustStore.trust(
            applicationID: peer.applicationID,
            displayName: peer.displayName,
            fingerprint: fingerprint,
            isVerified: false
        )
    }
    
    /// Marks a peer as verified (the user confirmed the fingerprint out of band).
    @discardableResult
    public func markAsVerified(_ peer: ConnectedPeer) -> Bool {
        guard peer.certificateFingerprint != nil else { return false }
        return trustStore.markAsVerified(peer.applicationID)
    }
    
    /// Accepts an identity change (the user confirmed it is legitimate).
    ///
    /// This replaces the stored fingerprint. Use with caution.
    @discardableResult
    public func acceptIdentityChange(_ peer: ConnectedPeer) -> Bool {
        guard let fingerprint = peer.certificateFingerprint else { return false }
        
        Self.logger.info("User accepted identity change for \(peer.applicationID)")
        identityChangedPeers.remove(peer.applicationID)
        
        trustStore.revoke(peer.applicationID)
        return trustStore.trust(
            applicationID: peer.applicationID,
            displayName: peer.displayName,
            fingerprint: fingerprint,
            isVerified: false
        )
    }
    
    /// Revokes trust in a peer.
    public func revoke(_ applicationID: String) {
        trustStore.revoke(applicationID)
        identityChangedPeers.remove(applicationID)
    }
    
    /// Returns identity info for display to the user.
    public func identityInfo(for peer: ConnectedPeer, state: NexoPeerVerificationState? = nil) -> NexoPeerIdentityInfo {
        let actualState = state ?? verify(peer)
        let record = trustStore.record(for: peer.applicationID)
        
        return NexoPeerIdentityInfo(
            applicationID: peer.applicationID,
            displayName: peer.displayName,
            fingerprint: peer.certificateFingerprint ?? "",
            verificationState: actualState,
            firstSeenAt: record?.firstSeenAt,
            lastVerifiedAt: record?.lastVerifiedAt
        )
    }
    
    /// Lists all trusted peers.
    public func trustedPeers() -> [NexoTrustRecord] {
        trustStore.allRecords()
    }
    
    /// Checks whether a peer is trusted.
    public func isTrusted(_ applicationID: String) -> Bool {
        trustStore.record(for: applicationID) != nil
    }
}

// MARK: - NexoTrustRecord

/// Trust record stored for a peer.
public struct NexoTrustRecord: Codable, Sendable, Identifiable {
    public let applicationID: String
    public let displayName: String
    public let fingerprint: String
    public let isVerified: Bool
    public let firstSeenAt: Date
    public var lastSeenAt: Date
    public var lastVerifiedAt: Date?
    
    public var id: String { applicationID }
}

// MARK: - NexoEnhancedTrustStore

/// Enhanced store of trusted peers with additional metadata.
@MainActor
public final class NexoEnhancedTrustStore {
    
    private static let service = "com.zafir.nexo.peer-trust-v2"
    
    private let account: String
    private var records: [String: NexoTrustRecord]
    
    public init(applicationID: String) {
        self.account = "peers.\(applicationID)"
        self.records = Self.load(account: account)
    }
    
    func record(for applicationID: String) -> NexoTrustRecord? {
        records[applicationID]
    }
    
    func allRecords() -> [NexoTrustRecord] {
        Array(records.values).sorted { $0.lastSeenAt > $1.lastSeenAt }
    }
    
    @discardableResult
    func trust(
        applicationID: String,
        displayName: String,
        fingerprint: String,
        isVerified: Bool
    ) -> Bool {
        let now = Date()
        let record = NexoTrustRecord(
            applicationID: applicationID,
            displayName: displayName,
            fingerprint: fingerprint,
            isVerified: isVerified,
            firstSeenAt: now,
            lastSeenAt: now,
            lastVerifiedAt: isVerified ? now : nil
        )
        records[applicationID] = record
        return save()
    }
    
    @discardableResult
    func markAsVerified(_ applicationID: String) -> Bool {
        guard var record = records[applicationID] else { return false }
        record = NexoTrustRecord(
            applicationID: record.applicationID,
            displayName: record.displayName,
            fingerprint: record.fingerprint,
            isVerified: true,
            firstSeenAt: record.firstSeenAt,
            lastSeenAt: record.lastSeenAt,
            lastVerifiedAt: Date()
        )
        records[applicationID] = record
        return save()
    }
    
    func updateLastSeen(for applicationID: String) {
        guard var record = records[applicationID] else { return }
        record.lastSeenAt = Date()
        records[applicationID] = record
        save()
    }
    
    func revoke(_ applicationID: String) {
        records.removeValue(forKey: applicationID)
        save()
    }
    
    // MARK: - Persistence
    
    private static func load(account: String) -> [String: NexoTrustRecord] {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let records = try? JSONDecoder().decode([NexoTrustRecord].self, from: data)
        else {
            return [:]
        }
        
        return Dictionary(uniqueKeysWithValues: records.map { ($0.applicationID, $0) })
    }
    
    @discardableResult
    private func save() -> Bool {
        guard let data = try? JSONEncoder().encode(Array(records.values)) else { return false }
        
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: account,
        ]
        
        let addStatus = SecItemAdd(
            query.merging([
                kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]) { current, _ in current } as CFDictionary,
            nil
        )
        
        guard addStatus == errSecDuplicateItem else { return addStatus == errSecSuccess }
        return SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary) == errSecSuccess
    }
}

// MARK: - QR Code Generation for Verification

/// Data for generating a verification QR code.
public struct NexoVerificationQRData: Codable, Sendable {
    public let applicationID: String
    public let displayName: String
    public let fingerprint: String
    public let timestamp: Date
    
    public init(applicationID: String, displayName: String, fingerprint: String) {
        self.applicationID = applicationID
        self.displayName = displayName
        self.fingerprint = fingerprint
        self.timestamp = Date()
    }
    
    /// Encodes the data for a QR code.
    public func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }
    
    /// Decodes data from a scanned QR code.
    public static func decode(_ data: Data) -> NexoVerificationQRData? {
        try? JSONDecoder().decode(NexoVerificationQRData.self, from: data)
    }
    
    /// Checks whether the QR data matches a connected peer.
    public func matches(_ peer: ConnectedPeer) -> Bool {
        guard let peerFingerprint = peer.certificateFingerprint else { return false }
        return applicationID == peer.applicationID
            && NexoFingerprintFormatter.compare(fingerprint, peerFingerprint)
    }
}
