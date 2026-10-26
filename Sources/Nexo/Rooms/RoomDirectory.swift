import Foundation

/// Directorio de salas descubiertas por anuncios de peers cercanos. Trabaja sobre
/// su propio estado (anuncios + salas), con acoplamiento mínimo al resto de la
/// capa de salas.
struct RoomDirectory {
    private(set) var advertisements: [TransportPeerID: PeerAdvertisement] = [:]
    private(set) var rooms: [RoomID: DiscoveredRoom] = [:]

    mutating func update(_ advertisement: PeerAdvertisement) {
        advertisements[advertisement.endpointID] = advertisement
        guard advertisement.isCompatible, let hostDeviceID = advertisement.deviceID else {
            removeRooms(advertisedBy: advertisement.endpointID, except: [])
            return
        }
        let descriptors = advertisement.rooms.filter {
            Self.isValid($0, hostDeviceID: hostDeviceID)
        }
        for descriptor in descriptors {
            upsert(descriptor, endpointID: advertisement.endpointID, hostDisplayName: advertisement.displayName)
        }
        if !advertisement.hasUndisclosedRooms {
            removeRooms(advertisedBy: advertisement.endpointID, except: Set(descriptors.map(\.id)))
        }
    }

    mutating func update(
        _ payload: RoomDirectoryPayload,
        from peer: ConnectedPeer,
        joinedIDs: Set<RoomID>
    ) -> Set<RoomID>? {
        guard let endpointID = advertisement(for: peer.deviceID)?.endpointID,
              payload.rooms.allSatisfy({ Self.isValid($0, hostDeviceID: peer.deviceID) }),
              Set(payload.rooms.map(\.id)).count == payload.rooms.count else { return nil }
        let descriptors = payload.rooms
        let ids = Set(descriptors.map(\.id))
        for descriptor in descriptors where !joinedIDs.contains(descriptor.id) {
            upsert(descriptor, endpointID: endpointID, hostDisplayName: peer.displayName)
        }
        removeRooms(advertisedBy: endpointID, except: ids)
        return ids
    }

    mutating func remove(_ endpointID: TransportPeerID) {
        advertisements.removeValue(forKey: endpointID)
        removeRooms(advertisedBy: endpointID, except: [])
    }

    mutating func removeRoom(_ roomID: RoomID) {
        rooms.removeValue(forKey: roomID)
    }

    mutating func suspend(keeping roomIDs: Set<RoomID>) {
        advertisements.removeAll()
        rooms = rooms.filter { roomIDs.contains($0.key) }
    }

    mutating func clear() {
        advertisements.removeAll()
        rooms.removeAll()
    }

    func advertisement(for deviceID: DeviceID) -> PeerAdvertisement? {
        advertisements.values.first { $0.deviceID == deviceID }
    }

    private static func isValid(_ descriptor: RoomDescriptor, hostDeviceID: DeviceID) -> Bool {
        descriptor.hostDeviceID == hostDeviceID
            && descriptor.memberCount > 0
            && descriptor.memberCount <= Limits.recoveryMemberLimit
            && (descriptor.capacity.map { $0 > 0 && descriptor.memberCount <= $0 } ?? true)
            && ProtocolInfo.isCompatible(remoteVersion: descriptor.protocolVersion)
    }

    private mutating func upsert(_ descriptor: RoomDescriptor, endpointID: TransportPeerID, hostDisplayName: String) {
        rooms[descriptor.id] = DiscoveredRoom(
            descriptor: descriptor,
            advertisedBy: endpointID,
            hostDisplayName: hostDisplayName,
            discoveredAt: rooms[descriptor.id]?.discoveredAt ?? Date()
        )
    }

    private mutating func removeRooms(advertisedBy endpointID: TransportPeerID, except ids: Set<RoomID>) {
        rooms = rooms.filter { $0.value.advertisedBy != endpointID || ids.contains($0.key) }
    }
}
