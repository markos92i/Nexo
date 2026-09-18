//
//  NetworkPeerTransport.swift
//  Nexo
//

import Foundation
import Network
import OSLog

// MARK: - NetworkPeerTransport

/// P2P transport over Network framework's structured API (iOS 26).
///
/// Control traffic uses `Coder<P2PFrame> / TCP / IP`; bulk traffic uses
/// authenticated QUIC streams over UDP/IP. Both services use Bonjour and
/// peer-to-peer networking.
@MainActor
public final class NetworkPeerTransport: PeerTransport {

    private static let logger = Logger(subsystem: "com.zafir.nexo", category: "transport")

    // MARK: - Network Types

    // `fileprivate`, not `private`: these types appear in signatures of
    // extensions in this same file.
    fileprivate typealias ApplicationProtocol = Coder<P2PFrame, P2PFrame, NetworkJSONCoder>
    fileprivate typealias Parameters = NWParametersBuilder<ApplicationProtocol>
    fileprivate typealias Connection = NetworkConnection<ApplicationProtocol>
    fileprivate typealias Listener = NetworkListener<ApplicationProtocol>
    fileprivate typealias QUICParameters = NWParametersBuilder<QUIC>
    fileprivate typealias QUICConnection = NetworkConnection<QUIC>
    fileprivate typealias QUICListener = NetworkListener<QUIC>

    // MARK: - PeerConnectionBox

