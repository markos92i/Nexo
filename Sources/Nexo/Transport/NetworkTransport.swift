//
//  NetworkTransport.swift
//  Nexo
//
//  Capa de transporte físico sobre la API clásica de Network framework
//  (NWConnection / NWListener / NWBrowser / NWParameters / NWProtocolTLS).
//
//  Se usa la API clásica y no la declarativa porque el cifrado PSK sólo puede
//  configurarse vía `NWProtocolTLS.Options.securityProtocolOptions` +
//  `sec_protocol_options_add_pre_shared_key`, inexistente en la API nueva.
//

import Foundation
import Network
import CryptoKit
import OSLog
import Synchronization

// MARK: - NetworkTransport

/// Transporte físico P2P cifrado con PSK, confinado a su propio actor.
///
/// Cada peer tiene una única conexión física indexada por `DeviceID`. El estado
/// mutable por conexión vive en una clase `Connection` NO-Sendable confinada al
/// actor; las tareas hijas sólo capturan identidad inmutable (`sessionID`,
/// `deviceID`) y `[weak self]`, nunca la clase completa.
public actor NetworkTransport: Transport, BinaryStreamOpening {

    private static let logger = Logger(subsystem: "com.zafir.nexo", category: "transport")

    // MARK: Estado compartido sin aislamiento (leído de forma síncrona)

    /// Estado mínimo que `start`/`stop`/`epoch`/`connectedPeers`/`emit` leen sin
    /// `await`. Un único `Mutex` sirve de puerta de admisión y de reloj de epoch.
    private struct Shared {
        var epoch: UInt64 = 0
        var isStopped = true
        var advertising = false
        var browsing = false
        /// Comandos pendientes de aplicar en el ejecutor del actor.
        var commands: [PendingCommand] = []
        /// Peers con handshake completado, para lectura síncrona.
        var connectedPeers: [DeviceID: ConnectedPeer] = [:]
    }

    private let shared = Mutex(Shared())
    private let wakeup: AsyncStream<Void>.Continuation

    private let eventStream: AsyncStream<TransportEvent>
    private let eventContinuation: AsyncStream<TransportEvent>.Continuation

    public nonisolated var events: AsyncStream<TransportEvent> { eventStream }
    public nonisolated var epoch: UInt64 { shared.withLock { $0.epoch } }
    public nonisolated var connectedPeers: [ConnectedPeer] {
        shared.withLock { Array($0.connectedPeers.values) }
    }

    // MARK: Identidad y cifrado (inmutable)

    private let crypto: SessionCrypto
    private let deviceID: DeviceID

    // MARK: Estado aislado al actor

    /// Anuncio local mutable. El TXT publicado se deriva de aquí.
    private var advertisement: AdvertisementRecord
    /// Epoch de la sesión activa, o `nil` si está parada.
    private var activeEpoch: UInt64?
    private var isAdvertising = false
    private var isBrowsing = false
    private var localNetworkPermission: LocalNetworkPermission = .unknown

    /// Nombre de servicio Bonjour, derivado del deviceID (minúsculas, acotado).
    private var serviceName: String { String(deviceID.description.prefix(8)).lowercased() }

    private var listener: NWListener?
    private var browser: NWBrowser?

    /// Canales QUIC binarios por peer (capacidad `BinaryStreamOpening`). Se crean
    /// perezosamente al abrir el primer stream a un peer, o al aceptar uno suyo.
    private var binaryChannels: [DeviceID: QUICChannel] = [:]
    private let incomingByteStreamContinuation: AsyncStream<QUICIncomingStream>.Continuation
    private let incomingByteStreamStream: AsyncStream<QUICIncomingStream>
    public nonisolated var incomingByteStreams: AsyncStream<QUICIncomingStream> { incomingByteStreamStream }
    private var listenerRetry: Task<Void, Never>?
    private var browserRetry: Task<Void, Never>?
    private var listenerRetryAttempt = 0
    private var browserRetryAttempt = 0

    /// Anuncios descubiertos, indexados por el endpoint Bonjour.
    private var advertisements: [TransportPeerID: PeerAdvertisement] = [:]
    private var endpoints: [TransportPeerID: NWEndpoint] = [:]

    /// Una conexión física por peer resuelto, indexada por `DeviceID`.
    private var connectionsByDevice: [DeviceID: Connection] = [:]
    /// Todas las conexiones vivas (resueltas o en handshake), por sessionID.
    private var connectionsBySession: [UUID: Connection] = [:]
    /// Tareas de despedida (goodbye) en vuelo.
    private var farewellTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: Init

    public init(crypto: SessionCrypto, deviceID: DeviceID, displayName: String) {
        self.crypto = crypto
        self.deviceID = deviceID
        self.advertisement = AdvertisementRecord(deviceID: deviceID, displayName: displayName)

        let events = AsyncStream<TransportEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.eventStream = events.stream
        self.eventContinuation = events.continuation

        let signals = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.wakeup = signals.continuation

        let binary = AsyncStream<QUICIncomingStream>.makeStream(bufferingPolicy: .bufferingOldest(16))
        self.incomingByteStreamStream = binary.stream
        self.incomingByteStreamContinuation = binary.continuation

        Task { [weak self] in
            for await _ in signals.stream {
                while let work = self?.nextCommand() {
                    await self?.apply(work)
                }
            }
        }
    }

    deinit {
        wakeup.finish()
        eventContinuation.finish()
        listenerRetry?.cancel()
        browserRetry?.cancel()
        for task in farewellTasks.values { task.cancel() }
    }

    // MARK: - Admisión de comandos (nonisolated, no-bloqueante)

    private enum Command: Sendable {
        case start(advertising: Bool, browsing: Bool)
        case stop
        case updateAdvertisement(AdvertisementRecord)
        case refreshDiscovery
        case disconnect(DeviceID, DisconnectReason?)
        case send(Envelope, DeviceID)
    }

    private struct PendingCommand: Sendable {
        let epoch: UInt64
        let command: Command
    }

    public nonisolated func start(advertising: Bool, browsing: Bool) {
        submit(.start(advertising: advertising, browsing: browsing))
    }

    public nonisolated func stop() {
        submit(.stop)
    }

    public nonisolated func updateAdvertisement(_ record: AdvertisementRecord) {
        submit(.updateAdvertisement(record))
    }

    public nonisolated func refreshDiscovery() {
        submit(.refreshDiscovery)
    }

    public nonisolated func disconnect(deviceID: DeviceID, reason: DisconnectReason?) {
        submit(.disconnect(deviceID, reason))
    }

    public nonisolated func enqueue(_ envelope: Envelope, to deviceID: DeviceID) {
        submit(.send(envelope, deviceID))
    }

    private nonisolated func submit(_ command: Command) {
        shared.withLock { state in
            switch command {
            case let .start(advertising, browsing):
                // Un cambio de parámetros, o un re-start tras stop, es una nueva epoch.
                if state.isStopped || state.advertising != advertising || state.browsing != browsing {
                    state.epoch &+= 1
                }
                state.isStopped = false
                state.advertising = advertising
                state.browsing = browsing
            case .stop:
                state.epoch &+= 1
                state.isStopped = true
            default:
                break
            }

            // Coalescing latest-wins para snapshots antes de encolar, no después de
            // acumular un backlog ilimitado en el AsyncStream.
            if case let .send(envelope, peer) = command {
                for index in state.commands.indices.reversed() {
                    guard state.commands[index].epoch == state.epoch,
                          case let .send(previous, previousPeer) = state.commands[index].command
                    else { break }
                    if peer == previousPeer && envelope.canReplace(previous) {
                        state.commands.remove(at: index)
                        break
                    }
                }
            }

            // Cota dura de backlog: ante sobrecarga, se descarta y se para.
            if state.commands.count >= 1024 {
                state.commands.removeAll()
                state.isStopped = true
                state.epoch &+= 1
            } else {
                state.commands.append(PendingCommand(epoch: state.epoch, command: command))
            }
            wakeup.yield(())
        }
    }

    private nonisolated func nextCommand() -> PendingCommand? {
        shared.withLock { state in
            guard !state.commands.isEmpty else { return nil }
            return state.commands.removeFirst()
        }
    }

    private nonisolated func isCurrent(_ token: UInt64) -> Bool {
        shared.withLock { !$0.isStopped && $0.epoch == token }
    }

    // MARK: - Aplicación de comandos (en el actor)

    private func apply(_ pending: PendingCommand) async {
        let token = pending.epoch
        switch pending.command {
        case .stop:
            // Un stop aplica a su epoch y a cualquiera anterior todavía activa.
            if activeEpoch.map({ $0 <= token }) ?? true {
                await stopSession()
            }

        case let .start(advertising, browsing):
            guard isCurrent(token) else { return }
            if activeEpoch != token { await stopSession() }
            guard isCurrent(token) else { return }
            activeEpoch = token
            isAdvertising = advertising
            isBrowsing = browsing
            resetRetries()
            if advertising { startListener(epoch: token) }
            if browsing { startBrowser(epoch: token) }
            if !advertising || listener != nil {
                emit(.lifecycleChanged(.active, epoch: token))
            }

        case let .updateAdvertisement(record):
            advertisement = record
            guard isCurrent(token), activeEpoch == token else { return }
            republishTXT()
            if isAdvertising, listener == nil { startListener(epoch: token) }

        case .refreshDiscovery:
            guard isCurrent(token), activeEpoch == token else { return }
            resetRetries()
            if isAdvertising, listener == nil { startListener(epoch: token) }
            if isBrowsing { startBrowser(epoch: token) }
            republishTXT()

        case let .disconnect(peerDeviceID, reason):
            guard isCurrent(token), let connection = connectionsByDevice[peerDeviceID] else { return }
            await fail(connection, error: TransportError.connectionFailed(reason ?? .connectionClosed), sendGoodbye: true)

        case let .send(envelope, peerDeviceID):
            guard isCurrent(token),
                  let connection = connectionsByDevice[peerDeviceID],
                  connection.epoch == token
            else { return }
            await connection.queue?.enqueue(envelope)
        }
    }

    private func stopSession() async {
        activeEpoch = nil
        isAdvertising = false
        isBrowsing = false
        resetRetries()

        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil

        let closingChannels = Array(binaryChannels.values)
        binaryChannels.removeAll()
        for channel in closingChannels { await channel.close() }

        for task in farewellTasks.values { task.cancel() }
        farewellTasks.removeAll()

        let closing = Array(connectionsBySession.values)
        connectionsByDevice.removeAll()
        connectionsBySession.removeAll()
        advertisements.removeAll()
        endpoints.removeAll()
        shared.withLock { $0.connectedPeers.removeAll() }

        for connection in closing {
            connection.resolve(.failure(TransportError.transportStopped))
            let queue = connection.cancel()
            connection.nwConnection.cancel()
            await queue?.stop()
        }
    }

    // MARK: - TLS PSK

    /// Opciones TLS con la PSK derivada del secreto de app + código de sala.
    ///
    /// Patrón oficial de Apple (muestra "Building a custom peer-to-peer protocol"):
    /// PSK + identidad como `DispatchData`, suite `TLS_PSK_WITH_AES_128_GCM_SHA256`
    /// y TLS 1.2 fijo. `tls_ciphersuite_t` se importa como enum C no exhaustivo,
    /// así que el valor 0x00A8 (no listado en el enum) sobrevive al `init(rawValue:)`.
    private func makeTLSOptions() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions

        // DIAGNÓSTICO TEMPORAL — quitar tras depurar PSK.
        print("[Nexo PSK] hint=\(crypto.pskHint) pskBytes=\(crypto.psk.count)")

        sec_protocol_options_add_pre_shared_key(
            security,
            Self.dispatchData(crypto.psk) as __DispatchData,
            Self.dispatchData(Data(crypto.pskHint.utf8)) as __DispatchData
        )
        sec_protocol_options_append_tls_ciphersuite(
            security,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        )
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(security, .TLSv12)
        return options
    }

    /// Construye un `DispatchData` que copia los bytes del `Data` de forma segura
    /// (construir el `DispatchData` dentro del `withUnsafeBytes` con el buffer
    /// explícito evita que el puntero se escape).
    static func dispatchData(_ data: Data) -> DispatchData {
        data.withUnsafeBytes { raw in
            DispatchData(bytes: UnsafeRawBufferPointer(start: raw.baseAddress, count: raw.count))
        }
    }

    /// Parámetros Bonjour P2P con el framer de longitud y TLS-PSK sobre TCP.
    private func makeParameters() -> NWParameters {
        let params = NWParameters(tls: makeTLSOptions(), tcp: NWProtocolTCP.Options())
        params.includePeerToPeer = true
        let framer = NWProtocolFramer.Options(definition: LengthPrefixFramer.definition)
        params.defaultProtocolStack.applicationProtocols.insert(framer, at: 0)
        return params
    }

    // MARK: - Listener Bonjour

    private func startListener(epoch token: UInt64) {
        listener?.cancel()
        listener = nil
        guard isCurrent(token), activeEpoch == token, isAdvertising else { return }

        let listener: NWListener
        do {
            listener = try NWListener(using: makeParameters())
        } catch {
            handleStackFailure(.listener, epoch: token, error: error)
            return
        }
        listener.service = NWListener.Service(
            name: serviceName,
            type: ProtocolInfo.serviceType,
            txtRecord: NWTXTRecord(advertisement.txtDictionary)
        )
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error), .waiting(let error):
                Task { await self.listenerStateFailed(epoch: token, error: error) }
            case .ready, .setup, .cancelled:
                break
            @unknown default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] nwConnection in
            guard let self else { nwConnection.cancel(); return }
            Task { await self.acceptIncoming(nwConnection, epoch: token) }
        }
        listener.start(queue: .global())
    }

    private func listenerStateFailed(epoch token: UInt64, error: NWError) async {
        guard isCurrent(token), activeEpoch == token else { return }
        listener?.cancel()
        listener = nil
        handleStackFailure(.listener, epoch: token, error: error)
    }

    private func republishTXT() {
        guard let listener else { return }
        listener.service = NWListener.Service(
            name: serviceName,
            type: ProtocolInfo.serviceType,
            txtRecord: NWTXTRecord(advertisement.txtDictionary)
        )
    }

    // MARK: - Browser Bonjour

    private func startBrowser(epoch token: UInt64) {
        browser?.cancel()
        browser = nil
        guard isCurrent(token), activeEpoch == token, isBrowsing else { return }

        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: ProtocolInfo.serviceType, domain: nil),
            using: params
        )
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error), .waiting(let error):
                Task { await self.browserStateFailed(epoch: token, error: error) }
            case .ready, .setup, .cancelled:
                break
            @unknown default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let snapshot = Array(results)
            Task { await self.browseResultsChanged(snapshot, epoch: token) }
        }
        browser.start(queue: .global())
    }

    private func browserStateFailed(epoch token: UInt64, error: NWError) async {
        guard isCurrent(token), activeEpoch == token else { return }
        browser?.cancel()
        browser = nil
        handleStackFailure(.browser, epoch: token, error: error)
    }

    private func browseResultsChanged(_ results: [NWBrowser.Result], epoch token: UInt64) async {
        guard isCurrent(token), activeEpoch == token else { return }
        updatePermission(.available, epoch: token)
        browserRetryAttempt = 0

        var seen: Set<TransportPeerID> = []
        for result in results.prefix(256) {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            let endpointID = TransportPeerID(endpointIdentifier(for: result.endpoint, name: name))

            var txt: [String: String] = [:]
            if case let .bonjour(record) = result.metadata {
                txt = record.dictionary
            }
            let record = AdvertisementRecord.advertisement(
                from: txt,
                endpointID: endpointID,
                fallbackName: name.isEmpty ? endpointID.description : name
            )
            // DIAGNÓSTICO TEMPORAL — quitar tras depurar.
            print("""
            [Nexo browse] endpointID=\(endpointID.rawValue)
            [Nexo browse] txt keys=\(txt.keys.sorted())
            [Nexo browse] record.deviceID=\(record.deviceID?.description ?? "nil")
            [Nexo browse] rooms=\(record.rooms.count) hostIDs=\(record.rooms.map { $0.hostDeviceID.description })
            """)
            // Filtra el propio dispositivo.
            guard record.deviceID != deviceID else { continue }

            seen.insert(endpointID)
            endpoints[endpointID] = result.endpoint

            // Si el mismo deviceID aparece por otro endpoint, retira el anterior.
            if let device = record.deviceID {
                for (oldID, old) in advertisements where oldID != endpointID && old.deviceID == device {
                    advertisements.removeValue(forKey: oldID)
                    endpoints.removeValue(forKey: oldID)
                    emit(.advertisementLost(oldID, epoch: token))
                }
            }

            let previous = advertisements.updateValue(record, forKey: endpointID)
            if previous == nil {
                emit(.advertisementFound(record, epoch: token))
            } else if previous != record {
                emit(.advertisementUpdated(record, epoch: token))
            }
        }

        for endpointID in advertisements.keys where !seen.contains(endpointID) {
            advertisements.removeValue(forKey: endpointID)
            endpoints.removeValue(forKey: endpointID)
            emit(.advertisementLost(endpointID, epoch: token))
        }
    }

    /// Identificador estable de un endpoint Bonjour para indexar anuncios.
    private nonisolated func endpointIdentifier(for endpoint: NWEndpoint, name: String) -> String {
        if case let .service(serviceName, type, domain, _) = endpoint {
            return "\(serviceName).\(type)\(domain)"
        }
        return name
    }

    // MARK: - Reintentos de stack

    private enum Stack { case listener, browser }

    private func resetRetries() {
        listenerRetry?.cancel()
        listenerRetry = nil
        browserRetry?.cancel()
        browserRetry = nil
        listenerRetryAttempt = 0
        browserRetryAttempt = 0
    }

    private func handleStackFailure(_ stack: Stack, epoch token: UInt64, error: any Error) {
        guard isCurrent(token), activeEpoch == token, !(error is CancellationError) else { return }
        Self.logger.error("Network stack failed: \(String(describing: error), privacy: .public)")

        if LocalNetworkDenial.isDenied(error) {
            updatePermission(.denied, epoch: token)
            if stack == .listener { emit(.lifecycleChanged(.disconnected, epoch: token)) }
            return
        }

        let delays: [Duration] = [.seconds(2), .seconds(5), .seconds(10)]
        switch stack {
        case .listener:
            emit(.lifecycleChanged(.disconnected, epoch: token))
            guard listenerRetryAttempt < delays.count else { return }
            let delay = delays[listenerRetryAttempt]
            listenerRetryAttempt += 1
            listenerRetry?.cancel()
            listenerRetry = Task { [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                await self?.retryListener(epoch: token)
            }
        case .browser:
            guard browserRetryAttempt < delays.count else { return }
            let delay = delays[browserRetryAttempt]
            browserRetryAttempt += 1
            browserRetry?.cancel()
            browserRetry = Task { [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                await self?.retryBrowser(epoch: token)
            }
        }
    }

    private func retryListener(epoch token: UInt64) {
        guard isCurrent(token), activeEpoch == token, isAdvertising, listener == nil else { return }
        startListener(epoch: token)
        if listener != nil { emit(.lifecycleChanged(.active, epoch: token)) }
    }

    private func retryBrowser(epoch token: UInt64) {
        guard isCurrent(token), activeEpoch == token, isBrowsing, browser == nil else { return }
        startBrowser(epoch: token)
    }

    private func updatePermission(_ permission: LocalNetworkPermission, epoch token: UInt64) {
        guard isCurrent(token), localNetworkPermission != permission else { return }
        localNetworkPermission = permission
        emit(.localNetworkPermissionChanged(permission, epoch: token))
    }

    // MARK: - Conexiones

    @discardableResult
    public func connect(to advertisement: PeerAdvertisement) async throws(TransportError) -> ConnectedPeer {
        guard let token = activeEpoch, isCurrent(token) else { throw TransportError.transportStopped }

        // Reutiliza una conexión viva existente al mismo deviceID.
        if let device = advertisement.deviceID,
           let existing = connectionsByDevice[device], let peer = existing.peer {
            return peer
        }

        guard ProtocolInfo.isCompatible(remoteVersion: advertisement.protocolVersion) else {
            throw TransportError.incompatibleProtocol(advertisement.protocolVersion)
        }
        guard let endpoint = endpoints[advertisement.endpointID] else {
            throw TransportError.peerNotDiscovered
        }

        // Reutiliza una saliente pendiente al mismo endpoint, o abre una nueva.
        let connection: Connection
        if let pending = connectionsBySession.values.first(where: {
            $0.isOutgoing && $0.endpointID == advertisement.endpointID && $0.peer == nil
        }) {
            connection = pending
        } else {
            guard connectionsBySession.count < 64 else {
                throw TransportError.connectionFailed(.connectionFailed)
            }
            let nwConnection = NWConnection(to: endpoint, using: makeParameters())
            connection = register(
                nwConnection,
                epoch: token,
                outgoing: true,
                endpointID: advertisement.endpointID,
                expectedDeviceID: advertisement.deviceID
            )
        }

        let waiterID = UUID()
        let sessionID = connection.sessionID
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ConnectedPeer, any Error>) in
                    guard isCurrent(token), connectionsBySession[sessionID] === connection else {
                        continuation.resume(throwing: TransportError.transportStopped)
                        return
                    }
                    if let peer = connection.peer {
                        continuation.resume(returning: peer)
                    } else if connection.waiters.count < 64 {
                        connection.waiters[waiterID] = continuation
                    } else {
                        continuation.resume(throwing: TransportError.connectionFailed(.connectionFailed))
                    }
                }
            } onCancel: {
                Task { [weak self] in await self?.cancelWaiter(waiterID, session: sessionID) }
            }
        } catch let error as TransportError {
            throw error
        } catch is CancellationError {
            throw TransportError.connectionFailed(.connectionClosed)
        } catch {
            throw TransportError.connectionFailed(DisconnectReason(error: error))
        }
    }

    private func cancelWaiter(_ id: UUID, session sessionID: UUID) async {
        guard let connection = connectionsBySession[sessionID] else { return }
        connection.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        if connection.waiters.isEmpty, connection.peer == nil {
            await fail(connection, error: TransportError.connectionFailed(.connectionClosed))
        }
    }

    private func acceptIncoming(_ nwConnection: NWConnection, epoch token: UInt64) async {
        guard isCurrent(token), activeEpoch == token, connectionsBySession.count < 64 else {
            nwConnection.cancel()
            return
        }
        _ = register(nwConnection, epoch: token, outgoing: false)
    }

    @discardableResult
    private func register(
        _ nwConnection: NWConnection,
        epoch token: UInt64,
        outgoing: Bool,
        endpointID: TransportPeerID? = nil,
        expectedDeviceID: DeviceID? = nil
    ) -> Connection {
        let connection = Connection(
            nwConnection: nwConnection,
            epoch: token,
            outgoing: outgoing,
            endpointID: endpointID,
            expectedDeviceID: expectedDeviceID
        )
        let sessionID = connection.sessionID
        connectionsBySession[sessionID] = connection

        // Cola de envío. Captura sólo la NWConnection (Sendable) y sessionID.
        connection.queue = SendQueue(
            send: { [weak nwConnection] envelope in
                guard let nwConnection else { throw TransportError.notConnected }
                try await Self.sendFrame(.envelope(envelope), on: nwConnection)
            },
            onFailure: { [weak self] error in
                await self?.failSession(sessionID, error: error)
            }
        )

        nwConnection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { await self?.connectionReady(sessionID, epoch: token) }
            case .failed(let error):
                Task { await self?.failSession(sessionID, error: error) }
            case .cancelled:
                break
            case .waiting(let error):
                Task { await self?.failSession(sessionID, error: error) }
            case .setup, .preparing:
                break
            @unknown default:
                break
            }
        }
        nwConnection.start(queue: .global())

        // Timeout de handshake: captura sólo sessionID.
        connection.timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: Limits.handshakeTimeout) } catch { return }
            await self?.handshakeTimedOut(sessionID)
        }

        return connection
    }

    private func connectionReady(_ sessionID: UUID, epoch token: UInt64) async {
        guard isCurrent(token), let connection = connectionsBySession[sessionID] else { return }
        // Envía el hello local y arranca el bucle de recepción.
        let hello = Frame.hello(HelloBody(
            deviceID: deviceID,
            displayName: advertisement.displayName,
            pskHint: crypto.pskHint
        ))
        let nwConnection = connection.nwConnection
        connection.helloTask = Task { [weak self] in
            do {
                try await Self.sendFrame(hello, on: nwConnection)
            } catch {
                await self?.failSession(sessionID, error: error)
            }
        }
        startReceiving(sessionID, on: nwConnection)
    }

    /// Bucle de recepción. Captura sólo `[weak self]`, la NWConnection y sessionID.
    private func startReceiving(_ sessionID: UUID, on nwConnection: NWConnection) {
        nwConnection.receiveMessage { [weak self] data, _, isComplete, error in
            Task { [weak self] in
                guard let self else { return }
                if let data, !data.isEmpty {
                    await self.receivedFrameData(data, session: sessionID)
                }
                if let error {
                    await self.failSession(sessionID, error: error)
                    return
                }
                if isComplete {
                    // Fin de stream: el peer cerró.
                    await self.failSession(sessionID, error: TransportError.connectionFailed(.connectionClosed))
                    return
                }
                // Continúa el bucle sólo si la sesión sigue viva.
                await self.continueReceiving(sessionID, on: nwConnection)
            }
        }
    }

    private func continueReceiving(_ sessionID: UUID, on nwConnection: NWConnection) {
        guard connectionsBySession[sessionID] != nil else { return }
        startReceiving(sessionID, on: nwConnection)
    }

    private func receivedFrameData(_ data: Data, session sessionID: UUID) async {
        guard let connection = connectionsBySession[sessionID],
              isCurrent(connection.epoch), activeEpoch == connection.epoch else { return }
        let frame: Frame
        do {
            frame = try JSONDecoder().decode(Frame.self, from: data)
        } catch {
            await fail(connection, error: TransportError.handshakeFailed(.incompleteHello))
            return
        }
        await handle(frame, on: connection)
    }

    private func handshakeTimedOut(_ sessionID: UUID) async {
        guard let connection = connectionsBySession[sessionID], connection.peer == nil else { return }
        await fail(connection, error: TransportError.handshakeTimedOut)
    }

    // MARK: - Handshake y recepción de frames

    private func handle(_ frame: Frame, on connection: Connection) async {
        guard connectionsBySession[connection.sessionID] === connection,
              isCurrent(connection.epoch), activeEpoch == connection.epoch else { return }

        switch frame.kind {
        case .hello:
            guard let body = frame.hello else {
                await fail(connection, error: TransportError.handshakeFailed(.incompleteHello))
                return
            }
            await completeHandshake(body, on: connection)

        case .envelope:
            guard let peer = connection.peer, let envelope = frame.envelope else { return }
            guard ProtocolInfo.isCompatible(remoteVersion: envelope.protocolVersion),
                  envelope.senderDeviceID == peer.deviceID,
                  envelope.payload.count <= Limits.maximumEnvelopeBytes else {
                await fail(connection, error: TransportError.connectionFailed(.connectionFailed))
                return
            }
            emit(.received(envelope, from: peer, epoch: connection.epoch))

        case .goodbye:
            let reason = frame.goodbye?.reason ?? .peerDisconnected
            await fail(connection, error: TransportError.connectionFailed(reason))
        }
    }

    private func completeHandshake(_ body: HelloBody, on connection: Connection) async {
        guard connection.peer == nil else { return }
        guard ProtocolInfo.isCompatible(remoteVersion: body.protocolVersion),
              body.minimumProtocolVersion <= ProtocolInfo.currentVersion else {
            await fail(connection, error: TransportError.incompatibleProtocol(body.protocolVersion))
            return
        }
        // No puede ser uno mismo, y el deviceID debe coincidir con el esperado.
        guard body.deviceID != deviceID,
              body.displayName.utf8.count <= 1024,
              connection.expectedDeviceID == nil || connection.expectedDeviceID == body.deviceID else {
            await fail(connection, error: TransportError.handshakeFailed(.invalidIdentity))
            return
        }

        // Resolución determinista de conexiones duplicadas al mismo deviceID.
        if let rival = connectionsByDevice[body.deviceID], rival !== connection {
            let keepOutgoing = min(deviceID.description, body.deviceID.description) == deviceID.description
            let loser = keepOutgoing
                ? (connection.isOutgoing ? rival : connection)
                : (connection.isOutgoing ? connection : rival)
            await fail(loser, error: TransportError.connectionFailed(.duplicateConnection),
                       notify: false, sendGoodbye: true)
            if loser === connection { return }
        }

        guard connectionsBySession[connection.sessionID] === connection,
              isCurrent(connection.epoch), activeEpoch == connection.epoch else { return }

        let peer = ConnectedPeer(
            deviceID: body.deviceID,
            displayName: body.displayName,
            pskHint: body.pskHint,
            protocolVersion: body.protocolVersion,
            capabilities: Set(body.capabilities),
            connectionSessionID: connection.sessionID
        )
        connection.peer = peer
        connection.timeoutTask?.cancel()
        connection.timeoutTask = nil
        connectionsByDevice[peer.deviceID] = connection
        shared.withLock { $0.connectedPeers[peer.deviceID] = peer }
        connection.resolve(.success(peer))
        emit(.peerConnected(peer, epoch: connection.epoch))
    }

    // MARK: - Teardown

    private func failSession(_ sessionID: UUID, error: any Error) async {
        guard let connection = connectionsBySession[sessionID] else { return }
        await fail(connection, error: error)
    }

    private func fail(
        _ connection: Connection,
        error: any Error,
        notify: Bool = true,
        sendGoodbye: Bool = false
    ) async {
        guard connectionsBySession[connection.sessionID] === connection else { return }
        connectionsBySession.removeValue(forKey: connection.sessionID)

        if sendGoodbye, isCurrent(connection.epoch) {
            beginGoodbye(on: connection.nwConnection, reason: DisconnectReason(error: error))
        }
        connection.resolve(.failure(error))
        let queue = connection.cancel()

        if let peer = connection.peer, connectionsByDevice[peer.deviceID] === connection {
            connectionsByDevice.removeValue(forKey: peer.deviceID)
            shared.withLock { state in
                if state.connectedPeers[peer.deviceID]?.connectionSessionID == peer.connectionSessionID {
                    state.connectedPeers.removeValue(forKey: peer.deviceID)
                }
            }
            if notify {
                emit(.peerDisconnected(deviceID: peer.deviceID, reason: DisconnectReason(error: error), epoch: connection.epoch))
            }
        }

        await queue?.stop()
        if !sendGoodbye {
            connection.nwConnection.cancel()
        }
    }

    private func beginGoodbye(on nwConnection: NWConnection, reason: DisconnectReason) {
        guard farewellTasks.count < 64 else { nwConnection.cancel(); return }
        let id = UUID()
        farewellTasks[id] = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    try? await Self.sendFrame(.goodbye(reason: reason), on: nwConnection)
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(1))
                }
                _ = await group.next()
                group.cancelAll()
            }
            nwConnection.cancel()
            await self?.farewellEnded(id)
        }
    }

    private func farewellEnded(_ id: UUID) {
        farewellTasks.removeValue(forKey: id)
    }

    // MARK: - Emisión de eventos

    private nonisolated func emit(_ event: TransportEvent) {
        shared.withLock { state in
            guard !state.isStopped, state.epoch == event.epoch else { return }
            eventContinuation.yield(event)
        }
    }

    // MARK: - Envío de frames por el socket

    /// Codifica un `Frame` a JSON y lo entrega como un mensaje delimitado por el
    /// framer de longitud. `async` que resuelve al completarse el envío.
    private static func sendFrame(_ frame: Frame, on nwConnection: NWConnection) async throws {
        let data = try JSONEncoder().encode(frame)
        let message = NWProtocolFramer.Message(definition: LengthPrefixFramer.definition)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [message])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            nwConnection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    // MARK: - Canal binario QUIC (capacidad BinaryStreamOpening)

    /// Nombre de servicio Bonjour de un peer, derivado de su `deviceID` igual que
    /// el propio. Permite construir su endpoint QUIC sin un browser UDP aparte.
    private nonisolated func serviceName(for deviceID: DeviceID) -> String {
        String(deviceID.description.prefix(8)).lowercased()
    }

    /// Abre (o reutiliza) un `QUICChannel` hacia un peer conectado y abre un stream.
    public func openByteStream(
        to deviceID: DeviceID,
        descriptor: ByteStreamDescriptor
    ) async throws(TransportError) -> QUICByteStream {
        guard connectionsByDevice[deviceID]?.peer != nil else {
            throw TransportError.notConnected
        }
        let channel = try await binaryChannel(for: deviceID)
        return try await channel.openStreamMapped(descriptor)
    }

    /// Crea (o reutiliza) el `QUICChannel` hacia un peer. El mismo canal sirve
    /// ambos sentidos: sus streams entrantes (los que el peer nos abre) se
    /// reenvían al flujo único `incomingByteStreams`.
    private func binaryChannel(for deviceID: DeviceID) async throws(TransportError) -> QUICChannel {
        if let existing = binaryChannels[deviceID] { return existing }

        let endpoint = NWEndpoint.service(
            name: serviceName(for: deviceID),
            type: ProtocolInfo.quicServiceType,
            domain: "local.",
            interface: nil
        )
        let channel = QUICChannel(crypto: crypto, deviceID: self.deviceID)
        binaryChannels[deviceID] = channel
        do {
            try await channel.connect(to: endpoint)
        } catch {
            binaryChannels.removeValue(forKey: deviceID)
            await channel.close()
            throw TransportError.connectionFailed(DisconnectReason(error: error))
        }
        // Reenvía los streams que este peer nos abra al flujo único.
        Task { [weak self] in
            do {
                for try await incoming in await channel.startIncoming() {
                    self?.forwardIncomingByteStream(incoming)
                }
            } catch { /* canal cerrado */ }
        }
        return channel
    }

    private nonisolated func forwardIncomingByteStream(_ incoming: QUICIncomingStream) {
        incomingByteStreamContinuation.yield(incoming)
    }

    // MARK: - Connection (estado por conexión, NO-Sendable, confinado al actor)

    /// Estado mutable de una conexión física. Es una clase normal, NO `Sendable`:
    /// vive sólo dentro del actor `NetworkTransport`. Las tareas hijas capturan
    /// únicamente `sessionID` (inmutable) y la `NWConnection` (Sendable).
    private final class Connection {
        let sessionID = UUID()
        let nwConnection: NWConnection
        let epoch: UInt64
        let isOutgoing: Bool
        let endpointID: TransportPeerID?
        let expectedDeviceID: DeviceID?

        var peer: ConnectedPeer?
        var queue: SendQueue?
        var helloTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<ConnectedPeer, any Error>] = [:]

        init(
            nwConnection: NWConnection,
            epoch: UInt64,
            outgoing: Bool,
            endpointID: TransportPeerID?,
            expectedDeviceID: DeviceID?
        ) {
            self.nwConnection = nwConnection
            self.epoch = epoch
            self.isOutgoing = outgoing
            self.endpointID = endpointID
            self.expectedDeviceID = expectedDeviceID
        }

        deinit {
            helloTask?.cancel()
            timeoutTask?.cancel()
            for waiter in waiters.values {
                waiter.resume(throwing: TransportError.transportStopped)
            }
        }

        func resolve(_ result: Result<ConnectedPeer, any Error>) {
            let pending = waiters.values
            waiters.removeAll()
            for waiter in pending { waiter.resume(with: result) }
        }

        /// Cancela tareas hijas y devuelve la cola para pararla fuera del actor.
        func cancel() -> SendQueue? {
            helloTask?.cancel()
            helloTask = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            let queue = self.queue
            self.queue = nil
            return queue
        }
    }
}

