import Foundation
import Testing
@testable import Nexo

@Test func activityKindRoundTrips() {
    let kind = ActivityKind("sudoku")
    #expect(kind.rawValue == "sudoku")
}

@Test func binaryFrameRoundTrips() throws {
    let id = UUID()
    let frame = NexoBinaryFrame(kind: .data, streamID: id, payload: Data([1, 2, 3, 4]))

    let encoded = try NexoBinaryFrameCodec.encode(frame)
    let decoded = try NexoBinaryFrameCodec.decode(encoded)

    #expect(decoded == frame)
}

@Test func binaryFrameRejectsTrailingBytes() throws {
    let frame = NexoBinaryFrame(kind: .finish, streamID: UUID())
    var encoded = try NexoBinaryFrameCodec.encode(frame)
    encoded.append(0)

    #expect(throws: NexoBinaryFrameError.truncated) {
        try NexoBinaryFrameCodec.decode(encoded)
    }
}

@Test func binaryHandshakeFrameRoundTrips() throws {
    let frame = NexoBinaryFrame(
        kind: .handshake,
        streamID: UUID(),
        payload: Data("peer-a".utf8)
    )

    #expect(try NexoBinaryFrameCodec.decode(NexoBinaryFrameCodec.encode(frame)) == frame)
}

@Test func byteStreamCanBeConsumedWithAsyncAwait() async throws {
    let pair = NexoByteStream.makeStream()
    _ = pair.source.yield(Data("hello".utf8))
    pair.source.finish()

    var received = Data()
    for try await chunk in pair.stream {
        received.append(chunk)
    }

    #expect(received == Data("hello".utf8))
}
