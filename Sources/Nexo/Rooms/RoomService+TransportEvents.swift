//
//  RoomService+TransportEvents.swift
//  Nexo
//

import Foundation

// MARK: - Eventos del transporte

@NexoActor
extension RoomService {

    func handle(_ event: TransportEvent) {
        guard event.epoch == transport.epoch else { return }
        switch event {
        case .advertisementFound(let advertisement, _), .advertisementUpdated(let advertisement, _):
            handleAdvertisement(advertisement)
        case .advertisementLost(let endpointID, _):
            handleAdvertisementLost(endpointID)
        case .peerConnected(let peer, _):
            handlePeerConnected(peer)
        case .peerDisconnected(let deviceID, let reason, _):
            handlePeerDisconnected(deviceID: deviceID, reason: reason)
        case .received(let envelope, let peer, _):
            route(envelope, from: peer)
        case .lifecycleChanged(let lifecycle, _):
            handleLifecycle(lifecycle)
        case .localNetworkPermissionChanged:
            break
        }
    }

    func handleAdvertisement(_ advertisement: PeerAdvertisement) {
        discovery.update(advertisement)
        publishRooms()
        if advertisement.isCompatible { reconnectMissingMembers() }
    }

    func handleAdvertisementLost(_ endpointID: TransportPeerID) {
        discovery.remove(endpointID)
        publishRooms()
    }

    func handlePeerConnected(_ peer: ConnectedPeer) {
        let wasRecovering = recoveryDeadlines.removeValue(forKey: peer.deviceID) != nil
        recoveryTasks.removeValue(forKey: peer.deviceID)?.cancel()
        hostMigrationTasks.removeValue(forKey: peer.deviceID)?.cancel()

        if connectedPeers[peer.deviceID]?.connectionSessionID == peer.connectionSessionID {
            return
        }
        connectedPeers[peer.deviceID] = peer
        for operation in Array(pendingJoins.values) where operation.hostDeviceID == peer.deviceID {
            if let room = operation.roomToJoin {
                completeJoinConnection(to: room, host: peer, requestID: operation.id)
            }
        }

        // Bonjour solo puede anunciar un subconjunto de salas. El handshake nos
        // permite pedir el catálogo completo sin abrir otra conexión física.
        requestRoomDirectory(from: peer)

        // El host reafirma la membresía, las actividades activas y el historial
        // corto de chat antes de reenviar los mensajes de actividad.
        for session in hostedRooms where session.contains(peer.deviceID) {
            sendMembership(of: session, to: [peer.deviceID])
            sendResume(of: session, to: peer.deviceID)
        }

        // Una actividad también puede estar alojada por un invitado. En ese caso
        // el host de la sala no puede reconstruirla solo; el dueño de la actividad
        // publica su descriptor directamente a sus participantes.
        for session in joinedRooms
        where session.contains(peer.deviceID)
            && session.activities.values.contains(where: {
                $0.isHost(identity.deviceID)
                    && $0.descriptor.includes(peer.deviceID)
            }) {
            sendResume(
                of: session,
                to: peer.deviceID,
                onlyActivitiesHostedByLocal: true
            )
        }

        // Cuando el host se recupera, el invitado vuelve a solicitar aceptación si
        // la caída fue temporal. La ruta existente es idempotente y devuelve el
        // descriptor completo de las actividades.
        for session in joinedRooms
        where session.descriptor.hostDeviceID == peer.deviceID
            && (wasRecovering || session.accessState != .joined) {

            beginRecoveryJoin(in: session, from: peer)
        }

        // El historial explícito completa el snapshot corto del resume. El host
        // ofrece la conversación agregada; un invitado solo ofrece sus propios
        // mensajes, para que el host siga siendo el agregador y cada emisor su
        // propia autoridad.
        for session in sessions.values where session.contains(peer.deviceID) {
            sendChatHistory(of: session, to: peer.deviceID)
            outboxes[session.roomID]?.replay(to: peer.deviceID)
        }
    }

    func requestRoomDirectory(from peer: ConnectedPeer) {
        guard peer.supports(.rooms) else { return }
        send(
            .roomDirectoryRequest,
            to: [peer.deviceID],
            roomID: directoryRequestRoomID
        )
    }

    func handlePeerDisconnected(deviceID: DeviceID, reason: DisconnectReason?) {
        connectedPeers.removeValue(forKey: deviceID)
        for (roomID, operation) in pendingJoins where operation.hostDeviceID == deviceID {
            finishJoin(roomID, requestID: operation.id, result: .failure(RoomError.connectionLost))
        }
        var isMemberOfAnyRoom = false

        for session in sessions.values {
            guard session.contains(deviceID) else {
                session.removeJoinRequests(for: deviceID)
                continue
            }

            isMemberOfAnyRoom = true
            // Una caída de socket no es salir de la sala. La membresía, el chat y
            // las actividades se conservan hasta que expire el periodo de gracia.
        }

        if isMemberOfAnyRoom {
            beginTemporaryRecovery(for: deviceID, scheduleAttempt: true)
            scheduleHostMigration(for: deviceID)
        } else {
            cancelRecoveryIfUnused(for: deviceID)
        }
    }

    // MARK: - Anuncio

    func publishAdvertisement() {
        transport.updateAdvertisement(AdvertisementRecord(
            deviceID: identity.deviceID,
            displayName: identity.displayName,
            rooms: advertisedRoomDescriptors,
            totalRoomCount: hostedRooms.count
        ))
    }

    /// Republica tras cambiar el conjunto de actividades vivas en una sala que
    /// alojamos: el tipo anunciado se deriva de él. Los invitados no anuncian nada.
    func republishIfHosting(_ session: Room) {
        guard session.isLocalHost else { return }
        publishAdvertisement()
    }

    // MARK: - Envío

    func send(_ message: ControlMessage, to deviceIDs: [DeviceID], roomID: RoomID) {
        guard !deviceIDs.isEmpty,
              let envelope = try? Envelope(
                  roomID: roomID,
                  channel: .control,
                  senderDeviceID: identity.deviceID,
                  message: message
              ),
              envelope.payload.count <= Limits.maximumEnvelopeBytes
        else { return }

        for deviceID in deviceIDs where isPeerAdmitted(deviceID) {
            transport.enqueue(envelope, to: deviceID)
        }
    }

    func isPeerAdmitted(_ deviceID: DeviceID) -> Bool {
        guard let peer = connectedPeers[deviceID], deviceID != identity.deviceID else { return false }
        return transport.connectedPeers.contains {
            $0.deviceID == deviceID && $0.connectionSessionID == peer.connectionSessionID
        }
    }

    func broadcast(_ message: ControlMessage, in session: Room) {
        send(message, to: session.remoteMembers.map(\.deviceID), roomID: session.roomID)
    }

    // MARK: - Directorio y descarte de sesiones

    func advertisement(for deviceID: DeviceID) -> PeerAdvertisement? {
        discovery.advertisement(for: deviceID)
    }

    func discardSession(_ roomID: RoomID, publishes: Bool = true) {
        if let session = sessions.removeValue(forKey: roomID) {
            session.removeAllJoinRequests()
            transfers?.cancelAll(in: session)
            for member in session.remoteMembers {
                cancelRecoveryIfUnused(for: member.deviceID)
            }
        }
        outboxes.removeValue(forKey: roomID)
        if activeRoomID == roomID { activeRoomID = nil }
        if publishes { publishRooms() }
    }
}
