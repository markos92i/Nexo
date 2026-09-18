//
//  TLSConfiguration.swift
//  Nexo
//

import Foundation
import Network
import Security

// MARK: - NexoTLSConfiguration

/// TLS identity and peer verification used by the physical transport.
///
/// The identity is deliberately supplied by the host application. Nexo does
/// not decide how certificates are generated or persisted; applications can
/// use Keychain, a provisioning service, or a pairing flow. The validator is
/// also responsible for accepting self-signed identities after pairing.
public struct NexoTLSConfiguration: @unchecked Sendable {

    public let identity: sec_identity_t
    private let validator: @Sendable (sec_trust_t) -> Bool

    public init(
        identity: sec_identity_t,
        validator: @escaping @Sendable (sec_trust_t) -> Bool
    ) {
        self.identity = identity
        self.validator = validator
    }

    /// Creates a configuration that accepts only a certificate whose public
    /// key matches the supplied pinned key data.
    public init(
        identity: sec_identity_t,
        pinnedPublicKey: Data
    ) {
        self.init(identity: identity) { trust in
            let secTrust = trust as! SecTrust
            guard let certificate = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate])?.first,
                  let key = SecCertificateCopyKey(certificate),
                  let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data?
            else { return false }

            return keyData == pinnedPublicKey
        }
    }

    func configure(_ tls: TLS) -> TLS {
        tls
            .localIdentity(identity)
            .certificateValidator { _, trust in
                validator(trust)
            }
    }

    func configure(_ quic: QUIC) -> QUIC {
        var configured = quic
        configured = configured.tls.localIdentity(identity)
        configured = configured.tls.certificateValidator { _, trust in
            validator(trust)
        }
        return configured
    }
}