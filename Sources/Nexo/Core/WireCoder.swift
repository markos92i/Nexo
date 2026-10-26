import Foundation

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
