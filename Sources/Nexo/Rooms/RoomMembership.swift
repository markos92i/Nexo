import Foundation

@NexoActor
final class RoomMembership {
    private(set) var members: [RoomMember] = []
    private var membersByID: [DeviceID: RoomMember] = [:]

    init(members: [RoomMember] = []) {
        update(members)
    }

    func update(_ members: [RoomMember]) {
        var sanitized: [RoomMember] = []
        var index: [DeviceID: RoomMember] = [:]
        // Los snapshots remotos pueden repetir identidades; gana la primera.
        for member in members where index[member.deviceID] == nil {
            sanitized.append(member)
            index[member.deviceID] = member
        }
        membersByID = index
        self.members = sanitized
    }

    static func validates(
        _ members: [RoomMember],
        descriptor: RoomDescriptor,
        roomID: RoomID,
        requiring deviceIDs: Set<DeviceID>
    ) -> Bool {
        let memberIDs = Set(members.map(\.deviceID))
        return descriptor.id == roomID
            && ProtocolInfo.isCompatible(remoteVersion: descriptor.protocolVersion)
            && !members.isEmpty
            && members.count <= Limits.recoveryMemberLimit
            && memberIDs.count == members.count
            && deviceIDs.isSubset(of: memberIDs)
            && members.filter(\.isHost).map(\.deviceID) == [descriptor.hostDeviceID]
            && descriptor.memberCount == members.count
            && (descriptor.capacity.map { $0 > 0 && members.count <= $0 } ?? true)
    }

    func member(_ deviceID: DeviceID) -> RoomMember? {
        membersByID[deviceID]
    }

    func contains(_ deviceID: DeviceID) -> Bool {
        membersByID[deviceID] != nil
    }
}

/// Elección determinista del sucesor del host cuando el actual se vuelve
/// inalcanzable. Todos los miembros calculan el mismo resultado a partir del
/// mismo orden de miembros, sin negociación.
enum RoomHostElection {
    struct Result: Equatable {
        let deviceID: DeviceID
        let skippedDeviceIDs: [DeviceID]
    }

    static func successor(
        in members: [RoomMember],
        after failedHostDeviceID: DeviceID,
        availableDeviceIDs: Set<DeviceID>
    ) -> Result? {
        guard !members.isEmpty,
              let failedIndex = members.firstIndex(where: { $0.deviceID == failedHostDeviceID })
        else { return nil }

        var skipped: [DeviceID] = []
        for offset in 1..<members.count {
            let deviceID = members[(failedIndex + offset) % members.count].deviceID
            guard deviceID != failedHostDeviceID else { continue }
            if availableDeviceIDs.contains(deviceID) {
                return Result(deviceID: deviceID, skippedDeviceIDs: skipped)
            }
            skipped.append(deviceID)
        }
        return nil
    }

    static func validates(
        _ result: Result,
        in members: [RoomMember],
        after failedHostDeviceID: DeviceID
    ) -> Bool {
        guard let expected = successor(
            in: members,
            after: failedHostDeviceID,
            availableDeviceIDs: [result.deviceID]
        ) else { return false }
        return expected == result
    }
}
