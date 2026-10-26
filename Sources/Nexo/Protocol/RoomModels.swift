import Foundation

// MARK: - RoomID

/// Identificador lógico de una sala, independiente del transporte: no deriva de
/// un endpoint de Bonjour ni de una conexión concreta, así que sobrevive a
/// reconexiones y puede viajar dentro de los mensajes.
public struct RoomID: Hashable, Codable, Sendable, Identifiable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    /// Reconstruye un `RoomID` publicado en un TXT o un mensaje.
    public init?(string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.rawValue = uuid
    }

    public var id: UUID { rawValue }
    public var description: String { rawValue.uuidString }

    /// Forma corta para depuración o como código de sala legible. Es también el
    /// `roomCode` por defecto del que se deriva la PSK de la sala.
    public var shortCode: String {
        String(rawValue.uuidString.prefix(8))
    }
}

// MARK: - RoomRole

public enum RoomRole: String, Codable, Sendable {
    /// Autoridad de la sala: admite miembros, la cierra, arbitra actividades.
    case host
    case guest
}

// MARK: - RoomAccessPolicy

public enum RoomAccessPolicy: String, Codable, Sendable, CaseIterable {
    /// Cualquier peer que descubra la sala entra directamente.
    case open
    /// El host debe aprobar cada solicitud de entrada.
    case approval
}

// MARK: - RoomFeatures

/// Capacidades activas en una sala dada.
///
/// Es lo que hace flexible el modelo: una sala solo-chat, una solo-juego y una
/// mixta son la misma entidad con distintos flags.
public struct RoomFeatures: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let chat = RoomFeatures(rawValue: 1 << 0)
    public static let activities = RoomFeatures(rawValue: 1 << 1)
    public static let fileTransfer = RoomFeatures(rawValue: 1 << 2)

    public static let chatOnly: RoomFeatures = [.chat, .fileTransfer]
    public static let gameOnly: RoomFeatures = [.activities]
    public static let full: RoomFeatures = [.chat, .activities, .fileTransfer]

    public var hasChat: Bool { contains(.chat) }
    public var hasActivities: Bool { contains(.activities) }
    public var hasFileTransfer: Bool { contains(.fileTransfer) }
}

// MARK: - RoomMember

public struct RoomMember: Codable, Hashable, Sendable, Identifiable {
    /// Identidad estable de la instalación remota, no un ID de transporte.
    public let deviceID: DeviceID
    public let displayName: String
    public let role: RoomRole
    /// Token de avatar opaco elegido por el peer (clave de catálogo o miniatura
    /// codificada). Ausente en peers anteriores a este campo.
    public let avatar: String?

    public var id: DeviceID { deviceID }

    public init(
        deviceID: DeviceID,
        displayName: String,
        role: RoomRole,
        avatar: String? = nil
    ) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.role = role
        self.avatar = avatar
    }

    public var isHost: Bool { role == .host }
}

// MARK: - RoomDescriptor

