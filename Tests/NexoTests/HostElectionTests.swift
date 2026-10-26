import Foundation
import Testing
@testable import Nexo

@Suite("Elección de host")
struct HostElectionTests {

    private func member(_ name: String, role: RoomRole = .guest) -> RoomMember {
        RoomMember(deviceID: DeviceID(), displayName: name, role: role)
    }

    @Test("Elige el siguiente miembro disponible en orden de sala")
    func choosesNextAvailableInOrder() {
        let host = member("Host", role: .host)
        let first = member("First")
        let second = member("Second")
        let third = member("Third")
        let members = [host, first, second, third]

        let election = RoomHostElection.successor(
            in: members,
            after: host.deviceID,
            availableDeviceIDs: [host.deviceID, second.deviceID, third.deviceID]
        )

        #expect(election?.deviceID == second.deviceID)
        #expect(election?.skippedDeviceIDs == [first.deviceID])
        #expect(election.map { RoomHostElection.validates($0, in: members, after: host.deviceID) } == true)
    }

    @Test("Da la vuelta y rechaza un candidato fuera de orden")
    func wrapsAroundAndRejectsOutOfOrder() {
        let host = member("Host", role: .host)
        let next = member("Next")
        let last = member("Last")
        let members = [host, next, last]

        let election = RoomHostElection.successor(
            in: members,
            after: last.deviceID,
            availableDeviceIDs: [host.deviceID, next.deviceID, last.deviceID]
        )
        #expect(election?.deviceID == host.deviceID)

        #expect(!RoomHostElection.validates(
            RoomHostElection.Result(deviceID: last.deviceID, skippedDeviceIDs: []),
            in: members,
            after: host.deviceID
        ))
    }

    @Test("Sin candidatos disponibles no hay sucesor")
    func noSuccessorWhenNobodyAvailable() {
        let host = member("Host", role: .host)
        let guest = member("Guest")
        let election = RoomHostElection.successor(
            in: [host, guest],
            after: host.deviceID,
            availableDeviceIDs: [host.deviceID]
        )
        #expect(election == nil)
    }
}
