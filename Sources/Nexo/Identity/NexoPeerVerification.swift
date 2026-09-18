//
//  NexoPeerVerification.swift
//  Nexo
//

import Foundation
import CryptoKit
import OSLog

// MARK: - NexoPeerVerificationState

/// Estado de verificación de la identidad de un peer.
///
/// Nexo usa un modelo TOFU (Trust On First Use) similar a SSH:
/// - La primera conexión almacena el fingerprint del peer
/// - Conexiones subsiguientes verifican que el fingerprint coincide
/// - Un cambio de fingerprint es una alerta de seguridad
public enum NexoPeerVerificationState: String, Sendable, Equatable, CaseIterable {
    /// El peer nunca se ha conectado antes. Su identidad no ha sido verificada.
    case unknown
    /// El peer se conectó por primera vez y el usuario aceptó su identidad.
    /// La conexión está cifrada pero no hay garantía de que sea quien dice ser.
    case trustedOnFirstUse
    /// El fingerprint del peer fue verificado fuera de banda (QR, comparación visual).
    case verified
    /// El fingerprint del peer cambió desde la última conexión conocida.
    /// Puede indicar un ataque MITM o que el peer reinstaló la app.
    case identityChanged
}

// MARK: - NexoPeerIdentityInfo

/// Información de identidad de un peer para mostrar al usuario.
public struct NexoPeerIdentityInfo: Sendable, Equatable, Identifiable {
    /// Application ID del peer.
    public let applicationID: String
    /// Nombre mostrado del peer.
    public let displayName: String
    /// Fingerprint SHA-256 del certificado público.
    public let fingerprint: String
    /// Estado de verificación.
    public let verificationState: NexoPeerVerificationState
    /// Fecha de primera conexión (si está en trust store).
    public let firstSeenAt: Date?
    /// Fecha de última verificación exitosa.
    public let lastVerifiedAt: Date?
    
    public var id: String { applicationID }
    
    /// Fingerprint formateado para mostrar (grupos de 4 caracteres).
    public var formattedFingerprint: String {
        NexoFingerprintFormatter.format(fingerprint)
    }
    
    /// Fingerprint representado como emojis para comparación visual fácil.
    public var emojiFingerprint: String {
        NexoFingerprintFormatter.toEmoji(fingerprint)
    }
    
    /// Fingerprint representado como palabras para verificación por voz.
    public var wordFingerprint: String {
        NexoFingerprintFormatter.toWords(fingerprint)
    }
}

// MARK: - NexoFingerprintFormatter

/// Utilidades para formatear fingerprints de forma legible.
public enum NexoFingerprintFormatter {
    
    /// Formatea un fingerprint hex en grupos de 4 caracteres.
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
    
    /// Convierte un fingerprint a una secuencia de emojis.
    ///
    /// Cada par de caracteres hex (256 valores) se mapea a un emoji.
    /// Esto hace la comparación visual más fácil y menos propensa a errores.
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
        
        // Tomamos los primeros 8 bytes (16 chars hex) para generar 8 emojis
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
    
    /// Convierte un fingerprint a una frase de palabras.
    ///
    /// Usa una lista de palabras cortas y distintivas, similar al sistema
    /// de verificación de Signal/WhatsApp.
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
        
        // Tomamos 6 bytes para generar 6 palabras
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
    
    /// Compara dos fingerprints y devuelve si coinciden.
    public static func compare(_ a: String, _ b: String) -> Bool {
        a.lowercased() == b.lowercased()
    }
    
