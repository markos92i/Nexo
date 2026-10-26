import Foundation

// MARK: - AdvertisementRecord

/// Contenido que el transporte publica en el TXT de Bonjour.
///
/// Bonjour limita cada entrada a 255 bytes y el registro entero a algo más de
/// 1 KB, así que las salas se serializan en formato compacto y solo se anuncian
/// las primeras. La capa de salas responde con el directorio completo cuando un
/// peer lo pide tras el handshake.
public struct AdvertisementRecord: Sendable, Equatable {
    public var deviceID: DeviceID
    public var displayName: String
    public var rooms: [RoomDescriptor]
    public var totalRoomCount: Int

    public init(
        deviceID: DeviceID,
        displayName: String,
        rooms: [RoomDescriptor] = [],
        totalRoomCount: Int = 0
    ) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.rooms = rooms
        self.totalRoomCount = totalRoomCount
    }

    // MARK: Codificación TXT

    private enum Key {
        static let version = "v"
        static let deviceID = "did"
        static let displayName = "dn"
        static let roomCount = "rc"
        static func room(_ index: Int) -> String { "r\(index)" }
    }

    /// Serializa el anuncio en pares clave/valor para el TXT.
    public var txtDictionary: [String: String] {
        var dictionary: [String: String] = [
            Key.version: String(ProtocolInfo.currentVersion),
            Key.deviceID: deviceID.description,
            // El nombre del dispositivo lo pone el usuario y puede ser largo o
            // llevar emoji. Se recorta en bytes para no pasar el límite de la
            // entrada, o Bonjour descartaría el anuncio entero.
            Key.displayName: Self.clamped(displayName, maximumBytes: 200),
            Key.roomCount: String(totalRoomCount)
        ]

        for (index, room) in rooms.prefix(Limits.advertisedRoomLimit).enumerated() {
            dictionary[Key.room(index)] = CompactRoom(room).encoded
        }

        return dictionary
    }

    /// Recorta una cadena a un presupuesto de bytes UTF-8 sin partir un carácter.
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

    /// Reconstruye un anuncio leído de un TXT remoto.
    public static func advertisement(
        from txt: [String: String],
        endpointID: TransportPeerID,
        fallbackName: String
    ) -> PeerAdvertisement {
        let version = txt[Key.version].flatMap { UInt8($0) } ?? 0
        let displayName = txt[Key.displayName] ?? fallbackName

        var rooms: [RoomDescriptor] = []
        for index in 0..<Limits.advertisedRoomLimit {
            guard let encoded = txt[Key.room(index)],
                  let compact = CompactRoom(encoded: encoded) else { continue }
            rooms.append(compact.descriptor(protocolVersion: version))
        }

        return PeerAdvertisement(
            endpointID: endpointID,
            deviceID: txt[Key.deviceID].flatMap { DeviceID(string: $0) },
            displayName: displayName,
            protocolVersion: version,
            rooms: rooms,
            totalRoomCount: txt[Key.roomCount].flatMap { Int($0) } ?? rooms.count
        )
    }
}

// MARK: - CompactRoom

/// Codificación compacta de un `RoomDescriptor` para el TXT.
///
/// Formato: `id|features|policy|members|capacity|activityKind|hostID|name`.
/// El nombre va al final y percent-escaped, así que un `|` dentro nunca rompe el parseo.
private struct CompactRoom {
    let id: RoomID
    let name: String
    let hostDeviceID: DeviceID
    let features: RoomFeatures
    let accessPolicy: RoomAccessPolicy
    let memberCount: Int
    let capacity: Int?
    let activityKind: ActivityKind?

    private static let separator: Character = "|"
    private static let allowedNameCharacters = CharacterSet.alphanumerics.union(.whitespaces)

    /// Bonjour limita cada entrada TXT a 255 bytes contando `key=value`. Se
    /// reservan unos pocos para la clave (`r0`) y el igual.
    private static let maximumEntryBytes = 250

    init(_ descriptor: RoomDescriptor) {
        self.id = descriptor.id
        self.name = descriptor.name
        self.hostDeviceID = descriptor.hostDeviceID
        self.features = descriptor.features
        self.accessPolicy = descriptor.accessPolicy
        self.memberCount = descriptor.memberCount
        self.capacity = descriptor.capacity
        self.activityKind = descriptor.activityKind
    }

    var encoded: String {
        let fixedFields = [
            id.rawValue.uuidString,
            String(features.rawValue),
            accessPolicy.rawValue,
            String(memberCount),
            capacity.map(String.init) ?? "",
            activityKind?.rawValue ?? "",
            hostDeviceID.description
        ]

        let prefix = fixedFields.joined(separator: String(Self.separator))
            + String(Self.separator)

        // El recorte se hace sobre bytes ya escapados, no caracteres: un
        // carácter acentuado o emoji puede ocupar 6-12 bytes una vez escapado, y
        // pasarse del presupuesto haría que Bonjour descarte la entrada.
        let budget = Self.maximumEntryBytes - prefix.utf8.count
        return prefix + Self.escapedName(name, maximumBytes: budget)
    }

    /// Escapa el nombre dentro de un presupuesto de bytes, sin partir un carácter.
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

    init?(encoded: String) {
        // `omittingEmptySubsequences: false` mantiene los campos vacíos, que son
        // significativos (sin límite de capacidad, sala sin actividad).
        let fields = encoded.split(
            separator: Self.separator,
            omittingEmptySubsequences: false
        ).map(String.init)

        guard fields.count == 8,
              let roomID = RoomID(string: fields[0]),
              let rawFeatures = UInt16(fields[1]),
              let policy = RoomAccessPolicy(rawValue: fields[2]),
              let memberCount = Int(fields[3]),
              let hostDeviceID = DeviceID(string: fields[6]) else { return nil }

        self.id = roomID
        self.features = RoomFeatures(rawValue: rawFeatures)
        self.accessPolicy = policy
        self.memberCount = memberCount
        self.capacity = Int(fields[4])
        self.activityKind = fields[5].isEmpty ? nil : ActivityKind(fields[5])
        self.hostDeviceID = hostDeviceID
        self.name = fields[7].removingPercentEncoding ?? fields[7]
    }

    func descriptor(protocolVersion: UInt8) -> RoomDescriptor {
        RoomDescriptor(
            id: id,
            name: name,
            hostDeviceID: hostDeviceID,
            features: features,
            activityKind: activityKind,
            accessPolicy: accessPolicy,
            memberCount: memberCount,
            capacity: capacity,
            protocolVersion: protocolVersion
        )
    }
}
