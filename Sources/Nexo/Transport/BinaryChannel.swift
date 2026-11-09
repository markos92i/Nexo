//
//  BinaryChannel.swift
//  Nexo
//
//  Streams binarios de alta velocidad sobre una conexión TCP dedicada, cifrada
//  con la misma TLS-PSK que la conexión de control.
//
//  Por qué no QUIC: con una PSK externa, el TLS de Apple solo negocia TLS 1.2, y
//  QUIC exige TLS 1.3. El handshake falla siempre con
//  `NO_SUPPORTED_VERSIONS_ENABLED` (comprobado en macOS 27 por loopback). Una
//  segunda conexión TCP por peer mantiene la ventaja que importaba: el volumen
//  binario no comparte cola ni socket con el control y el chat.
//

import Foundation

// MARK: - ByteStreamError

public enum ByteStreamError: Error, Sendable, Equatable {
    /// El canal o el stream se cerró.
    case closed
    /// Se superó el número de streams simultáneos o el tamaño de apertura.
    case capacityExceeded
    /// Ya hay una escritura en curso en este stream.
    case concurrentWrite
    /// El peer envió un frame que no respeta el protocolo.
    case protocolViolation
}

// MARK: - IncomingByteStream

/// Un stream binario que un peer nos abrió. Se consume con `for try await`.
public struct IncomingByteStream: Sendable {
    public let descriptor: ByteStreamDescriptor
    public let senderDeviceID: DeviceID
    public let stream: ByteStream

    public init(descriptor: ByteStreamDescriptor, senderDeviceID: DeviceID, stream: ByteStream) {
        self.descriptor = descriptor
        self.senderDeviceID = senderDeviceID
        self.stream = stream
    }
}

// MARK: - ByteStreamWriter

/// Lado de escritura de un stream binario. Las escrituras son secuenciales: cada
/// `send` vuelve cuando el sistema ha aceptado los bytes, lo que da
/// contrapresión natural al productor.
public actor ByteStreamWriter {
    public nonisolated let descriptor: ByteStreamDescriptor
    private let channel: BinaryChannel
    private var isFinished = false
    private var isWriting = false

    init(descriptor: ByteStreamDescriptor, channel: BinaryChannel) {
        self.descriptor = descriptor
        self.channel = channel
    }

    /// Envía bytes. Los bloques grandes se trocean en frames de 64 KB.
    public func send(_ data: Data) async throws {
        guard !isFinished else { throw ByteStreamError.closed }
        guard !isWriting else { throw ByteStreamError.concurrentWrite }
        isWriting = true
        defer { isWriting = false }

        var offset = data.startIndex
        while offset < data.endIndex {
            try Task.checkCancellation()
            let length = min(BinaryChannel.chunkBytes, data.distance(from: offset, to: data.endIndex))
            let end = data.index(offset, offsetBy: length)
            try await channel.write(BinaryFrame(kind: .data, streamID: descriptor.id, payload: Data(data[offset..<end])))
            offset = end
        }
    }

    /// Cierra el stream con éxito: el lector termina su `for try await`.
    public func finish() async throws {
        guard !isFinished else { return }
        guard !isWriting else { throw ByteStreamError.concurrentWrite }
        isFinished = true
        defer { Task { await channel.writerEnded(descriptor.id) } }
        try await channel.write(BinaryFrame(kind: .finish, streamID: descriptor.id))
    }

    /// Aborta el stream: el lector recibe un error.
    public func cancel() async {
        guard !isFinished else { return }
        isFinished = true
        try? await channel.write(BinaryFrame(kind: .cancel, streamID: descriptor.id))
        await channel.writerEnded(descriptor.id)
    }
}

// MARK: - BinaryChannel

