//
//  EnvelopeRouter.swift
//  Nexo
//

import Foundation

// MARK: - Enrutado de envelopes entrantes
//
// El enrutado comparte tanto estado con `RoomService` (sesiones, peers conectados,
// directorio, dedup) que separarlo en un tipo propio obligaría a pasarle el
// servicio entero en cada llamada. Es más honesto implementarlo como una
// extensión de `RoomService`, aislada en este archivo para que el `switch` gigante
// de control no engorde ningún otro. La deduplicación (`remember`) y su estado
// viven en `RoomService`, pero su mecánica se mantiene aquí junto al enrutado que
// la usa.

@NexoActor
extension RoomService {

    /// Punto de entrada de cada envelope recibido. El orden de validación es
    /// conexión física, sala, membresía, canal y por último el payload tipado.
    func route(_ envelope: Envelope, from peer: ConnectedPeer) {
        guard envelope.senderDeviceID == peer.deviceID,
              peer.deviceID != identity.deviceID,
              peer.supports(.rooms),
              ProtocolInfo.isCompatible(remoteVersion: envelope.protocolVersion),
              envelope.payload.count <= Limits.maximumEnvelopeBytes,
              connectedPeers[peer.deviceID]?.connectionSessionID == peer.connectionSessionID
        else { return }

        if envelope.channel == .control {
            guard envelope.activityID == nil else { return }
            handleControl(envelope, from: peer)
            return
        }

        guard let session = sessions[envelope.roomID],
              hasMembership(in: session, from: peer),
              let member = session.member(peer.deviceID) else { return }

        switch envelope.channel {
        case .control:
            break

        case .chat:
            guard session.features.hasChat, peer.supports(.chat), envelope.activityID == nil,
                  remember(envelope.messageID, from: peer.deviceID) else { return }
            session.chat?.receive(payload: envelope.payload, from: member)

        case .activity:
            guard session.features.hasActivities, peer.supports(.activities),
                  let activityID = envelope.activityID,
                  let activity = session.activity(activityID),
                  activity.descriptor.includes(identity.deviceID),
                  activity.descriptor.includes(peer.deviceID),
                  remember(envelope.messageID, from: peer.deviceID) else { return }
            activity.receive(payload: envelope.payload, from: member)

        case .fileTransfer:
            // El servicio de transferencias es opcional (Fase 6). Sin él, el
            // envelope de `.fileTransfer` se ignora.
            guard let transfers,
                  session.features.hasFileTransfer, peer.supports(.fileTransfer), envelope.activityID == nil,
                  remember(envelope.messageID, from: peer.deviceID) else { return }
            transfers.handle(envelope: envelope, from: member, in: session)
        }
    }

    // MARK: - Membresía y permisos de control

    func hasMembership(in session: Room, from peer: ConnectedPeer) -> Bool {
        guard session.contains(identity.deviceID), session.contains(peer.deviceID) else { return false }
        switch session.accessState {
        case .joined, .suspended, .reconnecting: return true
        case .available, .awaitingApproval, .rejected, .closed: return false
        }
    }

    func allowsControl(_ message: ControlMessage, from peer: ConnectedPeer, roomID: RoomID) -> Bool {
        switch message {
        case .roomDirectoryRequest, .roomDirectory, .joinRoomRequest:
            return true
        case .joinRoomAccepted(let payload):
            return matchesPendingJoin(roomID, requestID: payload.requestID, from: peer)
        case .joinRoomRejected(let payload):
            return matchesPendingJoin(roomID, requestID: payload.requestID, from: peer)
        case .roomClosed:
            return sessions[roomID]?.descriptor.hostDeviceID == peer.deviceID
        case .leaveRoom:
            guard let session = sessions[roomID] else { return false }
            return hasMembership(in: session, from: peer)
                || (session.isLocalHost && session.pendingJoinRequests.contains { $0.deviceID == peer.deviceID })
        default:
            guard let session = sessions[roomID] else { return false }
            return hasMembership(in: session, from: peer)
        }
    }

    // MARK: - Switch de control

