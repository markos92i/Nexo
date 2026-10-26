//
//  QUICChannel.swift
//  Nexo
//
//  High-speed binary streaming over QUIC, encrypted with a pre-shared key (PSK).
//
//  Cifrado PSK, no certificados. Con PSK la pertenencia ya está garantizada: si
//  el handshake QUIC-PSK se levanta, ambos extremos conocen el mismo secreto, así
//  que NO hay handshake de aplicación, NI autenticación por fingerprint, NI
//  challenge/response. El canal solo transporta streams binarios framed.
//
//  Se usa la API CLÁSICA de Network framework (NWConnectionGroup +
//  NWMultiplexGroup + NWProtocolQUIC.Options), no la declarativa, porque el PSK
//  solo puede configurarse vía `securityProtocolOptions` +
//  `sec_protocol_options_add_pre_shared_key` (mismo patrón que
//  `NetworkTransport.makeTLSOptions`). Cada stream QUIC es una `NWConnection`
//  extraída del grupo con `group.extract(...)`; los entrantes llegan por
//  `group.newConnectionHandler`.
//
//  NOTA DE RIESGO: PSK sobre QUIC usa TLS 1.3, y el soporte PSK histórico de
//  Apple era TLS 1.2 (`sec_protocol_options_add_pre_shared_key` +
//  `TLS_PSK_WITH_AES_128_GCM_SHA256`). Que el handshake QUIC-PSK negocie
//  realmente no está garantizado por la API y SOLO puede confirmarse en hardware
//  con dos dispositivos. Este archivo COMPILA y es correcto en su lógica; la
//  validación en runtime del PSK+QUIC queda pendiente de prueba en dispositivo.
//

import Foundation
import Network
import Security
import Synchronization

// MARK: - QUICChannelError

public enum QUICChannelError: Error, Sendable, Equatable {
    case alreadyStarted
    case openFrameRequired
    case closed
    case capacityExceeded
    case concurrentWrite
    case connectionFailed
}

// MARK: - QUICIncomingStream

/// Un stream entrante aceptado por el canal. Sin autenticación ni identidad de
/// peer: con PSK la pertenencia ya está garantizada por el propio cifrado.
public struct QUICIncomingStream: Sendable {
    public let descriptor: ByteStreamDescriptor
    public let stream: ByteStream

    public init(descriptor: ByteStreamDescriptor, stream: ByteStream) {
        self.descriptor = descriptor
        self.stream = stream
    }
}

// MARK: - QUICByteStream

/// Un stream binario de escritura respaldado por una `NWConnection` QUIC
/// bidireccional extraída del grupo multiplexado.
public actor QUICByteStream {
    private var connection: NWConnection?
    private let streamID: UUID
    private var writeTask: Task<Void, Error>?

    init(connection: NWConnection, streamID: UUID) {
        self.connection = connection
        self.streamID = streamID
    }

    deinit { writeTask?.cancel() }

    public func send(_ data: Data) async throws { try await write(.data, data: data) }
    public func finish() async throws { try await write(.finish) }
    public func cancel() async throws { try await write(.cancel) }

    private func write(_ kind: BinaryFrame.Kind, data: Data = Data()) async throws {
        guard let connection else { throw QUICChannelError.closed }
        guard writeTask == nil else { throw QUICChannelError.concurrentWrite }
        let streamID = streamID
        // One cancellable operation, with sequential bounded writes rather than a task per chunk.
        let task = Task {
            if kind == .data {
                var offset = data.startIndex
                while offset < data.endIndex {
                    try Task.checkCancellation()
                    let end = data.index(offset, offsetBy: min(64 * 1024, data.distance(from: offset, to: data.endIndex)))
                    let frame = BinaryFrame(kind: .data, streamID: streamID, payload: Data(data[offset..<end]))
                    try await QUICWire.send(try BinaryFrameCodec.encode(frame), on: connection, isComplete: false)
                    offset = end
                }
            } else {
                let frame = BinaryFrame(kind: kind, streamID: streamID)
                try await QUICWire.send(try BinaryFrameCodec.encode(frame), on: connection, isComplete: true)
            }
        }
        writeTask = task
        defer { writeTask = nil }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard self.connection != nil else { throw QUICChannelError.closed }
            if kind != .data { self.connection = nil }
        } catch {
            self.connection = nil
            throw error
        }
    }

    func close() {
        writeTask?.cancel()
        connection?.cancel()
        connection = nil
    }

    var isClosed: Bool { connection == nil }
}

