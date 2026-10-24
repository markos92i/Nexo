//
//  LocalP2PIdentity.swift
//  Nexo
//

import Foundation
import CryptoKit
import Network
import OSLog
import Security
import Synchronization
import X509

// MARK: - NexoLocalTLSIdentity

public struct NexoLocalTLSIdentity: @unchecked Sendable {

    private static let logger = Logger(subsystem: "com.zafir.nexo", category: "identity")

    public let networkIdentity: sec_identity_t
    public let certificate: SecCertificate
    public let publicKey: Data
    public let fingerprint: String

    private static let creationLock = Mutex<Void>(())

    @concurrent
    public static func loadOrCreate(applicationID: String) async throws(NexoLocalTLSIdentityError) -> Self {
        try creationLock.withLock { _ throws(NexoLocalTLSIdentityError) -> Self in
            let key = try privateKey(applicationID: applicationID)
            let certificate = try certificate(applicationID: applicationID)
            switch (key, certificate) {
            case let (.some(key), .some(certificate)):
                return try makeIdentity(key: key, certificate: certificate)
            case let (.some(key), .none):
                return try completeIdentity(key: key, applicationID: applicationID, storeKey: false)
            case (.none, .none):
                return try create(applicationID: applicationID)
            case (.none, .some):
                throw .incompleteKeychainState
            }
        }
    }

    public func makeTLSConfiguration() -> NexoTLSConfiguration {
        NexoTLSConfiguration(identity: networkIdentity) { trust in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let leaf = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate])?.first,
                  let leafKey = SecCertificateCopyKey(leaf),
                  SecKeyCopyExternalRepresentation(leafKey, nil) != nil
            else {
                Self.logger.error("TLS peer leaf has no readable public key")
                return false
            }
            // A self-signed peer never chains to a system root, and its
            // advertised name is not its identity: authentication is the
            // pinned fingerprint enforced by NexoPeerVerification once the
            // handshake exposes this leaf.
            return true
        }
    }

    private static func create(applicationID: String) throws(NexoLocalTLSIdentityError) -> Self {
        var keyError: Unmanaged<CFError>?
        // Build and validate everything before persisting either item.
        guard let key = SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
        ] as CFDictionary, &keyError) else {
            throw .keyGenerationFailed(keyError.map { NexoReason(error: $0.takeRetainedValue()) })
        }
        return try completeIdentity(key: key, applicationID: applicationID, storeKey: true)
    }

    private static func completeIdentity(
        key: SecKey, applicationID: String, storeKey: Bool
    ) throws(NexoLocalTLSIdentityError) -> Self {
        var exportError: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(key, &exportError) as Data? else {
            throw .keyExportFailed(exportError.map { NexoReason(error: $0.takeRetainedValue()) })
        }
        let signingKey: P256.Signing.PrivateKey
        do {
            signingKey = try P256.Signing.PrivateKey(x963Representation: keyData)
        } catch {
            throw .keyImportFailed(NexoReason(error: error))
        }
        let secCertificate: SecCertificate
        do {
            let subject = try DistinguishedName {
                CommonName("Zafir Nexo \(applicationID)")
                OrganizationName("Zafir")
            }
            let extensions = try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                KeyUsage(digitalSignature: true)
                try ExtendedKeyUsage([.serverAuth, .clientAuth])
            }
            let certificate = try Certificate(
                version: .v3, serialNumber: .init(), publicKey: .init(signingKey.publicKey),
                notValidBefore: Date(timeIntervalSinceNow: -60),
                notValidAfter: Date(timeIntervalSinceNow: 10 * 365 * 24 * 60 * 60),
                issuer: subject, subject: subject, extensions: extensions,
                issuerPrivateKey: .init(signingKey)
            )
            secCertificate = try SecCertificate.makeWithCertificate(certificate)
        } catch {
            throw .certificateCreationFailed(NexoReason(error: error))
        }
        let identity = try makeIdentity(key: key, certificate: secCertificate)
        let keyQuery: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag: keyTag(applicationID),
        ]
        if storeKey {
            let keyStatus = SecItemAdd(keyQuery.merging([
                kSecValueRef: key,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]) { _, new in new } as CFDictionary, nil)
            guard keyStatus == errSecSuccess else { throw .keyStorageFailed(keyStatus) }
        }
        // A crash between writes leaves recoverable key-only state, never a certificate without its key.
        let certificateStatus = SecItemAdd([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: certificateLabel(applicationID),
            kSecValueRef: secCertificate,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary, nil)
        guard certificateStatus == errSecSuccess else {
            if storeKey {
                let rollback = SecItemDelete(keyQuery as CFDictionary)
                guard rollback == errSecSuccess else {
                    throw .storageRollbackFailed(original: certificateStatus, rollback: rollback)
                }
            }
            throw .certificateStorageFailed(certificateStatus)
        }
        return identity
    }

    private static func makeIdentity(
        key: SecKey,
        certificate: SecCertificate
    ) throws(NexoLocalTLSIdentityError) -> Self {
        guard let identity = SecIdentityCreate(nil, certificate, key),
              let networkIdentity = sec_identity_create(identity),
              let certificateKey = SecCertificateCopyKey(certificate),
              let publicKeyData = SecKeyCopyExternalRepresentation(certificateKey, nil) as Data?
        else {
            throw NexoLocalTLSIdentityError.identityCreationFailed
        }

        guard let keyPublicKey = SecKeyCopyPublicKey(key),
              let keyPublicKeyData = SecKeyCopyExternalRepresentation(keyPublicKey, nil) as Data?,
              keyPublicKeyData == publicKeyData
        else {
            throw NexoLocalTLSIdentityError.keyCertificateMismatch
        }

        let fingerprint = SHA256.hash(data: publicKeyData)
            .map { String(format: "%02x", $0) }
            .joined()
        return Self(
            networkIdentity: networkIdentity,
            certificate: certificate,
            publicKey: publicKeyData,
            fingerprint: fingerprint
        )
    }

    private static func privateKey(applicationID: String) throws(NexoLocalTLSIdentityError) -> SecKey? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: keyTag(applicationID),
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw .keychainReadFailed(status) }
        guard let result, CFGetTypeID(result) == SecKeyGetTypeID() else {
            throw .incompleteKeychainState
        }
        return unsafeDowncast(result, to: SecKey.self)
    }

    private static func certificate(applicationID: String) throws(NexoLocalTLSIdentityError) -> SecCertificate? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: certificateLabel(applicationID),
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw .keychainReadFailed(status) }
        guard let result, CFGetTypeID(result) == SecCertificateGetTypeID() else {
            throw .incompleteKeychainState
        }
        return unsafeDowncast(result, to: SecCertificate.self)
    }

    private static func keyTag(_ applicationID: String) -> Data {
        Data("com.zafir.nexo.identity.\(applicationID)".utf8)
    }

    private static func certificateLabel(_ applicationID: String) -> String {
        "com.zafir.nexo.certificate.\(applicationID)"
    }
}

