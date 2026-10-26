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
