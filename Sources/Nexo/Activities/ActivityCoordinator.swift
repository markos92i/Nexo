//
//  ActivityCoordinator.swift
//  Nexo
//

import Foundation

// MARK: - Ciclo de vida de actividades
//
// La lógica de actividades comparte el estado central de `RoomService` (sesiones,
// peers conectados, registry, identidad), así que se implementa como una extensión
// aislada en su propio archivo en lugar de un tipo separado que tendría que recibir
// el servicio entero. Aquí vive todo el ciclo de vida: creación, invitación,
// terminación, reconciliación con autoridad independiente, y la admisión a
// actividades abiertas.

@NexoActor
extension RoomService {

    enum ActivityAnnouncement {
        case started
        case invitation
    }

    // MARK: - API pública

    /// Inicia una actividad dentro de la sala. Solo participan los miembros dados;
    /// el resto sigue en el chat como de costumbre.
    @discardableResult
    public func startActivity(
        kind: ActivityKind,
        in roomID: RoomID,
        participants: [DeviceID]? = nil,
        isExclusive: Bool = true
    ) throws(RoomError) -> any Activity {
        try createActivity(
            kind: kind,
            in: roomID,
            participants: participants,
            isExclusive: isExclusive,
            announcement: .started
        )
    }

    /// Inicia una actividad desde una conversación y anuncia una invitación
    /// explícita a los miembros incluidos en ella.
    @discardableResult
    public func inviteToActivity(
        kind: ActivityKind,
        in roomID: RoomID,
        participants: [DeviceID]? = nil,
        isExclusive: Bool = true
    ) throws(RoomError) -> any Activity {
        try createActivity(
            kind: kind,
            in: roomID,
            participants: participants,
            isExclusive: isExclusive,
            announcement: .invitation
        )
    }

    private func createActivity(
        kind: ActivityKind,
        in roomID: RoomID,
        participants: [DeviceID]?,
        isExclusive: Bool,
        announcement: ActivityAnnouncement
    ) throws(RoomError) -> any Activity {
        guard let session = sessions[roomID] else { throw RoomError.roomNotFound }
        guard session.features.hasActivities else { throw RoomError.featureUnavailable(.activities) }
        guard session.accessState == .joined else { throw RoomError.notAMember }
        guard session.activities.count < Limits.recoveryActivityLimit,
              !isExclusive || session.canStartActivity else { throw RoomError.activityAlreadyRunning }

        // Sin lista explícita la actividad queda abierta a la sala: quien entre
        // más tarde se admite solo mientras no haya empezado.
        let admitsRoomMembers = participants == nil
        var participantIDs = Set(participants ?? session.members.map(\.deviceID))
        participantIDs.insert(identity.deviceID)
        guard participantIDs.isSubset(of: Set(session.members.map(\.deviceID))) else {
            throw RoomError.notAMember
        }

        let descriptor = ActivityDescriptor(
            roomID: roomID,
            kind: kind,
            hostDeviceID: identity.deviceID,
            participantIDs: participantIDs,
            state: .lobby,
            admitsRoomMembers: admitsRoomMembers,
            isExclusive: isExclusive
        )

        guard let activity = registry.makeActivity(for: session.makeActivityContext(
            for: descriptor,
            endActivity: { [weak self] reason in
                self?.endActivity(descriptor.id, in: descriptor.roomID, reason: reason)
            }
        )) else {
            throw RoomError.activityUnsupported(kind)
        }

        session.register(activity)

        // Una sala que no declaró un tipo empieza a anunciar el que está jugando,
        // para que aparezca en la lista de salas cercanas de ese juego.
        republishIfHosting(session)

        let message: ControlMessage
        switch announcement {
        case .started:
            message = .activityStarted(ActivityLifecyclePayload(descriptor: descriptor))
        case .invitation:
            message = .activityInvite(ActivityLifecyclePayload(descriptor: descriptor))
        }

        send(
            message,
            to: participantIDs.filter { $0 != identity.deviceID }.sorted { $0.description < $1.description },
            roomID: roomID
        )

        return activity
    }