/// Multiplexa streams binarios en ambos sentidos sobre una conexión física.
///
/// No conoce Network framework: recibe una función para escribir un frame y otra
/// para cerrar la conexión, y el transporte le entrega cada mensaje recibido.
/// Protocolo: `.open` con el descriptor JSON, luego `.data`, y por último
/// `.finish` o `.cancel`. Un `.cancel` del lector detiene al escritor remoto.
actor BinaryChannel {
    static let chunkBytes = 64 * 1024
    static let maximumStreams = 8
    static let maximumOpenBytes = 4096
    /// Trozos que un lector lento puede acumular antes de que su stream se
    /// cancele (unos 16 MB). Cancelar uno no afecta al resto del canal.
    static let incomingBufferChunks = 256

    nonisolated let peerDeviceID: DeviceID

    private let writeFrame: @Sendable (Data) async throws -> Void
    private let onIncoming: @Sendable (IncomingByteStream) -> Void
    private let onClose: @Sendable () -> Void

    private var sources: [UUID: ByteStream.Source] = [:]
    private var openWriters: Set<UUID> = []
    private var cancelledWriters: Set<UUID> = []
    private(set) var isClosed = false

    init(
        peerDeviceID: DeviceID,
        writeFrame: @escaping @Sendable (Data) async throws -> Void,
        onIncoming: @escaping @Sendable (IncomingByteStream) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) {
        self.peerDeviceID = peerDeviceID
        self.writeFrame = writeFrame
        self.onIncoming = onIncoming
        self.onClose = onClose
    }

    // MARK: Escritura

    func openStream(_ descriptor: ByteStreamDescriptor) async throws -> ByteStreamWriter {
        guard !isClosed else { throw ByteStreamError.closed }
        guard openWriters.count < Self.maximumStreams, !openWriters.contains(descriptor.id) else {
            throw ByteStreamError.capacityExceeded
        }
        let metadata = try JSONEncoder().encode(descriptor)
        guard metadata.count <= Self.maximumOpenBytes else { throw ByteStreamError.capacityExceeded }

        openWriters.insert(descriptor.id)
        do {
            try await write(BinaryFrame(kind: .open, streamID: descriptor.id, payload: metadata))
        } catch {
            openWriters.remove(descriptor.id)
            throw error
        }
        return ByteStreamWriter(descriptor: descriptor, channel: self)
    }

    /// Como `openStream`, pero con el error ya traducido a `TransportError`. Se
    /// mapea con un `Result` porque typed throws + async + `catch` dispara un
    /// fallo de SILGen en Swift 6.4.
    func openStreamMapped(_ descriptor: ByteStreamDescriptor) async throws(TransportError) -> ByteStreamWriter {
        let result: Result<ByteStreamWriter, any Error>
        do {
            result = .success(try await openStream(descriptor))
        } catch {
            result = .failure(error)
        }
        switch result {
        case .success(let writer): return writer
        case .failure(let error): throw TransportError.connectionFailed(DisconnectReason(error: error))
        }
    }

    func write(_ frame: BinaryFrame) async throws {
        guard !isClosed else { throw ByteStreamError.closed }
        guard !cancelledWriters.contains(frame.streamID) else { throw ByteStreamError.closed }
        let data = try BinaryFrameCodec.encode(frame)
        do {
            try await writeFrame(data)
        } catch {
            close()
            throw ByteStreamError.closed
        }
    }

    func writerEnded(_ id: UUID) {
        openWriters.remove(id)
        cancelledWriters.remove(id)
    }

    // MARK: Lectura

    /// Procesa un mensaje recibido. El transporte espera a que vuelva antes de
    /// leer el siguiente, así que el orden de los frames se conserva.
    func receive(_ data: Data) async {
        guard !isClosed else { return }
        guard let frame = try? BinaryFrameCodec.decode(data) else {
            close()
            return
        }

        switch frame.kind {
        case .open:
            guard sources[frame.streamID] == nil,
                  sources.count < Self.maximumStreams,
                  frame.payload.count <= Self.maximumOpenBytes,
                  let descriptor = try? JSONDecoder().decode(ByteStreamDescriptor.self, from: frame.payload),
                  descriptor.id == frame.streamID
            else {
                try? await write(BinaryFrame(kind: .cancel, streamID: frame.streamID))
                return
            }
            let id = frame.streamID
            let pair = ByteStream.makeStream(bufferingPolicy: .bufferingOldest(Self.incomingBufferChunks))
            pair.source.setOnTermination { [weak self] termination in
                guard case .cancelled = termination else { return }
                Task { await self?.readerCancelled(id) }
            }
            sources[id] = pair.source
            onIncoming(IncomingByteStream(descriptor: descriptor, senderDeviceID: peerDeviceID, stream: pair.stream))

        case .data:
            // Un stream ya descartado puede tener frames en vuelo: se ignoran.
            guard let source = sources[frame.streamID] else { return }
            if case .dropped = source.yield(frame.payload) {
                sources.removeValue(forKey: frame.streamID)
                try? await write(BinaryFrame(kind: .cancel, streamID: frame.streamID))
            }

        case .finish:
            sources.removeValue(forKey: frame.streamID)?.finish()

        case .cancel:
            if let source = sources.removeValue(forKey: frame.streamID) {
                source.finish(throwing: ByteStreamError.closed)
            } else if openWriters.contains(frame.streamID) {
                // El lector remoto dejó de leer: el escritor local debe parar.
                cancelledWriters.insert(frame.streamID)
            }
        }
    }

    private func readerCancelled(_ id: UUID) async {
        guard sources.removeValue(forKey: id) != nil else { return }
        try? await write(BinaryFrame(kind: .cancel, streamID: id))
    }

    // MARK: Cierre

    func close() {
        guard !isClosed else { return }
        isClosed = true
        for source in sources.values { source.finish(throwing: ByteStreamError.closed) }
        sources.removeAll()
        openWriters.removeAll()
        cancelledWriters.removeAll()
        onClose()
    }
}