    /// Genera el fingerprint SHA-256 de una clave pública.
    public static func fingerprint(of publicKey: Data) -> String {
        SHA256.hash(data: publicKey)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - NexoPeerVerificationService

/// Servicio para gestionar la verificación de identidad de peers.
///
/// Este servicio implementa TOFU (Trust On First Use):
/// 1. Primera conexión: el fingerprint se almacena tras aceptación del usuario
/// 2. Conexiones siguientes: se verifica que el fingerprint coincida
/// 3. Cambio de fingerprint: se alerta al usuario (posible MITM)
///
/// Para mayor seguridad, los usuarios pueden verificar fingerprints fuera de banda
/// (comparando emojis en persona, escaneando QR, etc.) y marcar el peer como "verificado".
@MainActor
@Observable
public final class NexoPeerVerificationService {
    
    private static let logger = Logger(subsystem: "com.zafir.nexo", category: "verification")
    
    private let trustStore: NexoEnhancedTrustStore
    
    /// Peers con identidad cambiada detectada (posible MITM).
    public private(set) var identityChangedPeers: Set<String> = []
    
    /// Callback cuando se detecta un cambio de identidad.
    public var onIdentityChanged: ((NexoPeerIdentityInfo, String) -> Void)?
    
    public init(applicationID: String) {
        self.trustStore = NexoEnhancedTrustStore(applicationID: applicationID)
    }
    
    // MARK: - Verification API
    
    /// Verifica un peer conectado y retorna su estado de verificación.
    public func verify(_ peer: ConnectedPeer) -> NexoPeerVerificationState {
        guard let fingerprint = peer.certificateFingerprint else {
            return .unknown
        }
        
        guard let storedRecord = trustStore.record(for: peer.applicationID) else {
            // Primera vez que vemos este peer
            return .unknown
        }
        
        // Verificar que el fingerprint coincide
        guard NexoFingerprintFormatter.compare(fingerprint, storedRecord.fingerprint) else {
            // ¡Alerta! El fingerprint cambió
            Self.logger.warning("Identity changed for peer \(peer.applicationID): expected \(storedRecord.fingerprint.prefix(16))..., got \(fingerprint.prefix(16))...")
            identityChangedPeers.insert(peer.applicationID)
            
            let info = identityInfo(for: peer, state: .identityChanged)
            onIdentityChanged?(info, storedRecord.fingerprint)
            
            return .identityChanged
        }
        
        // El fingerprint coincide
        identityChangedPeers.remove(peer.applicationID)
        trustStore.updateLastSeen(for: peer.applicationID)
        
        return storedRecord.isVerified ? .verified : .trustedOnFirstUse
    }
    
    /// Confía en un peer por primera vez (TOFU).
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
    
    /// Marca un peer como verificado (el usuario confirmó el fingerprint fuera de banda).
    @discardableResult
    public func markAsVerified(_ peer: ConnectedPeer) -> Bool {
        guard peer.certificateFingerprint != nil else { return false }
        return trustStore.markAsVerified(peer.applicationID)
    }
    
    /// Acepta un cambio de identidad (el usuario confirmó que es legítimo).
    ///
    /// Esto reemplaza el fingerprint almacenado. Usar con precaución.
    @discardableResult
    public func acceptIdentityChange(_ peer: ConnectedPeer) -> Bool {
        guard let fingerprint = peer.certificateFingerprint else { return false }
        
        Self.logger.info("User accepted identity change for \(peer.applicationID)")
        identityChangedPeers.remove(peer.applicationID)
        
        // Eliminar el registro antiguo y crear uno nuevo
        trustStore.revoke(peer.applicationID)
        return trustStore.trust(
            applicationID: peer.applicationID,
            displayName: peer.displayName,
            fingerprint: fingerprint,
            isVerified: false
        )
    }
    
    /// Revoca la confianza en un peer.
    public func revoke(_ applicationID: String) {
        trustStore.revoke(applicationID)
        identityChangedPeers.remove(applicationID)
    }
    
    /// Obtiene información de identidad para mostrar al usuario.
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
    
    /// Lista todos los peers confiados.
    public func trustedPeers() -> [NexoTrustRecord] {
        trustStore.allRecords()
    }
    
    /// Verifica si un peer está confiado.
    public func isTrusted(_ applicationID: String) -> Bool {
        trustStore.record(for: applicationID) != nil
    }
}

// MARK: - NexoTrustRecord

/// Registro de confianza almacenado para un peer.
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

/// Almacén mejorado de peers confiados con metadatos adicionales.
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

/// Datos para generar un código QR de verificación.
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
    
    /// Codifica los datos para un código QR.
    public func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }
    
    /// Decodifica datos de un código QR escaneado.
    public static func decode(_ data: Data) -> NexoVerificationQRData? {
        try? JSONDecoder().decode(NexoVerificationQRData.self, from: data)
    }
    
    /// Verifica si los datos del QR coinciden con un peer conectado.
    public func matches(_ peer: ConnectedPeer) -> Bool {
        guard let peerFingerprint = peer.certificateFingerprint else { return false }
        return applicationID == peer.applicationID
            && NexoFingerprintFormatter.compare(fingerprint, peerFingerprint)
    }
}