    /// State of one physical connection.
    @MainActor
    fileprivate final class PeerConnectionBox {
        let connectionID: TransportPeerID
        let connection: Connection
        let isOutgoing: Bool
        /// Bonjour endpoint dialed, only set for outgoing connections.
        ///
        /// `connectionID` lives in Network's own identifier space and can't be
        /// compared to a `Bonjour.Endpoint`'s; keeping this separately is what
        /// lets us detect a second dial to the same endpoint.
        let dialedEndpointID: TransportPeerID?
        let sessionID = UUID()

        /// Filled in once the remote's `hello` arrives.
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

        /// Resolves and clears everyone waiting on this handshake.
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

    // MARK: - Identity and advertisement

    private let applicationID: String
    private let localCertificateFingerprint: String?
    private let tlsConfiguration: NexoTLSConfiguration?
    private var advertisement: AdvertisementRecord

    /// Bonjour service name. Derived from `applicationID`, not the display
    /// name, so renaming the device only changes the TXT record without
    /// restarting the listener or dropping open connections.
    private var serviceName: String { String(applicationID.prefix(8)).lowercased() }

    // MARK: - Lifecycle

    public private(set) var epoch: UInt64 = 0
    private var isAdvertising = false
    private var isBrowsing = false
    private var localNetworkPermissionState: LocalNetworkPermissionState = .unknown
    private var listener: Listener?
    private var listenerTask: Task<Void, Never>?
    private var quicListener: QUICListener?
    private var quicListenerTask: Task<Void, Never>?
    private var browserTask: Task<Void, Never>?
    private var quicBrowserTask: Task<Void, Never>?

    // MARK: - Events

    private let eventStream: AsyncStream<PeerTransportEvent>
    private let eventContinuation: AsyncStream<PeerTransportEvent>.Continuation

    public var events: AsyncStream<PeerTransportEvent> { eventStream }

    public var isTLSConfigured: Bool { tlsConfiguration != nil }

    // MARK: - Discovery

    private var advertisements: [TransportPeerID: PeerAdvertisement] = [:]
    private var endpoints: [TransportPeerID: Bonjour.Endpoint] = [:]
    private var quicEndpointsByApplicationID: [String: Bonjour.Endpoint] = [:]

    // MARK: - Connections

    /// Live connections indexed by Network's identifier.
    private var boxes: [TransportPeerID: PeerConnectionBox] = [:]
    /// Winning connection per peer, once handshaken.
    private var connectionIDsByApplicationID: [String: TransportPeerID] = [:]
    private var binaryTransportsByApplicationID: [String: NexoQUICBinaryTransport] = [:]
    private var binaryIncomingTasksByApplicationID: [String: Task<Void, Never>] = [:]

    private let incomingBinaryStream: AsyncStream<NexoQUICIncomingStream>
    private let incomingBinaryContinuation: AsyncStream<NexoQUICIncomingStream>.Continuation
    private let incomingPeerBinaryStream: AsyncStream<NexoPeerBinaryStream>
    private let incomingPeerBinaryContinuation: AsyncStream<NexoPeerBinaryStream>.Continuation

    public var incomingBinaryStreams: AsyncStream<NexoQUICIncomingStream> {
        incomingBinaryStream
    }

    public var incomingPeerBinaryStreams: AsyncStream<NexoPeerBinaryStream> {
        incomingPeerBinaryStream
    }

    public var connectedPeers: [ConnectedPeer] {
        connectionIDsByApplicationID.values.compactMap { boxes[$0]?.peer }
    }

    // MARK: - Init

    public init(
        applicationID: String,
        displayName: String,
        tlsConfiguration: NexoTLSConfiguration? = nil,
        localCertificateFingerprint: String? = nil
    ) {
        self.applicationID = applicationID
        self.localCertificateFingerprint = localCertificateFingerprint
        self.tlsConfiguration = tlsConfiguration
        self.advertisement = AdvertisementRecord(
            applicationID: applicationID,
            displayName: displayName
        )

        let stream = AsyncStream<PeerTransportEvent>.makeStream()
        self.eventStream = stream.stream
        self.eventContinuation = stream.continuation

        let binaryStream = AsyncStream<NexoQUICIncomingStream>.makeStream()
        self.incomingBinaryStream = binaryStream.stream
        self.incomingBinaryContinuation = binaryStream.continuation

        let peerBinaryStream = AsyncStream<NexoPeerBinaryStream>.makeStream()
        self.incomingPeerBinaryStream = peerBinaryStream.stream
        self.incomingPeerBinaryContinuation = peerBinaryStream.continuation
    }

    deinit {
        listenerTask?.cancel()
        quicListenerTask?.cancel()
        browserTask?.cancel()
        quicBrowserTask?.cancel()
        for task in binaryIncomingTasksByApplicationID.values {
            task.cancel()
        }
        eventContinuation.finish()
        incomingBinaryContinuation.finish()
        incomingPeerBinaryContinuation.finish()
    }

    // MARK: - Lifecycle

    public func start(advertising: Bool, browsing: Bool) {
        let advertisingChanged = isAdvertising != advertising
        let browsingChanged = isBrowsing != browsing
        guard advertisingChanged || browsingChanged else { return }

        epoch &+= 1
        isAdvertising = advertising
        isBrowsing = browsing
        updateLocalNetworkPermission(.unknown)

        if advertisingChanged {
            syncListener()
            syncQUICListener()
        }
        if browsingChanged {
            syncBrowser()
            syncQUICBrowser()
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
        quicListenerTask?.cancel()
        quicListenerTask = nil
        quicListener = nil
        browserTask?.cancel()
        browserTask = nil
        quicBrowserTask?.cancel()
        quicBrowserTask = nil
        for task in binaryIncomingTasksByApplicationID.values {
            task.cancel()
        }
        binaryIncomingTasksByApplicationID.removeAll()
        quicEndpointsByApplicationID.removeAll()
        binaryTransportsByApplicationID.removeAll()

        // Established peers must be notified: otherwise the domain keeps
        // thinking they're connected and never re-marks them after background.
        let establishedPeers = boxes.values.compactMap(\.peer)

        for box in boxes.values {
            box.resolve(with: .failure(P2PTransportError.transportStopped))
            box.teardown()
        }
        boxes.removeAll()
        connectionIDsByApplicationID.removeAll()

        // These events belong to the epoch being closed. The manager discards
        // them once they no longer match the active epoch, so a voluntary
        // suspension is never treated as a real room disconnect.
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

        // The TXT record can be swapped live: the remote browser sees the
        // change without the service restarting or connections dropping.
        var service = listener.service
        service?.txtRecordObject = NWTXTRecord(record.txtDictionary)
        listener.service = service

        if let quicListener {
            var quicService = quicListener.service
            quicService?.txtRecordObject = NWTXTRecord(record.txtDictionary)
            quicListener.service = quicService
        }

        // The display name travels in TXT, so a rename doesn't force
        // recreating the listener either.
    }

    // MARK: - Connections

    @discardableResult
    public func connect(to advertisement: PeerAdvertisement) async throws -> ConnectedPeer {
        // Reuses the existing physical connection: joining a second room with
        // the same peer must not open another socket.
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

        // If a dial to the same endpoint is already in flight, wait on it
        // instead of opening a second socket. Without this check several
        // connections appear in the same direction and tie-breaking stops being symmetric.
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

    // MARK: - Sending

    public func enqueue(_ envelope: RoomEnvelope, to applicationID: String) {
        guard let connectionID = connectionIDsByApplicationID[applicationID],
              let box = boxes[connectionID],
              let queue = box.queue else { return }

        queue.enqueue(envelope)
    }

    /// Opens a QUIC binary stream after the JSON connection has negotiated it.
    public func openBinaryStream(
        to applicationID: String,
        descriptor: NexoStreamDescriptor
    ) async throws -> NexoQUICByteStream {
        guard let connectionID = connectionIDsByApplicationID[applicationID],
              let peer = boxes[connectionID]?.peer,
              peer.supports(.binaryStreams)
        else {
            throw P2PTransportError.connectionFailed("El peer no admite streams binarios.")
        }

        guard let endpoint = quicEndpointsByApplicationID[applicationID] else {
            throw P2PTransportError.peerNotDiscovered
        }

        let transport: NexoQUICBinaryTransport
        if let existing = binaryTransportsByApplicationID[applicationID] {
            transport = existing
        } else {
            transport = NexoQUICBinaryTransport.connect(
                to: endpoint.nwEndpoint,
                applicationID: self.applicationID,
                expectedRemoteApplicationID: applicationID,
                tlsConfiguration: tlsConfiguration
            )
            binaryTransportsByApplicationID[applicationID] = transport
            startIncomingBinaryStreams(from: transport, for: applicationID)
        }

        return try await transport.openStream(descriptor)
    }
}

// MARK: - Network stack

@MainActor
private extension NetworkPeerTransport {

    func makeParameters() -> Parameters {
        if let tlsConfiguration {
            return NWParametersBuilder(auto: {
                Coder(P2PFrame.self, using: .json) {
                    tlsConfiguration.configure(TLS {
                        TCP {
                            IP()
                        }
                    })
                }
            })
            .peerToPeerIncluded(true)
        }

        return NWParametersBuilder(auto: {
            Coder(P2PFrame.self, using: .json) {
                TCP {
                    IP()
                }
            }
        })
        .peerToPeerIncluded(true)
    }

    func makeQUICParameters() -> QUICParameters {
        if let tlsConfiguration {
            return NWParametersBuilder(auto: {
                tlsConfiguration.configure(QUIC(
                    alpn: ["nexo-binary-v1"],
                    { UDP { IP() } }
                ))
            })
            .peerToPeerIncluded(true)
        }

        return NWParametersBuilder(auto: {
            QUIC(alpn: ["nexo-binary-v1"], { UDP { IP() } })
        })
        .peerToPeerIncluded(true)
    }

    func syncQUICListener() {
        quicListenerTask?.cancel()
        quicListenerTask = nil
        quicListener = nil

        guard isAdvertising else { return }

        quicListenerTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let listener = try QUICListener(
                    for: .bonjour(
                        name: self.serviceName,
                        type: P2PProtocolInfo.quicServiceType,
                        domain: nil,
                        txtRecord: NWTXTRecord(self.advertisement.txtDictionary)
                    ),
                    using: self.makeQUICParameters()
                )
                self.quicListener = listener

                try await listener.run { [weak self] connection in
                    guard let self else { return }
                    try await self.handleIncomingQUIC(connection)
                }
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("QUIC listener failed: \(error.localizedDescription, privacy: .public)")
                self.quicListener = nil
            }
        }
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
                Self.logger.error("TCP listener failed: \(error.localizedDescription, privacy: .public)")
                self.listener = nil
                if self.isLocalNetworkPermissionDenied(error) {
                    self.updateLocalNetworkPermission(.denied)
                }
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

            // `includeTxtRecord: true` is mandatory: without it the TXT
            // record arrives empty and rooms can't be listed before connecting.
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
                    self?.updateLocalNetworkPermission(.available)
                    self?.updateAdvertisements(endpoints)
                }
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("TCP browser failed: \(error.localizedDescription, privacy: .public)")
                self.clearAdvertisements()
                if self.isLocalNetworkPermissionDenied(error) {
                    self.updateLocalNetworkPermission(.denied)
                }
            }
        }
    }

    func syncQUICBrowser() {
        quicBrowserTask?.cancel()
        quicBrowserTask = nil

        guard isBrowsing else {
            quicEndpointsByApplicationID.removeAll()
            return
        }

        quicBrowserTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let browser = NetworkBrowser(
                for: .bonjour(
                    P2PProtocolInfo.quicServiceType,
                    domain: nil,
                    includeTxtRecord: true
                ),
                using: NWParameters().peerToPeerIncluded(true)
            )

            do {
                try await browser.run { [weak self] endpoints in
                    self?.updateQUICEndpoints(endpoints)
                }
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("QUIC browser failed: \(error.localizedDescription, privacy: .public)")
                self.quicEndpointsByApplicationID.removeAll()
            }
        }
    }

    func updateLocalNetworkPermission(_ state: LocalNetworkPermissionState) {
        guard localNetworkPermissionState != state else { return }
        localNetworkPermissionState = state
        emit(.localNetworkPermissionChanged(state, epoch: epoch))
    }

    func isLocalNetworkPermissionDenied(_ error: any Error) -> Bool {
        if let networkError = error as? NWError,
           case .posix(.EACCES) = networkError {
            return true
        }

        let description = String(describing: error) + " " + error.localizedDescription
        return description.localizedCaseInsensitiveContains("PolicyDenied")
            || description.localizedCaseInsensitiveContains("policy denied")
            || description.localizedCaseInsensitiveContains("LocalNetwork")
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

            // The advertisement shows up in our own browser: must be filtered out.
            guard record.applicationID != applicationID else { continue }

            seen.insert(endpointID)
            endpoints[endpointID] = endpoint

            // One installation can only be at one endpoint. If it reappears
            // with a different identifier (renamed, interface change), the
            // old one is stale and must be retired, or `connect` would dial it.
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

    func updateQUICEndpoints(_ discovered: [Bonjour.Endpoint]) {
        var seen: Set<String> = []

        for endpoint in discovered {
            guard let applicationID = endpoint.txtRecord.dictionary["aid"],
                  applicationID != self.applicationID else { continue }

            seen.insert(applicationID)
            quicEndpointsByApplicationID[applicationID] = endpoint
        }

        for applicationID in quicEndpointsByApplicationID.keys
        where !seen.contains(applicationID) {
            quicEndpointsByApplicationID.removeValue(forKey: applicationID)
            binaryTransportsByApplicationID.removeValue(forKey: applicationID)
        }
    }
}