// MARK: - ByteStreamDescriptor

/// Metadatos de un stream binario. El payload es independiente de chat, salas y
/// archivos a propósito, así que la misma API puede llevar estado de juego, media
/// o datos.
public struct ByteStreamDescriptor: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let roomID: RoomID
    public let mimeType: String
    public let name: String?
    public let expectedLength: Int64?

    public init(
        id: UUID = UUID(),
        roomID: RoomID,
        mimeType: String = "application/octet-stream",
        name: String? = nil,
        expectedLength: Int64? = nil
    ) {
        self.id = id
        self.roomID = roomID
        self.mimeType = mimeType
        self.name = name
        self.expectedLength = expectedLength
    }
}

// MARK: - ByteStream

/// Un flujo cancelable de trozos de bytes que se consume con `for try await`.
public struct ByteStream: AsyncSequence, Sendable {
    public typealias Element = Data
    public typealias AsyncIterator = AsyncThrowingStream<Data, any Error>.AsyncIterator

    private let base: AsyncThrowingStream<Data, any Error>

    private init(base: AsyncThrowingStream<Data, any Error>) {
        self.base = base
    }

    public static func makeStream(
        bufferingPolicy: AsyncThrowingStream<Data, any Error>.Continuation.BufferingPolicy = .bufferingOldest(8)
    ) -> (stream: ByteStream, source: Source) {
        let pair = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: bufferingPolicy)
        return (ByteStream(base: pair.stream), Source(continuation: pair.continuation))
    }

    public func makeAsyncIterator() -> AsyncIterator {
        base.makeAsyncIterator()
    }

    // MARK: - Source

    /// Lado productor del stream. Finalizar la fuente termina el stream; la
    /// cancelación se propaga cuando el consumidor deja de iterar.
    ///
    /// `AsyncThrowingStream.Continuation` ya es `Sendable` y segura frente a
    /// accesos concurrentes, así que `Source` es `Sendable` sin candados: solo
    /// envuelve la continuation. La detección de overflow se hace en el propio
    /// `yield` (fallo cerrado) sin estado mutable compartido.
    public struct Source: Sendable {
        private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

        init(continuation: AsyncThrowingStream<Data, any Error>.Continuation) {
            self.continuation = continuation
        }

        @discardableResult
        public func yield(_ data: Data) -> AsyncThrowingStream<Data, any Error>.Continuation.YieldResult {
            let result = continuation.yield(data)
            // Un productor síncrono no puede suspender; la pérdida debe fallar cerrado.
            if case .dropped = result {
                continuation.finish(throwing: FileTransferError.bufferOverflow)
            }
            return result
        }

        public func finish() {
            continuation.finish()
        }

        public func finish(throwing error: any Error) {
            continuation.finish(throwing: error)
        }

        public func setOnTermination(
            _ handler: @escaping @Sendable (AsyncThrowingStream<Data, any Error>.Continuation.Termination) -> Void
        ) {
            continuation.onTermination = handler
        }
    }
}

