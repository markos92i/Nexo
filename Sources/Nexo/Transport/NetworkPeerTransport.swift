//
//  NetworkPeerTransport.swift
//  Project Dark
//
//  Created by Marcos del Castillo Camacho on 11/09/2026.
//

import Foundation
import Network

// MARK: - NetworkPeerTransport

/// Transporte P2P sobre las APIs estructuradas de Network Framework (iOS 26).
///
/// Pila de protocolos: `Coder<P2PFrame> / TCP / IP` con Bonjour y peer-to-peer
/// activado.
///
/// - Note: **No hay TLS.** El `TLS` del builder nuevo exige un
///   `sec_identity_t` local (`TLS.localIdentity(_:)`); un listener sin identidad
///   falla el handshake con `-9810`, comprobado en ejecución. Emitir un
///   certificado autofirmado forma parte de la capa de identidad, que está fuera
///   de alcance ahora. Consecuencia: el tráfico viaja **sin cifrar** por la red
///   local y **no se verifica** la identidad del peer.
@MainActor
public final class NetworkPeerTransport: PeerTransport {

    // MARK: - Network Types

    // `fileprivate` y no `private`: los tipos aparecen en las firmas de las
    // extensiones de este mismo fichero.
    fileprivate typealias ApplicationProtocol = Coder<P2PFrame, P2PFrame, NetworkJSONCoder>
    fileprivate typealias Parameters = NWParametersBuilder<ApplicationProtocol>
    fileprivate typealias Connection = NetworkConnection<ApplicationProtocol>
    fileprivate typealias Listener = NetworkListener<ApplicationProtocol>

    // MARK: - PeerConnectionBox

    /// Estado de una conexión física concreta.
    @MainActor
    fileprivate final class PeerConnectionBox {
        let connectionID: TransportPeerID
        let connection: Connection
        let isOutgoing: Bool
        /// Endpoint Bonjour al que se marcó, solo en salientes.
        ///
        /// `connectionID` vive en el espacio de identificadores de Network y no
        /// se puede comparar con el de un `Bonjour.Endpoint`; guardarlo aparte es
        /// lo que permite detectar un segundo marcado al mismo endpoint.
        let dialedEndpointID: TransportPeerID?
        let sessionID = UUID()

        /// Se rellena al recibir el `hello` del remoto.
        var peer: ConnectedPeer?
        var receiveTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
        var readyContinuations: [CheckedContinuation<ConnectedPeer, Error>] = []
        var queue: TransportSendQueue?

        var isHandshakeComplete: Bool { peer != nil }

        init(
            connectionID: TransportPeerID,
            connection: Connection,
            isOutgoing: Bool,
            dialedEndpointID: TransportPeerID? = nil
        ) {
            self.connectionID = connectionID
            self.connection = connection
            self.isOutgoing = isOutgoing
            self.dialedEndpointID = dialedEndpointID
        }

        /// Resuelve y limpia a todos los que esperaban este handshake.
        func resolve(with result: Result<ConnectedPeer, Error>) {
            let waiting = readyContinuations
            readyContinuations.removeAll()
            for continuation in waiting {
                continuation.resume(with: result)
            }
        }

        func teardown() {
            receiveTask?.cancel()
            receiveTask = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            queue?.stop()
            queue = nil
        }
    }

    // MARK: - Identidad y anuncio

    private let applicationID: String
    private var advertisement: AdvertisementRecord

    /// Nombre de servicio Bonjour. Se deriva del `applicationID` y no del nombre
    /// visible, de modo que renombrar el dispositivo solo cambia el registro TXT
    /// y no obliga a reiniciar el listener ni corta las conexiones abiertas.
    private var serviceName: String { String(applicationID.prefix(8)).lowercased() }

    // MARK: - Ciclo de vida

    public private(set) var epoch: UInt64 = 0
    private var isAdvertising = false
    private var isBrowsing = false
    private var listener: Listener?
    private var listenerTask: Task<Void, Never>?
    private var browserTask: Task<Void, Never>?

    // MARK: - Eventos

    private let eventStream: AsyncStream<PeerTransportEvent>
    private let eventContinuation: AsyncStream<PeerTransportEvent>.Continuation

    public var events: AsyncStream<PeerTransportEvent> { eventStream }

