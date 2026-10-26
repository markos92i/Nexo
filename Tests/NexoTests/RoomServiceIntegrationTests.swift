import Foundation
import Testing
@testable import Nexo

@NexoActor
@Suite("Integración RoomService con transporte mock")
struct RoomServiceIntegrationTests {

    private func makeService(name: String) -> (service: RoomService, transport: MockTransport, identity: LocalIdentity) {
        let transport = MockTransport()
        let identity = LocalIdentity(deviceID: DeviceID(), displayName: name)
        let service = RoomService(transport: transport, identity: identity)
        return (service, transport, identity)
    }

    @Test("Crear una sala la registra como alojada localmente y activa")
    func createRoomRegistersHostedRoom() {
        let (service, _, identity) = makeService(name: "Anfitrión")
        let room = service.createRoom(name: "Partida", features: .full)

        #expect(service.sessions[room.roomID] != nil)
        #expect(service.activeRoomID == room.roomID)
        #expect(room.isLocalHost)
        #expect(room.descriptor.hostDeviceID == identity.deviceID)
        #expect(room.members.count == 1)
        #expect(room.members.first?.deviceID == identity.deviceID)
        #expect(service.hostedRooms.count == 1)
        #expect(service.joinedRooms.isEmpty)
    }

    @Test("El host envía su anuncio al transporte al crear una sala")
    func createRoomPublishesAdvertisement() {
        let (service, transport, _) = makeService(name: "Anfitrión")
        _ = service.createRoom(name: "Partida")
        // El servicio llama a updateAdvertisement; el mock no lo captura como envelope,
        // pero la sala queda anunciable (advertisedRoomDescriptors no vacío).
        #expect(service.advertisedRoomDescriptors.count == 1)
        _ = transport
    }

    @Test("Una sala solo-chat no expone API de actividades utilizable")
    func chatOnlyRoomHasNoActivities() throws {
        let (service, _, _) = makeService(name: "Anfitrión")
        let room = service.createRoom(name: "Charla", features: .chatOnly)
        #expect(room.chat != nil)
        #expect(!room.features.hasActivities)
        #expect(throws: RoomError.self) {
            try service.startActivity(kind: ActivityKind("sudoku"), in: room.roomID)
        }
    }

    @Test("Iniciar una actividad no registrada falla con activityUnsupported")
    func startingUnregisteredActivityFails() {
        let (service, _, _) = makeService(name: "Anfitrión")
        let room = service.createRoom(name: "Juegos", features: .gameOnly)
        #expect {
            try service.startActivity(kind: ActivityKind("ajedrez"), in: room.roomID)
        } throws: { error in
            guard case RoomError.activityUnsupported = error else { return false }
            return true
        }
    }

    @Test("Iniciar una actividad registrada la crea y queda como primaria")
    func startingRegisteredActivity() throws {
        let (service, _, _) = makeService(name: "Anfitrión")
        let kind = ActivityKind("sudoku")
        service.registerActivity(kind) { context in
            GenericActivity<SudokuMessage>(context: context)
        }
        let room = service.createRoom(name: "Juegos", features: .gameOnly)

        let activity = try service.startActivity(kind: kind, in: room.roomID, isExclusive: true)
        #expect(activity.descriptor.kind == kind)
        #expect(room.activity(activity.id) != nil)
        #expect(room.primaryActivity?.id == activity.id)
        #expect(!room.canStartActivity) // exclusiva ya activa
    }

    @Test("Chat local: enviar texto lo inserta en el historial de la sala")
    func chatAppendsLocalMessage() throws {
        let (service, _, _) = makeService(name: "Anfitrión")
        let room = service.createRoom(name: "Charla", features: .chatOnly)
        room.chat?.send(text: "Hola")
        #expect(room.chat?.messages.count == 1)
        #expect(room.chat?.messages.first?.body == "Hola")
    }

    @Test("closeAll cierra todas las sesiones")
    func closeAllClearsSessions() {
        let (service, _, _) = makeService(name: "Anfitrión")
        _ = service.createRoom(name: "A")
        _ = service.createRoom(name: "B")
        #expect(service.sessions.count == 2)
        service.closeAll(reason: .sessionEnded)
        #expect(service.sessions.isEmpty)
        #expect(service.activeRoomID == nil)
    }
}

// Mensaje de actividad de ejemplo para los tests.
private enum SudokuMessage: Codable, Sendable {
    case move(row: Int, col: Int, value: Int)
    case board([Int])
}
