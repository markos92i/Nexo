import Foundation

// MARK: - ActivityID

/// Identifica una instancia de actividad dentro de una sala. Una sala puede
/// alojar varias actividades vivas, y una revancha obtiene un ID nuevo.
public struct ActivityID: Hashable, Codable, Sendable, Identifiable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var id: UUID { rawValue }
    public var description: String { rawValue.uuidString }
}

// MARK: - ActivityKind

/// Identificador abierto de un tipo de actividad.
///
/// Nexo no incluye ninguno: cada juego declara el suyo en su propio módulo, p. ej.
/// `extension ActivityKind { static let sudoku = ActivityKind("sudoku") }`.
/// El título, icono y demás metadatos de presentación viven en el catálogo de la
/// app, nunca aquí.
public struct ActivityKind: RawRepresentable, Hashable, Codable, Sendable, Identifiable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var id: String { rawValue }
}

// MARK: - ActivityState

public enum ActivityState: String, Codable, Sendable {
    case lobby
    case running
    /// Terminada; la UI muestra el resultado antes de desmontarla.
    case finished
    case cancelled
}

// MARK: - ActivityDescriptor

/// Descripción transportable de una actividad.
public struct ActivityDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let id: ActivityID
    public let roomID: RoomID
    public let kind: ActivityKind
    /// Autoridad de esta actividad. Puede diferir del host de la sala.
    public var hostDeviceID: DeviceID
    /// Se incrementa cada vez que la autoridad de la actividad pasa a otro participante.
    public var hostGeneration: UInt64
    public var participantIDs: Set<DeviceID>
    public var state: ActivityState
    /// `true` si está abierta a toda la sala, de modo que los miembros que entren
    /// más tarde se admiten automáticamente mientras siga en `.lobby`. `false` si
    /// el host eligió a mano los participantes.
    public let admitsRoomMembers: Bool
    /// `true` si solo puede haber una instancia de este tipo activa a la vez en la
    /// sala (un juego). `false` si puede correr junto a cualquier otra actividad
    /// activa (p. ej. chat).
    public let isExclusive: Bool

    public init(
        id: ActivityID = ActivityID(),
        roomID: RoomID,
        kind: ActivityKind,
        hostDeviceID: DeviceID,
        participantIDs: Set<DeviceID>,
        hostGeneration: UInt64 = 0,
        state: ActivityState = .lobby,
        admitsRoomMembers: Bool = true,
        isExclusive: Bool = true
    ) {
        self.id = id
        self.roomID = roomID
        self.kind = kind
        self.hostDeviceID = hostDeviceID
        self.hostGeneration = hostGeneration
        self.participantIDs = participantIDs
        self.state = state
        self.admitsRoomMembers = admitsRoomMembers
        self.isExclusive = isExclusive
    }

    /// Decodificación tolerante para peers que no envían los campos nuevos.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ActivityID.self, forKey: .id)
        roomID = try container.decode(RoomID.self, forKey: .roomID)
        kind = try container.decode(ActivityKind.self, forKey: .kind)
        hostDeviceID = try container.decode(DeviceID.self, forKey: .hostDeviceID)
        hostGeneration = try container.decodeIfPresent(UInt64.self, forKey: .hostGeneration) ?? 0
        participantIDs = try container.decode(Set<DeviceID>.self, forKey: .participantIDs)
        state = try container.decode(ActivityState.self, forKey: .state)
        admitsRoomMembers = try container.decodeIfPresent(Bool.self, forKey: .admitsRoomMembers) ?? true
        isExclusive = try container.decodeIfPresent(Bool.self, forKey: .isExclusive) ?? true
    }

    public func includes(_ deviceID: DeviceID) -> Bool {
        participantIDs.contains(deviceID)
    }

    public var isActive: Bool { state == .lobby || state == .running }
}