    // MARK: - Descubrimiento

    private var advertisements: [TransportPeerID: PeerAdvertisement] = [:]
    private var endpoints: [TransportPeerID: Bonjour.Endpoint] = [:]

    // MARK: - Conexiones

    /// Conexiones vivas indexadas por el identificador de Network.
    private var boxes: [TransportPeerID: PeerConnectionBox] = [:]
    /// Conexión ganadora por peer, ya con handshake hecho.
    private var connectionIDsByApplicationID: [String: TransportPeerID] = [:]

    public var connectedPeers: [ConnectedPeer] {
        connectionIDsByApplicationID.values.compactMap { boxes[$0]?.peer }
    }

    // MARK: - Init

    public init(applicationID: String, displayName: String) {
        self.applicationID = applicationID
        self.advertisement = AdvertisementRecord(
            applicationID: applicationID,
            displayName: displayName
        )

        let stream = AsyncStream<PeerTransportEvent>.makeStream()
        self.eventStream = stream.stream
        self.eventContinuation = stream.continuation
    }

    deinit {
        listenerTask?.cancel()
        browserTask?.cancel()
        eventContinuation.finish()
    }

    // MARK: - Ciclo de vida

    public func start(advertising: Bool, browsing: Bool) {
        let advertisingChanged = isAdvertising != advertising
        let browsingChanged = isBrowsing != browsing
        guard advertisingChanged || browsingChanged else { return }

        epoch &+= 1
        isAdvertising = advertising
        isBrowsing = browsing

        if advertisingChanged {
            syncListener()
        }
        if browsingChanged {
            syncBrowser()
        }

        emit(.lifecycleChanged(.active, epoch: epoch))
    }

    public func stop() {
        guard isAdvertising || isBrowsing || listenerTask != nil || browserTask != nil || !boxes.isEmpty else {
            return
        }

        let stoppedEpoch = epoch
        epoch &+= 1
        isAdvertising = false
        isBrowsing = false

        listenerTask?.cancel()
        listenerTask = nil
        listener = nil
        browserTask?.cancel()
        browserTask = nil

        // Los peers establecidos deben notificarse: si no, el dominio sigue
        // creyéndolos conectados y al volver de background nunca se remarca.
        let establishedPeers = boxes.values.compactMap(\.peer)

        for box in boxes.values {
            box.resolve(with: .failure(P2PTransportError.transportStopped))
            box.teardown()
        }
        boxes.removeAll()
        connectionIDsByApplicationID.removeAll()

        // Estos eventos pertenecen a la época que se está cerrando. El manager
        // los descarta al ver que ya no coinciden con la época activa, evitando
        // tratar una suspensión voluntaria como una desconexión real de la room.
        for peer in establishedPeers {
            emit(.peerDisconnected(
                applicationID: peer.applicationID,
                reason: "La conectividad se ha detenido.",
                epoch: stoppedEpoch
            ))
        }

        for endpointID in advertisements.keys {
            emit(.advertisementLost(endpointID, epoch: stoppedEpoch))
        }
        advertisements.removeAll()
        endpoints.removeAll()

        emit(.lifecycleChanged(.disconnected, epoch: stoppedEpoch))
    }

    public func updateAdvertisement(_ record: AdvertisementRecord) {
        guard record != advertisement else { return }
        advertisement = record

        guard isAdvertising, let listener else { return }

        // El registro TXT se puede sustituir en caliente: el browser remoto ve el
        // cambio sin que se reinicie el servicio ni se caigan las conexiones.
        var service = listener.service
        service?.txtRecordObject = NWTXTRecord(record.txtDictionary)
        listener.service = service

        // El nombre visible viaja en TXT, así que un renombrado tampoco fuerza
        // recrear el listener.
    }

    // MARK: - Conexiones

