//
//  RoomModels.swift
//  Project Dark
//
//  Created by Marcos del Castillo Camacho on 11/09/2026.
//

import Foundation

// MARK: - RoomID

/// Identificador lógico de una room. Es independiente del transporte: no deriva
/// de un endpoint Bonjour ni de una conexión concreta, por lo que sobrevive a
/// reconexiones y puede viajar dentro de los mensajes.
public struct RoomID: Hashable, Codable, Sendable, Identifiable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    /// Reconstruye un `RoomID` publicado en un registro TXT o en un mensaje.
    public init?(string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.rawValue = uuid
    }

    public var id: UUID { rawValue }
    public var description: String { rawValue.uuidString }

    /// Forma corta para mostrar en depuración o como código de sala legible.
    public var shortCode: String {
        String(rawValue.uuidString.prefix(8))
    }
}

// MARK: - RoomRole

public enum RoomRole: String, Codable, Sendable {
    /// Autoridad de la room: admite miembros, cierra la room y arbitra actividades.
    case host
    /// Miembro normal.
    case guest
}

// MARK: - RoomAccessPolicy

public enum RoomAccessPolicy: String, Codable, Sendable, CaseIterable {
    /// Cualquier peer que descubra la room entra directamente.
    case open
    /// El host debe aprobar cada solicitud de entrada.
    case approval

    public var localizedTitle: String {
        switch self {
        case .open: "Abierta"
        case .approval: "Con aprobación"
        }
    }
}

// MARK: - RoomFeatures

/// Capacidades activas de una room concreta.
///
/// Es lo que hace flexible el modelo: una room de solo chat, una room de solo
/// juego sin chat, o una room mixta son la misma entidad con distintos flags.
public struct RoomFeatures: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// Habilita el canal de chat de texto.
    public static let chat = RoomFeatures(rawValue: 1 << 0)
    /// Permite iniciar actividades (juegos) dentro de la room.
    public static let activities = RoomFeatures(rawValue: 1 << 1)
    /// Permite enviar imágenes y ficheros.
    public static let fileTransfer = RoomFeatures(rawValue: 1 << 2)

    /// Room conversacional clásica.
    public static let chatOnly: RoomFeatures = [.chat, .fileTransfer]
    /// Room de partida directa, sin chat.
    public static let gameOnly: RoomFeatures = [.activities]
    /// Room completa: se charla y se juega en el mismo sitio.
    public static let full: RoomFeatures = [.chat, .activities, .fileTransfer]

    public var hasChat: Bool { contains(.chat) }
    public var hasActivities: Bool { contains(.activities) }
    public var hasFileTransfer: Bool { contains(.fileTransfer) }
}

// MARK: - RoomMember

public struct RoomMember: Codable, Hashable, Sendable, Identifiable {
    /// Identidad estable de la instalación remota. No es un id de transporte.
    public let applicationID: String
    public let displayName: String
    public let role: RoomRole

    public var id: String { applicationID }

    public init(applicationID: String, displayName: String, role: RoomRole) {
        self.applicationID = applicationID
        self.displayName = displayName
        self.role = role
    }

    public var isHost: Bool { role == .host }
}

// MARK: - RoomDescriptor

/// Descripción transportable de una room. No contiene tipos de Network Framework.
public struct RoomDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let id: RoomID
    public var name: String
    /// Identidad de aplicación del host que la creó y la gobierna.
    public let hostApplicationID: String
    public var features: RoomFeatures
    /// Actividad principal prevista. Una room de juego la declara para que el
    /// descubrimiento pueda filtrar por juego sin conectarse.
    public var activityKind: ActivityKind?
    public var accessPolicy: RoomAccessPolicy
    public var memberCount: Int
    /// `nil` significa sin límite declarado por el producto.
    public var capacity: Int?
    public let protocolVersion: UInt8

    public init(
        id: RoomID = RoomID(),
        name: String,
        hostApplicationID: String,
        features: RoomFeatures,
        activityKind: ActivityKind? = nil,
        accessPolicy: RoomAccessPolicy = .open,
        memberCount: Int = 1,
        capacity: Int? = nil,
        protocolVersion: UInt8 = P2PProtocolInfo.currentVersion
    ) {
        self.id = id
        self.name = name
        self.hostApplicationID = hostApplicationID
        self.features = features
        self.activityKind = activityKind
        self.accessPolicy = accessPolicy
        self.memberCount = memberCount
        self.capacity = capacity
        self.protocolVersion = protocolVersion
    }

    public var isFull: Bool {
        guard let capacity else { return false }
        return memberCount >= capacity
    }

    public var requiresApproval: Bool { accessPolicy == .approval }
}

// MARK: - RoomAccessState

/// Estado de la relación del usuario local con una room.
public enum RoomAccessState: Equatable, Sendable {
    /// Descubierta pero no solicitada.
    case available
    /// Solicitud enviada, esperando decisión del host.
    case awaitingApproval
    /// Miembro activo.
    case joined
    /// La conexión física con el host se ha suspendido (por ejemplo, background).
    case suspended
    /// Reintentando recuperar la membresía.
    case reconnecting
    /// El host rechazó la entrada o expulsó al miembro.
    case rejected(reason: String)
    /// La room se cerró o el host desapareció.
    case closed(reason: String)

    public var isUsable: Bool { self == .joined }
}

// MARK: - RoomJoinRequest

/// Solicitud de entrada pendiente de decisión. Es por room, no global: el host
/// puede tener varias rooms con colas independientes.
public struct RoomJoinRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let roomID: RoomID
    public let applicationID: String
    public let displayName: String
    public let receivedAt: Date

    public init(
        id: UUID = UUID(),
        roomID: RoomID,
        applicationID: String,
        displayName: String,
        receivedAt: Date = Date()
    ) {
        self.id = id
        self.roomID = roomID
        self.applicationID = applicationID
        self.displayName = displayName
        self.receivedAt = receivedAt
    }
}

// MARK: - DiscoveredRoom

/// Room anunciada por un peer cercano y todavía no unida. Combina el descriptor
/// publicado con el identificador de transporte necesario para conectar.
public struct DiscoveredRoom: Identifiable, Sendable, Equatable {
    public let descriptor: RoomDescriptor
    /// Peer que anuncia la room. Puede ser el host u otro miembro que la reenvía.
    public let advertisedBy: TransportPeerID
    public let hostDisplayName: String
    public let discoveredAt: Date

    public var id: RoomID { descriptor.id }
    public var name: String { descriptor.name }
    public var features: RoomFeatures { descriptor.features }
    public var activityKind: ActivityKind? { descriptor.activityKind }
}