/// Descripción transportable de una sala. No contiene tipos de Network framework.
public struct RoomDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let id: RoomID
    public var name: String
    /// Identidad del dispositivo host que la creó y gobierna.
    public var hostDeviceID: DeviceID
    /// Se incrementa cada vez que la autoridad pasa a otro miembro de la sala.
    public var hostGeneration: UInt64
    public var features: RoomFeatures
    /// Actividad principal prevista. Una sala de juego la declara para que el
    /// descubrimiento pueda filtrar por juego sin conectar.
    public var activityKind: ActivityKind?
    public var accessPolicy: RoomAccessPolicy
    public var memberCount: Int
    /// `nil` significa que el producto no declaró límite.
    public var capacity: Int?
    public let protocolVersion: UInt8

    public init(
        id: RoomID = RoomID(),
        name: String,
        hostDeviceID: DeviceID,
        features: RoomFeatures,
        activityKind: ActivityKind? = nil,
        accessPolicy: RoomAccessPolicy = .open,
        memberCount: Int = 1,
        capacity: Int? = nil,
        hostGeneration: UInt64 = 0,
        protocolVersion: UInt8 = ProtocolInfo.currentVersion
    ) {
        self.id = id
        self.name = name
        self.hostDeviceID = hostDeviceID
        self.hostGeneration = hostGeneration
        self.features = features
        self.activityKind = activityKind
        self.accessPolicy = accessPolicy
        self.memberCount = memberCount
        self.capacity = capacity
        self.protocolVersion = protocolVersion
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, hostDeviceID, hostGeneration, features, activityKind
        case accessPolicy, memberCount, capacity, protocolVersion
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(RoomID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        hostDeviceID = try container.decode(DeviceID.self, forKey: .hostDeviceID)
        hostGeneration = try container.decodeIfPresent(UInt64.self, forKey: .hostGeneration) ?? 0
        features = try container.decode(RoomFeatures.self, forKey: .features)
        activityKind = try container.decodeIfPresent(ActivityKind.self, forKey: .activityKind)
        accessPolicy = try container.decode(RoomAccessPolicy.self, forKey: .accessPolicy)
        memberCount = try container.decode(Int.self, forKey: .memberCount)
        capacity = try container.decodeIfPresent(Int.self, forKey: .capacity)
        protocolVersion = try container.decode(UInt8.self, forKey: .protocolVersion)
    }

    public var isFull: Bool {
        guard let capacity else { return false }
        return memberCount >= capacity
    }

    public var requiresApproval: Bool { accessPolicy == .approval }
}

// MARK: - RoomAccessState

/// Estado de la relación del usuario local con una sala.
public enum RoomAccessState: Equatable, Sendable {
    /// Descubierta pero no solicitada.
    case available
    /// Solicitud enviada, esperando decisión del host.
    case awaitingApproval
    case joined
    /// La conexión física al host está suspendida (p. ej. en segundo plano).
    case suspended
    /// Reintentando recuperar la membresía.
    case reconnecting
    /// El host rechazó la entrada o expulsó al miembro.
    case rejected(reason: DisconnectReason)
    /// La sala se cerró o el host desapareció.
    case closed(reason: DisconnectReason)

    public var isUsable: Bool { self == .joined }
}

// MARK: - RoomJoinRequest

/// Solicitud de entrada pendiente. Está acotada por sala, no es global: un host
/// puede tener varias salas con colas independientes.
public struct RoomJoinRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let roomID: RoomID
    public let deviceID: DeviceID
    public let displayName: String
    public let avatar: String?
    public let receivedAt: Date
    public let requestID: UUID?
    public let connectionSessionID: UUID?

    public init(
        id: UUID = UUID(),
        roomID: RoomID,
        deviceID: DeviceID,
        displayName: String,
        avatar: String? = nil,
        receivedAt: Date = Date(),
        requestID: UUID? = nil,
        connectionSessionID: UUID? = nil
    ) {
        self.id = id
        self.roomID = roomID
        self.deviceID = deviceID
        self.displayName = displayName
        self.avatar = avatar
        self.receivedAt = receivedAt
        self.requestID = requestID
        self.connectionSessionID = connectionSessionID
    }
}

// MARK: - DiscoveredRoom

/// Una sala anunciada por un peer cercano, aún no unida. Combina el descriptor
/// publicado con el identificador de transporte necesario para conectar.
public struct DiscoveredRoom: Identifiable, Sendable, Equatable {
    public let descriptor: RoomDescriptor
    /// Peer que anuncia la sala. Puede ser el host o un miembro que la retransmite.
    public let advertisedBy: TransportPeerID
    public let hostDisplayName: String
    public let discoveredAt: Date

    public var id: RoomID { descriptor.id }
    public var name: String { descriptor.name }
    public var features: RoomFeatures { descriptor.features }
    public var activityKind: ActivityKind? { descriptor.activityKind }
}