    @discardableResult
    public func connect(to advertisement: PeerAdvertisement) async throws -> ConnectedPeer {
        // Reutiliza la conexión física existente: entrar en una segunda room con
        // el mismo peer no debe abrir otro socket.
        if let applicationID = advertisement.applicationID,
           let existingID = connectionIDsByApplicationID[applicationID],
           let peer = boxes[existingID]?.peer {
            return peer
        }

        guard P2PProtocolInfo.isCompatible(remoteVersion: advertisement.protocolVersion) else {
            throw P2PTransportError.incompatibleProtocol(advertisement.protocolVersion)
        }

        guard let endpoint = endpoints[advertisement.endpointID] else {
            throw P2PTransportError.peerNotDiscovered
        }

        // Si ya hay un marcado en curso al mismo endpoint, se espera a ese en vez
        // de abrir un segundo socket. Sin esta comprobación aparecen varias
        // conexiones en la misma dirección y el desempate deja de ser simétrico.
        if let pending = boxes.values.first(where: {
            $0.isOutgoing && $0.dialedEndpointID == advertisement.endpointID && !$0.isHandshakeComplete
        }) {
            return try await withCheckedThrowingContinuation { continuation in
                pending.readyContinuations.append(continuation)
            }
        }

        let connection = Connection(to: endpoint, using: makeParameters())
        let box = register(
            connection: connection,
            isOutgoing: true,
            dialedEndpointID: advertisement.endpointID
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.readyContinuations.append(continuation)
                sendHello(on: box)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.fail(box, error: CancellationError(), notifyPeer: true)
            }
        }
    }

    public func disconnect(applicationID: String, reason: String?) {
        guard let connectionID = connectionIDsByApplicationID[applicationID],
              let box = boxes[connectionID] else { return }

        fail(
            box,
            error: P2PTransportError.connectionFailed(reason ?? "Conexión cerrada."),
            notifyPeer: true
        )
    }

    // MARK: - Envío

    public func enqueue(_ envelope: RoomEnvelope, to applicationID: String) {
        guard let connectionID = connectionIDsByApplicationID[applicationID],
              let box = boxes[connectionID],
              let queue = box.queue else { return }

        queue.enqueue(envelope)
    }
}

// MARK: - Pila Network

@MainActor
private extension NetworkPeerTransport {

    func makeParameters() -> Parameters {
        NWParametersBuilder(auto: {
            Coder(P2PFrame.self, using: .json) {
                TCP {
                    IP()
                }
            }
        })
        .peerToPeerIncluded(true)
    }

    func syncListener() {
        listenerTask?.cancel()
        listenerTask = nil
        listener = nil

        guard isAdvertising else { return }

        listenerTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let listener = try Listener(
                    for: .bonjour(
                        name: self.serviceName,
                        type: P2PProtocolInfo.serviceType,
                        domain: nil,
                        txtRecord: NWTXTRecord(self.advertisement.txtDictionary)
                    ),
                    using: self.makeParameters()
                )
                self.listener = listener

                try await listener.run { [weak self] connection in
                    guard let self else { return }
                    await self.handleIncoming(connection)
                }
            } catch is CancellationError {
                return
            } catch {
                self.listener = nil
                self.emit(.lifecycleChanged(.disconnected, epoch: self.epoch))
            }
        }
    }

    func syncBrowser() {
        browserTask?.cancel()
        browserTask = nil

        guard isBrowsing else {
            clearAdvertisements()
            return
        }

        browserTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // `includeTxtRecord: true` es obligatorio: sin él el registro TXT
            // llega vacío y no se pueden listar rooms antes de conectar.
            let browser = NetworkBrowser(
                for: .bonjour(
                    P2PProtocolInfo.serviceType,
                    domain: nil,
                    includeTxtRecord: true
                ),
                using: NWParameters().peerToPeerIncluded(true)
            )

            do {
                try await browser.run { [weak self] endpoints in
                    self?.updateAdvertisements(endpoints)
                }
            } catch is CancellationError {
                return
            } catch {
                self.clearAdvertisements()
            }
        }
    }

    func updateAdvertisements(_ discovered: [Bonjour.Endpoint]) {
        var seen: Set<TransportPeerID> = []

        for endpoint in discovered {
            let endpointID = TransportPeerID(endpoint.id)

            let record = AdvertisementRecord.advertisement(
                from: endpoint.txtRecord.dictionary,
                endpointID: endpointID,
                fallbackName: endpoint.name.isEmpty ? endpoint.id : endpoint.name
            )

            // El propio anuncio se ve en el browser: hay que filtrarlo.
            guard record.applicationID != applicationID else { continue }

            seen.insert(endpointID)
            endpoints[endpointID] = endpoint

            // Una instalación solo puede estar en un endpoint. Si reaparece con
            // otro identificador (renombrado, cambio de interfaz), el anterior
            // queda obsoleto y hay que retirarlo o `connect` marcaría al viejo.
            if let applicationID = record.applicationID {
                for (staleID, stale) in advertisements
                where staleID != endpointID && stale.applicationID == applicationID {
                    advertisements.removeValue(forKey: staleID)
                    endpoints.removeValue(forKey: staleID)
                    emit(.advertisementLost(staleID, epoch: epoch))
                }
            }

            guard let previous = advertisements[endpointID] else {
                advertisements[endpointID] = record
                emit(.advertisementFound(record, epoch: epoch))
                continue
            }

            if previous != record {
                advertisements[endpointID] = record
                emit(.advertisementUpdated(record, epoch: epoch))
            }
        }

        for endpointID in advertisements.keys where !seen.contains(endpointID) {
            advertisements.removeValue(forKey: endpointID)
            endpoints.removeValue(forKey: endpointID)
            emit(.advertisementLost(endpointID, epoch: epoch))
        }
    }

    func clearAdvertisements() {
        for endpointID in advertisements.keys {
            emit(.advertisementLost(endpointID, epoch: epoch))
        }
        advertisements.removeAll()
        endpoints.removeAll()
    }
}