public enum NexoLocalTLSIdentityError: Error, Sendable {
    case incompleteKeychainState
    case keyGenerationFailed(NexoReason?)
    case keyExportFailed(NexoReason?)
    case keyImportFailed(NexoReason)
    case certificateCreationFailed(NexoReason)
    case keychainReadFailed(OSStatus)
    case keyStorageFailed(OSStatus)
    case certificateStorageFailed(OSStatus)
    case storageRollbackFailed(original: OSStatus, rollback: OSStatus)
    case identityCreationFailed
    case keyCertificateMismatch
}

/// Reads the negotiated leaf, never application-layer identity assertions.
enum NexoTLSPeerIdentity {
    static func fingerprint(from metadata: sec_protocol_metadata_t) throws(P2PTransportError) -> String {
        let leaf = Mutex<(visited: Bool, key: Data?)>((false, nil))
        let accessible = sec_protocol_metadata_access_peer_certificate_chain(metadata) { certificate in
            leaf.withLock { state in
                guard !state.visited else { return }
                state.visited = true
                let certificate = sec_certificate_copy_ref(certificate).takeRetainedValue()
                guard let key = SecCertificateCopyKey(certificate) else { return }
                state.key = SecKeyCopyExternalRepresentation(key, nil) as Data?
            }
        }
        guard accessible, let key = leaf.withLock({ $0.key }), !key.isEmpty else {
            throw .handshakeFailed(.invalidIdentity)
        }
        return NexoFingerprintFormatter.fingerprint(of: key)
    }
}

// MARK: - NexoPeerTrustStore

@NexoActor
public final class NexoPeerTrustStore {

    private static let service = "com.zafir.nexo.peer-trust"

    private let account: String
    private var fingerprints: Set<String>

    public init(applicationID: String) {
        self.account = "peers.\(applicationID)"
        self.fingerprints = Self.load(account: account)
    }

    public func isTrusted(_ peer: ConnectedPeer) -> Bool {
        guard let fingerprint = peer.certificateFingerprint else { return false }
        return fingerprints.contains(fingerprint)
    }

    @discardableResult
    public func trust(_ peer: ConnectedPeer) -> Bool {
        guard let fingerprint = peer.certificateFingerprint else { return false }
        let wasInserted = fingerprints.insert(fingerprint).inserted
        guard wasInserted else { return true }

        guard save() else {
            fingerprints.remove(fingerprint)
            return false
        }
        return true
    }

    private static func load(account: String) -> Set<String> {
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
              let values = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return Set(values)
    }

    private func save() -> Bool {
        guard let data = try? JSONEncoder().encode(fingerprints.sorted()) else { return false }
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

// MARK: - LocalP2PIdentity

/// Observable local identity. The display name is user-editable and
/// propagates to the Bonjour TXT record and outgoing messages.
///
/// `applicationID` is a label bound to the negotiated TLS key for each session.
/// The consumer still needs TOFU or out-of-band verification to authorize a peer;
/// a self-signed certificate does not prove ownership of an application ID.
@NexoActor
public final class LocalP2PIdentity {

    public let applicationID: String
    public var displayName: String
    /// Opaque avatar token (catalog key or encoded thumbnail) published to
    /// peers alongside the display name.
    public var avatar: String?

    public init(applicationID: String, displayName: String, avatar: String? = nil) {
        self.applicationID = applicationID
        self.displayName = displayName
        self.avatar = avatar
    }

    public func member(role: RoomRole) -> RoomMember {
        RoomMember(
            applicationID: applicationID,
            displayName: displayName,
            role: role,
            avatar: avatar
        )
    }
}

