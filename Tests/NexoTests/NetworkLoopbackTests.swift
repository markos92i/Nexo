import Foundation
import Testing
@testable import Nexo

/// Dos `NetworkTransport` reales en el mismo proceso, por Bonjour y TLS-PSK sobre
/// loopback. Cubren lo que `MockTransport` no puede ver: el framer, el hello, el
/// cifrado y la conexión binaria.
@Suite("Red real por loopback", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct NetworkLoopbackTests {

    private struct Message: Codable, Sendable {}

    private struct Node {
        let rooms: RoomService
        let transport: NetworkTransport
        let deviceID: DeviceID
    }

    /// Tipo Bonjour único por test, para que dos ejecuciones no se crucen.
    private let service = ServiceType("nx-" + String(UUID().uuidString.lowercased().prefix(8)))
    private let kind = ActivityKind("loopback")

    @NexoActor
    private func makeNode(_ name: String) -> Node {
        let deviceID = DeviceID()
        let transport = NetworkTransport(
            crypto: SessionCrypto(appSecret: "nexo-loopback-tests"),
            deviceID: deviceID,
            displayName: name,
            service: service
        )
        let rooms = RoomService(
            transport: transport,
            identity: LocalIdentity(deviceID: deviceID, displayName: name)
        )
        rooms.registerActivity(kind) { GenericActivity<Message>(context: $0) }
        transport.start(advertising: true, browsing: true)
        return Node(rooms: rooms, transport: transport, deviceID: deviceID)
    }

    /// Espera a que una condición se cumpla, o falla al agotar el plazo.
    @NexoActor
    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(15),
        _ condition: @NexoActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for \(description)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @NexoActor
    private func discover(_ room: Room, from guest: Node) async throws -> DiscoveredRoom {
        try await waitUntil("discovery of \(room.name)") {
            guest.rooms.availableRooms.contains { $0.id == room.roomID }
        }
        return try #require(guest.rooms.availableRooms.first { $0.id == room.roomID })
    }

    @Test("Entrar con aprobación: progreso visible, sala en la lista y aviso de solicitud resuelta")
    @NexoActor
    func joinWithApproval() async throws {
        let host = makeNode("Host")
        let guest = makeNode("Guest")
        defer { host.transport.stop(); guest.transport.stop() }

        let room = host.rooms.createRoom(name: "Sala", features: .gameOnly, activityKind: kind, accessPolicy: .approval)
        let target = try await discover(room, from: guest)

        var resolvedRequests: [UUID] = []
        let notices = host.rooms.notices
        let approver = Task { @NexoActor in
            for await notice in notices {
                switch notice {
                case .joinRequest(let request):
                    // Antes de aceptar, el invitado debe ver la sala esperando.
                    try? await waitUntil("awaitingApproval") {
                        guest.rooms.joinProgress[room.roomID] == .awaitingApproval
                    }
                    #expect(guest.rooms.availableRooms.contains { $0.id == room.roomID })
                    if let pending = host.rooms.session(request.roomID)?.pendingJoinRequests.first(where: { $0.id == request.requestID }) {
                        host.rooms.respond(to: pending, accept: true)
                    }
                case .joinRequestResolved(let request):
                    resolvedRequests.append(request.requestID)
                    return
                default:
                    break
                }
            }
        }

        let joined = try await guest.rooms.join(target)
        _ = await approver.value

        #expect(joined.accessState == .joined)
        #expect(joined.members.count == 2)
        #expect(guest.rooms.joinProgress.isEmpty)
        #expect(!guest.rooms.availableRooms.contains { $0.id == room.roomID })
        #expect(resolvedRequests.count == 1)
    }

    @Test("Cancelar la espera retira la solicitud en el host")
    @NexoActor
    func cancellingJoinWithdrawsRequest() async throws {
        let host = makeNode("Host")
        let guest = makeNode("Guest")
        defer { host.transport.stop(); guest.transport.stop() }

        let room = host.rooms.createRoom(name: "Sala", accessPolicy: .approval)
        let target = try await discover(room, from: guest)

        let joinTask = Task { @NexoActor in try await guest.rooms.join(target) }
        try await waitUntil("pending request on host") {
            host.rooms.session(room.roomID)?.pendingJoinRequests.isEmpty == false
        }
        joinTask.cancel()
        _ = await joinTask.result

        try await waitUntil("request withdrawn on host") {
            host.rooms.session(room.roomID)?.pendingJoinRequests.isEmpty == true
        }
        #expect(guest.rooms.joinProgress.isEmpty)
        #expect(guest.rooms.session(room.roomID) == nil)
    }

    @Test("Un stream binario llega íntegro por la conexión dedicada")
    @NexoActor
    func byteStreamRoundTrip() async throws {
        let host = makeNode("Host")
        let guest = makeNode("Guest")
        defer { host.transport.stop(); guest.transport.stop() }

        let room = host.rooms.createRoom(name: "Sala", accessPolicy: .open)
        let target = try await discover(room, from: guest)
        _ = try await guest.rooms.join(target)
        try await waitUntil("host sees guest as member") {
            host.rooms.session(room.roomID)?.contains(guest.deviceID) == true
        }

        let payload = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let incoming = host.rooms.incomingByteStreams
        let reader = Task { @NexoActor () -> (Data, DeviceID)? in
            for await stream in incoming {
                var received = Data()
                do {
                    for try await chunk in stream.stream { received.append(chunk) }
                } catch {
                    return nil
                }
                return (received, stream.senderDeviceID)
            }
            return nil
        }

        let writer = try await guest.rooms.openByteStream(to: host.deviceID, in: room.roomID, name: "blob")
        try await writer.send(payload)
        try await writer.finish()

        let result = try #require(await reader.value)
        #expect(result.0 == payload)
        #expect(result.1 == guest.deviceID)
        // La conexión binaria no debe aparecer como un peer más.
        #expect(host.transport.connectedPeers.count == 1)
    }
}
