//
//  TransportModels.swift
//  Project Dark
//
//  Created by Marcos del Castillo Camacho on 11/09/2026.
//

import Foundation

// MARK: - TransportPeerID

/// Identidad efímera de un endpoint dentro del transporte. Cambia entre
/// sesiones y no debe usarse como identidad de dominio.
public struct TransportPeerID: Hashable, Codable, Sendable, Identifiable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var id: String { rawValue }
    public var description: String { rawValue }
}

// MARK: - PeerAdvertisement

/// Anuncio Bonjour de un dispositivo cercano, leído del registro TXT antes de
/// abrir ninguna conexión. Permite listar rooms sin conectarse a cada peer.
public struct PeerAdvertisement: Identifiable, Sendable, Equatable {
    public let endpointID: TransportPeerID
    public let applicationID: String?
    public let displayName: String
    public let protocolVersion: UInt8
    /// Rooms anunciadas en TXT. Puede ser un subconjunto de las que hospeda.
    public let rooms: [RoomDescriptor]
    /// Total real de rooms hospedadas, incluso si no caben todas en el TXT.
    public let totalRoomCount: Int

    public var id: TransportPeerID { endpointID }

    public var isCompatible: Bool { P2PProtocolInfo.isCompatible(remoteVersion: protocolVersion) }

    public var hasUndisclosedRooms: Bool { totalRoomCount > rooms.count }
}

// MARK: - ConnectedPeer

/// Peer con handshake completado. A partir de aquí el sistema lo identifica por
/// `applicationID`, nunca por el identificador de conexión.
public struct ConnectedPeer: Identifiable, Sendable, Hashable {
    public let applicationID: String
    public let displayName: String
    public let protocolVersion: UInt8
    public let capabilities: Set<P2PCapability>
    /// Instancia concreta de conexión. Cambia en cada reconexión y sirve para
    /// descartar eventos de una conexión ya sustituida.
    public let connectionSessionID: UUID

    public var id: String { applicationID }

    public func supports(_ capability: P2PCapability) -> Bool {
        capabilities.contains(capability)
    }
}

// MARK: - ConnectivityLifecycle

/// Estado global del transporte.
public enum ConnectivityLifecycle: String, Sendable, Equatable {
    case idle
    case active
    /// La app pasó a background: se conservan las rooms pero no las conexiones.
    case suspended
    case reconnecting
    case disconnected
}

// MARK: - PeerTransportEvent

/// Eventos del transporte físico.
///
/// Cada evento lleva el `epoch` vigente cuando se generó. Un `stop()` incrementa
/// el epoch, así que los eventos encolados antes se descartan sin ambigüedad.
public enum PeerTransportEvent: Sendable {
    case advertisementFound(PeerAdvertisement, epoch: UInt64)
    case advertisementUpdated(PeerAdvertisement, epoch: UInt64)
    case advertisementLost(TransportPeerID, epoch: UInt64)
    case peerConnected(ConnectedPeer, epoch: UInt64)
    case peerDisconnected(applicationID: String, reason: String?, epoch: UInt64)
    case received(RoomEnvelope, from: ConnectedPeer, epoch: UInt64)
    case lifecycleChanged(ConnectivityLifecycle, epoch: UInt64)
}

// MARK: - P2PTransportError

public enum P2PTransportError: Error, LocalizedError, Sendable, Equatable {
    case peerNotDiscovered
    case notConnected
    case handshakeTimedOut
    case handshakeFailed(String)
    case incompatibleProtocol(UInt8)
    case envelopeTooLarge(Int)
    case transportStopped
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .peerNotDiscovered:
            "El dispositivo ya no está visible en la red local."
        case .notConnected:
            "No hay conexión activa con el dispositivo."
        case .handshakeTimedOut:
            "El dispositivo no completó la conexión a tiempo."
        case .handshakeFailed(let reason):
            reason
        case .incompatibleProtocol(let version):
            "La versión del protocolo del otro dispositivo (\(version)) no es compatible."
        case .envelopeTooLarge(let bytes):
            "El mensaje ocupa \(bytes) bytes y supera el límite permitido."
        case .transportStopped:
            "La conectividad se ha detenido."
        case .connectionFailed(let reason):
            reason
        }
    }
}

