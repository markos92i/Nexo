//
//  NexoByteStream.swift
//  Nexo
//

import Foundation

// MARK: - NexoStreamDescriptor

/// Metadata for a binary stream. The payload is intentionally independent of
/// chat, rooms and files, so the same API can carry game state, media or data.
public struct NexoStreamDescriptor: Codable, Sendable, Equatable, Identifiable {
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

// MARK: - NexoByteStream

/// A cancellable stream of byte chunks consumed with `for try await`.
public struct NexoByteStream: AsyncSequence, Sendable {
    public typealias Element = Data
    public typealias AsyncIterator = AsyncThrowingStream<Data, Error>.AsyncIterator

    private let base: AsyncThrowingStream<Data, Error>

    private init(
        base: AsyncThrowingStream<Data, Error>
    ) {
        self.base = base
    }

    public static func makeStream(
        bufferingPolicy: AsyncThrowingStream<Data, Error>.Continuation.BufferingPolicy = .bufferingOldest(8)
    ) -> (stream: NexoByteStream, source: Source) {
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: bufferingPolicy)
        return (NexoByteStream(base: pair.stream), Source(continuation: pair.continuation))
    }

    public func makeAsyncIterator() -> AsyncIterator {
        base.makeAsyncIterator()
    }

    /// Producer side of a byte stream. Finishing the source ends the stream;
    /// cancellation is propagated when the consumer stops iterating.
    public final class Source: @unchecked Sendable {
        private let continuation: AsyncThrowingStream<Data, Error>.Continuation
        // Serialize yield/finish so a racing finish cannot hide overflow. Recursive
        // because AsyncStream can invoke a client's termination handler inline.
        private let lock = NSRecursiveLock()

        fileprivate init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
            self.continuation = continuation
        }

        @discardableResult
        public func yield(_ data: Data) -> AsyncThrowingStream<Data, Error>.Continuation.YieldResult {
            lock.lock()
            defer { lock.unlock() }
            let result = continuation.yield(data)
            // Existing synchronous producers cannot suspend; loss must fail closed.
            if case .dropped = result {
                continuation.finish(throwing: FileTransferError.bufferOverflow)
            }
            return result
        }

        public func finish() {
            lock.lock()
            defer { lock.unlock() }
            continuation.finish()
        }

        public func finish(throwing error: any Error) {
            lock.lock()
            defer { lock.unlock() }
            continuation.finish(throwing: error)
        }

        public var onTermination: (@Sendable (AsyncThrowingStream<Data, Error>.Continuation.Termination) -> Void)? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return continuation.onTermination
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                continuation.onTermination = newValue
            }
        }
    }
}

// MARK: - NexoBinaryFrame

/// Binary framing used by a bulk channel. It avoids JSON/Base64 overhead and
/// keeps framing separate from the room envelope protocol.
public struct NexoBinaryFrame: Sendable, Equatable {
    public enum Kind: UInt8, Sendable {
        case open = 1
        case data = 2
        case finish = 3
        case cancel = 4
        case handshake = 5
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

public enum NexoBinaryFrameError: Error, Sendable, Equatable {
    case truncated
    case invalidLength
    case invalidKind(UInt8)
    case oversized(Int)
}

// MARK: - NexoBinaryFrameCodec

public enum NexoBinaryFrameCodec {
    public static let maximumFrameBytes = 4 * 1024 * 1024
    private static let headerBytes = 4 + 1 + 16

    /// Encodes one complete frame as a 4-byte big-endian length prefix,
    /// followed by kind, UUID and payload.
    public static func encode(_ frame: NexoBinaryFrame) throws -> Data {
        let bodyLength = 1 + 16 + frame.payload.count
        guard bodyLength <= maximumFrameBytes else {
            throw NexoBinaryFrameError.oversized(bodyLength)
        }

        var data = Data()
        data.reserveCapacity(4 + bodyLength)
        data.append(contentsOf: UInt32(bodyLength).bigEndianBytes)
        data.append(frame.kind.rawValue)
        withUnsafeBytes(of: frame.streamID.uuid) { uuidBytes in
            data.append(contentsOf: uuidBytes)
        }
        data.append(frame.payload)
        return data
    }