// MARK: - Handshake and receiving

@MainActor
private extension NetworkPeerTransport {

    func handleIncoming(_ connection: Connection) async {
        let box = register(connection: connection, isOutgoing: false)
        sendHello(on: box)

        // The incoming connection lives as long as its receive loop runs;
        // `listener.run`'s closure must not return before that.
        if let receiveTask = box.receiveTask {
            await receiveTask.value
        }
    }

    func handleIncomingQUIC(_ connection: QUICConnection) async throws {
        let transport = NexoQUICBinaryTransport(
            connection: connection,
            applicationID: applicationID
        )
        let streams = await transport.startIncoming()

        for try await stream in streams {
            binaryTransportsByApplicationID[stream.peerApplicationID] = transport
            acceptIncomingBinaryStream(stream)
        }
    }

    func startIncomingBinaryStreams(
        from transport: NexoQUICBinaryTransport,
        for applicationID: String
    ) {
        let streams = Task { await transport.startIncoming() }
        binaryIncomingTasksByApplicationID[applicationID]?.cancel()
        binaryIncomingTasksByApplicationID[applicationID] = Task { @MainActor [weak self] in
            let incoming = await streams.value
            do {
                for try await stream in incoming {
                    self?.acceptIncomingBinaryStream(stream)
                }
            } catch {
                return
            }
        }
    }

