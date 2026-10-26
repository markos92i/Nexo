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

    /// Debe coincidir con `NSBonjourServices` en el Info.plist de la app.
    public static let serviceType = "_nexo._tcp"
    public static let quicServiceType = "_nexo._udp"

    public static func isCompatible(remoteVersion: UInt8) -> Bool {
        remoteVersion >= minimumVersion
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
