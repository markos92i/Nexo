//
//  RoomService+Migration.swift
//  Nexo
//

import Foundation

// MARK: - Migración de host (sala y actividades)

@NexoActor
extension RoomService {

    @discardableResult
    func migrateRoomHost(after failedHostDeviceID: DeviceID, in session: Room) -> Bool {
        guard session.descriptor.hostDeviceID == failedHostDeviceID,
              session.descriptor.hostGeneration < UInt64.max,
              connectedPeers[failedHostDeviceID] == nil else { return false }
        let available = Set(connectedPeers.keys).union([identity.deviceID])
        guard let election = RoomHostElection.successor(
            in: session.members,
            after: failedHostDeviceID,
            availableDeviceIDs: available
        ) else { return false }

        guard election.deviceID == identity.deviceID else {
            migrateActivities(hostedBy: failedHostDeviceID, in: session)
            session.setAccessState(.reconnecting)
            publishRooms()
            return true
        }

        let members = session.members
            .filter { $0.deviceID != failedHostDeviceID }
            .map { member in
            RoomMember(
                deviceID: member.deviceID,
                displayName: member.displayName,
                role: member.deviceID == identity.deviceID ? .host : .guest,
                avatar: member.avatar
            )
        }

        let migratedIDs = prepareActivityMigration(after: failedHostDeviceID, in: session)
        var descriptor = session.descriptor
        descriptor.hostDeviceID = identity.deviceID
        descriptor.hostGeneration += 1
        descriptor.memberCount = members.count
        session.apply(descriptor: descriptor)
        session.setAccessState(.joined)
        session.record(.hostChanged)

        apply(members, to: session)
        let activities = session.activities.values.map(\.descriptor)

        let payload = RoomHostChangedPayload(
            failedHostDeviceID: failedHostDeviceID,
            skippedDeviceIDs: election.skippedDeviceIDs,
            descriptor: descriptor,
            members: members,
            activities: activities
        )
        broadcast(.roomHostChanged(payload), in: session)
        announceMigratedActivities(migratedIDs, in: session)
        connectToMembers(of: session)
        for member in session.remoteMembers {
            sendResume(of: session, to: member.deviceID)
        }
        publishAdvertisement()
        publishRooms()
        return true
    }

    func prepareActivityMigration(after failedHostDeviceID: DeviceID, in session: Room) -> [ActivityID] {
        var migratedIDs: [ActivityID] = []
        let available = Set(connectedPeers.keys).union([identity.deviceID])
        // Elige mientras la membresía antigua aún contiene al participante caído.
        for activity in session.activities.values where activity.isHost(failedHostDeviceID) {
            guard activity.descriptor.hostGeneration < UInt64.max,
                  let election = RoomHostElection.successor(
                      in: session.members.filter { activity.descriptor.includes($0.deviceID) },
                      after: failedHostDeviceID,
                      availableDeviceIDs: available
                  ) else { continue }
            var descriptor = activity.descriptor
            descriptor.hostDeviceID = election.deviceID
            descriptor.hostGeneration += 1
            activity.apply(descriptor: descriptor)
            migratedIDs.append(activity.id)
        }
        return migratedIDs
    }

    func announceMigratedActivities(_ activityIDs: [ActivityID], in session: Room) {
        for activityID in activityIDs {
            guard let activity = session.activity(activityID), activity.isHost(identity.deviceID) else { continue }
            send(
                .activityStarted(ActivityLifecyclePayload(descriptor: activity.descriptor)),
                to: activity.descriptor.participantIDs.filter { $0 != identity.deviceID }.sorted { $0.description < $1.description },
                roomID: session.roomID
            )
        }
    }

