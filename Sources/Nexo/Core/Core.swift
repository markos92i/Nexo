import Foundation

/// Identificador único y persistente de una instalación de la app en un
/// dispositivo. Lo genera y persiste Nexo (no el consumidor) y sobrevive a
/// reinicios y reconexiones.
///
/// En el formato de cable se codifica como su `UUID` subyacente.
public struct DeviceID: Hashable, Codable, Sendable, Identifiable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    /// Reconstruye un `DeviceID` recibido como texto (p. ej. en un TXT de Bonjour).
    public init?(string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.rawValue = uuid
    }

    public var id: UUID { rawValue }
    public var description: String { rawValue.uuidString }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Ejecutor serial de toda la lógica de Nexo.
///
/// Mantiene el estado de salas, chat, actividades, transferencias e identidad
/// fuera del hilo principal. La app vuelve al hilo principal cuando necesita
/// publicar snapshots para la UI.
@globalActor
public actor NexoActor {
    public static let shared = NexoActor()
    private init() {}
}

/// Coders compartidos. Reutilizarlos evita asignar un `JSONEncoder` por mensaje,
/// que era el coste dominante al difundir snapshots a varios peers.
enum WireCoder {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func encode(_ value: some Encodable) throws -> Data {
        try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}
