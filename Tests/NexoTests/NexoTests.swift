import Foundation
import Testing
@testable import Nexo

@Suite("Identidad y modelos base")
struct IdentityTests {

    @Test("DeviceID se codifica como un único UUID en el cable")
    func deviceIDEncodesAsSingleUUID() throws {
        let id = DeviceID()
        let data = try JSONEncoder().encode(id)
        // Debe ser una cadena JSON (el UUID), no un objeto con rawValue.
        let asString = try JSONDecoder().decode(String.self, from: data)
        #expect(asString == id.description)
    }

    @Test("DeviceID hace round-trip por Codable")
    func deviceIDRoundTrips() throws {
        let id = DeviceID()
        let decoded = try JSONDecoder().decode(DeviceID.self, from: JSONEncoder().encode(id))
        #expect(decoded == id)
    }

    @Test("DeviceID reconstruye desde texto válido y rechaza inválido")
    func deviceIDFromString() {
        let id = DeviceID()
        #expect(DeviceID(string: id.description) == id)
        #expect(DeviceID(string: "no-es-uuid") == nil)
    }

    @Test("ActivityKind conserva su rawValue")
    func activityKindRoundTrips() {
        #expect(ActivityKind("sudoku").rawValue == "sudoku")
    }

    @Test("hostGeneration sobrevive a la codificación del RoomDescriptor")
    func hostGenerationSurvivesCoding() throws {
        let descriptor = RoomDescriptor(
            name: "Partida",
            hostDeviceID: DeviceID(),
            features: .full,
            hostGeneration: 7
        )
        let decoded = try JSONDecoder().decode(
            RoomDescriptor.self,
            from: JSONEncoder().encode(descriptor)
        )
        #expect(decoded.hostDeviceID == descriptor.hostDeviceID)
        #expect(decoded.hostGeneration == 7)
    }

    @Test("RoomID.shortCode son los primeros 8 caracteres del UUID")
    func shortCode() {
        let id = RoomID()
        #expect(id.shortCode == String(id.rawValue.uuidString.prefix(8)))
        #expect(id.shortCode.count == 8)
    }
}
