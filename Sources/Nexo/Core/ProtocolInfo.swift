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