    /// Termina la actividad. La sala y su chat quedan intactos.
    public func endActivity(_ activityID: ActivityID, in roomID: RoomID, reason: DisconnectReason) {
        guard let session = sessions[roomID],
              let activity = session.activity(activityID) else { return }

        let participants = activity.descriptor.participantIDs
            .filter { $0 != identity.deviceID }
            .sorted { $0.description < $1.description }

        if activity.isHost(identity.deviceID) {
            send(
                .activityEnded(ActivityEndedPayload(
                    roomID: roomID,
                    activityID: activityID,
                    reason: reason
                )),
                to: participants,
                roomID: roomID
            )
        } else {
            send(
                .activityLeft(ActivityMembershipPayload(
                    roomID: roomID,
                    activityID: activityID,
                    displayName: identity.displayName
                )),
                to: participants,
                roomID: roomID
            )
        }

        session.removeActivity(activityID, reason: reason)

        // La sala sobrevive a la actividad, así que el tipo anunciado se va con ella.
        republishIfHosting(session)
    }

    // MARK: - Entrantes

    func handleActivityAnnouncement(
        _ descriptor: ActivityDescriptor,
        from peer: ConnectedPeer,
        publishesNotice: Bool
    ) {
        guard let session = sessions[descriptor.roomID],
              session.features.hasActivities,
              descriptor.hostDeviceID == peer.deviceID,
              descriptor.includes(identity.deviceID) else { return }

        let isNewActivity = session.activity(descriptor.id) == nil
        guard reconcileActivity(descriptor, from: peer, in: session) else { return }

        guard publishesNotice,
              isNewActivity,
              descriptor.state == .lobby,
              session.activity(descriptor.id) != nil else { return }

        guard let hostDisplayName = session.member(descriptor.hostDeviceID)?.displayName else { return }
        publishNotice(.activityInvitation(ActivityInvitationNotice(
            activityID: descriptor.id,
            roomID: descriptor.roomID,
            kind: descriptor.kind,
            hostDisplayName: hostDisplayName
        )))
    }

    func handleActivityJoinRequest(_ payload: ActivityMembershipPayload, from peer: ConnectedPeer) {
        guard let session = sessions[payload.roomID],
              let activity = session.activity(payload.activityID),
              activity.isHost(identity.deviceID) else { return }
        guard activity.descriptor.admitsRoomMembers || activity.descriptor.includes(peer.deviceID) else {
            send(
                .activityJoinRejected(ActivityRejectionPayload(
                    roomID: payload.roomID,
                    activityID: payload.activityID,
                    reason: .hostRejected
                )),
                to: [peer.deviceID],
                roomID: payload.roomID
            )
            return
        }

        guard activity.descriptor.state == .lobby else {
            send(
                .activityJoinRejected(ActivityRejectionPayload(
                    roomID: payload.roomID,
                    activityID: payload.activityID,
                    reason: .activityAlreadyStarted
                )),
                to: [peer.deviceID],
                roomID: payload.roomID
            )
            return
        }

        var descriptor = activity.descriptor
        descriptor.participantIDs.insert(peer.deviceID)
        activity.apply(descriptor: descriptor)

        if let member = session.member(peer.deviceID) {
            activity.participantDidJoin(member)
        }

        send(
            .activityJoinAccepted(ActivityLifecyclePayload(descriptor: descriptor)),
            to: descriptor.participantIDs.filter { $0 != identity.deviceID }.sorted { $0.description < $1.description },
            roomID: payload.roomID
        )
    }

