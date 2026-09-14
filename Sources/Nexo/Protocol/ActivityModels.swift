//
//  ActivityModels.swift
//  Project Dark
//
//  Created by Marcos del Castillo Camacho on 11/09/2026.
//

import Foundation

// MARK: - ActivityID

/// Identificador de una actividad concreta dentro de una room. Una room puede
/// tener varias actividades vivas y una actividad puede repetirse (revancha)
/// con un identificador nuevo.
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
/// El paquete no conoce ningún juego concreto: cada juego declara su propio
/// `static let` en su propio módulo, p. ej. `extension ActivityKind { static
/// let sudoku = ActivityKind("sudoku") }`. Título, icono y demás metadatos de
/// presentación viven en el catálogo de la app, nunca aquí.
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
    /// Creada, admitiendo participantes.
    case lobby
    /// En curso.
    case running
    /// Terminada; la UI muestra el resultado antes de destruirla.
    case finished
    /// Cancelada por el host o por falta de participantes.
    case cancelled
}

// MARK: - ActivityDescriptor

/// Descripción transportable de una actividad.
public struct ActivityDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let id: ActivityID
    public let roomID: RoomID
    public let kind: ActivityKind
    /// Autoridad de la actividad. Puede no ser el host de la room.
    public let hostApplicationID: String
    public var participantIDs: Set<String>
    public var state: ActivityState
    /// `true` si la actividad se abrió a toda la room, de modo que quien entre
    /// después se incorpora automáticamente mientras siga en `.lobby`.
    /// `false` cuando el host eligió a dedo a los participantes.
    public let admitsRoomMembers: Bool
    /// `true` si solo puede haber una instancia activa de esta clase a la vez en
    /// la room (un juego). `false` si puede convivir con cualquier otra
    /// actividad activa (p. ej. un chat).
    public let isExclusive: Bool

    public init(
        id: ActivityID = ActivityID(),
        roomID: RoomID,
        kind: ActivityKind,
        hostApplicationID: String,
        participantIDs: Set<String>,
        state: ActivityState = .lobby,
        admitsRoomMembers: Bool = true,
        isExclusive: Bool = true
    ) {
        self.id = id
        self.roomID = roomID
        self.kind = kind
        self.hostApplicationID = hostApplicationID
        self.participantIDs = participantIDs
        self.state = state
        self.admitsRoomMembers = admitsRoomMembers
        self.isExclusive = isExclusive
    }

    /// Decodificación tolerante para peers que no envíen los campos nuevos.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ActivityID.self, forKey: .id)
        roomID = try container.decode(RoomID.self, forKey: .roomID)
        kind = try container.decode(ActivityKind.self, forKey: .kind)
        hostApplicationID = try container.decode(String.self, forKey: .hostApplicationID)
        participantIDs = try container.decode(Set<String>.self, forKey: .participantIDs)
        state = try container.decode(ActivityState.self, forKey: .state)
        admitsRoomMembers = try container.decodeIfPresent(Bool.self, forKey: .admitsRoomMembers) ?? true
        isExclusive = try container.decodeIfPresent(Bool.self, forKey: .isExclusive) ?? true
    }

    public func includes(_ applicationID: String) -> Bool {
        participantIDs.contains(applicationID)
    }

    public var isActive: Bool { state == .lobby || state == .running }
}
