import Foundation

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
