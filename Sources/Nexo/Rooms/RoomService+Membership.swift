//
//  RoomService+Membership.swift
//  Nexo
//

import Foundation

// MARK: - Unirse y salir

@NexoActor
extension RoomService {

    /// Solicita unirse a una sala descubierta. Devuelve la sesión cuando el host
    /// acepta, o lanza si rechaza o no responde.
    @discardableResult
    public func join(_ room: DiscoveredRoom) async throws(RoomError) -> Room {
        if let existing = sessions[room.id], existing.accessState == .joined {
            activeRoomID = room.id
            publishRooms()
            return existing
        }

        guard pendingJoins[room.id] == nil else {
            throw RoomError.joinRejected(.duplicateConnection)
        }
        if let existing = sessions[room.id] {
            guard existing.descriptor.hostDeviceID == room.descriptor.hostDeviceID,
                  existing.descriptor.hostGeneration == room.descriptor.hostGeneration else {
                throw RoomError.peerUnavailable
            }
        }
        guard let advertisement = discovery.advertisement(forEndpoint: room.advertisedBy),
              advertisement.deviceID == room.descriptor.hostDeviceID else {
            throw RoomError.peerUnavailable
        }
        guard !room.descriptor.isFull else { throw RoomError.roomFull }

        let requestID = UUID()
        // Reserva la sala antes de cualquier suspensión, incluido el montaje del
        // manejador de cancelación.
        pendingJoins[room.id] = PendingJoin(
            id: requestID,
            hostDeviceID: room.descriptor.hostDeviceID,
            continuation: nil,
            isRecovery: false,
            roomToJoin: room,
            originalSessionInstanceID: sessions[room.id]?.instanceID
        )
        scheduleJoinTimeout(for: room.id, requestID: requestID)
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    guard pendingJoins[room.id]?.id == requestID else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    pendingJoins[room.id]?.continuation = continuation
                    guard !Task.isCancelled else {
                        finishJoin(room.id, requestID: requestID, result: .failure(CancellationError()))
                        return
                    }
                    pendingJoins[room.id]?.connectionTask = Task { @NexoActor [weak self, transport] in
                        do {
                            let host = try await transport.connect(to: advertisement)
                            try Task.checkCancellation()
                            self?.completeJoinConnection(to: room, host: host, requestID: requestID)
                        } catch {
                            let failure: any Error = error is CancellationError
                                ? CancellationError() : RoomError.transportFailure(DisconnectReason(error: error))
                            self?.finishJoin(room.id, requestID: requestID, result: .failure(failure))
                        }
                    }
                }
            } onCancel: {
                Task { @NexoActor [weak self] in
                    self?.finishJoin(room.id, requestID: requestID, result: .failure(CancellationError()))
                }
            }
        } catch let error as RoomError {
            throw error
        } catch is CancellationError {
            throw RoomError.transportFailure(.connectionClosed)
        } catch {
            throw RoomError.transportFailure(DisconnectReason(error: error))
        }
    }

    /// Sale de la sala. No cierra ninguna conexión física: otras salas y
    /// actividades que comparten esos peers siguen funcionando.
    public func leave(_ roomID: RoomID) {
        guard let session = sessions[roomID] else {
            finishJoin(roomID, result: .failure(RoomError.roomNotFound))
            return
        }
        let remoteDeviceIDs = session.remoteMembers.map(\.deviceID)

        transfers?.cancelAll(in: session)
        session.removeAllActivities(reason: .leftRoom)
        session.setAccessState(.closed(reason: .leftRoom))

        if session.isLocalHost {
            broadcast(
                .roomClosed(RoomClosedPayload(roomID: roomID, reason: .hostClosed)),
                in: session
            )
        } else {
            send(
                .leaveRoom(LeaveRoomPayload(roomID: roomID)),
                to: remoteDeviceIDs,
                roomID: roomID
            )
        }

        discardSession(roomID, publishes: false)
        finishJoin(roomID, result: .failure(RoomError.roomNotFound), publishes: false)
        publishAdvertisement()
        publishRooms()
    }

    // MARK: - Aprobación de entrada

    public func respond(to request: RoomJoinRequest, accept: Bool, reason: DisconnectReason? = nil) {
        guard let session = sessions[request.roomID],
              session.isLocalHost,
              let request = session.removeJoinRequest(request.id),
              let peer = connectedPeers[request.deviceID],
              request.connectionSessionID == nil || request.connectionSessionID == peer.connectionSessionID
        else { return }

        guard accept, !session.descriptor.isFull,
              session.members.count < Limits.recoveryMemberLimit else {
            send(
                .joinRoomRejected(JoinRoomRejectedPayload(
                    roomID: request.roomID,
                    reason: accept ? .roomFull : (reason ?? .hostRejected),
                    requestID: request.requestID
                )),
                to: [request.deviceID],
                roomID: request.roomID
            )
            return
        }

        admit(
            deviceID: request.deviceID,
            displayName: request.displayName,
            avatar: request.avatar,
            to: session,
            requestID: request.requestID
        )
    }

    // MARK: - Membresía entrante

    func handleJoinRequest(_ payload: JoinRoomRequestPayload, from peer: ConnectedPeer) {
        guard let session = sessions[payload.roomID], session.isLocalHost else {
            send(
                .joinRoomRejected(JoinRoomRejectedPayload(
                    roomID: payload.roomID,
                    reason: .roomUnavailable,
                    requestID: payload.requestID
                )),
                to: [peer.deviceID],
                roomID: payload.roomID
            )
            return
        }

        // Un miembro reconectando que ya estaba aquí: reafirma la membresía.
        if session.contains(peer.deviceID) {
            sendAcceptance(of: session, to: peer.deviceID, requestID: payload.requestID)
            return
        }

        guard !session.descriptor.isFull, session.members.count < Limits.recoveryMemberLimit else {
            send(
                .joinRoomRejected(JoinRoomRejectedPayload(
                    roomID: payload.roomID,
                    reason: .roomFull,
                    requestID: payload.requestID
                )),
                to: [peer.deviceID],
                roomID: payload.roomID
            )
            return
        }

        switch session.descriptor.accessPolicy {
        case .open:
            admit(
                deviceID: peer.deviceID,
                displayName: payload.displayName,
                avatar: payload.avatar,
                to: session,
                requestID: payload.requestID
            )

        case .approval:
            if let existing = session.pendingJoinRequests.first(where: { $0.deviceID == peer.deviceID }) {
                guard existing.requestID != payload.requestID
                    || existing.connectionSessionID != peer.connectionSessionID else { return }
                session.removeJoinRequests(for: peer.deviceID)
            }
            let request = RoomJoinRequest(
                roomID: payload.roomID,
                deviceID: peer.deviceID,
                displayName: payload.displayName,
                avatar: payload.avatar,
                requestID: payload.requestID,
                connectionSessionID: peer.connectionSessionID
            )
            guard session.enqueueJoinRequest(request) else { return }

            publishNotice(.joinRequest(JoinRequestNotice(
                requestID: request.id,
                roomID: request.roomID,
                displayName: request.displayName
            )))
        }
    }

    func handleJoinAccepted(_ payload: JoinRoomAcceptedPayload, from peer: ConnectedPeer) {
        let roomID = payload.descriptor.id
        guard matchesPendingJoin(roomID, requestID: payload.requestID, from: peer),
              let session = sessions[roomID],
              peer.deviceID == session.descriptor.hostDeviceID,
              payload.descriptor.hostDeviceID == peer.deviceID,
              payload.descriptor.hostGeneration == session.descriptor.hostGeneration,
              RoomMembership.validates(payload.members, descriptor: payload.descriptor, roomID: roomID,
                                       requiring: [identity.deviceID, peer.deviceID]),
              validatesActivities(payload.activities, roomID: roomID, members: payload.members)
        else { return }

        session.apply(descriptor: payload.descriptor)
        apply(payload.members, to: session)
        session.setAccessState(.joined)
        activeRoomID = roomID

        // Un host de sala puede introducir actividades, pero no cambiar la
        // autoridad de otra actividad.
        for descriptor in payload.activities where descriptor.isActive && descriptor.includes(identity.deviceID) {
            reconcileActivity(descriptor, from: peer, in: session)
        }

        connectToMembers(of: session)
        sendChatHistory(of: session, to: peer.deviceID)
        publishRooms()
        finishJoin(roomID, requestID: payload.requestID, result: .success(session))
    }

    func admit(
        deviceID: DeviceID,
        displayName: String,
        avatar: String?,
        to session: Room,
        requestID: UUID?
    ) {
        var members = session.members
        if !members.contains(where: { $0.deviceID == deviceID }) {
            members.append(RoomMember(
                deviceID: deviceID,
                displayName: displayName,
                role: .guest,
                avatar: avatar
            ))
        }
        apply(members, to: session)
        session.removeJoinRequests(for: deviceID)

        // Debe ocurrir antes de la aceptación: así el descriptor que recibe el
        // recién llegado ya lo incluye como participante.
        admitToOpenActivities(deviceID: deviceID, in: session)

        sendAcceptance(of: session, to: deviceID, requestID: requestID)
        // El resto de la sala recibe la nueva lista y abre una conexión al recién
        // llegado, completando la malla.
        sendMembership(
            of: session,
            to: session.remoteMembers.map(\.deviceID).filter { $0 != deviceID }
        )
        publishAdvertisement()
    }

    func remove(deviceID: DeviceID, from session: Room) {
        var members = session.members
        members.removeAll { $0.deviceID == deviceID }
        apply(members, to: session)
        session.removeJoinRequests(for: deviceID)
        cancelRecoveryIfUnused(for: deviceID)
        sendMembership(of: session, to: session.remoteMembers.map(\.deviceID))
        publishAdvertisement()
    }

    // MARK: - Membresía saliente

    func sendAcceptance(of session: Room, to deviceID: DeviceID, requestID: UUID?) {
        send(
            .joinRoomAccepted(JoinRoomAcceptedPayload(
                descriptor: session.descriptor,
                members: session.members,
                activities: session.activities.values.map(\.descriptor).filter {
                    $0.isActive && $0.includes(deviceID)
                },
                requestID: requestID
            )),
            to: [deviceID],
            roomID: session.roomID
        )
        sendChatHistory(of: session, to: deviceID)
    }

    func sendMembership(of session: Room, to deviceIDs: [DeviceID]) {
        guard !deviceIDs.isEmpty else { return }
        send(
            .roomMembershipChanged(RoomMembershipPayload(
                descriptor: session.descriptor,
                members: session.members
            )),
            to: deviceIDs,
            roomID: session.roomID
        )
    }

    func sendResume(
        of session: Room,
        to deviceID: DeviceID,
        onlyActivitiesHostedByLocal: Bool = false
    ) {
        let resumableChatMessages = session.chat?.messages.filter {
            $0.kind != .systemInfo
                && (!onlyActivitiesHostedByLocal || $0.senderDeviceID == identity.deviceID)
        } ?? []
        var chatMessages = Array(
            resumableChatMessages.suffix(Limits.recoveryChatMessageLimit)
        )
        let activities = Array(
            session.activities.values
                .filter { activity in
                    activity.descriptor.includes(deviceID)
                        && (!onlyActivitiesHostedByLocal || activity.isHost(identity.deviceID))
                }
                .map(\.descriptor)
                .filter(\.isActive)
                .prefix(Limits.recoveryActivityLimit)
        )

        // El límite se calcula sobre el payload codificado, no el número de
        // mensajes: los caracteres Unicode y los metadatos varían mucho.
        while true {
            let payload = RoomResumePayload(
                descriptor: session.descriptor,
                members: session.members,
                activities: activities,
                chatMessages: chatMessages
            )
            let encodedSize = (try? WireCoder.encode(ControlMessage.roomResume(payload)))?.count ?? Int.max
            guard encodedSize > Limits.maximumEnvelopeBytes,
                  !chatMessages.isEmpty else { break }
            chatMessages.removeFirst(max(1, chatMessages.count / 4))
        }

        send(
            .roomResume(RoomResumePayload(
                descriptor: session.descriptor,
                members: session.members,
                activities: activities,
                chatMessages: chatMessages
            )),
            to: [deviceID],
            roomID: session.roomID
        )
    }

    // MARK: - Malla

    /// Abre conexiones a los miembros de una sala que aún no están conectados. La
    /// tarea es única por `DeviceID`, aunque el peer esté en varias salas.
    func connectToMembers(of session: Room) {
        for member in session.remoteMembers where connectedPeers[member.deviceID] == nil {
            beginTemporaryRecovery(for: member.deviceID, scheduleAttempt: true)
        }
    }

    // MARK: - Operaciones de join

    func completeJoinConnection(to room: DiscoveredRoom, host: ConnectedPeer, requestID: UUID) {
        guard let operation = pendingJoins[room.id], operation.id == requestID,
              operation.roomToJoin != nil,
              connectedPeers[host.deviceID]?.connectionSessionID == host.connectionSessionID else { return }
        guard sessions[room.id]?.instanceID == operation.originalSessionInstanceID else {
            finishJoin(room.id, requestID: requestID, result: .failure(RoomError.roomNotFound))
            return
        }
        if let previous = sessions[room.id] {
            guard previous.descriptor.hostDeviceID == room.descriptor.hostDeviceID,
                  previous.descriptor.hostGeneration == room.descriptor.hostGeneration else {
                finishJoin(room.id, requestID: requestID, result: .failure(RoomError.peerUnavailable))
                return
            }
        }
        guard host.deviceID == room.descriptor.hostDeviceID else {
            finishJoin(room.id, requestID: requestID, result: .failure(RoomError.peerUnavailable))
            return
        }
        guard host.supports(.rooms) else {
            finishJoin(room.id, requestID: requestID, result: .failure(RoomError.incompatibleProtocol(host.protocolVersion)))
            return
        }
        pendingJoins[room.id]?.roomToJoin = nil
        if let previous = sessions[room.id] {
            previous.removeAllActivities(reason: .sessionEnded)
            previous.setAccessState(.closed(reason: .sessionEnded))
            discardSession(room.id, publishes: false)
        }
        let session = makeSession(descriptor: room.descriptor, accessState: .awaitingApproval)
        sessions[room.id] = session
        pendingJoins[room.id]?.sessionInstanceID = session.instanceID
        pendingJoins[room.id]?.connectionSessionID = host.connectionSessionID
        activeRoomID = room.id
        publishRooms()
        sendJoinRequest(roomID: room.id, to: host.deviceID, requestID: requestID)
    }

    func beginRecoveryJoin(in session: Room, from peer: ConnectedPeer) {
        guard pendingJoins[session.roomID] == nil,
              session.contains(identity.deviceID) else { return }
        let requestID = UUID()
        pendingJoins[session.roomID] = PendingJoin(
            id: requestID,
            hostDeviceID: peer.deviceID,
            continuation: nil,
            isRecovery: true,
            connectionSessionID: peer.connectionSessionID,
            sessionInstanceID: session.instanceID
        )
        scheduleJoinTimeout(for: session.roomID, requestID: requestID)
        sendJoinRequest(roomID: session.roomID, to: peer.deviceID, requestID: requestID)
    }

    func sendJoinRequest(roomID: RoomID, to deviceID: DeviceID, requestID: UUID) {
        send(
            .joinRoomRequest(JoinRoomRequestPayload(
                roomID: roomID,
                displayName: identity.displayName,
                avatar: identity.avatar,
                requestID: requestID
            )),
            to: [deviceID],
            roomID: roomID
        )
    }

    func matchesPendingJoin(_ roomID: RoomID, requestID: UUID?, from peer: ConnectedPeer) -> Bool {
        guard let requestID, let operation = pendingJoins[roomID] else { return false }
        return operation.id == requestID
            && operation.hostDeviceID == peer.deviceID
            && operation.connectionSessionID == peer.connectionSessionID
            && operation.sessionInstanceID == sessions[roomID]?.instanceID
            && operation.sessionInstanceID != nil
    }

    func scheduleJoinTimeout(for roomID: RoomID, requestID: UUID) {
        pendingJoins[roomID]?.timeoutTask = Task { @NexoActor [weak self] in
            do {
                try await Task.sleep(for: Limits.joinTimeout)
            } catch {
                return
            }
            self?.finishJoin(roomID, requestID: requestID, result: .failure(RoomError.joinTimedOut))
        }
    }

    func finishJoin(
        _ roomID: RoomID,
        requestID: UUID? = nil,
        result: Result<Room, any Error>,
        publishes: Bool = true
    ) {
        guard let operation = pendingJoins[roomID],
              requestID == nil || operation.id == requestID else { return }
        pendingJoins.removeValue(forKey: roomID)
        operation.connectionTask?.cancel()
        operation.timeoutTask?.cancel()

        switch result {
        case .success(let session):
            operation.continuation?.resume(returning: session)
        case .failure(let error):
            if let session = sessions[roomID], session.instanceID == operation.sessionInstanceID {
                if operation.isRecovery {
                    if session.accessState == .suspended { session.setAccessState(.reconnecting) }
                } else {
                    if connectedPeers[operation.hostDeviceID]?.connectionSessionID == operation.connectionSessionID {
                        send(.leaveRoom(LeaveRoomPayload(roomID: roomID)), to: [operation.hostDeviceID], roomID: roomID)
                    }
                    session.removeAllActivities(reason: .sessionEnded)
                    session.setAccessState(.closed(reason: DisconnectReason(error: error)))
                    discardSession(roomID, publishes: publishes)
                }
            }
            operation.continuation?.resume(throwing: error)
        }
    }
}
