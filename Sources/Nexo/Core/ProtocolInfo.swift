import Foundation

// MARK: - ProtocolInfo

/// Versión y capacidades del protocolo de aplicación que viaja sobre Network
/// framework. Se negocia durante el handshake, antes de admitir ningún envelope.
public enum ProtocolInfo {

    public static let currentVersion: UInt8 = 1
    public static let minimumVersion: UInt8 = 1

    /// Capacidades anunciadas en el `hello`. Permiten desplegar funciones nuevas
    /// sin romper peers antiguos: una capacidad no soportada simplemente no se usa.
    public static let capabilities: Set<Capability> = [
        .rooms,
        .chat,
        .activities,
        .fileTransfer,
        .coalescedSnapshots,
        .binaryStreams
    ]

    public static func isCompatible(remoteVersion: UInt8) -> Bool {
        remoteVersion >= minimumVersion
    }
}

// MARK: - ServiceType

/// Tipo de servicio Bonjour con el que una app anuncia y busca peers.
///
/// Cada app basada en Nexo debe usar el suyo: dos apps con el mismo tipo se
/// verían entre sí y fallarían al conectar, porque sus PSK no coinciden. El
/// valor debe declararse en `NSBonjourServices` del Info.plist (`_nombre._tcp`).
public struct ServiceType: Sendable, Equatable, CustomStringConvertible {
    /// Nombre corto sin guion bajo ni protocolo, p. ej. `"project-dark"`.
    public let name: String

    /// - Precondition: 1–15 caracteres, solo minúsculas ASCII, dígitos y guiones,
    ///   sin empezar ni acabar en guion (RFC 6335).
    public init(_ name: String) {
        precondition(Self.isValid(name), "Invalid Bonjour service name: \(name)")
        self.name = name
    }

    /// Tipo genérico. Úsalo solo en pruebas: una app real debe tener el suyo.
    public static let nexo = ServiceType("nexo")

    /// Tipo completo para Bonjour, p. ej. `_project-dark._tcp`.
    public var bonjourType: String { "_\(name)._tcp" }

    public var description: String { bonjourType }

    static func isValid(_ name: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        return (1...15).contains(name.count)
            && name.allSatisfy(allowed.contains)
            && name.first != "-" && name.last != "-"
    }
}

// MARK: - Capability

public enum Capability: String, Codable, Sendable, CaseIterable {
    case rooms
    case chat
    case activities
    case fileTransfer
    case coalescedSnapshots
    case binaryStreams
}

// MARK: - Limits

/// Límites técnicos. No hay tope duro de participantes, pero el host necesita
/// protegerse de presión de memoria, ancho de banda y mensajes abusivos.
public enum Limits {

    public static let maximumEnvelopeBytes = 512 * 1024
    public static let maximumTransferBytes: Int64 = 25 * 1024 * 1024
    public static let transferChunkBytes = 32 * 1024
    /// Chunks en vuelo antes de esperar backpressure del receptor.
    public static let transferWindowChunks = 8
    public static let chatHistoryLimit = 500

    /// Cuánto tiempo una desconexión física se sigue considerando recuperable.
    /// También se comprueba al volver a primer plano, ya que iOS puede suspender
    /// la ejecución sin garantizar que un temporizador avance.
    public static let temporaryDisconnectGracePeriod: TimeInterval = 60
    /// Falla antes que el periodo de gracia de reconexión para que un host muerto
    /// no congele una malla por lo demás conectada durante un minuto entero.
    public static let hostMigrationDelay: Duration = .seconds(5)

    /// Ventana de retención del journal de chat/actividad usado para reenviar
    /// mensajes tras una reconexión física.
    public static let recoveryJournalRetention: TimeInterval = 60
    public static let recoveryJournalLimit = 2_000
    public static let recoveryJournalBytesLimit = 4 * 1024 * 1024
    public static let recoveryChatMessageLimit = 100
    public static let recoveryMemberLimit = 256
    public static let recoveryActivityLimit = 64

    /// Salas anunciadas en el TXT de Bonjour. El resto se descubren al conectar
    /// vía `roomDirectory`.
    public static let advertisedRoomLimit = 3

    public static let handshakeTimeout: Duration = .seconds(12)
    /// Plazo para conectar con el host al entrar en una sala. Algo mayor que el
    /// handshake, que ya acota la conexión física.
    public static let joinConnectTimeout: Duration = .seconds(15)
    /// Plazo para que el host responda una vez conectados. Depende de que una
    /// persona acepte, así que es largo; la UI permite cancelar antes.
    public static let joinApprovalTimeout: Duration = .seconds(120)
    /// Plazo de una re-entrada automática tras reconectar, sin persona de por medio.
    public static let joinTimeout: Duration = .seconds(30)
}
