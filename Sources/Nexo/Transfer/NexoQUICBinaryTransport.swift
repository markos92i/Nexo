//
//  NexoQUICBinaryTransport.swift
//  Nexo
//

import Foundation
import Network

// MARK: - NexoQUICIncomingStream

public struct NexoQUICIncomingStream: Sendable {
    public let descriptor: NexoStreamDescriptor
    public let stream: NexoByteStream
    public let peerApplicationID: String

    public init(
        descriptor: NexoStreamDescriptor,
        stream: NexoByteStream,
        peerApplicationID: String
    ) {
        self.descriptor = descriptor
        self.stream = stream
        self.peerApplicationID = peerApplicationID
    }
}

public struct NexoPeerBinaryStream: Sendable {
    public let peer: ConnectedPeer
    public let descriptor: NexoStreamDescriptor
    public let stream: NexoByteStream

    public init(
        peer: ConnectedPeer,
        descriptor: NexoStreamDescriptor,
        stream: NexoByteStream
    ) {
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

// MARK: - NexoQUICByteStream

/// A writable binary stream backed by one QUIC bidirectional stream.
public actor NexoQUICByteStream {
    private let stream: QUIC.Stream<QUICStream>
    private let streamID: UUID
    private var isFinished = false

    fileprivate init(stream: QUIC.Stream<QUICStream>, streamID: UUID) {
        self.stream = stream
        self.streamID = streamID
    }

    public func send(_ data: Data) async throws {
        guard !isFinished else { throw CancellationError() }
        let frame = NexoBinaryFrame(kind: .data, streamID: streamID, payload: data)
        try await stream.send(try NexoBinaryFrameCodec.encode(frame), endOfStream: false)
    }

    public func finish() async throws {
        guard !isFinished else { return }
        isFinished = true
        let frame = NexoBinaryFrame(kind: .finish, streamID: streamID)
        try await stream.send(try NexoBinaryFrameCodec.encode(frame), endOfStream: true)
    }

    public func cancel() async throws {
        guard !isFinished else { return }
        isFinished = true
        let frame = NexoBinaryFrame(kind: .cancel, streamID: streamID)
        try await stream.send(try NexoBinaryFrameCodec.encode(frame), endOfStream: true)
    }

}

// MARK: - NexoQUICBinaryTransport

/// Binary stream adapter for an existing `NetworkConnection<QUIC>`.
///
/// The owner is responsible for creating and authenticating the QUIC
/// connection. This type owns only the multiplexed binary streams on it.
public actor NexoQUICBinaryTransport {
    private static let applicationProtocol = "nexo-binary-v1"
    private static let maximumHandshakeBytes = 4096

    private let connection: NetworkConnection<QUIC>
    private let applicationID: String
    private let expectedRemoteApplicationID: String?
    private let channel = NexoBinaryStreamChannel()
    private var inboundTask: Task<Void, Never>?
    private var incomingContinuation: AsyncThrowingStream<NexoQUICIncomingStream, Error>.Continuation?
    private var isStarted = false
    private var authenticatedRemoteApplicationID: String?
    private var authenticationInProgress = false
    private var authenticationWaiters: [CheckedContinuation<String, Error>] = []

    public init(
        connection: NetworkConnection<QUIC>,
        applicationID: String,
        expectedRemoteApplicationID: String? = nil
    ) {
        self.connection = connection
        self.applicationID = applicationID
        self.expectedRemoteApplicationID = expectedRemoteApplicationID
    }

    /// Creates a QUIC binary transport to a discovered Bonjour endpoint.
    public static func connect(
        to endpoint: NWEndpoint,
        applicationID: String,
        expectedRemoteApplicationID: String? = nil,
        tlsConfiguration: NexoTLSConfiguration? = nil
    ) -> NexoQUICBinaryTransport {
        let connection = NetworkConnection<QUIC>(
            to: endpoint,
            using: makeParameters(tlsConfiguration: tlsConfiguration)
        )
        return NexoQUICBinaryTransport(
            connection: connection,
            applicationID: applicationID,
            expectedRemoteApplicationID: expectedRemoteApplicationID
        )
    }

    deinit {
        inboundTask?.cancel()
        incomingContinuation?.finish()
    }

    /// Opens a bidirectional QUIC stream and sends its descriptor frame first.
    public func openStream(_ descriptor: NexoStreamDescriptor) async throws -> NexoQUICByteStream {
        _ = try await authenticateIfNeeded()
        let stream = try await connection.openStream(directionality: .bidirectional)
        let frame = NexoBinaryFrame(
            kind: .open,
            streamID: descriptor.id,
            payload: try JSONEncoder().encode(descriptor)
        )
        try await stream.send(try NexoBinaryFrameCodec.encode(frame), endOfStream: false)
        return NexoQUICByteStream(stream: stream, streamID: descriptor.id)
    }

    /// Starts accepting incoming QUIC streams. Call this once per connection.
    public func startIncoming() -> AsyncThrowingStream<NexoQUICIncomingStream, Error> {
        guard !isStarted else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: NexoQUICBinaryTransportError.alreadyStarted)
            }
        }