// MARK: - QUICChannel

/// Streams binarios multiplexados sobre una sesión QUIC cifrada con PSK.
///
/// Un único grupo `NWConnectionGroup` multiplexa todos los streams. Cada stream
/// saliente se abre extrayendo una `NWConnection` del grupo; cada entrante llega
/// por `newConnectionHandler`. El primer frame de cada stream es `.open` con el
/// descriptor; luego `.data`, y finalmente `.finish` o `.cancel`.
public actor QUICChannel {
    private static let applicationProtocol = "nexo-binary-v1"
    private static let maximumOpenBytes = 4096
    private static let maximumStreams = 8

    private let crypto: SessionCrypto
    private let deviceID: DeviceID

    private var group: NWConnectionGroup?
    private var isStarted = false
    private var isClosed = false

    private var receiverTasks: [UUID: Task<Void, Never>] = [:]
    private var sources: [UUID: ByteStream.Source] = [:]
    private var sourceOwners: [UUID: UUID] = [:]
    private var writers: [UUID: QUICByteStream] = [:]
    private var openingTasks: [UUID: Task<QUICByteStream, Error>] = [:]
    private var incomingContinuation: AsyncThrowingStream<QUICIncomingStream, any Error>.Continuation?

    public init(crypto: SessionCrypto, deviceID: DeviceID) {
        self.crypto = crypto
        self.deviceID = deviceID
    }

    deinit {
        for task in receiverTasks.values { task.cancel() }
        for task in openingTasks.values { task.cancel() }
        for writer in writers.values { Task { await writer.close() } }
        for source in sources.values { source.finish(throwing: QUICChannelError.closed) }
        incomingContinuation?.finish()
        group?.cancel()
    }

    // MARK: - Ciclo de vida

    /// Levanta el grupo QUIC-PSK hacia el endpoint y espera a que quede listo.
    /// Para el lado entrante, basta con llamar a `startIncoming()` tras conectar.
    public func connect(to endpoint: NWEndpoint) async throws {
        guard !isClosed else { throw QUICChannelError.closed }
        guard group == nil else { throw QUICChannelError.alreadyStarted }

        let params = Self.makeParameters(crypto: crypto)
        let multiplex = NWMultiplexGroup(to: endpoint)
        let group = NWConnectionGroup(with: multiplex, using: params)
        self.group = group

        group.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.acceptIncoming(connection) }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let box = ContinuationBox(continuation)
            group.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    box.resume(with: .success(()))
                case .failed(let error):
                    box.resume(with: .failure(error))
                    Task { await self?.close() }
                case .cancelled:
                    box.resume(with: .failure(QUICChannelError.closed))
                case .waiting(let error):
                    box.resume(with: .failure(error))
                case .setup:
                    break
                @unknown default:
                    break
                }
            }
            group.start(queue: .global())
        }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        for task in receiverTasks.values { task.cancel() }
        receiverTasks.removeAll()
        for task in openingTasks.values { task.cancel() }
        openingTasks.removeAll()
        for source in sources.values { source.finish(throwing: QUICChannelError.closed) }
        sources.removeAll()
        sourceOwners.removeAll()
        incomingContinuation?.finish(throwing: QUICChannelError.closed)
        incomingContinuation = nil
        let closing = Array(writers.values)
        writers.removeAll()
        for writer in closing { await writer.close() }
        group?.cancel()
        group = nil
    }

    // MARK: - Streams salientes

    public func openStream(_ descriptor: ByteStreamDescriptor) async throws -> QUICByteStream {
        for (id, writer) in writers {
            if await writer.isClosed { writers.removeValue(forKey: id) }
        }
        guard !isClosed, let group else { throw QUICChannelError.closed }
        guard openingTasks.count + writers.count < Self.maximumStreams,
              openingTasks[descriptor.id] == nil, writers[descriptor.id] == nil else {
            throw QUICChannelError.capacityExceeded
        }
        let metadata = try JSONEncoder().encode(descriptor)
        guard metadata.count <= Self.maximumOpenBytes else { throw QUICChannelError.capacityExceeded }

        let task = Task { () async throws -> QUICByteStream in
            try Task.checkCancellation()
            // Cada stream es una NWConnection bidireccional extraída del grupo.
            let streamOptions = NWProtocolQUIC.Options()
            streamOptions.direction = .bidirectional
            guard let connection = group.extract(connectionTo: nil, using: streamOptions) else {
                throw QUICChannelError.connectionFailed
            }
            try await Self.ready(connection)
            try Task.checkCancellation()
            // El primer frame abre el stream con el descriptor.
            let open = BinaryFrame(kind: .open, streamID: descriptor.id, payload: metadata)
            try await QUICWire.send(try BinaryFrameCodec.encode(open), on: connection, isComplete: false)
            try Task.checkCancellation()
            return QUICByteStream(connection: connection, streamID: descriptor.id)
        }
        openingTasks[descriptor.id] = task
        defer { openingTasks.removeValue(forKey: descriptor.id) }
        let writer = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !isClosed else {
            await writer.close()
            throw QUICChannelError.closed
        }
        writers[descriptor.id] = writer
        return writer
    }

    /// Como `openStream`, pero mapea cualquier fallo a `TransportError`, para que
    /// el llamador pueda usar typed throws sin un `catch` que dispara un crash de
    /// SILGen en Swift 6.4 al combinar typed throws + async.
    public func openStreamMapped(_ descriptor: ByteStreamDescriptor) async throws(TransportError) -> QUICByteStream {
        let result: Result<QUICByteStream, any Error>
        do {
            result = .success(try await openStream(descriptor))
        } catch {
            result = .failure(error)
        }
        switch result {
        case .success(let stream): return stream
        case .failure(let error): throw TransportError.connectionFailed(DisconnectReason(error: error))
        }
    }

    // MARK: - Streams entrantes

    /// Consumidor único. Los descriptores sin leer y los streams concurrentes
    /// tienen presupuesto finito.
    public func startIncoming() -> AsyncThrowingStream<QUICIncomingStream, any Error> {
        guard !isStarted, !isClosed, group != nil else {
            return AsyncThrowingStream { $0.finish(throwing: QUICChannelError.closed) }
        }
        isStarted = true
        let pair = AsyncThrowingStream<QUICIncomingStream, any Error>.makeStream(bufferingPolicy: .bufferingOldest(Self.maximumStreams))
        incomingContinuation = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.close() } }
        return pair.stream
    }

    private func acceptIncoming(_ connection: NWConnection) {
        guard !isClosed, incomingContinuation != nil else { connection.cancel(); return }
        guard receiverTasks.count < Self.maximumStreams else { connection.cancel(); return }
        let id = UUID()
        let task = Task { [weak self] () -> Void in
            await self?.runReceiver(connection, receiverID: id)
        }
        receiverTasks[id] = task
    }

    private func runReceiver(_ connection: NWConnection, receiverID: UUID) async {
        var streamID: UUID?
        do {
            try await Self.ready(connection)
            var buffer = Data()
            while !Task.isCancelled {
                let (chunk, isComplete) = try await Self.receive(on: connection)
                if let chunk, !chunk.isEmpty { buffer.append(chunk) }
                while let frame = try BinaryFrameCodec.nextFrame(from: &buffer) {
                    let shouldContinue = try await receive(frame, receiverID: receiverID, streamID: &streamID)
                    if !shouldContinue {
                        receiverEnded(receiverID, streamID: streamID)
                        connection.cancel()
                        return
                    }
                }
                if isComplete {
                    guard buffer.isEmpty else { throw BinaryFrameError.truncated }
                    break
                }
            }
            receiverEnded(receiverID, streamID: streamID)
            connection.cancel()
        } catch {
            receiverEnded(receiverID, streamID: streamID, error: error)
            connection.cancel()
        }
    }

    private func receive(
        _ frame: BinaryFrame, receiverID: UUID, streamID: inout UUID?
    ) async throws -> Bool {
        guard !isClosed else { throw QUICChannelError.closed }
        if streamID == nil {
            guard frame.kind == .open, frame.payload.count <= Self.maximumOpenBytes else {
                throw QUICChannelError.openFrameRequired
            }
            let descriptor = try JSONDecoder().decode(ByteStreamDescriptor.self, from: frame.payload)
            guard descriptor.id == frame.streamID, sources[descriptor.id] == nil,
                  sources.count < Self.maximumStreams else { throw QUICChannelError.capacityExceeded }
            let pair = ByteStream.makeStream(bufferingPolicy: .bufferingOldest(8))
            pair.source.setOnTermination { [weak self] termination in
                guard case .cancelled = termination else { return }
                Task { await self?.cancelReceiver(receiverID, streamID: descriptor.id) }
            }
            sources[descriptor.id] = pair.source
            sourceOwners[descriptor.id] = receiverID
            streamID = descriptor.id
            let accepted = QUICIncomingStream(descriptor: descriptor, stream: pair.stream)
            guard let result = incomingContinuation?.yield(accepted), case .enqueued = result else {
                throw QUICChannelError.capacityExceeded
            }
            return true
        }
        guard frame.streamID == streamID, sourceOwners[frame.streamID] == receiverID,
              let source = sources[frame.streamID] else {
            throw QUICChannelError.openFrameRequired
        }
        switch frame.kind {
        case .data:
            guard case .enqueued = source.yield(frame.payload) else { throw QUICChannelError.capacityExceeded }
            return true
        case .finish:
            source.finish()
        case .cancel:
            source.finish(throwing: QUICChannelError.closed)
        case .open:
            throw QUICChannelError.openFrameRequired
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

    private func receiverEnded(_ id: UUID, streamID: UUID?, error: (any Error)? = nil) {
        receiverTasks.removeValue(forKey: id)
        if let streamID, sourceOwners[streamID] == id {
            sourceOwners.removeValue(forKey: streamID)
            sources.removeValue(forKey: streamID)?.finish(throwing: error ?? QUICChannelError.closed)
        }
    }

    // MARK: - Parámetros QUIC-PSK

    /// Opciones QUIC con la PSK derivada del secreto de app + código de sala.
    ///
    /// Mismo patrón que `NetworkTransport.makeTLSOptions`: PSK + identidad como
    /// `DispatchData` y suite `TLS_PSK_WITH_AES_128_GCM_SHA256`. QUIC exige TLS
    /// 1.3, de ahí la nota de riesgo de cabecera.
    private static func makeParameters(crypto: SessionCrypto) -> NWParameters {
        let quic = NWProtocolQUIC.Options(alpn: [applicationProtocol])
        quic.initialMaxStreamsBidirectional = maximumStreams
        quic.initialMaxStreamsUnidirectional = 0

        let security = quic.securityProtocolOptions
        let pskData = crypto.psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = Data(crypto.pskHint.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(
            security,
            pskData as __DispatchData,
            identityData as __DispatchData
        )
        sec_protocol_options_append_tls_ciphersuite(
            security,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        )

        let params = NWParameters(quic: quic)
        params.includePeerToPeer = true
        return params
    }

    // MARK: - Helpers de NWConnection

    /// Arranca una `NWConnection` extraída/entrante y espera a que quede lista.
    private static func ready(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let box = ContinuationBox(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.resume(with: .success(()))
                case .failed(let error):
                    box.resume(with: .failure(error))
                case .cancelled:
                    box.resume(with: .failure(QUICChannelError.closed))
                case .waiting(let error):
                    box.resume(with: .failure(error))
                case .setup, .preparing:
                    break
                @unknown default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }

    /// Recibe el siguiente bloque de bytes de una `NWConnection` QUIC.
    private static func receive(on connection: NWConnection) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data?, Bool), any Error>) in
            let box = ContinuationBox(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { content, _, isComplete, error in
                if let error {
                    box.resume(with: .failure(error))
                } else {
                    box.resume(with: .success((content, isComplete)))
                }
            }
        }
    }
}

