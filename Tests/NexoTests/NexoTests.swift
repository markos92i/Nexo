import Foundation
import Testing
@testable import Nexo

@Test func activityKindRoundTrips() {
    let kind = ActivityKind("sudoku")
    #expect(kind.rawValue == "sudoku")
}

@Test func hostElectionChoosesNextAvailableMemberInRoomOrder() {
    let members = [
        RoomMember(applicationID: "host", displayName: "Host", role: .host),
        RoomMember(applicationID: "first", displayName: "First", role: .guest),
        RoomMember(applicationID: "second", displayName: "Second", role: .guest),
        RoomMember(applicationID: "third", displayName: "Third", role: .guest)
    ]

    let election = RoomHostElection.successor(
        in: members,
        after: "host",
        availableApplicationIDs: ["host", "second", "third"]
    )

    #expect(election == RoomHostElection.Result(
        applicationID: "second",
        skippedApplicationIDs: ["first"]
    ))
    #expect(election.map {
        RoomHostElection.validates($0, in: members, after: "host")
    } == true)
}

@Test func hostElectionWrapsAroundAndRejectsOutOfOrderCandidate() {
    let members = [
        RoomMember(applicationID: "host", displayName: "Host", role: .host),
        RoomMember(applicationID: "next", displayName: "Next", role: .guest),
        RoomMember(applicationID: "last", displayName: "Last", role: .guest)
    ]

    let election = RoomHostElection.successor(
        in: members,
        after: "last",
        availableApplicationIDs: ["host", "next", "last"]
    )

    #expect(election?.applicationID == "host")
    #expect(!RoomHostElection.validates(
        .init(applicationID: "last", skippedApplicationIDs: []),
        in: members,
        after: "host"
    ))
}

@Test func hostGenerationSurvivesRoomDescriptorCoding() throws {
    let descriptor = RoomDescriptor(
        name: "Partida",
        hostApplicationID: "successor",
        features: .full,
        hostGeneration: 7
    )

    let data = try JSONEncoder().encode(descriptor)
    let decoded = try JSONDecoder().decode(RoomDescriptor.self, from: data)

    #expect(decoded.hostApplicationID == "successor")
    #expect(decoded.hostGeneration == 7)
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
