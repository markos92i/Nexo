import Foundation

// MARK: - TransportPeerID

/// Identidad efímera de endpoint dentro del transporte. Cambia entre sesiones y
/// nunca debe usarse como identidad de dominio (para eso está `DeviceID`).
public struct TransportPeerID: Hashable, Codable, Sendable, Identifiable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var id: String { rawValue }
    public var description: String { rawValue }
}

// MARK: - PeerAdvertisement

/// Un anuncio de Bonjour de un dispositivo cercano, leído del TXT antes de abrir
/// ninguna conexión. Permite listar salas sin conectar a cada peer.
public struct PeerAdvertisement: Identifiable, Sendable, Equatable {
    public let endpointID: TransportPeerID
    public let deviceID: DeviceID?
    public let displayName: String
    public let protocolVersion: UInt8
    /// Salas anunciadas en el TXT. Puede ser un subconjunto de las alojadas.
    public let rooms: [RoomDescriptor]
    /// Total real de salas alojadas, aunque no todas quepan en el TXT.
    public let totalRoomCount: Int

    public var id: TransportPeerID { endpointID }

    public var isCompatible: Bool { ProtocolInfo.isCompatible(remoteVersion: protocolVersion) }

    public var hasUndisclosedRooms: Bool { totalRoomCount > rooms.count }

    public init(
        endpointID: TransportPeerID,
        deviceID: DeviceID?,
        displayName: String,
        protocolVersion: UInt8,
        rooms: [RoomDescriptor],
        totalRoomCount: Int
    ) {
        self.endpointID = endpointID
        self.deviceID = deviceID
        self.displayName = displayName
        self.protocolVersion = protocolVersion
        self.rooms = rooms
        self.totalRoomCount = totalRoomCount
    }
}

// MARK: - ConnectedPeer

/// Un peer con el handshake completado. A partir de aquí el sistema lo identifica
/// por `deviceID`, nunca por el identificador de conexión.
public struct ConnectedPeer: Identifiable, Sendable, Hashable {
    public let deviceID: DeviceID
    public let displayName: String
    /// Derivado público de la PSK negociada (`SHA256(PSK).prefix(16)` en hex).
    /// Confirma que el peer comparte el mismo secreto de app+sala; no identifica
    /// al dispositivo. Igual para todos los miembros de una misma sala.
    public let pskHint: String?
    public let protocolVersion: UInt8
    public let capabilities: Set<Capability>
    /// Instancia concreta de conexión. Cambia en cada reconexión; se usa para
    /// descartar eventos de una conexión ya reemplazada.
    public let connectionSessionID: UUID

    public var id: DeviceID { deviceID }

    public init(
        deviceID: DeviceID,
        displayName: String,
        pskHint: String?,
        protocolVersion: UInt8,
        capabilities: Set<Capability>,
        connectionSessionID: UUID
    ) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.pskHint = pskHint
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.connectionSessionID = connectionSessionID
    }

    public func supports(_ capability: Capability) -> Bool {
        capabilities.contains(capability)
    }
}

// MARK: - ConnectivityLifecycle

/// Estado global del transporte.
public enum ConnectivityLifecycle: String, Sendable, Equatable {
    case idle
    case active
    /// La app pasó a segundo plano: las salas se conservan, las conexiones no.
    case suspended
    case reconnecting
    case disconnected
}

// MARK: - LocalNetworkPermission

public enum LocalNetworkPermission: Sendable, Equatable {
    case unknown
    case available
    case denied
}