// MARK: - LengthPrefixFramer

/// Framer de longitud: delimita cada `Frame` JSON con un header UInt32 big-endian
/// seguido del payload. Así el stream TCP recupera mensajes completos aunque el
/// socket entregue los bytes fragmentados o agrupados.
final class LengthPrefixFramer: NWProtocolFramerImplementation {

    static let definition = NWProtocolFramer.Definition(implementation: LengthPrefixFramer.self)
    static var label: String { "NexoLengthPrefix" }

    private static let headerSize = 4
    /// Cota de seguridad: un frame nunca debería superar el envelope máximo más
    /// el overhead de control y el header.
    private static let maximumFrameBytes = Limits.maximumEnvelopeBytes + 64 * 1024

    init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}

    /// Serializa: header de 4 bytes big-endian + payload.
    func handleOutput(
        framer: NWProtocolFramer.Instance,
        message: NWProtocolFramer.Message,
        messageLength: Int,
        isComplete: Bool
    ) {
        var header = UInt32(messageLength).bigEndian
        let headerData = withUnsafeBytes(of: &header) { Data($0) }
        framer.writeOutput(data: headerData)
        do {
            try framer.writeOutputNoCopy(length: messageLength)
        } catch {
            // El framer cerró; nada que delimitar.
        }
    }

    /// Parsea: lee el header, luego el payload de esa longitud, y entrega un mensaje.
    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var payloadLength = 0
            let parsedHeader = framer.parseInput(
                minimumIncompleteLength: Self.headerSize,
                maximumLength: Self.headerSize
            ) { buffer, _ in
                guard let buffer, buffer.count >= Self.headerSize else { return 0 }
                var value: UInt32 = 0
                withUnsafeMutableBytes(of: &value) { raw in
                    raw.copyBytes(from: buffer.prefix(Self.headerSize))
                }
                payloadLength = Int(UInt32(bigEndian: value))
                return Self.headerSize
            }

            guard parsedHeader else { return Self.headerSize }

            // Protección contra longitudes absurdas: fuerza cierre descartando.
            guard payloadLength >= 0, payloadLength <= Self.maximumFrameBytes else {
                return 0
            }

            let message = NWProtocolFramer.Message(definition: Self.definition)
            if !framer.deliverInputNoCopy(length: payloadLength, message: message, isComplete: true) {
                return 0
            }
        }
    }
}