// MARK: - ContinuationBox

/// Garantiza un único resume aunque un handler de estado se dispare varias veces.
/// `NWConnection`/`NWConnectionGroup` pueden invocar `stateUpdateHandler` más de
/// una vez, y reanudar una continuation dos veces es un fallo fatal.
///
/// Sin `@unchecked Sendable`: el estado mutable (la continuation) vive dentro de
/// un `Mutex`, que es `Sendable` de verdad. `CheckedContinuation` ya es
/// `Sendable`.
private final class ContinuationBox<T: Sendable>: Sendable {
    private let storage: Mutex<CheckedContinuation<T, any Error>?>

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.storage = Mutex(continuation)
    }

    func resume(with result: Result<T, any Error>) {
        let pending = storage.withLock { current -> CheckedContinuation<T, any Error>? in
            let value = current
            current = nil
            return value
        }
        pending?.resume(with: result)
    }
}

// MARK: - QUICWire

/// Helpers de E/S sobre `NWConnection` compartidos por el canal y sus streams.
enum QUICWire {
    /// Envía un bloque por la `NWConnection` y espera a que el stack lo procese.
    static func send(_ data: Data, on connection: NWConnection, isComplete: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: data,
                contentContext: .defaultMessage,
                isComplete: isComplete,
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
}