    func handleControl(_ envelope: Envelope, from peer: ConnectedPeer) {
        guard let message = try? envelope.decodePayload(as: ControlMessage.self),
              message.roomID == nil || message.roomID == envelope.roomID,
              allowsControl(message, from: peer, roomID: envelope.roomID),
              remember(envelope.messageID, from: peer.deviceID) else { return }

        switch message {

        // MARK: Directorio

        case .roomDirectoryRequest:
            send(
                .roomDirectory(RoomDirectoryPayload(
                    hostDisplayName: identity.displayName,
                    rooms: advertisedRoomDescriptors
                )),
                to: [peer.deviceID],
                roomID: envelope.roomID
            )

        case .roomDirectory(let payload):
            guard let roomIDs = discovery.update(
                payload,
                from: peer,
                joinedIDs: Set(sessions.keys)
            ) else { return }

            // Un host puede reiniciarse y recrear una sala con el mismo nombre
            // pero un ID nuevo. Su directorio completo es autoritativo: descarta
            // cualquier sesión unida vieja que el host ya no anuncie.
            let staleSessions = joinedRooms.filter {
                $0.descriptor.hostDeviceID == peer.deviceID
                    && !roomIDs.contains($0.roomID)
            }
            for session in staleSessions {
                let reason: DisconnectReason = .roomUnavailable
                let roomID = session.roomID
                session.removeAllActivities(reason: reason)
                session.setAccessState(.closed(reason: reason))
                discardSession(roomID, publishes: false)
                finishJoin(roomID, result: .failure(RoomError.roomNotFound), publishes: false)
            }
            if !staleSessions.isEmpty {
                publishAdvertisement()
            }
            publishRooms()
            for session in staleSessions {
                publishNotice(.roomClosed(RoomClosedNotice(
                    roomID: session.roomID,
                    reason: .roomUnavailable
                )))
            }

        // MARK: Membresía

        case .joinRoomRequest(let payload):
            handleJoinRequest(payload, from: peer)

        case .joinRoomAccepted(let payload):
            handleJoinAccepted(payload, from: peer)

        case .joinRoomRejected(let payload):
            guard matchesPendingJoin(payload.roomID, requestID: payload.requestID, from: peer),
                  let session = sessions[payload.roomID] else { return }
            session.removeAllActivities(reason: payload.reason)
            session.setAccessState(.rejected(reason: payload.reason))
            discardSession(payload.roomID)
            finishJoin(payload.roomID, requestID: payload.requestID, result: .failure(RoomError.joinRejected(payload.reason)))

        case .leaveRoom(let payload):
            guard let session = sessions[payload.roomID] else { return }
            if session.isLocalHost {
                remove(deviceID: peer.deviceID, from: session)
            } else {
                var members = session.members
                members.removeAll { $0.deviceID == peer.deviceID }
                apply(members, to: session)
            }

        case .roomMembershipChanged(let payload):
            guard let session = sessions[payload.descriptor.id],
                  RoomMembership.validates(payload.members, descriptor: payload.descriptor, roomID: session.roomID,
                                           requiring: [identity.deviceID, peer.deviceID]) else { return }
            if payload.descriptor.hostGeneration == session.descriptor.hostGeneration {
                guard peer.deviceID == session.descriptor.hostDeviceID,
                      payload.descriptor.hostDeviceID == session.descriptor.hostDeviceID else { return }
                session.apply(descriptor: payload.descriptor)
                apply(payload.members, to: session)
                session.setAccessState(.joined)
                connectToMembers(of: session)
                publishRooms()
            } else {
                guard validatesRoomMigration(payload.descriptor, members: payload.members, from: peer, in: session)
                else { return }
                applyRoomMigration(payload.descriptor, members: payload.members, to: session)
            }

        case .roomResume(let payload):
            handleRoomResume(payload, from: peer, roomID: envelope.roomID)

        case .roomHostChanged(let payload):
            handleRoomHostChanged(payload, from: peer, roomID: envelope.roomID)

        case .chatHistory(let payload):
            handleChatHistory(payload, from: peer, roomID: envelope.roomID)

        case .roomClosed(let payload):
            guard let session = sessions[payload.roomID],
                  session.descriptor.hostDeviceID == peer.deviceID else { return }
            session.removeAllActivities(reason: payload.reason)
            session.setAccessState(.closed(reason: payload.reason))
            // Quita la sala del descubrimiento primero: `discardSession` publica y
            // de lo contrario anunciaría una sala que ya no existe.
            discovery.removeRoom(payload.roomID)
            discardSession(payload.roomID)
            publishNotice(.roomClosed(RoomClosedNotice(
                roomID: payload.roomID,
                reason: payload.reason
            )))
            finishJoin(payload.roomID, result: .failure(RoomError.joinRejected(payload.reason)))

        // MARK: Actividades

        case .activityStarted(let payload), .activityInvite(let payload):
            handleActivityAnnouncement(payload.descriptor, from: peer, publishesNotice: true)

        case .activityJoinAccepted(let payload):
            handleActivityAnnouncement(payload.descriptor, from: peer, publishesNotice: false)

        case .activityJoinRequest(let payload):
            handleActivityJoinRequest(payload, from: peer)

        case .activityJoinRejected(let payload):
            guard let session = sessions[payload.roomID],
                  let activity = session.activity(payload.activityID),
                  activity.isHost(peer.deviceID) else { return }
            session.removeActivity(payload.activityID, reason: payload.reason)
            republishIfHosting(session)

        case .activityLeft(let payload):
            guard let session = sessions[payload.roomID],
                  let activity = session.activity(payload.activityID),
                  activity.descriptor.includes(peer.deviceID),
                  let member = session.member(peer.deviceID) else { return }
            activity.participantDidLeave(member)

        case .activityEnded(let payload):
            guard let session = sessions[payload.roomID],
                  let activity = session.activity(payload.activityID),
                  activity.isHost(peer.deviceID) else { return }
            session.removeActivity(payload.activityID, reason: payload.reason)
            republishIfHosting(session)
        }
    }

    // MARK: - Deduplicación

    /// Registra un `messageID` por emisor para que los replays idempotentes no se
    /// procesen dos veces. Devuelve `false` si ya se había visto.
    func remember(_ messageID: UUID, from deviceID: DeviceID) -> Bool {
        let key = ReceivedEnvelopeKey(sender: deviceID, messageID: messageID)
        guard !receivedEnvelopeIDs.contains(key) else { return false }
        // Los envelopes de directorio llevan room IDs arbitrarios; nunca asignes
        // un bucket por sala.
        let perSenderLimit = Limits.recoveryJournalLimit
        if receivedEnvelopeOrder.lazy.filter({ $0.sender == deviceID }).count >= perSenderLimit,
           let index = receivedEnvelopeOrder.firstIndex(where: { $0.sender == deviceID }) {
            receivedEnvelopeIDs.remove(receivedEnvelopeOrder.remove(at: index))
        }
        if receivedEnvelopeOrder.count >= perSenderLimit * 4 {
            receivedEnvelopeIDs.remove(receivedEnvelopeOrder.removeFirst())
        }
        receivedEnvelopeIDs.insert(key)
        receivedEnvelopeOrder.append(key)
        return true
    }
}