        isStarted = true
        let pair = AsyncThrowingStream<NexoQUICIncomingStream, Error>.makeStream()
        incomingContinuation = pair.continuation
        inboundTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.connection.inboundStreams { stream in
                    Task { await self.receive(stream) }
                }
                pair.continuation.finish()
            } catch is CancellationError {
                pair.continuation.finish()
            } catch {
                pair.continuation.finish(throwing: error)
            }
        }
        return pair.stream
    }

    private func receive(_ stream: QUIC.Stream<QUICStream>) async {
        var buffer = Data()
        var incoming: NexoQUICIncomingStream?

        do {
            while true {
                let message = try await stream.receive(atLeast: 1, atMost: NexoBinaryFrameCodec.maximumFrameBytes + 21)
                buffer.append(message.content)

                while let frame = try nextFrame(from: &buffer) {
                    if incoming == nil {
                        if frame.kind == .handshake {
                            try await receiveHandshake(frame, on: stream)
                            return
                        }

                        _ = try await waitForAuthentication()
                        guard frame.kind == .open else {
                            throw NexoQUICBinaryTransportError.openFrameRequired
                        }

                        let descriptor = try JSONDecoder().decode(NexoStreamDescriptor.self, from: frame.payload)
                        let byteStream = await channel.openIncoming(descriptor)
                        guard let peerApplicationID = authenticatedRemoteApplicationID else {
                            throw NexoQUICBinaryTransportError.handshakeRequired
                        }
                        let accepted = NexoQUICIncomingStream(
                            descriptor: descriptor,
                            stream: byteStream,
                            peerApplicationID: peerApplicationID
                        )
                        incoming = accepted
                        incomingContinuation?.yield(accepted)
                    } else {
                        await channel.receive(frame)
                    }
                }

                if message.metadata.endOfStream {
                    guard buffer.isEmpty else { throw NexoBinaryFrameError.truncated }
                    if let incoming {
                        await channel.cancel(incoming.descriptor.id)
                    }
                    return
                }
            }
        } catch {
            if let incoming {
                await channel.cancel(incoming.descriptor.id)
            }
        }
    }

    private func nextFrame(from buffer: inout Data) throws -> NexoBinaryFrame? {
        guard buffer.count >= 4 else { return nil }
        let bodyLength = Int(buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard bodyLength >= 17 else { throw NexoBinaryFrameError.invalidLength }
        guard bodyLength <= NexoBinaryFrameCodec.maximumFrameBytes else {
            throw NexoBinaryFrameError.oversized(bodyLength)
        }

        let frameLength = bodyLength + 4
        guard buffer.count >= frameLength else { return nil }
        let frameData = Data(buffer.prefix(frameLength))
        buffer = Data(buffer.dropFirst(frameLength))
        return try NexoBinaryFrameCodec.decode(frameData)
    }

    private func authenticateIfNeeded() async throws -> String {
        if let authenticatedRemoteApplicationID {
            return authenticatedRemoteApplicationID
        }

        if authenticationInProgress {
            return try await withCheckedThrowingContinuation { continuation in
                authenticationWaiters.append(continuation)
            }
        }

        authenticationInProgress = true
        do {
            let stream = try await connection.openStream(directionality: .bidirectional)
            let challenge = UUID()
            let handshake = NexoQUICHandshake(
                applicationID: applicationID,
                protocolVersion: P2PProtocolInfo.currentVersion,
                minimumProtocolVersion: P2PProtocolInfo.minimumVersion,
                challenge: challenge,
                responseTo: nil
            )
            let frame = NexoBinaryFrame(
                kind: .handshake,
                streamID: challenge,
                payload: try JSONEncoder().encode(handshake)
            )
            try await stream.send(try NexoBinaryFrameCodec.encode(frame), endOfStream: false)

            var buffer = Data()
            let message = try await stream.receive(
                atLeast: 1,
                atMost: Self.maximumHandshakeBytes
            )
            buffer.append(message.content)
            guard let responseFrame = try nextFrame(from: &buffer),
                  responseFrame.kind == .handshake
            else { throw NexoQUICBinaryTransportError.handshakeRequired }

            let response = try JSONDecoder().decode(NexoQUICHandshake.self, from: responseFrame.payload)
            guard response.responseTo == challenge,
                  !response.applicationID.isEmpty,
                  P2PProtocolInfo.isCompatible(remoteVersion: response.protocolVersion),
                  response.minimumProtocolVersion <= P2PProtocolInfo.currentVersion
            else { throw NexoQUICBinaryTransportError.handshakeFailed }

            if let expectedRemoteApplicationID,
               response.applicationID != expectedRemoteApplicationID {
                throw NexoQUICBinaryTransportError.unexpectedPeer(response.applicationID)
            }

            authenticatedRemoteApplicationID = response.applicationID
            authenticationInProgress = false
            resumeAuthenticationWaiters(with: .success(response.applicationID))
            return response.applicationID
        } catch {
            authenticationInProgress = false
            resumeAuthenticationWaiters(with: .failure(error))
            throw error
        }
    }

    private func receiveHandshake(
        _ frame: NexoBinaryFrame,
        on stream: QUIC.Stream<QUICStream>
    ) async throws {
        let handshake = try JSONDecoder().decode(NexoQUICHandshake.self, from: frame.payload)
        guard handshake.responseTo == nil,
              !handshake.applicationID.isEmpty,
              P2PProtocolInfo.isCompatible(remoteVersion: handshake.protocolVersion),
              handshake.minimumProtocolVersion <= P2PProtocolInfo.currentVersion
        else { throw NexoQUICBinaryTransportError.handshakeFailed }

        if let expectedRemoteApplicationID,
           handshake.applicationID != expectedRemoteApplicationID {
            throw NexoQUICBinaryTransportError.unexpectedPeer(handshake.applicationID)
        }

        let response = NexoQUICHandshake(
            applicationID: applicationID,
            protocolVersion: P2PProtocolInfo.currentVersion,
            minimumProtocolVersion: P2PProtocolInfo.minimumVersion,
            challenge: UUID(),
            responseTo: handshake.challenge
        )
        let responseFrame = NexoBinaryFrame(
            kind: .handshake,
            streamID: frame.streamID,
            payload: try JSONEncoder().encode(response)
        )
        try await stream.send(
            try NexoBinaryFrameCodec.encode(responseFrame),
            endOfStream: true
        )

        authenticatedRemoteApplicationID = handshake.applicationID
        resumeAuthenticationWaiters(with: .success(handshake.applicationID))
    }

    private func waitForAuthentication() async throws -> String {
        if let authenticatedRemoteApplicationID {
            return authenticatedRemoteApplicationID
        }

        return try await withCheckedThrowingContinuation { continuation in
            authenticationWaiters.append(continuation)
        }
    }

    private func resumeAuthenticationWaiters(with result: Result<String, Error>) {
        let waiters = authenticationWaiters
        authenticationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }

    private static func makeParameters(
        tlsConfiguration: NexoTLSConfiguration?
    ) -> NWParametersBuilder<QUIC> {
        if let tlsConfiguration {
            return NWParametersBuilder(auto: {
                tlsConfiguration.configure(QUIC(
                    alpn: [applicationProtocol],
                    { UDP { IP() } }
                ))
            })
            .peerToPeerIncluded(true)
        }

        return NWParametersBuilder(auto: {
            QUIC(alpn: [applicationProtocol], { UDP { IP() } })
        })
        .peerToPeerIncluded(true)
    }
}

public enum NexoQUICBinaryTransportError: Error, LocalizedError, Sendable, Equatable {
    case alreadyStarted
    case openFrameRequired
    case handshakeRequired
    case handshakeFailed
    case unexpectedPeer(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted: "La recepción de streams QUIC ya está iniciada."
        case .openFrameRequired: "El primer frame QUIC debe ser un frame de apertura."
        case .handshakeRequired: "El stream QUIC no está autenticado."
        case .handshakeFailed: "El handshake QUIC no es válido."
        case .unexpectedPeer(let applicationID): "El peer QUIC no coincide: \(applicationID)."
        }
    }
}
