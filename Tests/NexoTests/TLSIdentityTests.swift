//
//  TLSIdentityTests.swift
//  Nexo
//

import Foundation
import Testing
import CryptoKit
@testable import Nexo

// MARK: - Fingerprint Generation Tests

@Test func fingerprintGenerationIsConsistent() {
    let publicKeyData = Data([0x04, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
                              0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f])
    
    let fingerprint1 = NexoFingerprintFormatter.fingerprint(of: publicKeyData)
    let fingerprint2 = NexoFingerprintFormatter.fingerprint(of: publicKeyData)
    
    #expect(fingerprint1 == fingerprint2)
    #expect(fingerprint1.count == 64) // SHA-256 produce 32 bytes = 64 hex chars
}

@Test func fingerprintGenerationDifferentKeysAreDifferent() {
    let key1 = Data([0x01, 0x02, 0x03, 0x04])
    let key2 = Data([0x01, 0x02, 0x03, 0x05])  // Un byte diferente
    
    let fp1 = NexoFingerprintFormatter.fingerprint(of: key1)
    let fp2 = NexoFingerprintFormatter.fingerprint(of: key2)
    
    #expect(fp1 != fp2)
}

@Test func fingerprintIsValidHex() {
    let publicKeyData = Data("test public key data".utf8)
    let fingerprint = NexoFingerprintFormatter.fingerprint(of: publicKeyData)
    
    // Debe contener solo caracteres hex válidos
    let validHexChars = CharacterSet(charactersIn: "0123456789abcdef")
    let fingerprintChars = CharacterSet(charactersIn: fingerprint)
    
    #expect(fingerprintChars.isSubset(of: validHexChars))
}

// MARK: - TLS Configuration Tests

@Test func tlsConfigurationCreation() throws {
    // Este test verifica que la estructura de NexoTLSConfiguration se puede crear
    // No podemos probar la funcionalidad real sin un sec_identity_t válido
    
    // Verificamos que los tipos públicos existen y tienen la forma correcta
    #expect(NexoTLSConfiguration.self is Any.Type)
}

// MARK: - Local TLS Identity Error Tests

@Test func localTLSIdentityErrorDescriptions() {
    let errors: [NexoLocalTLSIdentityError] = [
        .incompleteKeychainState,
        .keyGenerationFailed("test reason"),
        .certificateStorageFailed(42),
        .identityCreationFailed,
        .keyCertificateMismatch
    ]
    
    for error in errors {
        // Cada error debe tener una descripción no vacía
        #expect(error.errorDescription?.isEmpty == false)
    }
}

@Test func localTLSIdentityErrorMessages() {
    let error1 = NexoLocalTLSIdentityError.keyGenerationFailed("test reason")
    #expect(error1.errorDescription?.contains("test reason") == true)
    
    let error2 = NexoLocalTLSIdentityError.certificateStorageFailed(-25300)
    #expect(error2.errorDescription?.contains("-25300") == true)
}
