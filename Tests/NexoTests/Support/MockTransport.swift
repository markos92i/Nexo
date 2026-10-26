import Foundation
@testable import Nexo

/// Transporte de pruebas que conduce la pila de salas sin red real.
///
/// Emite eventos programados por el test y captura los envelopes encolados, para
/// poder afirmar qué se envió y a quién, y simular conexiones, caídas y
/// recuperación de forma determinista.
final class MockTransport: Transport, @unchecked Sendable {

    // El `@unchecked Sendable` es aceptable AQUÍ: es código de test, no de la
    // librería. El estado se protege con un lock simple.
    private let lock = NSLock()

    private let eventStream: AsyncStream<TransportEvent>
    private let eventContinuation: AsyncStream<TransportEvent>.Continuation

    private var _epoch: UInt64 = 1
    private var _connectedPeers: [DeviceID: ConnectedPeer] = [:]

    /// Envelopes capturados: (envelope, destinatario), en orden de encolado.
    private(set) var sent: [(envelope: Envelope, to: DeviceID)] = []
    /// Peers a los que se pidió `connect`.
    private(set) var connectRequests: [DeviceID] = []
    /// Respuesta programada para `connect`, por deviceID.
    private var connectResponses: [DeviceID: Result<ConnectedPeer, TransportError>] = [:]

    var events: AsyncStream<TransportEvent> {
        eventStream
    }

    var epoch: UInt64 {
        lock.withLock { _epoch }
    }

    var connectedPeers: [ConnectedPeer] {
        lock.withLock { Array(_connectedPeers.values) }
    }

    init() {
        let stream = AsyncStream<TransportEvent>.makeStream(bufferingPolicy: .unbounded)
        eventStream = stream.stream
        eventContinuation = stream.continuation
    }

    // MARK: - Transport

    func start(advertising: Bool, browsing: Bool) {}
    func stop() {}
    func updateAdvertisement(_ record: AdvertisementRecord) {}
    func refreshDiscovery() {}

    func connect(to advertisement: PeerAdvertisement) async throws(TransportError) -> ConnectedPeer {
        let device = advertisement.deviceID ?? DeviceID()
        lock.withLock { connectRequests.append(device) }
        if let response = lock.withLock({ connectResponses[device] }) {
            switch response {
            case .success(let peer): return peer
            case .failure(let error): throw error
            }
        }
        // Por defecto: conexión instantánea con un peer sintético.
        let peer = ConnectedPeer(
            deviceID: device,
            displayName: advertisement.displayName,
            pskHint: "mock",
            protocolVersion: ProtocolInfo.currentVersion,
            capabilities: ProtocolInfo.capabilities,
            connectionSessionID: UUID()
        )
        simulatePeerConnected(peer)
        return peer
    }

    func disconnect(deviceID: DeviceID, reason: DisconnectReason?) {
        lock.withLock { _ = _connectedPeers.removeValue(forKey: deviceID) }
        emit(.peerDisconnected(deviceID: deviceID, reason: reason, epoch: epoch))
    }

    func enqueue(_ envelope: Envelope, to deviceID: DeviceID) {
        lock.withLock { sent.append((envelope, deviceID)) }
    }

    // MARK: - Control del test

    /// Programa la respuesta de un futuro `connect` a este deviceID.
    func stubConnect(_ deviceID: DeviceID, result: Result<ConnectedPeer, TransportError>) {
        lock.withLock { connectResponses[deviceID] = result }
    }

    func simulatePeerConnected(_ peer: ConnectedPeer) {
        lock.withLock { _connectedPeers[peer.deviceID] = peer }
        emit(.peerConnected(peer, epoch: epoch))
    }

    func simulateAdvertisement(_ advertisement: PeerAdvertisement) {
        emit(.advertisementFound(advertisement, epoch: epoch))
    }

    func simulateReceived(_ envelope: Envelope, from peer: ConnectedPeer) {
        emit(.received(envelope, from: peer, epoch: epoch))
    }

    func simulateLifecycle(_ lifecycle: ConnectivityLifecycle) {
        emit(.lifecycleChanged(lifecycle, epoch: epoch))
    }

    /// Vacía la lista de envelopes capturados (para aislar fases de un test).
    func clearSent() {
        lock.withLock { sent.removeAll() }
    }

    /// Envelopes capturados dirigidos a un destinatario concreto.
    func sent(to deviceID: DeviceID) -> [Envelope] {
        lock.withLock { sent.filter { $0.to == deviceID }.map(\.envelope) }
    }

    private func emit(_ event: TransportEvent) {
        eventContinuation.yield(event)
    }
}
