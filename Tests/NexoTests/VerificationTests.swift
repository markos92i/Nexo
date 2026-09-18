//
//  VerificationTests.swift
//  Nexo
//

import Foundation
import Testing
@testable import Nexo

// MARK: - Fingerprint Formatter Tests

@Test func fingerprintFormatGroups() {
    let fingerprint = "a3b5c7d9e1f2"
    let formatted = NexoFingerprintFormatter.format(fingerprint)
    
    #expect(formatted == "A3B5 C7D9 E1F2")
}

@Test func fingerprintFormatCustomGroupSize() {
    let fingerprint = "a3b5c7d9"
    let formatted = NexoFingerprintFormatter.format(fingerprint, groupSize: 2, separator: ":")
    
    #expect(formatted == "A3:B5:C7:D9")
}

@Test func fingerprintToEmojiProducesConsistentOutput() {
    let fingerprint = "a3b5c7d9e1f20011223344556677889900aabbccddeeff"
    
    let emoji1 = NexoFingerprintFormatter.toEmoji(fingerprint)
    let emoji2 = NexoFingerprintFormatter.toEmoji(fingerprint)
    
    #expect(emoji1 == emoji2)
    #expect(emoji1.count == 8) // 8 emojis
}

@Test func fingerprintToEmojiDifferentInputsProduceDifferentOutput() {
    let fp1 = "a3b5c7d9e1f20011223344556677889900aabbccddeeff"
    let fp2 = "00112233445566778899aabbccddeeff00112233445566"
    
    let emoji1 = NexoFingerprintFormatter.toEmoji(fp1)
    let emoji2 = NexoFingerprintFormatter.toEmoji(fp2)
    
    #expect(emoji1 != emoji2)
}

@Test func fingerprintToWordsProducesConsistentOutput() {
    let fingerprint = "a3b5c7d9e1f20011223344556677889900aabbccddeeff"
    
    let words1 = NexoFingerprintFormatter.toWords(fingerprint)
    let words2 = NexoFingerprintFormatter.toWords(fingerprint)
    
    #expect(words1 == words2)
    
    let wordCount = words1.split(separator: " ").count
    #expect(wordCount == 6) // 6 palabras
}

@Test func fingerprintCompareIsCaseInsensitive() {
    let lower = "a3b5c7d9"
    let upper = "A3B5C7D9"
    let mixed = "a3B5c7D9"
    
    #expect(NexoFingerprintFormatter.compare(lower, upper) == true)
    #expect(NexoFingerprintFormatter.compare(lower, mixed) == true)
    #expect(NexoFingerprintFormatter.compare(upper, mixed) == true)
}

@Test func fingerprintCompareDetectsDifferences() {
    let fp1 = "a3b5c7d9"
    let fp2 = "a3b5c7d8"  // último dígito diferente
    
    #expect(NexoFingerprintFormatter.compare(fp1, fp2) == false)
}

// MARK: - Trust Record Tests

@Test func trustRecordEncoding() throws {
    let record = NexoTrustRecord(
        applicationID: "test-app-123",
        displayName: "iPhone de Juan",
        fingerprint: "abc123def456",
        isVerified: true,
        firstSeenAt: Date(timeIntervalSince1970: 1000000),
        lastSeenAt: Date(timeIntervalSince1970: 2000000),
        lastVerifiedAt: Date(timeIntervalSince1970: 1500000)
    )
    
    let encoded = try JSONEncoder().encode(record)
    let decoded = try JSONDecoder().decode(NexoTrustRecord.self, from: encoded)
    
    #expect(decoded.applicationID == record.applicationID)
    #expect(decoded.displayName == record.displayName)
    #expect(decoded.fingerprint == record.fingerprint)
    #expect(decoded.isVerified == record.isVerified)
}

// MARK: - QR Verification Data Tests

@Test func qrDataEncoding() throws {
    let qrData = NexoVerificationQRData(
        applicationID: "my-app-id",
        displayName: "Mi iPhone",
        fingerprint: "a3b5c7d9e1f2001122334455667788"
    )
    
    guard let encoded = qrData.encode() else {
        Issue.record("Failed to encode QR data")
        return
    }
    
    guard let decoded = NexoVerificationQRData.decode(encoded) else {
        Issue.record("Failed to decode QR data")
        return
    }
    
    #expect(decoded.applicationID == qrData.applicationID)
    #expect(decoded.displayName == qrData.displayName)
    #expect(decoded.fingerprint == qrData.fingerprint)
}

@Test func qrDataMatchesConnectedPeer() {
    let fingerprint = "a3b5c7d9e1f2001122334455667788"
    
    let qrData = NexoVerificationQRData(
        applicationID: "peer-123",
        displayName: "Peer Name",
        fingerprint: fingerprint
    )
    
    let matchingPeer = ConnectedPeer(
        applicationID: "peer-123",
        displayName: "Peer Name",
        certificateFingerprint: fingerprint,
        protocolVersion: 3,
        capabilities: [.rooms, .chat],
        connectionSessionID: UUID()
    )
    
    let differentAppIDPeer = ConnectedPeer(
        applicationID: "peer-456",
        displayName: "Other Peer",
        certificateFingerprint: fingerprint,
        protocolVersion: 3,
        capabilities: [.rooms],
        connectionSessionID: UUID()
    )
    
    let differentFingerprintPeer = ConnectedPeer(
        applicationID: "peer-123",
        displayName: "Peer Name",
        certificateFingerprint: "different-fingerprint",
        protocolVersion: 3,
        capabilities: [.rooms],
        connectionSessionID: UUID()
    )
    
    #expect(qrData.matches(matchingPeer) == true)
    #expect(qrData.matches(differentAppIDPeer) == false)
    #expect(qrData.matches(differentFingerprintPeer) == false)
}

// MARK: - Peer Identity Info Tests

@Test func peerIdentityInfoFormattedFingerprint() {
    let info = NexoPeerIdentityInfo(
        applicationID: "test",
        displayName: "Test Device",
        fingerprint: "a3b5c7d9e1f2001122334455667788990011223344556677",
        verificationState: .unknown,
        firstSeenAt: nil,
        lastVerifiedAt: nil
    )
    
    // El fingerprint formateado debe tener espacios
    #expect(info.formattedFingerprint.contains(" "))
    
    // Los emojis deben ser consistentes
    #expect(info.emojiFingerprint.isEmpty == false)
    
    // Las palabras deben ser consistentes
    #expect(info.wordFingerprint.isEmpty == false)
}

// MARK: - Verification State Tests

@Test func verificationStatesAreMutuallyExclusive() {
    let states: [NexoPeerVerificationState] = [.unknown, .trustedOnFirstUse, .verified, .identityChanged]
    
    // Cada estado debe ser único
    #expect(Set(states).count == states.count)
}