    func migrateActivities(hostedBy failedHostDeviceID: DeviceID, in session: Room) {
        guard connectedPeers[failedHostDeviceID] == nil else { return }
        let available = Set(connectedPeers.keys).union([identity.deviceID])

        for activity in session.activities.values
        where activity.descriptor.hostDeviceID == failedHostDeviceID {
            let participants = session.members.filter {
                activity.descriptor.includes($0.deviceID)
            }
            guard activity.descriptor.hostGeneration < UInt64.max,
                  let election = RoomHostElection.successor(
                      in: participants,
                      after: failedHostDeviceID,
                      availableDeviceIDs: available
                  ), election.deviceID == identity.deviceID else { continue }

            var descriptor = activity.descriptor
            descriptor.hostDeviceID = identity.deviceID
            descriptor.hostGeneration += 1
            activity.apply(descriptor: descriptor)
            send(
                .activityStarted(ActivityLifecyclePayload(descriptor: descriptor)),
                to: descriptor.participantIDs.filter { $0 != identity.deviceID }.sorted { $0.description < $1.description },
                roomID: session.roomID
            )
        }
    }

    // MARK: - Validación y aplicación de migración de sala

    func validatesRoomMigration(
        _ descriptor: RoomDescriptor,
        members: [RoomMember],
        from peer: ConnectedPeer,
        in session: Room
    ) -> Bool {
        let current = session.descriptor
        guard current.hostGeneration < UInt64.max,
              descriptor.hostGeneration == current.hostGeneration + 1,
              descriptor.hostDeviceID == peer.deviceID,
              connectedPeers[current.hostDeviceID] == nil,
              current.hostDeviceID != identity.deviceID,
              RoomMembership.validates(members, descriptor: descriptor, roomID: session.roomID,
                                       requiring: [identity.deviceID, peer.deviceID]),
              members.map(\.deviceID) == session.members.map(\.deviceID)
                  .filter({ $0 != current.hostDeviceID }),
              descriptor.name == current.name,
              descriptor.features == current.features,
              descriptor.activityKind == current.activityKind,
              descriptor.accessPolicy == current.accessPolicy,
              descriptor.capacity == current.capacity,
              descriptor.protocolVersion == current.protocolVersion,
              let election = RoomHostElection.successor(
                  in: session.members,
                  after: current.hostDeviceID,
                  availableDeviceIDs: Set(connectedPeers.keys).union([identity.deviceID])
              ) else { return false }
        return election.deviceID == peer.deviceID
    }

    func applyRoomMigration(_ descriptor: RoomDescriptor, members: [RoomMember], to session: Room) {
        let migratedIDs = prepareActivityMigration(after: session.descriptor.hostDeviceID, in: session)
        session.apply(descriptor: descriptor)
        apply(members, to: session)
        session.setAccessState(.joined)
        session.record(.hostChanged)
        announceMigratedActivities(migratedIDs, in: session)
        connectToMembers(of: session)
        publishRooms()
    }

    func handleRoomHostChanged(
        _ payload: RoomHostChangedPayload,
        from peer: ConnectedPeer,
        roomID: RoomID
    ) {
        guard let session = sessions[roomID],
              payload.failedHostDeviceID == session.descriptor.hostDeviceID,
              validatesRoomMigration(payload.descriptor, members: payload.members, from: peer, in: session),
              RoomHostElection.validates(
                  RoomHostElection.Result(deviceID: peer.deviceID,
                                          skippedDeviceIDs: payload.skippedDeviceIDs),
                  in: session.members,
                  after: payload.failedHostDeviceID
              ) else { return }

        applyRoomMigration(payload.descriptor, members: payload.members, to: session)

        // Un sucesor de sala puede ni siquiera conocer una actividad privada.
        // Solo su propia autoridad de actividad puede reconciliar datos; las
        // omisiones nunca borran actividades locales.
        if validatesActivities(payload.activities, roomID: roomID, members: payload.members) {
            for descriptor in payload.activities where descriptor.hostDeviceID == peer.deviceID
                && descriptor.includes(identity.deviceID) {
                reconcileActivity(descriptor, from: peer, in: session)
            }
        }
    }
}
