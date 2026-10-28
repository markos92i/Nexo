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
