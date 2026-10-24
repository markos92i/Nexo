//
//  NetworkPeerTransport.swift
//  Nexo
//

import Foundation
import Network
import OSLog
import Synchronization

/// TLS control traffic and QUIC binary channels, confined to a transport actor.
public actor NetworkPeerTransport: PeerTransport {
    private static let logger = Logger(subsystem: "com.zafir.nexo", category: "transport")
    private typealias ApplicationProtocol = Coder<P2PFrame, P2PFrame, NetworkJSONCoder>
    private typealias Parameters = NWParametersBuilder<ApplicationProtocol>
    private typealias Connection = NetworkConnection<ApplicationProtocol>
    private typealias Listener = NetworkListener<ApplicationProtocol>
    private typealias QUICListener = NetworkListener<QUIC>

    private enum Command: Sendable {
        case start(advertising: Bool, browsing: Bool)
        case stop
        case updateAdvertisement(AdvertisementRecord)
        case refreshDiscovery
        case disconnect(String, NexoReason?)
        case send(RoomEnvelope, String)

        var budgetBytes: Int {
            switch self {
            case .send(let envelope, let peer):
                return envelope.transportBudgetBytes + peer.utf8.count
            case .updateAdvertisement(let record):
                return record.applicationID.utf8.count + record.displayName.utf8.count
                    + record.rooms.reduce(512) {
                        $0 + $1.name.utf8.count + $1.hostApplicationID.utf8.count
                            + ($1.activityKind?.rawValue.utf8.count ?? 0) + 512
                    }
            case .disconnect(let peer, let reason):
                if case .system(let domain, _)? = reason { return peer.utf8.count + domain.utf8.count + 512 }
                return peer.utf8.count + 512
            default:
                return 512
            }
        }
    }

    private struct PendingCommand: Sendable {
        let epoch: UInt64
        let command: Command
    }

    /// Admission and generation assignment share one lock, including the wakeup.
    private struct Session: Sendable {
        var epoch: UInt64 = 0
        var isStopped = true
        var advertising = false
        var browsing = false
        var commands: [PendingCommand] = []
        var bytes = 0
        var overloadedEpoch: UInt64?
    }

    private let session = Mutex(Session())
    private let wakeup: AsyncStream<Void>.Continuation
    private var activeEpoch: UInt64?
    public nonisolated var epoch: UInt64 { session.withLock { $0.epoch } }
    /// Reason for a disconnected lifecycle without changing the existing event enum.
    public private(set) var lastFailure: NexoReason?

    private enum Piece: CaseIterable, Hashable, Sendable { case listener, quicListener, browser, quicBrowser }
    private struct Runner: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var runners: [Piece: Runner] = [:]
    private var retries: [Piece: Task<Void, Never>] = [:]
    private var retryAttempts: [Piece: Int] = [:]
    private var listener: Listener?
    private var quicListener: QUICListener?
    private var isAdvertising = false
    private var isBrowsing = false
    public private(set) var localNetworkPermissionState: LocalNetworkPermissionState = .unknown
    public var isTLSConfigured: Bool { tlsConfiguration != nil }

    private let applicationID: String
    private let localCertificateFingerprint: String?
    private let tlsConfiguration: NexoTLSConfiguration?
    private var advertisement: AdvertisementRecord
    private var serviceName: String { String(applicationID.prefix(8)).lowercased() }
    private let eventStream: AsyncStream<PeerTransportEvent>
    private let eventContinuation: AsyncStream<PeerTransportEvent>.Continuation
    public nonisolated var events: AsyncStream<PeerTransportEvent> { eventStream }
    private var advertisements: [TransportPeerID: PeerAdvertisement] = [:]
    private var endpoints: [TransportPeerID: Bonjour.Endpoint] = [:]
    private var quicEndpoints: [String: Bonjour.Endpoint] = [:]

    /// Mutable fields are confined to this actor; task captures use immutable socket identity.
    private final class Box: @unchecked Sendable {
        let id: TransportPeerID
        let connection: Connection
        let epoch: UInt64
        let sessionID = UUID()
        let isOutgoing: Bool
        let endpointID: TransportPeerID?
        let expectedApplicationID: String?
        var peer: ConnectedPeer?
        var receiveTask: Task<Void, Never>?
        var helloTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
        var queue: TransportSendQueue?
        var waiters: [UUID: CheckedContinuation<ConnectedPeer, Error>] = [:]

        init(connection: Connection, epoch: UInt64, isOutgoing: Bool,
             endpointID: TransportPeerID? = nil, expectedApplicationID: String? = nil) {
            self.id = TransportPeerID(connection.id)
            self.connection = connection
            self.epoch = epoch
            self.isOutgoing = isOutgoing
            self.endpointID = endpointID
            self.expectedApplicationID = expectedApplicationID
        }
        deinit {
            receiveTask?.cancel()
            helloTask?.cancel()
            timeoutTask?.cancel()
            for waiter in waiters.values { waiter.resume(throwing: P2PTransportError.transportStopped) }
        }
        func resolve(_ result: Result<ConnectedPeer, Error>) {
            let pending = waiters.values
            waiters.removeAll()
            for waiter in pending { waiter.resume(with: result) }
        }
        func cancel() -> TransportSendQueue? {
            receiveTask?.cancel()
            receiveTask = nil
            helloTask?.cancel()
            helloTask = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            let queue = queue
            self.queue = nil
            return queue
        }
    }

    private var boxes: [TransportPeerID: Box] = [:]
    private var farewellTasks: [UUID: Task<Void, Never>] = [:]
    private var connectionIDs: [String: TransportPeerID] = [:]
    private let establishedPeers = Mutex<[String: ConnectedPeer]>([:])
    public nonisolated var connectedPeers: [ConnectedPeer] { establishedPeers.withLock { Array($0.values) } }

    private struct BinaryChannel: Sendable {
        let transport: NexoQUICBinaryTransport
        let epoch: UInt64
        var peer: ConnectedPeer?
        var task: Task<Void, Never>?
    }
    private var binaryChannels: [UUID: BinaryChannel] = [:]
    private var binaryIDs: [String: UUID] = [:]
    private enum BinaryConsumer: Sendable, Equatable { case legacy, peer }
    private let binaryConsumer = Mutex<BinaryConsumer?>(nil)
    private let incomingBinaryStream: AsyncStream<NexoQUICIncomingStream>
    private let incomingBinaryContinuation: AsyncStream<NexoQUICIncomingStream>.Continuation
    private let incomingPeerBinaryStream: AsyncStream<NexoPeerBinaryStream>
    private let incomingPeerBinaryContinuation: AsyncStream<NexoPeerBinaryStream>.Continuation

    /// Alternative views of one subscription. The first accessor claims it; never read both.
    public nonisolated var incomingBinaryStreams: AsyncStream<NexoQUICIncomingStream> {
        let accepted = binaryConsumer.withLock { consumer in
            if consumer == nil { consumer = .legacy }
            return consumer == .legacy
        }
        return accepted ? incomingBinaryStream : AsyncStream { $0.finish() }
    }
    public nonisolated var incomingPeerBinaryStreams: AsyncStream<NexoPeerBinaryStream> {
        let accepted = binaryConsumer.withLock { consumer in
            if consumer == nil { consumer = .peer }
            return consumer == .peer
        }
        return accepted ? incomingPeerBinaryStream : AsyncStream { $0.finish() }
    }

    public init(applicationID: String, displayName: String,
                tlsConfiguration: NexoTLSConfiguration? = nil, localCertificateFingerprint: String? = nil) {
        self.applicationID = applicationID
        self.localCertificateFingerprint = localCertificateFingerprint
        self.tlsConfiguration = tlsConfiguration
        advertisement = AdvertisementRecord(applicationID: applicationID, displayName: displayName)
        let events = AsyncStream<PeerTransportEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        eventStream = events.stream
        eventContinuation = events.continuation
        let signals = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakeup = signals.continuation
        let binary = AsyncStream<NexoQUICIncomingStream>.makeStream(bufferingPolicy: .bufferingOldest(8))
        incomingBinaryStream = binary.stream
        incomingBinaryContinuation = binary.continuation
        let peerBinary = AsyncStream<NexoPeerBinaryStream>.makeStream(bufferingPolicy: .bufferingOldest(8))
        incomingPeerBinaryStream = peerBinary.stream
        incomingPeerBinaryContinuation = peerBinary.continuation
        Task { [weak self] in
            for await _ in signals.stream {
                while let work = self?.nextCommand() { await self?.apply(work) }
            }
        }
    }

    deinit {
        wakeup.finish()
        eventContinuation.finish()
        incomingBinaryContinuation.finish()
        incomingPeerBinaryContinuation.finish()
        for runner in runners.values { runner.task.cancel() }
        for retry in retries.values { retry.cancel() }
        for task in farewellTasks.values { task.cancel() }
        for channel in binaryChannels.values {
            channel.task?.cancel()
            let transport = channel.transport
            Task { await transport.close() }
        }
    }

    // MARK: - Command admission

    public nonisolated func start(advertising: Bool, browsing: Bool) {
        submit(.start(advertising: advertising, browsing: browsing))
    }
    public nonisolated func stop() { submit(.stop) }
    public nonisolated func updateAdvertisement(_ record: AdvertisementRecord) { submit(.updateAdvertisement(record)) }
    public nonisolated func refreshDiscovery() { submit(.refreshDiscovery) }
    public nonisolated func disconnect(applicationID: String, reason: NexoReason?) { submit(.disconnect(applicationID, reason)) }
    public nonisolated func enqueue(_ envelope: RoomEnvelope, to applicationID: String) { submit(.send(envelope, applicationID)) }

    private nonisolated func submit(_ command: Command) {
        session.withLock { state in
            switch command {
            case .start(let advertising, let browsing):
                if state.isStopped || state.overloadedEpoch == state.epoch
                    || state.advertising != advertising || state.browsing != browsing { state.epoch &+= 1 }
                state.isStopped = false
                state.advertising = advertising
                state.browsing = browsing
            case .stop:
                state.epoch &+= 1
                state.isStopped = true
            default: break
            }
            // Coalesce before admission, not after an unbounded AsyncStream backlog.
            var replacement: Int?
            if case .send(let envelope, let peer) = command {
                for index in state.commands.indices.reversed() {
                    guard state.commands[index].epoch == state.epoch,
                          case .send(let previous, let previousPeer) = state.commands[index].command else { break }
                    if peer == previousPeer && envelope.canReplace(previous) {
                        replacement = index
                        state.bytes -= state.commands.remove(at: index).command.budgetBytes
                        break
                    }
                }
            }
            if state.commands.count >= 512 || command.budgetBytes > 8 * 1024 * 1024 - state.bytes {
                state.overloadedEpoch = state.epoch
                state.commands.removeAll()
                state.bytes = 0
            } else {
                let pending = PendingCommand(epoch: state.epoch, command: command)
                if let replacement { state.commands.insert(pending, at: replacement) }
                else { state.commands.append(pending) }
                state.bytes += command.budgetBytes
            }
            wakeup.yield(())
        }
    }

    private enum Work: Sendable { case command(PendingCommand), overloaded(UInt64) }
    private nonisolated func nextCommand() -> Work? {
        session.withLock { state in
            if let failedEpoch = state.overloadedEpoch {
                state.overloadedEpoch = nil
                state.commands.removeAll { $0.epoch == failedEpoch }
                state.bytes = state.commands.reduce(0) { $0 + $1.command.budgetBytes }
                if state.epoch == failedEpoch { state.isStopped = true }
                return .overloaded(failedEpoch)
            }
            guard !state.commands.isEmpty else { return nil }
            let next = state.commands.removeFirst()
            state.bytes -= next.command.budgetBytes
            return .command(next)
        }
    }
    private nonisolated func isCurrent(_ token: UInt64) -> Bool {
        session.withLock { !$0.isStopped && $0.epoch == token }
    }

    private func apply(_ work: Work) async {
        switch work {
        case .overloaded(let token):
            guard epoch == token else { return }
            lastFailure = .connectionFailed
            await stopSession()
            session.withLock { state in
                guard state.epoch == token else { return }
                state.isStopped = true
                eventContinuation.yield(.lifecycleChanged(.disconnected, epoch: token))
            }
        case .command(let pending):
            let token = pending.epoch
            switch pending.command {
            case .stop:
                if activeEpoch.map({ $0 <= token }) ?? true { await stopSession() }
            case .start(let advertising, let browsing):
                guard isCurrent(token) else { return }
                if activeEpoch != token { await stopSession() }
                guard isCurrent(token) else { return }
                guard tlsConfiguration != nil else {
                    lastFailure = .invalidIdentity
                    emit(.lifecycleChanged(.disconnected, epoch: token))
                    return
                }
                activeEpoch = token
                lastFailure = nil
                isAdvertising = advertising
                isBrowsing = browsing
                resetRetries()
                for piece in Piece.allCases where runners[piece] == nil { sync(piece, epoch: token) }
                if !advertising || runners[.listener] != nil { emit(.lifecycleChanged(.active, epoch: token)) }
            case .updateAdvertisement(let record):
                advertisement = record
                guard isCurrent(token), activeEpoch == token else { return }
                republishTXTRecord()
                if isAdvertising {
                    if runners[.listener] == nil { sync(.listener, epoch: token) }
                    if runners[.quicListener] == nil { sync(.quicListener, epoch: token) }
                }
            case .refreshDiscovery:
                guard isCurrent(token), activeEpoch == token else { return }
                resetRetries()
                if runners[.listener] == nil { sync(.listener, epoch: token) }
                if runners[.quicListener] == nil { sync(.quicListener, epoch: token) }
                sync(.browser, epoch: token)
                sync(.quicBrowser, epoch: token)
                republishTXTRecord()
            case .disconnect(let peer, let reason):
                guard isCurrent(token), let id = connectionIDs[peer], let box = boxes[id] else { return }
                await fail(box, error: P2PTransportError.connectionFailed(reason ?? .connectionClosed), sendGoodbye: true)
            case .send(let envelope, let peer):
                guard isCurrent(token), let id = connectionIDs[peer], let box = boxes[id], box.epoch == token else { return }
                await box.queue?.enqueue(envelope)
            }
        }
    }

    private func stopSession() async {
        activeEpoch = nil
        isAdvertising = false
        isBrowsing = false
        resetRetries()
        for runner in runners.values { runner.task.cancel() }
        runners.removeAll()
        for task in farewellTasks.values { task.cancel() }
        farewellTasks.removeAll()
        listener = nil
        quicListener = nil
        let closingBoxes = Array(boxes.values)
        boxes.removeAll()
        connectionIDs.removeAll()
        establishedPeers.withLock { $0.removeAll() }
        let closingChannels = Array(binaryChannels.values)
        binaryChannels.removeAll()
        binaryIDs.removeAll()
        advertisements.removeAll()
        endpoints.removeAll()
        quicEndpoints.removeAll()
        for box in closingBoxes {
            box.resolve(.failure(P2PTransportError.transportStopped))
            await box.cancel()?.stop()
        }
        for channel in closingChannels {
            channel.task?.cancel()
            await channel.transport.close()
        }
    }

    // MARK: - Bonjour stack

    private func parameters() throws(P2PTransportError) -> Parameters {
        guard let tlsConfiguration else { throw .handshakeFailed(.invalidIdentity) }
        return NWParametersBuilder(auto: {
            Coder(P2PFrame.self, using: .json) {
                tlsConfiguration.configure(TLS { TCP { IP() } }).peerAuthentication(.required).earlyDataEnabled(false)
            }
        }).peerToPeerIncluded(true)
    }

    private func sync(_ piece: Piece, epoch token: UInt64) {
        runners.removeValue(forKey: piece)?.task.cancel()
        guard isCurrent(token), activeEpoch == token, let tlsConfiguration else { return }
        let id = UUID()
        do {
            let task: Task<Void, Never>
            switch piece {
            case .listener:
                listener = nil
                guard isAdvertising else { return }
                let listener = try Listener(for: .bonjour(
                    name: serviceName, type: P2PProtocolInfo.serviceType, domain: nil,
                    txtRecord: NWTXTRecord(advertisement.txtDictionary)
                ), using: parameters())
                self.listener = listener
                task = Task { [weak self] in
                    do {
                        try await listener.run { [weak self] connection in
                            guard let receive = await self?.accept(connection, epoch: token, runnerID: id) else { return }
                            await withTaskCancellationHandler { await receive.value } onCancel: { receive.cancel() }
                        }
                    } catch { await self?.stackFailed(piece, id: id, epoch: token, error: error) }
                }
            case .quicListener:
                quicListener = nil
                guard isAdvertising else { return }
                let listener = try QUICListener(for: .bonjour(
                    name: serviceName, type: P2PProtocolInfo.quicServiceType, domain: nil,
                    txtRecord: NWTXTRecord(advertisement.txtDictionary)
                ), using: NexoQUICBinaryTransport.parameters(tlsConfiguration))
                quicListener = listener
                task = Task { [weak self] in
                    do {
                        try await listener.run { [weak self] connection in
                            guard let channel = await self?.acceptQUIC(connection, epoch: token, runnerID: id) else { return }
                            await withTaskCancellationHandler { await channel.value } onCancel: { channel.cancel() }
                        }
                    } catch { await self?.stackFailed(piece, id: id, epoch: token, error: error) }
                }
            case .browser, .quicBrowser:
                guard isBrowsing else { return }
                let browser = NetworkBrowser(for: .bonjour(
                    piece == .browser ? P2PProtocolInfo.serviceType : P2PProtocolInfo.quicServiceType,
                    domain: nil, includeTxtRecord: true
                ), using: NWParameters().peerToPeerIncluded(true))
                task = Task { [weak self] in
                    do {
                        try await browser.run { [weak self] found in
                            await self?.discovered(found, piece: piece, id: id, epoch: token)
                        }
                    } catch { await self?.stackFailed(piece, id: id, epoch: token, error: error) }
                }
            }
            runners[piece] = Runner(id: id, task: task)
        } catch { stackConstructionFailed(piece, epoch: token, error: error) }
    }

    private func stackFailed(_ piece: Piece, id: UUID, epoch token: UInt64, error: any Error) {
        guard isCurrent(token), activeEpoch == token, runners[piece]?.id == id else { return }
        runners.removeValue(forKey: piece)
        if piece == .listener { listener = nil }
        if piece == .quicListener { quicListener = nil }
        if piece == .browser { clearAdvertisements(epoch: token) }
        if piece == .quicBrowser { quicEndpoints.removeAll() }
        stackConstructionFailed(piece, epoch: token, error: error)
    }
    private func stackConstructionFailed(_ piece: Piece, epoch token: UInt64, error: any Error) {
        guard isCurrent(token), activeEpoch == token, !(error is CancellationError) else { return }
        Self.logger.error("Network service failed: \(error.localizedDescription, privacy: .public)")
        lastFailure = NexoReason(error: error)
        if NexoLocalNetworkPermission.isDenied(error) {
            updatePermission(.denied, epoch: token)
        } else {
            let delays: [Duration] = [.seconds(2), .seconds(5), .seconds(10)]
            let attempt = retryAttempts[piece, default: 0]
            if attempt < delays.count {
                retryAttempts[piece] = attempt + 1
                retries[piece]?.cancel()
                retries[piece] = Task { [weak self] in
                    do { try await Task.sleep(for: delays[attempt]) } catch { return }
                    await self?.retry(piece, epoch: token)
                }
            }
        }
        if piece == .listener { emit(.lifecycleChanged(.disconnected, epoch: token)) }
    }
    private func retry(_ piece: Piece, epoch token: UInt64) {
        guard isCurrent(token), activeEpoch == token, runners[piece] == nil else { return }
        sync(piece, epoch: token)
        if piece == .listener, runners[piece] != nil { emit(.lifecycleChanged(.active, epoch: token)) }
    }
    private func resetRetries() {
        for retry in retries.values { retry.cancel() }
        retries.removeAll()
        retryAttempts.removeAll()
    }
    private func updatePermission(_ state: LocalNetworkPermissionState, epoch token: UInt64) {
        guard isCurrent(token), localNetworkPermissionState != state else { return }
        localNetworkPermissionState = state
        emit(.localNetworkPermissionChanged(state, epoch: token))
    }
    private func republishTXTRecord() {
        let txt = NWTXTRecord(advertisement.txtDictionary)
        if let listener {
            var service = listener.service
            service?.txtRecordObject = txt
            listener.service = service
        }
        if let quicListener {
            var service = quicListener.service
            service?.txtRecordObject = txt
            quicListener.service = service
        }
    }
    private func discovered(_ found: [Bonjour.Endpoint], piece: Piece, id: UUID, epoch token: UInt64) {
        guard isCurrent(token), activeEpoch == token, runners[piece]?.id == id else { return }
        retryAttempts[piece] = 0
        if piece == .quicBrowser {
            quicEndpoints.removeAll()
            for endpoint in found.prefix(256) {
                guard let peer = endpoint.txtRecord.dictionary["aid"], peer != applicationID, peer.utf8.count <= 256 else { continue }
                quicEndpoints[peer] = endpoint
            }
            return
        }
        updatePermission(.available, epoch: token)
        var seen: Set<TransportPeerID> = []
        for endpoint in found.prefix(256) {
            let endpointID = TransportPeerID(endpoint.id)
            let record = AdvertisementRecord.advertisement(
                from: endpoint.txtRecord.dictionary, endpointID: endpointID,
                fallbackName: endpoint.name.isEmpty ? endpoint.id : endpoint.name
            )
            guard record.applicationID != applicationID else { continue }
            seen.insert(endpointID)
            endpoints[endpointID] = endpoint
            if let peer = record.applicationID {
                for (oldID, old) in advertisements where oldID != endpointID && old.applicationID == peer {
                    advertisements.removeValue(forKey: oldID)
                    endpoints.removeValue(forKey: oldID)
                    emit(.advertisementLost(oldID, epoch: token))
                }
            }
            let previous = advertisements.updateValue(record, forKey: endpointID)
            if previous == nil { emit(.advertisementFound(record, epoch: token)) }
            else if previous != record { emit(.advertisementUpdated(record, epoch: token)) }
        }
        for endpointID in advertisements.keys where !seen.contains(endpointID) {
            advertisements.removeValue(forKey: endpointID)
            endpoints.removeValue(forKey: endpointID)
            emit(.advertisementLost(endpointID, epoch: token))
        }
    }
    private func clearAdvertisements(epoch token: UInt64) {
        for endpointID in advertisements.keys { emit(.advertisementLost(endpointID, epoch: token)) }
        advertisements.removeAll()
        endpoints.removeAll()
    }

    // MARK: - TCP sessions

    @discardableResult
    public func connect(to advertisement: PeerAdvertisement) async throws -> ConnectedPeer {
        guard tlsConfiguration != nil else { throw P2PTransportError.handshakeFailed(.invalidIdentity) }
        guard let token = activeEpoch, isCurrent(token) else { throw P2PTransportError.transportStopped }
        if let applicationID = advertisement.applicationID,
           let id = connectionIDs[applicationID], let peer = boxes[id]?.peer { return peer }
        guard P2PProtocolInfo.isCompatible(remoteVersion: advertisement.protocolVersion) else {
            throw P2PTransportError.incompatibleProtocol(advertisement.protocolVersion)
        }
        guard let endpoint = endpoints[advertisement.endpointID] else { throw P2PTransportError.peerNotDiscovered }
        let box: Box
        if let pending = boxes.values.first(where: { $0.isOutgoing && $0.endpointID == advertisement.endpointID && $0.peer == nil }) {
            box = pending
        } else {
            guard boxes.count < 64 else { throw P2PTransportError.connectionFailed(.connectionFailed) }
            box = register(Connection(to: endpoint, using: try parameters()), epoch: token, outgoing: true,
                           endpointID: advertisement.endpointID, expectedApplicationID: advertisement.applicationID)
        }
        guard box.waiters.count < 64 else { throw P2PTransportError.connectionFailed(.connectionFailed) }
        let waiterID = UUID()
        let peer = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ConnectedPeer, Error>) in
                guard isCurrent(token), boxes[box.id] === box else {
                    continuation.resume(throwing: P2PTransportError.transportStopped)
                    return
                }
                if let peer = box.peer { continuation.resume(returning: peer) }
                else if box.waiters.count < 64 { box.waiters[waiterID] = continuation }
                else { continuation.resume(throwing: P2PTransportError.connectionFailed(.connectionFailed)) }
            }
        } onCancel: {
            Task { [weak self] in await self?.cancelWaiter(waiterID, on: box.id) }
        }
        guard isCurrent(token), boxes[box.id] === box else { throw P2PTransportError.transportStopped }
        return peer
    }
    private func cancelWaiter(_ id: UUID, on connectionID: TransportPeerID) async {
        guard let box = boxes[connectionID] else { return }
        box.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        if box.waiters.isEmpty, box.peer == nil { await fail(box, error: CancellationError()) }
    }
    private func accept(_ connection: Connection, epoch token: UInt64, runnerID: UUID) -> Task<Void, Never>? {
        guard isCurrent(token), activeEpoch == token, runners[.listener]?.id == runnerID, boxes.count < 64 else { return nil }
        return register(connection, epoch: token, outgoing: false).receiveTask
    }
    private func register(_ connection: Connection, epoch token: UInt64, outgoing: Bool,
                          endpointID: TransportPeerID? = nil, expectedApplicationID: String? = nil) -> Box {
        let box = Box(connection: connection, epoch: token, isOutgoing: outgoing,
                      endpointID: endpointID, expectedApplicationID: expectedApplicationID)
        boxes[box.id] = box
        box.queue = TransportSendQueue(send: { [weak connection] envelope in
            guard let connection else { throw P2PTransportError.notConnected }
            try await connection.send(.envelope(envelope))
        }, onFailure: { [weak self, weak box] error in
            guard let box else { return }
            await self?.fail(box, error: error)
        })
        // Socket awaits do not retain the owner of these long-running tasks.
        box.receiveTask = Task { [weak self, weak box] in
            do {
                for try await message in connection.messages {
                    guard let box, !Task.isCancelled else { return }
                    await self?.handle(message.content, on: box)
                }
                if let box { await self?.fail(box, error: P2PTransportError.connectionFailed(.connectionClosed)) }
            } catch { if let box { await self?.fail(box, error: error) } }
        }
        box.timeoutTask = Task { [weak self, weak box] in
            do { try await Task.sleep(for: P2PLimits.handshakeTimeout) } catch { return }
            guard let box else { return }
            await self?.handshakeTimedOut(box)
        }
        let hello = P2PFrame.hello(HelloBody(applicationID: applicationID, displayName: advertisement.displayName,
                                            certificateFingerprint: localCertificateFingerprint))
        box.helloTask = Task { [weak self, weak box] in
            do { try await connection.send(hello) }
            catch { if let box { await self?.fail(box, error: error) } }
        }
        return box
    }
    private func handshakeTimedOut(_ box: Box) async {
        guard box.peer == nil else { return }
        await fail(box, error: P2PTransportError.handshakeTimedOut)
    }
    private func handle(_ frame: P2PFrame, on box: Box) async {
        guard isCurrent(box.epoch), activeEpoch == box.epoch, boxes[box.id] === box else { return }
        switch frame.kind {
        case .hello:
            guard let body = frame.hello else { await fail(box, error: P2PTransportError.handshakeFailed(.incompleteHello)); return }
            await completeHandshake(body, on: box)
        case .envelope:
            guard let peer = box.peer, let envelope = frame.envelope else { return }
            guard P2PProtocolInfo.isCompatible(remoteVersion: envelope.protocolVersion),
                  envelope.senderApplicationID == peer.applicationID,
                  envelope.payload.count <= P2PLimits.maximumEnvelopeBytes,
                  envelope.transportBudgetBytes <= P2PLimits.maximumEnvelopeBytes + 4096 else {
                await fail(box, error: P2PTransportError.connectionFailed(.connectionFailed)); return
            }
            emit(.received(envelope, from: peer, epoch: box.epoch))
        case .goodbye:
            await fail(box, error: P2PTransportError.connectionFailed(frame.goodbye?.reason ?? .peerDisconnected))
        }
    }
    private func completeHandshake(_ body: HelloBody, on box: Box) async {
        guard box.peer == nil else { return }
        guard P2PProtocolInfo.isCompatible(remoteVersion: body.protocolVersion),
              body.minimumProtocolVersion <= P2PProtocolInfo.currentVersion else {
            await fail(box, error: P2PTransportError.incompatibleProtocol(body.protocolVersion)); return
        }
        guard !body.applicationID.isEmpty, body.applicationID != applicationID,
              body.applicationID.utf8.count <= 256, body.displayName.utf8.count <= 1024,
              box.expectedApplicationID == nil || box.expectedApplicationID == body.applicationID else {
            await fail(box, error: P2PTransportError.handshakeFailed(.invalidIdentity)); return
        }
        let fingerprint: String
        do {
            guard let metadata = box.connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
                throw P2PTransportError.handshakeFailed(.invalidIdentity)
            }
            fingerprint = try NexoTLSPeerIdentity.fingerprint(from: metadata.securityProtocolMetadata)
        } catch { await fail(box, error: error); return }
        if let rivalID = connectionIDs[body.applicationID], let rival = boxes[rivalID], rival !== box {
            // An asserted ID cannot evict a live session with a different TLS key.
            guard rival.peer?.certificateFingerprint == fingerprint else {
                await fail(box, error: P2PTransportError.handshakeFailed(.invalidIdentity)); return
            }
            let keepOutgoing = min(applicationID, body.applicationID) == applicationID
            let loser = keepOutgoing ? (box.isOutgoing ? rival : box) : (box.isOutgoing ? box : rival)
            await fail(loser, error: P2PTransportError.connectionFailed(.duplicateConnection), notify: false, sendGoodbye: true)
            if loser === box { return }
        }
        guard isCurrent(box.epoch), activeEpoch == box.epoch, boxes[box.id] === box else { return }
        let peer = ConnectedPeer(applicationID: body.applicationID, displayName: body.displayName,
            certificateFingerprint: fingerprint, protocolVersion: body.protocolVersion,
            capabilities: Set(body.capabilities), connectionSessionID: box.sessionID)
        box.peer = peer
        box.timeoutTask?.cancel()
        box.timeoutTask = nil
        connectionIDs[peer.applicationID] = box.id
        establishedPeers.withLock { $0[peer.applicationID] = peer }
        box.resolve(.success(peer))
        emit(.peerConnected(peer, epoch: box.epoch))
    }
    private func fail(_ box: Box, error: any Error, notify: Bool = true, sendGoodbye: Bool = false) async {
        guard boxes[box.id] === box else { return }
        // Remove indexes before suspension; stale teardown cannot evict a replacement.
        boxes.removeValue(forKey: box.id)
        if sendGoodbye, isCurrent(box.epoch) { beginGoodbye(on: box.connection, reason: NexoReason(error: error)) }
        box.resolve(.failure(error))
        let queue = box.cancel()
        var channels: [BinaryChannel] = []
        if let peer = box.peer, connectionIDs[peer.applicationID] == box.id {
            connectionIDs.removeValue(forKey: peer.applicationID)
            establishedPeers.withLock { stored in
                if stored[peer.applicationID]?.connectionSessionID == peer.connectionSessionID { stored.removeValue(forKey: peer.applicationID) }
            }
            for (id, channel) in binaryChannels where channel.peer?.connectionSessionID == peer.connectionSessionID {
                channels.append(channel)
                binaryChannels.removeValue(forKey: id)
            }
            binaryIDs.removeValue(forKey: peer.applicationID)
            if notify { emit(.peerDisconnected(applicationID: peer.applicationID, reason: NexoReason(error: error), epoch: box.epoch)) }
        }
        await queue?.stop()
        for channel in channels {
            channel.task?.cancel()
            await channel.transport.close()
        }
    }

    private func beginGoodbye(on connection: Connection, reason: NexoReason) {
        guard farewellTasks.count < 64 else { return }
        let id = UUID()
        farewellTasks[id] = Task { [weak self] in
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await connection.send(.goodbye(reason: reason)) }
                    group.addTask { try await Task.sleep(for: .seconds(1)) }
                    defer { group.cancelAll() }
                    _ = try await group.next()
                }
            } catch { /* The connection may already have closed. */ }
            await self?.farewellEnded(id)
        }
    }

    private func farewellEnded(_ id: UUID) { farewellTasks.removeValue(forKey: id) }

    // MARK: - Authenticated QUIC channels

    public func openBinaryStream(to peerID: String, descriptor: NexoStreamDescriptor) async throws -> NexoQUICByteStream {
        guard let token = activeEpoch, isCurrent(token), let id = connectionIDs[peerID],
              let peer = boxes[id]?.peer, peer.supports(.binaryStreams) else {
            throw P2PTransportError.connectionFailed(.binaryStreamsUnsupported)
        }
        let transport: NexoQUICBinaryTransport
        if let binaryID = binaryIDs[peerID], let existing = binaryChannels[binaryID] {
            transport = existing.transport
        } else {
            guard let endpoint = quicEndpoints[peerID] else { throw P2PTransportError.peerNotDiscovered }
            guard binaryChannels.count < 16 else { throw P2PTransportError.connectionFailed(.connectionFailed) }
            let binaryID = UUID()
            transport = try NexoQUICBinaryTransport.connect(
                to: endpoint.nwEndpoint, applicationID: applicationID, expectedRemoteApplicationID: peerID,
                tlsConfiguration: tlsConfiguration, authenticatePeer: { [weak self] remoteID, fingerprint in
                    guard let self else { throw P2PTransportError.transportStopped }
                    return try await self.authenticateBinary(remoteID, fingerprint: fingerprint,
                        candidates: [peer], binaryID: binaryID, epoch: token)
                })
            binaryChannels[binaryID] = BinaryChannel(transport: transport, epoch: token, peer: peer)
            binaryIDs[peerID] = binaryID
            startBinaryReceiver(transport, id: binaryID, epoch: token)
        }
        do {
            let stream = try await transport.openStream(descriptor)
            guard isCurrent(token), boxes[id]?.peer?.connectionSessionID == peer.connectionSessionID else {
                await transport.close()
                throw P2PTransportError.transportStopped
            }
            return stream
        } catch { await transport.close(); throw error }
    }
    private func acceptQUIC(_ connection: NetworkConnection<QUIC>, epoch token: UInt64, runnerID: UUID) -> Task<Void, Never>? {
        guard isCurrent(token), activeEpoch == token, runners[.quicListener]?.id == runnerID,
              binaryChannels.count < 16 else { return nil }
        // Freeze candidate TCP sessions at channel acceptance, before any declared QUIC ID.
        let candidates = boxes.values.compactMap(\.peer)
        guard !candidates.isEmpty else { return nil }
        let id = UUID()
        let transport = NexoQUICBinaryTransport(connection: connection, applicationID: applicationID,
            authenticatePeer: { [weak self] remoteID, fingerprint in
                guard let self else { throw P2PTransportError.transportStopped }
                return try await self.authenticateBinary(remoteID, fingerprint: fingerprint,
                    candidates: candidates, binaryID: id, epoch: token)
            })
        binaryChannels[id] = BinaryChannel(transport: transport, epoch: token)
        startBinaryReceiver(transport, id: id, epoch: token)
        return binaryChannels[id]?.task
    }
    private func authenticateBinary(_ peerID: String, fingerprint: String, candidates: [ConnectedPeer],
                                    binaryID: UUID, epoch token: UInt64) throws -> ConnectedPeer {
        guard isCurrent(token), activeEpoch == token,
              let candidate = candidates.first(where: { $0.applicationID == peerID }),
              candidate.certificateFingerprint == fingerprint, candidate.supports(.binaryStreams),
              let id = connectionIDs[peerID], boxes[id]?.peer?.connectionSessionID == candidate.connectionSessionID,
              binaryChannels[binaryID]?.epoch == token else { throw P2PTransportError.handshakeFailed(.invalidIdentity) }
        binaryChannels[binaryID]?.peer = candidate
        if binaryIDs[peerID] == nil { binaryIDs[peerID] = binaryID }
        return candidate
    }
    private func startBinaryReceiver(_ transport: NexoQUICBinaryTransport, id: UUID, epoch token: UInt64) {
        binaryChannels[id]?.task = Task { [weak self] in
            let streams = await transport.startIncoming()
            do {
                for try await stream in streams {
                    guard !Task.isCancelled else { break }
                    await self?.acceptBinary(stream, id: id, epoch: token)
                }
            } catch { /* Closing a channel finishes its incoming subscription. */ }
            await transport.close()
            await self?.binaryEnded(id, epoch: token)
        }
    }
    private func acceptBinary(_ stream: NexoQUICIncomingStream, id: UUID, epoch token: UInt64) async {
        guard isCurrent(token), let authenticated = stream.authenticatedPeer,
              binaryChannels[id]?.peer == authenticated,
              let connectionID = connectionIDs[authenticated.applicationID], let box = boxes[connectionID],
              box.peer?.connectionSessionID == authenticated.connectionSessionID else {
            if let transport = binaryChannels[id]?.transport { await transport.close() }
            return
        }
        let accepted: Bool
        switch binaryConsumer.withLock({ $0 }) {
        case .legacy:
            if case .enqueued = incomingBinaryContinuation.yield(stream) { accepted = true } else { accepted = false }
        case .peer:
            if case .enqueued = incomingPeerBinaryContinuation.yield(.init(
                peer: authenticated, descriptor: stream.descriptor, stream: stream.stream
            )) { accepted = true } else { accepted = false }
        case nil: accepted = false
        }
        if !accepted { await fail(box, error: P2PTransportError.connectionFailed(.connectionFailed)) }
    }
    private func binaryEnded(_ id: UUID, epoch token: UInt64) {
        guard let channel = binaryChannels[id], channel.epoch == token else { return }
        binaryChannels.removeValue(forKey: id)
        if let peer = channel.peer, binaryIDs[peer.applicationID] == id { binaryIDs.removeValue(forKey: peer.applicationID) }
    }
    private nonisolated func emit(_ event: PeerTransportEvent) {
        session.withLock { state in
            guard !state.isStopped, state.epoch == event.epoch else { return }
            if case .dropped = eventContinuation.yield(event) {
                // Reliable event loss terminates the session rather than pretending delivery succeeded.
                state.overloadedEpoch = event.epoch
                wakeup.yield(())
            }
        }
    }
}

// MARK: - NexoLocalNetworkPermission

enum NexoLocalNetworkPermission {
    /// mDNSResponder wraps denied local-network permission in a DNS NoAuth error.
    static func isDenied(_ error: any Error) -> Bool {
        if let networkError = error as? NWError {
            switch networkError {
            case .posix(.EACCES), .posix(.EPERM): return true
            case .dns(let code) where code == -65555: return true
            default: break
            }
        }
        let description = String(describing: error) + " " + error.localizedDescription
        return description.localizedCaseInsensitiveContains("PolicyDenied")
            || description.localizedCaseInsensitiveContains("policy denied")
            || description.localizedCaseInsensitiveContains("LocalNetwork")
            || description.localizedCaseInsensitiveContains("NoAuth")
    }
}