    /// Decodes one frame and rejects trailing bytes so callers can safely
    /// decide whether a transport delivered one message or a partial buffer.
    public static func decode(_ data: Data) throws -> NexoBinaryFrame {
        guard data.count >= headerBytes else { throw NexoBinaryFrameError.truncated }

        let bodyLength = Int(data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard bodyLength >= 17 else { throw NexoBinaryFrameError.invalidLength }
        guard bodyLength <= maximumFrameBytes else { throw NexoBinaryFrameError.oversized(bodyLength) }
        guard data.count == bodyLength + 4 else { throw NexoBinaryFrameError.truncated }

        guard let kind = NexoBinaryFrame.Kind(rawValue: data[4]) else {
            throw NexoBinaryFrameError.invalidKind(data[4])
        }

        let uuidStart = data.index(data.startIndex, offsetBy: 5)
        let uuidEnd = data.index(uuidStart, offsetBy: 16)
        let uuidBytes = Data(data[uuidStart..<uuidEnd])
        let uuid = uuidBytes.withUnsafeBytes { bytes in
            UUID(uuid: bytes.loadUnaligned(as: uuid_t.self))
        }

        return NexoBinaryFrame(
            kind: kind,
            streamID: uuid,
            payload: Data(data[data.index(data.startIndex, offsetBy: 21)...])
        )
    }
}

// MARK: - NexoBinaryStreamChannel

/// Adapts binary frames to async byte streams. A future QUIC transport can
/// feed this channel directly from a QUIC stream without changing consumers.
public actor NexoBinaryStreamChannel {
    private var sources: [UUID: NexoByteStream.Source] = [:]

    public init() {}

    public func openIncoming(_ descriptor: NexoStreamDescriptor) -> NexoByteStream {
        let pair = NexoByteStream.makeStream()
        sources.removeValue(forKey: descriptor.id)?.finish(throwing: FileTransferError.cancelled)
        sources[descriptor.id] = pair.source
        pair.source.onTermination = { [weak self, weak source = pair.source] _ in
            guard let source else { return }
            Task { await self?.remove(descriptor.id, source: source) }
        }
        return pair.stream
    }

    public func receive(_ frame: NexoBinaryFrame) {
        guard let source = sources[frame.streamID] else { return }

        switch frame.kind {
        case .open:
            break
        case .data:
            switch source.yield(frame.payload) {
            case .enqueued: break
            case .dropped, .terminated:
                sources.removeValue(forKey: frame.streamID)
            @unknown default:
                source.finish(throwing: FileTransferError.bufferOverflow)
                sources.removeValue(forKey: frame.streamID)
            }
        case .finish:
            source.finish()
            sources.removeValue(forKey: frame.streamID)
        case .cancel:
            source.finish(throwing: FileTransferError.cancelled)
            sources.removeValue(forKey: frame.streamID)
        case .handshake:
            break
        }
    }

    public func cancel(_ streamID: UUID) {
        sources.removeValue(forKey: streamID)?.finish(throwing: FileTransferError.cancelled)
    }

    private func remove(_ streamID: UUID, source: NexoByteStream.Source) {
        guard sources[streamID] === source else { return }
        sources.removeValue(forKey: streamID)
    }

    deinit {
        for source in sources.values {
            source.finish(throwing: FileTransferError.cancelled)
        }
    }
}

// MARK: - NexoBinaryStreamFrames

public enum NexoBinaryStreamFrames {
    /// Converts a byte stream into open/data/finish frames. The caller owns
    /// the returned async sequence and can cancel it to stop reading bytes.
    public static func make(
        descriptor: NexoStreamDescriptor,
        from stream: NexoByteStream
    ) -> AsyncThrowingStream<NexoBinaryFrame, Error> {
        let pair = AsyncThrowingStream<NexoBinaryFrame, Error>.makeStream(bufferingPolicy: .bufferingOldest(8))

        let task = Task {
            do {
                let metadata = try JSONEncoder().encode(descriptor)
                try yield(NexoBinaryFrame(kind: .open, streamID: descriptor.id, payload: metadata), to: pair.continuation)
                for try await chunk in stream {
                    try Task.checkCancellation()
                    try yield(NexoBinaryFrame(kind: .data, streamID: descriptor.id, payload: chunk), to: pair.continuation)
                }
                try Task.checkCancellation()
                try yield(NexoBinaryFrame(kind: .finish, streamID: descriptor.id), to: pair.continuation)
                pair.continuation.finish()
            } catch {
                try? yield(NexoBinaryFrame(kind: .cancel, streamID: descriptor.id), to: pair.continuation)
                pair.continuation.finish(throwing: error)
            }
        }
        pair.continuation.onTermination = { _ in task.cancel() }
        return pair.stream
    }

    private static func yield(
        _ frame: NexoBinaryFrame,
        to continuation: AsyncThrowingStream<NexoBinaryFrame, Error>.Continuation
    ) throws(FileTransferError) {
        switch continuation.yield(frame) {
        case .enqueued: break
        case .dropped: throw .bufferOverflow
        case .terminated: throw .cancelled
        @unknown default: throw .bufferOverflow
        }
    }
}

private extension UInt32 {
    var bigEndianBytes: [UInt8] {
        [
            UInt8((self >> 24) & 0xff),
            UInt8((self >> 16) & 0xff),
            UInt8((self >> 8) & 0xff),
            UInt8(self & 0xff)
        ]
    }
}