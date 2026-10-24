//
//  NexoQUICBinaryTransport.swift
//  Nexo
//

import Foundation
import Network

public struct NexoQUICIncomingStream: Sendable {
    public let descriptor: NexoStreamDescriptor
    public let stream: NexoByteStream
    public let peerApplicationID: String
    /// The TCP session against which this channel's negotiated TLS key was checked.
    public let authenticatedPeer: ConnectedPeer?

    public init(
        descriptor: NexoStreamDescriptor, stream: NexoByteStream,
        peerApplicationID: String, authenticatedPeer: ConnectedPeer? = nil
    ) {
        self.descriptor = descriptor
        self.stream = stream
        self.peerApplicationID = peerApplicationID
        self.authenticatedPeer = authenticatedPeer
    }
}

public struct NexoPeerBinaryStream: Sendable {
    public let peer: ConnectedPeer
    public let descriptor: NexoStreamDescriptor
    public let stream: NexoByteStream

    public init(peer: ConnectedPeer, descriptor: NexoStreamDescriptor, stream: NexoByteStream) {
        self.peer = peer
        self.descriptor = descriptor
        self.stream = stream
    }
}

private struct NexoQUICHandshake: Codable, Sendable {
    let applicationID: String
    let protocolVersion: UInt8
    let minimumProtocolVersion: UInt8
    let challenge: UUID
    let responseTo: UUID?
}

/// A writable binary stream backed by one QUIC bidirectional stream.
public actor NexoQUICByteStream {
    private var stream: QUIC.Stream<QUICStream>?
    private let streamID: UUID
    private var writeTask: Task<Void, Error>?

    fileprivate init(stream: QUIC.Stream<QUICStream>, streamID: UUID) {
        self.stream = stream
        self.streamID = streamID
    }

    deinit { writeTask?.cancel() }

    public func send(_ data: Data) async throws { try await write(.data, data: data) }
    public func finish() async throws { try await write(.finish) }
    public func cancel() async throws { try await write(.cancel) }

    private func write(_ kind: NexoBinaryFrame.Kind, data: Data = Data()) async throws {
        guard let stream else { throw NexoQUICBinaryTransportError.closed }
        guard writeTask == nil else { throw NexoQUICBinaryTransportError.concurrentWrite }
        let streamID = streamID
        // One cancellable operation, with sequential bounded writes rather than a task per chunk.
        let task = Task {
            if kind == .data {
                var offset = data.startIndex
                while offset < data.endIndex {
                    try Task.checkCancellation()
                    let end = data.index(offset, offsetBy: min(64 * 1024, data.distance(from: offset, to: data.endIndex)))
                    let frame = NexoBinaryFrame(kind: .data, streamID: streamID, payload: Data(data[offset..<end]))
                    try await stream.send(try NexoBinaryFrameCodec.encode(frame), endOfStream: false)
                    offset = end
                }
            } else {
                try await stream.send(try NexoBinaryFrameCodec.encode(.init(kind: kind, streamID: streamID)), endOfStream: true)
            }
        }
        writeTask = task
        defer { writeTask = nil }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard self.stream != nil else { throw NexoQUICBinaryTransportError.closed }
            if kind != .data { self.stream = nil }
        } catch {
            self.stream = nil
            throw error
        }
    }

    fileprivate func close() {
        writeTask?.cancel()
        stream = nil
    }
    fileprivate var isClosed: Bool { stream == nil }
}