// MARK: - AdvertisementRecord

/// Contenido que el transporte publica en el registro TXT de Bonjour.
///
/// Bonjour limita cada entrada a 255 bytes y el registro completo a poco más de
/// 1 KB, así que las rooms se serializan en un formato compacto y solo se
/// anuncian las primeras. `RoomCoordinator` responde con el directorio completo
/// cuando un peer lo pide tras el handshake.
public struct AdvertisementRecord: Sendable, Equatable {
    public var applicationID: String
    public var displayName: String
    public var rooms: [RoomDescriptor]
    public var totalRoomCount: Int

    public init(
        applicationID: String,
        displayName: String,
        rooms: [RoomDescriptor] = [],
        totalRoomCount: Int = 0
    ) {
        self.applicationID = applicationID
        self.displayName = displayName
        self.rooms = rooms
        self.totalRoomCount = totalRoomCount
    }

    // MARK: TXT encoding

    private enum Key {
        static let version = "v"
        static let applicationID = "aid"
        static let displayName = "dn"
        static let roomCount = "rc"
        static func room(_ index: Int) -> String { "r\(index)" }
    }

    /// Serializa el anuncio a pares clave/valor para el registro TXT.
    public var txtDictionary: [String: String] {
        var dictionary: [String: String] = [
            Key.version: String(P2PProtocolInfo.currentVersion),
            Key.applicationID: applicationID,
            // El nombre del dispositivo lo pone el usuario y puede ser largo o
            // llevar emoji. Se acota en bytes para no pasarse del límite de una
            // entrada TXT, que haría que Bonjour descartase el anuncio.
            Key.displayName: Self.clamped(displayName, maximumBytes: 200),
            Key.roomCount: String(totalRoomCount)
        ]

        for (index, room) in rooms.prefix(P2PLimits.advertisedRoomLimit).enumerated() {
            dictionary[Key.room(index)] = CompactRoom(room).encoded
        }

        return dictionary
    }

    /// Recorta una cadena a un número de bytes UTF-8 sin partir un carácter.
    private static func clamped(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }

        var result = ""
        var usedBytes = 0

        for character in value {
            let size = String(character).utf8.count
            guard usedBytes + size <= maximumBytes else { break }
            result.append(character)
            usedBytes += size
        }

        return result
    }

    /// Reconstruye un anuncio leído de un registro TXT remoto.
    public static func advertisement(
        from txt: [String: String],
        endpointID: TransportPeerID,
        fallbackName: String
    ) -> PeerAdvertisement {
        let version = txt[Key.version].flatMap { UInt8($0) } ?? 0
        let displayName = txt[Key.displayName]?.isEmpty == false
            ? txt[Key.displayName]!
            : fallbackName

        var rooms: [RoomDescriptor] = []
        for index in 0..<P2PLimits.advertisedRoomLimit {
            guard let encoded = txt[Key.room(index)],
                  let compact = CompactRoom(encoded: encoded) else { continue }
            rooms.append(compact.descriptor(protocolVersion: version))
        }

        return PeerAdvertisement(
            endpointID: endpointID,
            applicationID: txt[Key.applicationID],
            displayName: displayName,
            protocolVersion: version,
            rooms: rooms,
            totalRoomCount: txt[Key.roomCount].flatMap { Int($0) } ?? rooms.count
        )
    }
}

// MARK: - CompactRoom