// MARK: - Handshake y recepción

@MainActor
private extension NetworkPeerTransport {

    func handleIncoming(_ connection: Connection) async {
        let box = register(connection: connection, isOutgoing: false)
        sendHello(on: box)

        // La conexión entrante vive mientras dure su bucle de recepción; el
        // closure de `listener.run` no debe volver antes.
        if let receiveTask = box.receiveTask {
            await receiveTask.value
        }
    }

    @discardableResult
    func register(
        connection: Connection,
        isOutgoing: Bool,
        dialedEndpointID: TransportPeerID? = nil
    ) -> PeerConnectionBox {
        let connectionID = TransportPeerID(connection.id)
        let box = PeerConnectionBox(
            connectionID: connectionID,
            connection: connection,
            isOutgoing: isOutgoing,
            dialedEndpointID: dialedEndpointID
        )

        box.queue = TransportSendQueue(
            send: { [weak connection] envelope in
                guard let connection else { throw P2PTransportError.notConnected }
                try await connection.send(.envelope(envelope))
            },
            onFailure: { [weak self, weak box] error in
                guard let self, let box else { return }
                self.fail(box, error: error, notifyPeer: false)
            }
        )

        boxes[connectionID] = box

        box.receiveTask = Task { @MainActor [weak self] in
            await self?.receiveLoop(box)
        }

        box.timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: P2PLimits.handshakeTimeout)
            } catch {
                return
            }
            guard let self, !box.isHandshakeComplete else { return }
            self.fail(box, error: P2PTransportError.handshakeTimedOut, notifyPeer: true)
        }

        return box
    }

    func sendHello(on box: PeerConnectionBox) {
        let body = HelloBody(
            applicationID: applicationID,
            displayName: advertisement.displayName
        )

        Task { @MainActor [weak self, weak box] in
            guard let box else { return }
            do {
                try await box.connection.send(.hello(body))
            } catch {
                self?.fail(box, error: error, notifyPeer: false)
            }
        }
    }

    func receiveLoop(_ box: PeerConnectionBox) async {
        do {
            for try await message in box.connection.messages {
                handle(message.content, on: box)
            }
            // Fin limpio del stream: el peer soltó la conexión.
            fail(
                box,
                error: P2PTransportError.connectionFailed("El otro dispositivo cerró la conexión."),
                notifyPeer: false
            )
        } catch is CancellationError {
            return
        } catch {
            fail(box, error: error, notifyPeer: false)
        }
    }

    func handle(_ frame: P2PFrame, on box: PeerConnectionBox) {
        switch frame.kind {
        case .hello:
            guard let body = frame.hello else {
                fail(box, error: P2PTransportError.handshakeFailed("Hello incompleto."), notifyPeer: true)
                return
            }
            completeHandshake(body, on: box)

        case .envelope:
            guard let peer = box.peer, let envelope = frame.envelope else { return }

            guard envelope.protocolVersion >= P2PProtocolInfo.minimumVersion else {
                fail(
                    box,
                    error: P2PTransportError.incompatibleProtocol(envelope.protocolVersion),
                    notifyPeer: true
                )
                return
            }

            // Un peer no puede firmar un envelope en nombre de otro.
            guard envelope.senderApplicationID == peer.applicationID else { return }

            guard envelope.payload.count <= P2PLimits.maximumEnvelopeBytes else { return }

            emit(.received(envelope, from: peer, epoch: epoch))

        case .goodbye:
            let reason = frame.goodbye?.reason ?? "El otro dispositivo se ha desconectado."
            fail(box, error: P2PTransportError.connectionFailed(reason), notifyPeer: false)
        }
    }

    func completeHandshake(_ body: HelloBody, on box: PeerConnectionBox) {
        guard !box.isHandshakeComplete else { return }

        guard P2PProtocolInfo.isCompatible(remoteVersion: body.protocolVersion),
              body.minimumProtocolVersion <= P2PProtocolInfo.currentVersion else {
            fail(
                box,
                error: P2PTransportError.incompatibleProtocol(body.protocolVersion),
                notifyPeer: true
            )
            return
        }

        guard !body.applicationID.isEmpty, body.applicationID != applicationID else {
            fail(box, error: P2PTransportError.handshakeFailed("Identidad inválida."), notifyPeer: true)
            return
        }

        // Ambos dispositivos anuncian y buscan a la vez, así que pueden abrir dos
        // conexiones simultáneas. La regla de desempate es determinista y ambos
        // extremos llegan a la misma conclusión, por lo que descartan la misma.
        if let rivalID = connectionIDsByApplicationID[body.applicationID],
           let rival = boxes[rivalID], rival !== box {
            let keepOutgoing = min(applicationID, body.applicationID) == applicationID
            let loser = keepOutgoing
                ? (box.isOutgoing ? rival : box)
                : (box.isOutgoing ? box : rival)

            if loser === box {
                discardDuplicate(box)
                return
            }
            discardDuplicate(loser)
        }

        let peer = ConnectedPeer(
            applicationID: body.applicationID,
            displayName: body.displayName.isEmpty ? "Dispositivo cercano" : body.displayName,
            protocolVersion: body.protocolVersion,
            capabilities: Set(body.capabilities),
            connectionSessionID: box.sessionID
        )

        box.peer = peer
        box.timeoutTask?.cancel()
        box.timeoutTask = nil
        connectionIDsByApplicationID[body.applicationID] = box.connectionID

        box.resolve(with: .success(peer))

        emit(.peerConnected(peer, epoch: epoch))
    }

    /// Cierra la conexión perdedora de un empate sin emitir `peerDisconnected`:
    /// el peer sigue conectado por la otra conexión.
    func discardDuplicate(_ box: PeerConnectionBox) {
        box.resolve(with: .failure(P2PTransportError.connectionFailed("Conexión duplicada.")))

        let connection = box.connection
        Task { @MainActor in
            try? await connection.send(.goodbye(reason: "Conexión duplicada."))
        }

        box.teardown()
        boxes.removeValue(forKey: box.connectionID)
    }

    /// Única ruta de teardown. Suelta la conexión (Network no ofrece `cancel()`
    /// en iOS 26) y notifica al dominio solo si el peer estaba establecido.
    func fail(_ box: PeerConnectionBox, error: Error, notifyPeer: Bool) {
        guard boxes[box.connectionID] != nil else { return }

        if notifyPeer {
            let connection = box.connection
            let reason = error.localizedDescription
            Task { @MainActor in
                try? await connection.send(.goodbye(reason: reason))
            }
        }

        box.resolve(with: .failure(error))
        box.teardown()
        boxes.removeValue(forKey: box.connectionID)

        guard let peer = box.peer else { return }

        // Solo se limpia el índice si esta era la conexión vigente del peer.
        if connectionIDsByApplicationID[peer.applicationID] == box.connectionID {
            connectionIDsByApplicationID.removeValue(forKey: peer.applicationID)
            emit(.peerDisconnected(
                applicationID: peer.applicationID,
                reason: error.localizedDescription,
                epoch: epoch
            ))
        }
    }

    func emit(_ event: PeerTransportEvent) {
        eventContinuation.yield(event)
    }
}