/// Multiplexed binary streams pinned to a live, authenticated TCP session.
public actor NexoQUICBinaryTransport {
    public typealias PeerAuthenticator = @Sendable (String, String) async throws -> ConnectedPeer
    private static let applicationProtocol = "nexo-binary-v1"
    private static let maximumHandshakeBytes = 4096
    private static let maximumStreams = 8

    private var connection: NetworkConnection<QUIC>?
    private let applicationID: String
    private let expectedRemoteApplicationID: String?
    private let authenticatePeer: PeerAuthenticator?
    private var inboundTask: Task<Void, Never>?
    private var receiverTasks: [UUID: Task<Void, Never>] = [:]
    private var sources: [UUID: NexoByteStream.Source] = [:]
    private var sourceOwners: [UUID: UUID] = [:]
    private var writers: [UUID: NexoQUICByteStream] = [:]
    private var openingTasks: [UUID: Task<NexoQUICByteStream, Error>] = [:]
    private var incomingContinuation: AsyncThrowingStream<NexoQUICIncomingStream, Error>.Continuation?
    private var isStarted = false
    private var isClosed = false
    private var authenticatedPeer: ConnectedPeer?
    private var authenticationTask: Task<ConnectedPeer, Error>?
    private var authenticationWaiters: [UUID: CheckedContinuation<ConnectedPeer, Error>] = [:]
    private var timeoutTask: Task<Void, Never>?

    public init(
        connection: NetworkConnection<QUIC>, applicationID: String,
        expectedRemoteApplicationID: String? = nil,
        authenticatePeer: PeerAuthenticator? = nil
    ) {
        self.connection = connection
        self.applicationID = applicationID
        self.expectedRemoteApplicationID = expectedRemoteApplicationID
        self.authenticatePeer = authenticatePeer
    }

    /// A missing TLS configuration or TCP-session authenticator fails before dialing.
    public static func connect(
        to endpoint: NWEndpoint, applicationID: String,
        expectedRemoteApplicationID: String? = nil,
        tlsConfiguration: NexoTLSConfiguration? = nil,
        authenticatePeer: PeerAuthenticator? = nil
    ) throws -> NexoQUICBinaryTransport {
        guard let tlsConfiguration, let authenticatePeer else {
            throw P2PTransportError.handshakeFailed(.invalidIdentity)
        }
        let connection = NetworkConnection<QUIC>(
            to: endpoint, using: parameters(tlsConfiguration)
        )
        return NexoQUICBinaryTransport(
            connection: connection, applicationID: applicationID,
            expectedRemoteApplicationID: expectedRemoteApplicationID,
            authenticatePeer: authenticatePeer
        )
    }

    deinit {
        inboundTask?.cancel()
        authenticationTask?.cancel()
        timeoutTask?.cancel()
        for task in receiverTasks.values { task.cancel() }
        for task in openingTasks.values { task.cancel() }
        for writer in writers.values { Task { await writer.close() } }
        for source in sources.values { source.finish(throwing: NexoQUICBinaryTransportError.closed) }
        for waiter in authenticationWaiters.values { waiter.resume(throwing: NexoQUICBinaryTransportError.closed) }
        incomingContinuation?.finish()
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        connection = nil
        inboundTask?.cancel()
        inboundTask = nil
        authenticationTask?.cancel()
        authenticationTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        for task in receiverTasks.values { task.cancel() }
        receiverTasks.removeAll()
        for task in openingTasks.values { task.cancel() }
        openingTasks.removeAll()
        for source in sources.values { source.finish(throwing: NexoQUICBinaryTransportError.closed) }
        sources.removeAll()
        sourceOwners.removeAll()
        resumeAuthenticationWaiters(with: .failure(NexoQUICBinaryTransportError.closed))
        incomingContinuation?.finish(throwing: NexoQUICBinaryTransportError.closed)
        incomingContinuation = nil
        let closing = Array(writers.values)
        writers.removeAll()
        for writer in closing { await writer.close() }
    }

    public func openStream(_ descriptor: NexoStreamDescriptor) async throws -> NexoQUICByteStream {
        for (id, writer) in writers {
            if await writer.isClosed { writers.removeValue(forKey: id) }
        }
        guard !isClosed, let connection else { throw NexoQUICBinaryTransportError.closed }
        guard openingTasks.count + writers.count < Self.maximumStreams,
              openingTasks[descriptor.id] == nil, writers[descriptor.id] == nil else {
            throw NexoQUICBinaryTransportError.capacityExceeded
        }
        let metadata = try JSONEncoder().encode(descriptor)
        guard metadata.count <= Self.maximumHandshakeBytes else { throw NexoQUICBinaryTransportError.capacityExceeded }
        let task = Task { [weak self] () async throws -> NexoQUICByteStream in
            guard try await self?.authenticateIfNeeded() != nil else { throw NexoQUICBinaryTransportError.closed }
            try Task.checkCancellation()
            let stream = try await connection.openStream(directionality: .bidirectional)
            try Task.checkCancellation()
            try await stream.send(try NexoBinaryFrameCodec.encode(
                .init(kind: .open, streamID: descriptor.id, payload: metadata)
            ), endOfStream: false)
            try Task.checkCancellation()
            return NexoQUICByteStream(stream: stream, streamID: descriptor.id)
        }
        openingTasks[descriptor.id] = task
        defer { openingTasks.removeValue(forKey: descriptor.id) }
        let writer = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !isClosed else {
            await writer.close()
            throw NexoQUICBinaryTransportError.closed
        }
        writers[descriptor.id] = writer
        return writer
    }

    /// Single consumer; unread descriptors and concurrent streams have finite budgets.
    public func startIncoming() -> AsyncThrowingStream<NexoQUICIncomingStream, Error> {
        guard !isStarted, !isClosed, let connection, authenticatePeer != nil else {
            return AsyncThrowingStream { $0.finish(throwing: NexoQUICBinaryTransportError.handshakeRequired) }
        }
        isStarted = true
        let pair = AsyncThrowingStream<NexoQUICIncomingStream, Error>.makeStream(bufferingPolicy: .bufferingOldest(Self.maximumStreams))
        incomingContinuation = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.close() } }
        startAuthenticationTimeout()
        inboundTask = Task { [weak self] in
            do {
                try await connection.inboundStreams { [weak self] stream in
                    guard let receiver = try await self?.startReceiver(stream) else { return }
                    await withTaskCancellationHandler { await receiver.value } onCancel: { receiver.cancel() }
                }
            } catch {
                pair.continuation.finish(throwing: error)
            }
            await self?.close()
        }
        return pair.stream
    }

    private func startReceiver(_ stream: QUIC.Stream<QUICStream>) throws -> Task<Void, Never> {
        guard !isClosed else { throw NexoQUICBinaryTransportError.closed }
        guard receiverTasks.count < Self.maximumStreams else { throw NexoQUICBinaryTransportError.capacityExceeded }
        let id = UUID()
        let task = Task { [weak self] in
            var buffer = Data()
            var streamID: UUID?
            do {
                while !Task.isCancelled {
                    let message = try await stream.receive(atLeast: 1, atMost: 64 * 1024)
                    buffer.append(message.content)
                    while let frame = try Self.nextFrame(from: &buffer) {
                        guard let shouldContinue = try await self?.receive(frame, stream: stream, receiverID: id, streamID: &streamID), shouldContinue else {
                            await self?.receiverEnded(id, streamID: streamID)
                            return
                        }
                    }
                    if message.metadata.endOfStream {
                        guard buffer.isEmpty else { throw NexoBinaryFrameError.truncated }
                        break
                    }
                }
                await self?.receiverEnded(id, streamID: streamID)
            } catch {
                await self?.receiverEnded(id, streamID: streamID, error: error)
            }
        }
        receiverTasks[id] = task
        return task
    }

    private func receive(
        _ frame: NexoBinaryFrame, stream: QUIC.Stream<QUICStream>, receiverID: UUID, streamID: inout UUID?
    ) async throws -> Bool {
        guard !isClosed else { throw NexoQUICBinaryTransportError.closed }
        if streamID == nil {
            if frame.kind == .handshake {
                try await receiveHandshake(frame, on: stream)
                return false
            }
            let peer = try await waitForAuthentication()
            guard !isClosed, frame.kind == .open, frame.payload.count <= Self.maximumHandshakeBytes else {
                throw NexoQUICBinaryTransportError.openFrameRequired
            }
            let descriptor = try JSONDecoder().decode(NexoStreamDescriptor.self, from: frame.payload)
            guard descriptor.id == frame.streamID, sources[descriptor.id] == nil,
                  sources.count < Self.maximumStreams else { throw NexoQUICBinaryTransportError.capacityExceeded }
            let pair = NexoByteStream.makeStream(bufferingPolicy: .bufferingOldest(8))
            pair.source.onTermination = { [weak self] termination in
                guard case .cancelled = termination else { return }
                Task { await self?.cancelReceiver(receiverID, streamID: descriptor.id) }
            }
            sources[descriptor.id] = pair.source
            sourceOwners[descriptor.id] = receiverID
            streamID = descriptor.id
            let accepted = NexoQUICIncomingStream(
                descriptor: descriptor, stream: pair.stream,
                peerApplicationID: peer.applicationID, authenticatedPeer: peer
            )
            guard let result = incomingContinuation?.yield(accepted), case .enqueued = result else {
                throw NexoQUICBinaryTransportError.capacityExceeded
            }
            return true
        }
        guard frame.streamID == streamID, sourceOwners[frame.streamID] == receiverID,
              let source = sources[frame.streamID] else {
            throw NexoQUICBinaryTransportError.openFrameRequired
        }
        switch frame.kind {
        case .data:
            guard case .enqueued = source.yield(frame.payload) else { throw NexoQUICBinaryTransportError.capacityExceeded }
            return true
        case .finish:
            source.finish()
        case .cancel:
            source.finish(throwing: NexoQUICBinaryTransportError.closed)
        default:
            throw NexoQUICBinaryTransportError.openFrameRequired
        }
        sources.removeValue(forKey: frame.streamID)
        sourceOwners.removeValue(forKey: frame.streamID)
        return false
    }

    private func cancelReceiver(_ id: UUID, streamID: UUID) {
        receiverTasks.removeValue(forKey: id)?.cancel()
        guard sourceOwners[streamID] == id else { return }
        sourceOwners.removeValue(forKey: streamID)
        sources.removeValue(forKey: streamID)?.finish(throwing: CancellationError())
    }

    private func receiverEnded(_ id: UUID, streamID: UUID?, error: (any Error)? = nil) async {
        receiverTasks.removeValue(forKey: id)
        if let streamID, sourceOwners[streamID] == id {
            sourceOwners.removeValue(forKey: streamID)
            sources.removeValue(forKey: streamID)?.finish(throwing: error ?? NexoQUICBinaryTransportError.closed)
        }
        if let error, !(error is CancellationError) { await close() }
    }

    private static func nextFrame(from buffer: inout Data) throws -> NexoBinaryFrame? {
        guard buffer.count >= 4 else { return nil }
        let length = Int(buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard length >= 17 else { throw NexoBinaryFrameError.invalidLength }
        guard length <= 64 * 1024 + 17 else { throw NexoBinaryFrameError.oversized(length) }
        guard buffer.count >= length + 4 else { return nil }
        let frame = try NexoBinaryFrameCodec.decode(Data(buffer.prefix(length + 4)))
        buffer = Data(buffer.dropFirst(length + 4))
        return frame
    }

    private func startAuthenticationTimeout() {
        guard timeoutTask == nil, authenticatedPeer == nil else { return }
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: P2PLimits.handshakeTimeout) } catch { return }
            await self?.authenticationTimedOut()
        }
    }

    private func authenticationTimedOut() async {
        guard authenticatedPeer == nil else { return }
        await close()
    }

    private func authenticateIfNeeded() async throws -> ConnectedPeer {
        guard !isClosed else { throw NexoQUICBinaryTransportError.closed }
        if let authenticatedPeer { return authenticatedPeer }
        if let authenticationTask { return try await authenticationTask.value }
        guard let connection, let authenticatePeer else { throw NexoQUICBinaryTransportError.handshakeRequired }
        startAuthenticationTimeout()
        let applicationID = applicationID
        let expectedID = expectedRemoteApplicationID
        let task = Task { [weak self] () async throws -> ConnectedPeer in
            let stream = try await connection.openStream(directionality: .bidirectional)
            let challenge = UUID()
            let handshake = NexoQUICHandshake(
                applicationID: applicationID, protocolVersion: P2PProtocolInfo.currentVersion,
                minimumProtocolVersion: P2PProtocolInfo.minimumVersion, challenge: challenge, responseTo: nil
            )
            try await stream.send(try NexoBinaryFrameCodec.encode(.init(
                kind: .handshake, streamID: challenge, payload: try JSONEncoder().encode(handshake)
            )), endOfStream: true)
            // A QUIC receive can return a partial frame, even for tiny handshakes.
            var buffer = Data()
            while true {
                let message = try await stream.receive(atLeast: 1, atMost: Self.maximumHandshakeBytes)
                buffer.append(message.content)
                guard buffer.count <= Self.maximumHandshakeBytes else { throw NexoQUICBinaryTransportError.handshakeFailed }
                if let frame = try Self.nextFrame(from: &buffer) {
                    guard frame.kind == .handshake, frame.streamID == challenge, buffer.isEmpty else {
                        throw NexoQUICBinaryTransportError.handshakeFailed
                    }
                    let response = try JSONDecoder().decode(NexoQUICHandshake.self, from: frame.payload)
                    try Self.validate(response, expectedID: expectedID)
                    guard response.responseTo == challenge else { throw NexoQUICBinaryTransportError.handshakeFailed }
                    let fingerprint = try NexoTLSPeerIdentity.fingerprint(from: connection.securityProtocolMetadata)
                    let peer = try await authenticatePeer(response.applicationID, fingerprint)
                    try Task.checkCancellation()
                    guard let self else { throw NexoQUICBinaryTransportError.closed }
                    try await self.authenticated(peer)
                    return peer
                }
                guard !message.metadata.endOfStream else { throw NexoQUICBinaryTransportError.handshakeFailed }
            }
        }
        authenticationTask = task
        do { return try await task.value } catch { await close(); throw error }
    }

    private func receiveHandshake(_ frame: NexoBinaryFrame, on stream: QUIC.Stream<QUICStream>) async throws {
        guard frame.payload.count <= Self.maximumHandshakeBytes,
              authenticatedPeer == nil, let connection, let authenticatePeer else {
            throw NexoQUICBinaryTransportError.handshakeFailed
        }
        let handshake = try JSONDecoder().decode(NexoQUICHandshake.self, from: frame.payload)
        try Self.validate(handshake, expectedID: expectedRemoteApplicationID)
        guard handshake.responseTo == nil, frame.streamID == handshake.challenge else {
            throw NexoQUICBinaryTransportError.handshakeFailed
        }
        let fingerprint = try NexoTLSPeerIdentity.fingerprint(from: connection.securityProtocolMetadata)
        let peer = try await authenticatePeer(handshake.applicationID, fingerprint)
        guard !isClosed else { throw NexoQUICBinaryTransportError.closed }
        let response = NexoQUICHandshake(
            applicationID: applicationID, protocolVersion: P2PProtocolInfo.currentVersion,
            minimumProtocolVersion: P2PProtocolInfo.minimumVersion,
            challenge: UUID(), responseTo: handshake.challenge
        )
        try await stream.send(try NexoBinaryFrameCodec.encode(.init(
            kind: .handshake, streamID: frame.streamID, payload: try JSONEncoder().encode(response)
        )), endOfStream: true)
        try authenticated(peer)
    }

    private static func validate(_ handshake: NexoQUICHandshake, expectedID: String?) throws {
        guard !handshake.applicationID.isEmpty, handshake.applicationID.utf8.count <= 256,
              P2PProtocolInfo.isCompatible(remoteVersion: handshake.protocolVersion),
              handshake.minimumProtocolVersion <= P2PProtocolInfo.currentVersion else {
            throw NexoQUICBinaryTransportError.handshakeFailed
        }
        if let expectedID, expectedID != handshake.applicationID {
            throw NexoQUICBinaryTransportError.unexpectedPeer(handshake.applicationID)
        }
    }

    private func authenticated(_ peer: ConnectedPeer) throws {
        guard !isClosed, authenticatedPeer == nil || authenticatedPeer == peer else {
            throw NexoQUICBinaryTransportError.handshakeFailed
        }
        authenticatedPeer = peer
        timeoutTask?.cancel()
        timeoutTask = nil
        resumeAuthenticationWaiters(with: .success(peer))
    }

    private func waitForAuthentication() async throws -> ConnectedPeer {
        guard !isClosed else { throw NexoQUICBinaryTransportError.closed }
        if let authenticatedPeer { return authenticatedPeer }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if isClosed { continuation.resume(throwing: NexoQUICBinaryTransportError.closed) }
                else if let authenticatedPeer { continuation.resume(returning: authenticatedPeer) }
                else { authenticationWaiters[id] = continuation }
            }
        } onCancel: {
            Task { [weak self] in await self?.cancelAuthenticationWaiter(id) }
        }
    }

    private func cancelAuthenticationWaiter(_ id: UUID) {
        authenticationWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func resumeAuthenticationWaiters(with result: Result<ConnectedPeer, Error>) {
        let waiters = authenticationWaiters.values
        authenticationWaiters.removeAll()
        for waiter in waiters { waiter.resume(with: result) }
    }

    static func parameters(_ tlsConfiguration: NexoTLSConfiguration) -> NWParametersBuilder<QUIC> {
        NWParametersBuilder(auto: {
            tlsConfiguration.configure(QUIC(alpn: [applicationProtocol], { UDP { IP() } }))
                .tls.peerAuthentication(.required)
                .initialMaxBidirectionalStreams(maximumStreams)
                .initialMaxUnidirectionalStreams(0)
        }).peerToPeerIncluded(true)
    }
}

public enum NexoQUICBinaryTransportError: Error, Sendable, Equatable {
    case alreadyStarted
    case openFrameRequired
    case handshakeRequired
    case handshakeFailed
    case unexpectedPeer(String)
    case closed
    case capacityExceeded
    case concurrentWrite
}