/// Codificación compacta de una `RoomDescriptor` para el registro TXT.
///
/// Formato: `id|features|policy|members|capacity|activityKind|hostID|name`
/// El nombre va al final y percent-escapado, así que un `|` en el nombre no
/// rompe el parseo.
private struct CompactRoom {
    public let id: RoomID
    public let name: String
    public let hostApplicationID: String
    public let features: RoomFeatures
    public let accessPolicy: RoomAccessPolicy
    public let memberCount: Int
    public let capacity: Int?
    public let activityKind: ActivityKind?

    private static let separator: Character = "|"
    private static let allowedNameCharacters = CharacterSet.alphanumerics.union(.whitespaces)

    /// Bonjour limita cada entrada TXT a 255 bytes, contando `clave=valor`. Se
    /// reservan unos pocos para la clave (`r0`) y el signo igual.
    private static let maximumEntryBytes = 250

    public init(_ descriptor: RoomDescriptor) {
        self.id = descriptor.id
        self.name = descriptor.name
        self.hostApplicationID = descriptor.hostApplicationID
        self.features = descriptor.features
        self.accessPolicy = descriptor.accessPolicy
        self.memberCount = descriptor.memberCount
        self.capacity = descriptor.capacity
        self.activityKind = descriptor.activityKind
    }

    public var encoded: String {
        // El nombre va al final y percent-escapado, así que un `|` dentro del
        // nombre no rompe el parseo.
        let fixedFields = [
            id.rawValue.uuidString,
            String(features.rawValue),
            accessPolicy.rawValue,
            String(memberCount),
            capacity.map(String.init) ?? "",
            activityKind?.rawValue ?? "",
            hostApplicationID
        ]

        let prefix = fixedFields.joined(separator: String(Self.separator))
            + String(Self.separator)

        // El recorte se hace por bytes ya escapados, no por caracteres: un nombre
        // acentuado o con emoji ocupa entre 6 y 12 bytes por carácter al
        // percent-escaparlo, y pasarse del límite haría que Bonjour descartara la
        // entrada y la sala no se anunciara.
        let budget = Self.maximumEntryBytes - prefix.utf8.count
        return prefix + Self.escapedName(name, maximumBytes: budget)
    }

    /// Escapa el nombre respetando un presupuesto en bytes y sin partir un
    /// carácter por la mitad.
    private static func escapedName(_ name: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }

        var result = ""
        var usedBytes = 0

        for character in name {
            guard let escaped = String(character)
                .addingPercentEncoding(withAllowedCharacters: allowedNameCharacters)
            else { continue }

            let size = escaped.utf8.count
            guard usedBytes + size <= maximumBytes else { break }

            result += escaped
            usedBytes += size
        }

        return result
    }

    public init?(encoded: String) {
        // `omittingEmptySubsequences: false` conserva los campos vacíos, que son
        // significativos (capacidad sin límite, room sin actividad).
        let fields = encoded.split(
            separator: Self.separator,
            omittingEmptySubsequences: false
        ).map(String.init)

        guard fields.count == 8,
              let roomID = RoomID(string: fields[0]),
              let rawFeatures = UInt16(fields[1]),
              let policy = RoomAccessPolicy(rawValue: fields[2]),
              let memberCount = Int(fields[3]) else { return nil }

        self.id = roomID
        self.features = RoomFeatures(rawValue: rawFeatures)
        self.accessPolicy = policy
        self.memberCount = memberCount
        self.capacity = Int(fields[4])
        self.activityKind = ActivityKind(rawValue: fields[5])
        self.hostApplicationID = fields[6]
        self.name = fields[7].removingPercentEncoding ?? fields[7]
    }

    public func descriptor(protocolVersion: UInt8) -> RoomDescriptor {
        RoomDescriptor(
            id: id,
            name: name,
            hostApplicationID: hostApplicationID,
            features: features,
            activityKind: activityKind,
            accessPolicy: accessPolicy,
            memberCount: memberCount,
            capacity: capacity,
            protocolVersion: protocolVersion
        )
    }
}
