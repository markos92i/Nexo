import Foundation
import CryptoKit

// MARK: - SessionCrypto

/// Material de cifrado de sesión basado en clave precompartida (PSK).
///
/// Sustituye al modelo de certificado autofirmado. El canal se cifra con una PSK
/// que solo pueden derivar quienes comparten el mismo secreto de app (y, si se
/// usa, el mismo código de sala). Si un peer no conoce el secreto, el handshake
/// PSK falla y no se conecta.
///
/// Es `Sendable` de verdad: solo contiene `Data` inmutable, sin tipos de C.
///
/// - `appSecret` lo aporta el consumidor (constante compilada en su app):
///   garantiza "solo mi app habla con mi app".
/// - `roomCode` (opcional) aísla el canal por sala: dos peers de la misma app
///   pero distinta sala no pueden descifrarse entre sí.
///
/// Derivación:
/// ```
/// PSK     = HMAC-SHA256(key: appSecret, message: roomCode ?? "")
/// pskHint = SHA256(PSK).prefix(16)   // identificador público, no secreto
/// ```
public struct SessionCrypto: Sendable, Equatable {

    /// Clave precompartida de 32 bytes derivada del secreto de app y el código de sala.
    public let psk: Data
    /// Identificador público de la PSK (el "hint" del handshake). No es secreto:
    /// confirma que dos peers comparten la misma PSK, sin revelarla.
    public let pskHint: String

    /// Canal común de app: todas las salas comparten PSK.
    public init(appSecret: Data) {
        self.init(appSecret: appSecret, roomCode: nil)
    }

    /// Canal aislado por sala: la PSK depende también del código de sala.
    public init(appSecret: Data, roomCode: String) {
        self.init(appSecret: appSecret, roomCode: Optional(roomCode))
    }

    /// Conveniencia: deriva el secreto de app de una cadena UTF-8.
    public init(appSecret: String, roomCode: String? = nil) {
        self.init(appSecret: Data(appSecret.utf8), roomCode: roomCode)
    }

    private init(appSecret: Data, roomCode: String?) {
        let key = SymmetricKey(data: appSecret)
        let message = Data((roomCode ?? "").utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        let psk = Data(mac)
        self.psk = psk
        self.pskHint = Self.hint(for: psk)
    }

    /// Hint público derivado de una PSK: primeros 16 bytes de su SHA-256, en hex.
    static func hint(for psk: Data) -> String {
        SHA256.hash(data: psk)
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