// MARK: - BinaryFrame

/// Framing binario de un canal de alto rendimiento. Evita el overhead de
/// JSON/Base64 y mantiene el framing separado del protocolo de envelopes.
public struct BinaryFrame: Sendable, Equatable {
    public enum Kind: UInt8, Sendable {
        case open = 1
        case data = 2
        case finish = 3
        case cancel = 4
    }

    public let kind: Kind
    public let streamID: UUID
    public let payload: Data

    public init(kind: Kind, streamID: UUID, payload: Data = Data()) {
        self.kind = kind
        self.streamID = streamID
        self.payload = payload
    }
}

public enum BinaryFrameError: Error, Sendable, Equatable {
    case truncated
    case invalidLength
    case invalidKind(UInt8)
    case oversized(Int)
}

// MARK: - BinaryFrameCodec

public enum BinaryFrameCodec {
    public static let maximumFrameBytes = 4 * 1024 * 1024
    private static let headerBytes = 4 + 1 + 16

    /// Codifica un frame completo: prefijo de longitud (4 bytes big-endian),
    /// luego kind, UUID y payload.
    public static func encode(_ frame: BinaryFrame) throws(BinaryFrameError) -> Data {
        let bodyLength = 1 + 16 + frame.payload.count
        guard bodyLength <= maximumFrameBytes else { throw .oversized(bodyLength) }

        var data = Data()
        data.reserveCapacity(4 + bodyLength)
        data.append(contentsOf: UInt32(bodyLength).bigEndianBytes)
        data.append(frame.kind.rawValue)
        withUnsafeBytes(of: frame.streamID.uuid) { data.append(contentsOf: $0) }
        data.append(frame.payload)
        return data
    }

    /// Decodifica un frame y rechaza bytes sobrantes, para que quien llama pueda
    /// decidir con seguridad si el transporte entregó un mensaje o un buffer parcial.
    public static func decode(_ data: Data) throws(BinaryFrameError) -> BinaryFrame {
        guard data.count >= headerBytes else { throw .truncated }

        let bodyLength = Int(data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard bodyLength >= 17 else { throw .invalidLength }
        guard bodyLength <= maximumFrameBytes else { throw .oversized(bodyLength) }
        guard data.count == bodyLength + 4 else { throw .truncated }

        guard let kind = BinaryFrame.Kind(rawValue: data[4]) else {
            throw .invalidKind(data[4])
        }

        let uuidStart = data.index(data.startIndex, offsetBy: 5)
        let uuidEnd = data.index(uuidStart, offsetBy: 16)
        let uuidBytes = Data(data[uuidStart..<uuidEnd])
        let uuid = uuidBytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }

        return BinaryFrame(
            kind: kind,
            streamID: uuid,
            payload: Data(data[data.index(data.startIndex, offsetBy: 21)...])
        )
    }

    /// Extrae el siguiente frame completo de un buffer de bytes, o `nil` si aún no
    /// está completo. Consume del buffer lo leído.
    static func nextFrame(from buffer: inout Data, maximumPayload: Int = 64 * 1024) throws(BinaryFrameError) -> BinaryFrame? {
        guard buffer.count >= 4 else { return nil }
        let length = Int(buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard length >= 17 else { throw .invalidLength }
        guard length <= maximumPayload + 17 else { throw .oversized(length) }
        guard buffer.count >= length + 4 else { return nil }
        let frame = try decode(Data(buffer.prefix(length + 4)))
        buffer = Data(buffer.dropFirst(length + 4))
        return frame
    }
}

private extension UInt32 {
    var bigEndianBytes: [UInt8] {
        [UInt8((self >> 24) & 0xff), UInt8((self >> 16) & 0xff), UInt8((self >> 8) & 0xff), UInt8(self & 0xff)]
    }
}