    func acceptIncomingBinaryStream(_ stream: NexoQUICIncomingStream) {
        guard let connectionID = connectionIDsByApplicationID[stream.peerApplicationID],
              let peer = boxes[connectionID]?.peer,
              peer.supports(.binaryStreams)
        else { return }

        incomingBinaryContinuation.yield(stream)
        incomingPeerBinaryContinuation.yield(NexoPeerBinaryStream(
            peer: peer,
            descriptor: stream.descriptor,
            stream: stream.stream
        ))
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
            displayName: advertisement.displayName,
            certificateFingerprint: localCertificateFingerprint
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
            // Clean end of stream: the peer dropped the connection.
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

            // A peer can't sign an envelope on another's behalf.
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

        // Both devices advertise and browse at once, so they can open two
        // simultaneous connections. The tie-break rule is deterministic and
        // both ends reach the same conclusion, so they discard the same one.
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
            certificateFingerprint: body.certificateFingerprint,
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

    /// Closes the loser of a tie without emitting `peerDisconnected`: the
    /// peer is still connected through the other connection.
    func discardDuplicate(_ box: PeerConnectionBox) {
        box.resolve(with: .failure(P2PTransportError.connectionFailed("Conexión duplicada.")))

        let connection = box.connection
        Task { @MainActor in
            try? await connection.send(.goodbye(reason: "Conexión duplicada."))
        }

        box.teardown()
        boxes.removeValue(forKey: box.connectionID)
    }

    /// The single teardown path. Drops the connection (Network offers no
    /// `cancel()` on iOS 26) and notifies the domain only if the peer had
    /// been established.
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

        // Only clean up the index if this was the peer's current connection.
        if connectionIDsByApplicationID[peer.applicationID] == box.connectionID {
            connectionIDsByApplicationID.removeValue(forKey: peer.applicationID)
            binaryIncomingTasksByApplicationID.removeValue(forKey: peer.applicationID)?.cancel()
            binaryTransportsByApplicationID.removeValue(forKey: peer.applicationID)
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
