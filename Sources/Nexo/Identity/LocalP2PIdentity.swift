//
//  LocalP2PIdentity.swift
//  Nexo
//

import Foundation
import CryptoKit
import Network
import Security
import X509

// MARK: - NexoLocalTLSIdentity

public struct NexoLocalTLSIdentity: @unchecked Sendable {

    public let networkIdentity: sec_identity_t
    public let certificate: SecCertificate
    public let publicKey: Data
    public let fingerprint: String

    public static func loadOrCreate(applicationID: String) throws -> Self {
        let key = privateKey(applicationID: applicationID)
        let certificate = certificate(applicationID: applicationID)

        switch (key, certificate) {
        case let (.some(key), .some(certificate)):
            return try makeIdentity(key: key, certificate: certificate)
        case (.none, .none):
            return try create(applicationID: applicationID)
        default:
            throw NexoLocalTLSIdentityError.incompleteKeychainState
        }
    }

    public func makeTLSConfiguration() -> NexoTLSConfiguration {
        NexoTLSConfiguration(identity: networkIdentity) { trust in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let leaf = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate])?.first,
                  let leafKey = SecCertificateCopyKey(leaf),
                  SecKeyCopyExternalRepresentation(leafKey, nil) != nil,
                  SecTrustSetAnchorCertificates(secTrust, [leaf] as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(secTrust, true) == errSecSuccess
            else {
                return false
            }

            return SecTrustEvaluateWithError(secTrust, nil)
        }
    }

    private static func create(applicationID: String) throws -> Self {
        var keyError: Unmanaged<CFError>?
        let keyAttributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: keyTag(applicationID),
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ],
        ]
        guard let key = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &keyError),
              let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let signingKey = try? P256.Signing.PrivateKey(rawRepresentation: keyData)
        else {
            throw NexoLocalTLSIdentityError.keyGenerationFailed(
                keyError?.takeRetainedValue().localizedDescription ?? "Unknown key generation error."
            )
        }

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
            version: .v3,
            serialNumber: .init(),
            publicKey: .init(signingKey.publicKey),
            notValidBefore: Date(timeIntervalSinceNow: -60),
            notValidAfter: Date(timeIntervalSinceNow: 10 * 365 * 24 * 60 * 60),
            issuer: subject,
            subject: subject,
            extensions: extensions,
            issuerPrivateKey: .init(signingKey)
        )
        let secCertificate = try SecCertificate.makeWithCertificate(certificate)
        let addStatus = SecItemAdd([
            kSecClass: kSecClassCertificate,
            kSecValueRef: secCertificate,
            kSecAttrLabel: certificateLabel(applicationID),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NexoLocalTLSIdentityError.certificateStorageFailed(addStatus)
        }

        return try makeIdentity(key: key, certificate: secCertificate)
    }

    private static func makeIdentity(
        key: SecKey,
        certificate: SecCertificate
    ) throws -> Self {
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

    private static func privateKey(applicationID: String) -> SecKey? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: keyTag(applicationID),
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
          guard status == errSecSuccess,
              let result,
              CFGetTypeID(result) == SecKeyGetTypeID()
          else { return nil }
          return unsafeDowncast(result, to: SecKey.self)
    }

    private static func certificate(applicationID: String) -> SecCertificate? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: certificateLabel(applicationID),
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
          guard status == errSecSuccess,
              let result,
              CFGetTypeID(result) == SecCertificateGetTypeID()
          else { return nil }
          return unsafeDowncast(result, to: SecCertificate.self)
    }

    private static func keyTag(_ applicationID: String) -> Data {
        Data("com.zafir.nexo.identity.\(applicationID)".utf8)
    }

    private static func certificateLabel(_ applicationID: String) -> String {
        "com.zafir.nexo.certificate.\(applicationID)"
    }
}

public enum NexoLocalTLSIdentityError: LocalizedError, Sendable {
    case incompleteKeychainState
    case keyGenerationFailed(String)
    case certificateStorageFailed(OSStatus)
    case identityCreationFailed
    case keyCertificateMismatch

    public var errorDescription: String? {
        switch self {
        case .incompleteKeychainState:
            "La identidad local de Nexo está incompleta en Keychain."
        case .keyGenerationFailed(let reason):
            "No se pudo generar la clave local de Nexo: \(reason)"
        case .certificateStorageFailed(let status):
            "No se pudo guardar el certificado local de Nexo (\(status))."
        case .identityCreationFailed:
            "No se pudo crear la identidad TLS local de Nexo."
        case .keyCertificateMismatch:
            "La clave privada y el certificado local de Nexo no coinciden."
        }
    }
}

// MARK: - NexoPeerTrustStore

@MainActor
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