    /// Admite a un nuevo miembro en las actividades que alojamos y siguen abiertas.
    /// Sin esto, quien se une después de crear una partida nunca acaba en
    /// `participantIDs` y sus mensajes se descartan al enrutar.
    func admitToOpenActivities(deviceID: DeviceID, in session: Room) {
        guard let member = session.member(deviceID) else { return }

        for activity in session.activities.values
        where activity.isHost(identity.deviceID)
            && activity.descriptor.admitsRoomMembers
            && activity.descriptor.state == .lobby
            && !activity.descriptor.includes(deviceID) {

            var descriptor = activity.descriptor
            descriptor.participantIDs.insert(deviceID)
            activity.apply(descriptor: descriptor)
            activity.participantDidJoin(member)

            // El recién llegado pidió entrar a la sala, así que para él esto es
            // una admisión, no una invitación: `.activityStarted` haría que su UI
            // anunciara un juego al que acaba de entrar.
            send(
                .activityJoinAccepted(ActivityLifecyclePayload(descriptor: descriptor)),
                to: [deviceID],
                roomID: session.roomID
            )
            send(
                .activityStarted(ActivityLifecyclePayload(descriptor: descriptor)),
                to: descriptor.participantIDs
                    .filter { $0 != identity.deviceID && $0 != deviceID }
                    .sorted { $0.description < $1.description },
                roomID: session.roomID
            )
        }
    }

    // MARK: - Validación y reconciliación

    func validatesActivities(_ descriptors: [ActivityDescriptor], roomID: RoomID, members: [RoomMember]) -> Bool {
        let memberIDs = Set(members.map(\.deviceID))
        return descriptors.count <= Limits.recoveryActivityLimit
            && Set(descriptors.map(\.id)).count == descriptors.count
            && descriptors.allSatisfy {
                $0.roomID == roomID
                    && $0.participantIDs.isSubset(of: memberIDs)
                    && $0.includes($0.hostDeviceID)
            }
    }

    @discardableResult
    func reconcileActivity(_ descriptor: ActivityDescriptor, from peer: ConnectedPeer, in session: Room) -> Bool {
        guard session.features.hasActivities,
              descriptor.includes(identity.deviceID),
              validatesActivities([descriptor], roomID: session.roomID, members: session.members) else { return false }
        if let activity = session.activity(descriptor.id) {
            let current = activity.descriptor
            guard descriptor.kind == current.kind,
                  descriptor.admitsRoomMembers == current.admitsRoomMembers,
                  descriptor.isExclusive == current.isExclusive,
                  descriptor.hostDeviceID == peer.deviceID else { return false }
            if descriptor.hostGeneration == current.hostGeneration {
                guard descriptor.hostDeviceID == current.hostDeviceID else { return false }
            } else {
                guard current.hostGeneration < UInt64.max,
                      descriptor.hostGeneration == current.hostGeneration + 1,
                      current.hostDeviceID != identity.deviceID,
                      connectedPeers[current.hostDeviceID] == nil,
                      descriptor.participantIDs == current.participantIDs
                          || descriptor.participantIDs == current.participantIDs.subtracting([current.hostDeviceID]),
                      let election = RoomHostElection.successor(
                          in: session.members.filter { current.includes($0.deviceID) },
                          after: current.hostDeviceID,
                          availableDeviceIDs: Set(connectedPeers.keys).union([identity.deviceID])
                      ), election.deviceID == peer.deviceID else { return false }
            }
        } else {
            guard descriptor.hostDeviceID == peer.deviceID
                || session.descriptor.hostDeviceID == peer.deviceID else { return false }
        }
        instantiateActivity(descriptor, in: session)
        return true
    }

    func instantiateActivity(_ descriptor: ActivityDescriptor, in session: Room) {
        if let existing = session.activity(descriptor.id) {
            // La misma actividad puede llegar vía `activityStarted` y luego vía
            // `joinRoomAccepted` al reconectar. Reusarla preserva su buffer de
            // mensajes y cualquier estado local asociado.
            existing.apply(descriptor: descriptor)
            return
        }

        guard let activity = registry.makeActivity(for: session.makeActivityContext(
            for: descriptor,
            endActivity: { [weak self] reason in
                self?.endActivity(descriptor.id, in: descriptor.roomID, reason: reason)
            }
        )) else { return }
        session.register(activity)
        republishIfHosting(session)
    }
}
