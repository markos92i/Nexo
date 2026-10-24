//
//  RoomMembership.swift
//  Nexo
//

@NexoActor
final class RoomMembership {
    private(set) var members: [RoomMember] = []
    private var membersByID: [String: RoomMember] = [:]

    init(members: [RoomMember] = []) {
        update(members)
    }

    func update(_ members: [RoomMember]) {
        var sanitized: [RoomMember] = []
        var index: [String: RoomMember] = [:]
        // Remote snapshots can repeat identities; the first occurrence wins.
        for member in members where index[member.applicationID] == nil {
            sanitized.append(member)
            index[member.applicationID] = member
        }
        membersByID = index
        self.members = sanitized
    }

    static func validates(
        _ members: [RoomMember],
        descriptor: RoomDescriptor,
        roomID: RoomID,
        requiring applicationIDs: Set<String>
    ) -> Bool {
        let memberIDs = Set(members.map(\.applicationID))
        return descriptor.id == roomID
            && P2PProtocolInfo.isCompatible(remoteVersion: descriptor.protocolVersion)
            && !members.isEmpty
            && members.count <= P2PLimits.recoveryMemberLimit
            && memberIDs.count == members.count
            && !memberIDs.contains("")
            && applicationIDs.isSubset(of: memberIDs)
            && members.filter(\.isHost).map(\.applicationID) == [descriptor.hostApplicationID]
            && descriptor.memberCount == members.count
            && (descriptor.capacity.map { $0 > 0 && members.count <= $0 } ?? true)
    }

    func member(_ applicationID: String) -> RoomMember? {
        membersByID[applicationID]
    }

    func contains(_ applicationID: String) -> Bool {
        membersByID[applicationID] != nil
    }
}
