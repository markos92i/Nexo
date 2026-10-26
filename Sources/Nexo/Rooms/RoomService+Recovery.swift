//
//  RoomService+Recovery.swift
//  Nexo
//

import Foundation

// MARK: - Recuperación tras caída física

@NexoActor
extension RoomService {

    func reconnectMissingMembers() {
        for session in sessions.values {
            connectToMembers(of: session)
        }
    }

    func beginTemporaryRecovery(for deviceID: DeviceID, scheduleAttempt: Bool) {
        guard sessions.values.contains(where: { $0.contains(deviceID) }) else {
            cancelRecoveryIfUnused(for: deviceID)
            return
        }

        if recoveryDeadlines[deviceID] == nil {
            recoveryDeadlines[deviceID] = Date().addingTimeInterval(
                Limits.temporaryDisconnectGracePeriod
            )
        }

        if scheduleAttempt {
            scheduleRecoveryAttempt(for: deviceID)
        }
    }

    func scheduleRecoveryAttempt(for deviceID: DeviceID) {
        guard recoveryTasks[deviceID] == nil,
              recoveryDeadlines[deviceID] != nil else { return }

        recoveryTasks[deviceID] = Task { @NexoActor [weak self] in
            let delays: [Duration] = [
                .zero,
                .seconds(1),
                .seconds(2),
                .seconds(4),
                .seconds(8),
                .seconds(15),
                .seconds(25)
            ]

            for delay in delays {
                if delay != .zero {
                    do {
                        try await Task.sleep(for: delay)
                    } catch {
                        return
                    }
                }

                guard let self,
                      let deadline = self.recoveryDeadlines[deviceID]
                else { return }

                guard Date() < deadline else {
                    self.expireTemporaryRecovery(for: deviceID)
                    return
                }
                guard self.connectedPeers[deviceID] == nil else { return }

                guard let advertisement = self.advertisement(for: deviceID) else {
                    continue
                }

                // `connect` espera el handshake físico. Si tiene éxito, el evento
                // `peerConnected` cancela esta tarea y dispara el resume.
                _ = try? await self.transport.connect(to: advertisement)
            }

            while !Task.isCancelled {
                guard let self,
                      let deadline = self.recoveryDeadlines[deviceID]
                else { return }

                guard Date() < deadline else {
                    self.expireTemporaryRecovery(for: deviceID)
                    return
                }
                guard self.connectedPeers[deviceID] == nil else { return }

                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }

                guard let advertisement = self.advertisement(for: deviceID) else {
                    continue
                }
                _ = try? await self.transport.connect(to: advertisement)
            }
        }
    }

    func expireTemporaryRecovery(for deviceID: DeviceID) {
        guard let deadline = recoveryDeadlines[deviceID],
              Date() >= deadline else { return }

        recoveryDeadlines.removeValue(forKey: deviceID)
        recoveryTasks.removeValue(forKey: deviceID)?.cancel()

        guard connectedPeers[deviceID] == nil else { return }

        for session in sessions.values where session.contains(deviceID) {
            if session.isLocalHost {
                migrateActivities(hostedBy: deviceID, in: session)
                // Una caída solo se vuelve una expulsión real cuando pasa toda la
                // ventana sin recuperar al peer.
                remove(deviceID: deviceID, from: session)
            } else if session.descriptor.hostDeviceID == deviceID {
                if !migrateRoomHost(after: deviceID, in: session) {
                    session.setAccessState(.reconnecting)
                    session.record(.hostConnectionLost)
                    session.removeAllActivities(reason: .hostConnectionLost)
                }
            } else {
                migrateActivities(hostedBy: deviceID, in: session)
                var members = session.members
                members.removeAll { $0.deviceID == deviceID }
                apply(members, to: session)
            }
        }
    }

    func cancelRecoveryIfUnused(for deviceID: DeviceID) {
        guard !sessions.values.contains(where: { $0.contains(deviceID) }) else { return }
        recoveryTasks.removeValue(forKey: deviceID)?.cancel()
        recoveryDeadlines.removeValue(forKey: deviceID)
        hostMigrationTasks.removeValue(forKey: deviceID)?.cancel()
    }

    func scheduleHostMigration(for deviceID: DeviceID) {
        guard hostMigrationTasks[deviceID] == nil else { return }
        hostMigrationTasks[deviceID] = Task { @NexoActor [weak self] in
            do {
                try await Task.sleep(for: Limits.hostMigrationDelay)
            } catch {
                return
            }
            guard let self,
                  self.connectedPeers[deviceID] == nil else { return }
            for session in self.sessions.values where session.contains(deviceID) {
                if session.descriptor.hostDeviceID == deviceID {
                    _ = self.migrateRoomHost(after: deviceID, in: session)
                } else {
                    self.migrateActivities(hostedBy: deviceID, in: session)
                }
            }
            self.hostMigrationTasks.removeValue(forKey: deviceID)
        }
    }

    // MARK: - Ciclo de vida del transporte

    func handleLifecycle(_ lifecycle: ConnectivityLifecycle) {
        switch lifecycle {
        case .suspended:
            // El transporte se cerrará, pero la presencia lógica no cambia. Al
            // volver a activo, cada miembro retenido se recupera.
            connectedPeers.removeAll()
            for session in sessions.values {
                for member in session.remoteMembers {
                    beginTemporaryRecovery(for: member.deviceID, scheduleAttempt: false)
                }
            }

        case .active:
            for deviceID in recoveryDeadlines.keys {
                scheduleRecoveryAttempt(for: deviceID)
            }
            reconnectMissingMembers()

        case .disconnected:
            connectedPeers.removeAll()
            for session in sessions.values {
                for member in session.remoteMembers where connectedPeers[member.deviceID] == nil {
                    beginTemporaryRecovery(for: member.deviceID, scheduleAttempt: true)
                }
            }

        case .idle, .reconnecting:
            break
        }
    }

    // MARK: - Historial de chat (resume/replay)

    /// Fusiona un trozo de historial. El host puede agregar mensajes de cada
    /// miembro actual; cualquier otro peer solo puede aportar los suyos.
    func handleChatHistory(
        _ payload: ChatHistoryPayload,
        from peer: ConnectedPeer,
        roomID: RoomID
    ) {
        guard let session = sessions[roomID],
              session.features.hasChat,
              session.contains(peer.deviceID),
              payload.roomID == roomID,
              payload.messages.count <= Limits.recoveryChatMessageLimit,
              let chat = session.chat
        else { return }

        let messages = RoomChatHistory.validatedMessages(
            payload.messages,
            roomID: roomID,
            members: session.members,
            senderDeviceID: peer.deviceID,
            hostDeviceID: session.descriptor.hostDeviceID
        )
        guard chat.merge(messages: messages), session.isLocalHost else { return }

        // Los trozos pueden llegar por separado. Republicar tras cada fusión es
        // idempotente y garantiza que los peers ya en línea convergen aunque se
        // pierdan el trozo original.
        for member in session.remoteMembers {
            sendChatHistory(of: session, to: member.deviceID)
        }
    }

    /// Envía la conversación retenida en trozos que caben en un envelope de
    /// control. Un invitado solo envía sus propios mensajes; el host envía el
    /// historial agregado guardado en su sesión.
    func sendChatHistory(of session: Room, to deviceID: DeviceID) {
        guard session.features.hasChat,
              let chat = session.chat else { return }

        for payload in RoomChatHistory.chunks(
            chat.messages,
            roomID: session.roomID,
            senderDeviceID: identity.deviceID,
            hostDeviceID: session.descriptor.hostDeviceID
        ) {
            send(.chatHistory(payload), to: [deviceID], roomID: session.roomID)
        }
    }

    // MARK: - Resume de sala

    /// Aplica el estado autoritativo del host, y deja que el journal reenvíe
    /// envelopes más nuevos que el snapshot. Un invitado que aloja una actividad
    /// puede enviar un resume parcial acotado solo a esa actividad.
    func handleRoomResume(
        _ payload: RoomResumePayload,
        from peer: ConnectedPeer,
        roomID: RoomID
    ) {
        guard let session = sessions[roomID],
              payload.descriptor.id == roomID,
              payload.descriptor.hostDeviceID == session.descriptor.hostDeviceID,
              payload.descriptor.hostGeneration == session.descriptor.hostGeneration,
              payload.members.count <= Limits.recoveryMemberLimit,
              payload.activities.count <= Limits.recoveryActivityLimit,
              payload.chatMessages.count <= Limits.recoveryChatMessageLimit
        else { return }

        let isRoomHost = peer.deviceID == session.descriptor.hostDeviceID
        guard RoomMembership.validates(payload.members, descriptor: payload.descriptor, roomID: roomID,
                                       requiring: [identity.deviceID, peer.deviceID]),
              validatesActivities(payload.activities, roomID: roomID,
                                  members: isRoomHost ? payload.members : session.members),
              payload.activities.allSatisfy({ isRoomHost || $0.hostDeviceID == peer.deviceID })
        else { return }

        // El historial se valida contra la membresía que el host va a publicar,
        // antes de mutar descriptor, miembros o actividades.
        let validMessages = RoomChatHistory.validatedMessages(
            payload.chatMessages,
            roomID: roomID,
            members: isRoomHost ? payload.members : session.members,
            senderDeviceID: peer.deviceID,
            hostDeviceID: session.descriptor.hostDeviceID
        )

        if isRoomHost {
            session.apply(descriptor: payload.descriptor)
            apply(payload.members, to: session)
        }

        let activeDescriptors = payload.activities.filter {
            $0.isActive
                && $0.includes(identity.deviceID)
                && (isRoomHost || $0.hostDeviceID == peer.deviceID)
        }
        let activeIDs = Set(activeDescriptors.map(\.id))

        // Solo se reconcilian actividades controladas por el peer que envió este
        // snapshot. Las actividades de otros invitados no aparecen en el snapshot
        // del host de sala y deben conservarse.
        let staleActivities = session.activities.values.filter {
            $0.isHost(peer.deviceID) && !activeIDs.contains($0.id)
        }
        for activity in staleActivities {
            session.removeActivity(
                activity.id,
                reason: .activityInactive
            )
        }
        if !staleActivities.isEmpty {
            republishIfHosting(session)
        }

        for descriptor in activeDescriptors {
            reconcileActivity(descriptor, from: peer, in: session)
        }

        let didMerge = session.chat?.merge(messages: validMessages) ?? false

        if isRoomHost {
            session.setAccessState(.joined)
            connectToMembers(of: session)
            publishRooms()
        }

        // Un invitado puede haber conservado mensajes suyos que el host aún no
        // tenía. Una vez fusionados, el host republica la conversación convergida
        // al resto de la sala.
        if session.isLocalHost && !isRoomHost && didMerge {
            for member in session.remoteMembers {
                sendChatHistory(of: session, to: member.deviceID)
            }
        }
    }
}
