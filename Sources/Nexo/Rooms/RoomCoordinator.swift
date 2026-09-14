//
//  RoomCoordinator.swift
//  Project Dark
//
//  Created by Marcos del Castillo Camacho on 11/09/2026.
//

import Foundation

// MARK: - RoomCoordinator

/// Capa lógica de rooms. No conoce Network Framework: habla con el transporte a
/// través del contrato `PeerTransport` y con el dominio mediante `RoomSession`.
///
/// Topología: **malla**. El host introduce a los miembros entre sí enviando la
/// lista de membresía, y cada miembro abre una conexión directa con los demás que
/// pueda ver por Bonjour. Así ningún mensaje depende de que el host lo reenvíe y
/// una misma conexión física sirve a todas las rooms que compartan ese peer.
@MainActor
@Observable
public final class RoomCoordinator {

    // MARK: - Estado observable

    /// Rooms de las que el usuario forma parte, ya sea como host o invitado.
    public private(set) var sessions: [RoomID: RoomSession] = [:]
    /// Rooms anunciadas por peers cercanos y todavía no unidas.
    public private(set) var discoveredRooms: [RoomID: DiscoveredRoom] = [:]
    /// Última room con la que ha interactuado el usuario. La primera UI se centra
    /// en una sola room activa, pero el registro admite varias.
    public private(set) var activeRoomID: RoomID?

    // MARK: - Dependencias

    private let transport: any PeerTransport
    private let identity: LocalP2PIdentity
    private let registry: RoomActivityRegistry

    // MARK: - Estado interno

    private var advertisements: [TransportPeerID: PeerAdvertisement] = [:]
    private var connectedPeers: [String: ConnectedPeer] = [:]
    private var joinContinuations: [RoomID: CheckedContinuation<RoomSession, Error>] = [:]
    private var joinTimeoutTasks: [RoomID: Task<Void, Never>] = [:]
    /// Emisores por room. El chat y las actividades reciben el suyo a través de
    /// la sesión; el servicio de ficheros lo pide aquí.
    private var outboxes: [RoomID: RoomOutbox] = [:]

    /// Una pérdida física no altera la membresía lógica inmediatamente. El
    /// registro es por `applicationID` porque una conexión sirve a varias rooms.
    private var recoveryTasks: [String: Task<Void, Never>] = [:]
    private var recoveryDeadlines: [String: Date] = [:]

    /// Los replays conservan el mismo messageID. Este registro hace idempotente
    /// la recuperación para actividades que no conocen nada del transporte.
    private var receivedEnvelopeIDs: [RoomID: Set<UUID>] = [:]
    private var receivedEnvelopeOrder: [RoomID: [UUID]] = [:]

    /// Enganche del `FileTransferService`. Se inyecta desde el manager para no
    /// acoplar el coordinador al servicio de ficheros.
    public var fileTransferHandler: ((RoomEnvelope, RoomMember, RoomSession) -> Void)?

    /// Avisos de dominio para superficies globales como HomeView. El coordinador
    /// no crea toasts ni conoce navegación: solo publica hechos ya validados.
    public var noticeHandler: ((P2PNotice) -> Void)?

    // MARK: - Derivados

    public var activeRoom: RoomSession? {
        guard let activeRoomID else { return nil }
        return sessions[activeRoomID]
    }

    public var hostedRooms: [RoomSession] {
        sessions.values
            .filter(\.isLocalHost)
            .sorted { lhs, rhs in
                lhs.roomID.description < rhs.roomID.description
            }
    }

    public var joinedRooms: [RoomSession] {
        sessions.values
            .filter { !$0.isLocalHost }
            .sorted { lhs, rhs in
                lhs.roomID.description < rhs.roomID.description
            }
    }

    /// Descriptores publicados en el anuncio Bonjour.
    public var advertisedRoomDescriptors: [RoomDescriptor] {
        hostedRooms.map(\.descriptor)
    }

    /// Rooms descubiertas listas para mostrar, ordenadas de forma estable.
    public var availableRooms: [DiscoveredRoom] {
        discoveredRooms.values
            // Una sesión en reconexión no debe ocultar la room: si el host la
            // sigue anunciando, el usuario tiene que poder volver a entrar.
            .filter { room in
                guard let session = sessions[room.id] else { return true }
                return session.accessState != .joined && session.accessState != .awaitingApproval
            }
            .sorted { lhs, rhs in
                if lhs.name == rhs.name { return lhs.id.description < rhs.id.description }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// Rooms descubiertas que ofrecen la actividad indicada. Es lo que consume el
    /// lobby de un juego para listar partidas sin pasar por el chat.
    public func availableRooms(for kind: ActivityKind) -> [DiscoveredRoom] {
        availableRooms.filter { $0.activityKind == kind && $0.features.hasActivities }
    }

    // MARK: - Init

    public init(
        transport: any PeerTransport,
        identity: LocalP2PIdentity,
        registry: RoomActivityRegistry? = nil
    ) {
        self.transport = transport
        self.identity = identity
        self.registry = registry ?? .shared
    }

    // MARK: - Crear una room

    /// Crea una room hospedada localmente.
    ///
    /// `features` es lo que la hace flexible: `.chatOnly` para una sala de charla,
    /// `.gameOnly` para entrar directo a jugar sin chat, `.full` para ambas cosas.
    @discardableResult
    public func createRoom(
        name: String,
        features: RoomFeatures = .full,
        activityKind: ActivityKind? = nil,
        accessPolicy: RoomAccessPolicy = .open,
        capacity: Int? = nil
    ) -> RoomSession {
        var descriptor = RoomDescriptor(
            name: name,
            hostApplicationID: identity.applicationID,
            features: features,
            activityKind: activityKind,
            accessPolicy: accessPolicy,
            memberCount: 1,
            capacity: capacity
        )

        // RoomID usa UUID por defecto, pero no dejamos que una colisión improbable
        // pueda reemplazar una sesión local ya existente en el diccionario.
        while sessions[descriptor.id] != nil {
            descriptor = RoomDescriptor(
                name: name,
                hostApplicationID: identity.applicationID,
                features: features,
                activityKind: activityKind,
                accessPolicy: accessPolicy,
                memberCount: 1,
                capacity: capacity
            )
        }

        let session = makeSession(descriptor: descriptor, accessState: .joined)
        session.apply(members: [identity.member(role: .host)])
        sessions[descriptor.id] = session
        activeRoomID = descriptor.id

        publishAdvertisement()
        return session
    }

    // MARK: - Entrar en una room

    /// Solicita entrar en una room descubierta. Devuelve la sesión cuando el host
    /// acepta, o lanza si rechaza o no responde.
    @discardableResult
    public func join(_ room: DiscoveredRoom) async throws -> RoomSession {
        if let existing = sessions[room.id], existing.accessState == .joined {
            activeRoomID = room.id
            return existing
        }

        guard let advertisement = advertisements[room.advertisedBy] else {
            throw RoomError.peerUnavailable
        }

        guard !room.descriptor.isFull else { throw RoomError.roomFull }

        let host: ConnectedPeer
        do {
            host = try await transport.connect(to: advertisement)
        } catch {
            throw RoomError.transportFailure(error.localizedDescription)
        }

        // El peer que anuncia la room debe ser su host: solo se publican en TXT
        // las rooms propias. Si no coincide, el anuncio no es de fiar y la
        // solicitud se perdería en silencio.
        guard host.applicationID == room.descriptor.hostApplicationID else {
            throw RoomError.peerUnavailable
        }

        guard host.supports(.rooms) else {
            throw RoomError.incompatibleProtocol(host.protocolVersion)
        }

        let session = makeSession(descriptor: room.descriptor, accessState: .awaitingApproval)
        sessions[room.id] = session
        activeRoomID = room.id

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                joinContinuations[room.id] = continuation
                scheduleJoinTimeout(for: room.id)

                send(
                    .joinRoomRequest(JoinRoomRequestPayload(
                        roomID: room.id,
                        displayName: identity.displayName
                    )),
                    to: [room.descriptor.hostApplicationID],
                    roomID: room.id
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishJoin(room.id, result: .failure(CancellationError()))
            }
        }
    }

    // MARK: - Salir de una room

    /// Abandona la room. No cierra ninguna conexión física: las demás rooms y
    /// actividades que compartan esos peers siguen funcionando.
    public func leave(_ roomID: RoomID) {
        guard let session = sessions.removeValue(forKey: roomID) else { return }
        let remoteApplicationIDs = session.remoteMembers.map(\.applicationID)

        session.removeAllActivities(reason: "Has salido de la sala.")

        if session.isLocalHost {
            broadcast(
                .roomClosed(RoomClosedPayload(roomID: roomID, reason: "El anfitrión cerró la sala.")),
                in: session
            )
        } else {
            send(
                .leaveRoom(LeaveRoomPayload(roomID: roomID)),
                to: remoteApplicationIDs,
                roomID: roomID
            )
        }

        outboxes.removeValue(forKey: roomID)
        receivedEnvelopeIDs.removeValue(forKey: roomID)
        receivedEnvelopeOrder.removeValue(forKey: roomID)
        for applicationID in remoteApplicationIDs {
            cancelRecoveryIfUnused(for: applicationID)
        }

        // No reasignamos a otra sesión automáticamente: cuál sala pasa a ser la
        // activa es una decisión de navegación que le corresponde a la UI, no
        // una elección arbitraria por orden de diccionario.
        if activeRoomID == roomID {
            activeRoomID = nil
        }

        finishJoin(roomID, result: .failure(RoomError.roomNotFound))
        publishAdvertisement()
    }

    public func setActiveRoom(_ roomID: RoomID?) {
        activeRoomID = roomID
    }

    /// Emisor de una room concreta.
    public func outbox(for roomID: RoomID) -> RoomOutbox? {
        outboxes[roomID]
    }

    /// Olvida el descubrimiento sin tocar las rooms. Se usa al suspender: los
    /// anuncios caducan, pero la membresía se conserva para poder recuperarla al
    /// volver a primer plano.
    public func forgetDiscoveredPeers() {
        advertisements.removeAll()
        connectedPeers.removeAll()
        discoveredRooms = discoveredRooms.filter { sessions[$0.key] != nil }
    }

    /// Cierra todas las rooms. Lo usa el manager en logout o al detener el stack.
    public func closeAll(reason: String) {
        for task in recoveryTasks.values { task.cancel() }
        recoveryTasks.removeAll()
        recoveryDeadlines.removeAll()

        for session in sessions.values {
            session.removeAllActivities(reason: reason)
            session.setAccessState(.closed(reason: reason))
        }

        for roomID in joinContinuations.keys {
            finishJoin(roomID, result: .failure(RoomError.transportFailure(reason)))
        }

        sessions.removeAll()
        outboxes.removeAll()
        receivedEnvelopeIDs.removeAll()
        receivedEnvelopeOrder.removeAll()
        discoveredRooms.removeAll()
        advertisements.removeAll()
        connectedPeers.removeAll()
        activeRoomID = nil
    }

    // MARK: - Aprobación de entrada

    public func respond(to request: RoomJoinRequest, accept: Bool, reason: String? = nil) {
        guard let session = sessions[request.roomID],
              session.isLocalHost,
              session.removeJoinRequest(request.id) != nil else { return }

        guard accept else {
            send(
                .joinRoomRejected(JoinRoomRejectedPayload(
                    roomID: request.roomID,
                    reason: reason ?? "El anfitrión ha rechazado tu entrada."
                )),
                to: [request.applicationID],
                roomID: request.roomID
            )
            return
        }

        admit(applicationID: request.applicationID, displayName: request.displayName, to: session)
    }

    // MARK: - Actividades

    private enum ActivityAnnouncement {
        case started
        case invitation
    }

    /// Arranca una actividad dentro de la room. Solo participan los miembros
    /// indicados; el resto sigue en el chat con normalidad.
    @discardableResult
    public func startActivity(
        kind: ActivityKind,
        in roomID: RoomID,
        participants: [String]? = nil,
        isExclusive: Bool = true
    ) throws -> any RoomActivity {
        try createActivity(
            kind: kind,
            in: roomID,
            participants: participants,
            isExclusive: isExclusive,
            announcement: .started
        )
    }

    /// Arranca una actividad desde una conversación y anuncia una invitación
    /// explícita a los miembros incluidos en la actividad.
    @discardableResult
    public func inviteToActivity(
        kind: ActivityKind,
        in roomID: RoomID,
        participants: [String]? = nil,
        isExclusive: Bool = true
    ) throws -> any RoomActivity {
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
        participants: [String]?,
        isExclusive: Bool,
        announcement: ActivityAnnouncement
    ) throws -> any RoomActivity {
        guard let session = sessions[roomID] else { throw RoomError.roomNotFound }
        guard session.features.hasActivities else { throw RoomError.featureUnavailable("partidas") }
        guard !isExclusive || session.canStartActivity else { throw RoomError.activityAlreadyRunning }

        // Sin lista explícita la actividad queda abierta a la room: quien entre
        // después se incorpora solo mientras no haya empezado.
        let admitsRoomMembers = participants == nil
        var participantIDs = Set(participants ?? session.members.map(\.applicationID))
        participantIDs.insert(identity.applicationID)

        let descriptor = ActivityDescriptor(
            roomID: roomID,
            kind: kind,
            hostApplicationID: identity.applicationID,
            participantIDs: participantIDs,
            state: .lobby,
            admitsRoomMembers: admitsRoomMembers,
            isExclusive: isExclusive
        )

        guard let activity = registry.makeActivity(for: session.makeActivityContext(for: descriptor)) else {
            throw RoomError.featureUnavailable(kind.rawValue)
        }

        session.register(activity)

        let message: RoomControlMessage
        switch announcement {
        case .started:
            message = .activityStarted(ActivityLifecyclePayload(descriptor: descriptor))
        case .invitation:
            message = .activityInvite(ActivityLifecyclePayload(descriptor: descriptor))
        }

        send(
            message,
            to: participantIDs.filter { $0 != identity.applicationID }.sorted(),
            roomID: roomID
        )

        return activity
    }

    /// Termina la actividad. La room y su chat permanecen intactos.
    public func endActivity(_ activityID: ActivityID, in roomID: RoomID, reason: String) {
        guard let session = sessions[roomID],
              let activity = session.activity(activityID) else { return }

        let participants = activity.descriptor.participantIDs
            .filter { $0 != identity.applicationID }
            .sorted()

        if activity.isHost(identity.applicationID) {
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
    }
}

// MARK: - Eventos del transporte

@MainActor
public extension RoomCoordinator {

    func handleAdvertisement(_ advertisement: PeerAdvertisement) {
        advertisements[advertisement.endpointID] = advertisement

        guard advertisement.isCompatible else { return }

        // El TXT puede estar truncado a las primeras rooms. Solo aceptamos
        // descriptores cuyo host coincide con el dispositivo que los anuncia.
        let validDescriptors = advertisement.rooms.filter { descriptor in
            descriptor.hostApplicationID == advertisement.applicationID
        }
        let stillAdvertised = Set(validDescriptors.map(\.id))

        for descriptor in validDescriptors {
            discoveredRooms[descriptor.id] = DiscoveredRoom(
                descriptor: descriptor,
                advertisedBy: advertisement.endpointID,
                hostDisplayName: advertisement.displayName,
                discoveredAt: discoveredRooms[descriptor.id]?.discoveredAt ?? Date()
            )
        }

        // Si el TXT declara más rooms de las que caben, la ausencia de una room
        // no significa que se haya cerrado: el directorio completo llega después
        // del handshake. La reconciliación de eliminaciones se hace allí.
        if !advertisement.hasUndisclosedRooms {
            for (roomID, room) in discoveredRooms
            where room.advertisedBy == advertisement.endpointID && !stillAdvertised.contains(roomID) {
                discoveredRooms.removeValue(forKey: roomID)
            }
        }

        // La malla se completa de forma perezosa: cada vez que se ve un anuncio,
        // se intenta conectar con los miembros de nuestras rooms que aún faltan.
        reconnectMissingMembers()
    }

    func handleAdvertisementLost(_ endpointID: TransportPeerID) {
        advertisements.removeValue(forKey: endpointID)
        for (roomID, room) in discoveredRooms where room.advertisedBy == endpointID {
            discoveredRooms.removeValue(forKey: roomID)
        }
    }

    func handlePeerConnected(_ peer: ConnectedPeer) {
        let wasRecovering = recoveryDeadlines.removeValue(forKey: peer.applicationID) != nil
        recoveryTasks.removeValue(forKey: peer.applicationID)?.cancel()

        if connectedPeers[peer.applicationID]?.connectionSessionID == peer.connectionSessionID {
            return
        }
        connectedPeers[peer.applicationID] = peer

        // Bonjour solo puede anunciar un subconjunto de rooms. El handshake
        // permite pedir el catálogo completo sin abrir otra conexión física.
        requestRoomDirectory(from: peer)

        // El host reafirma la membresía, las actividades activas y el historial
        // corto de chat antes de reentregar los mensajes de la actividad.
        for session in hostedRooms where session.contains(peer.applicationID) {
            sendMembership(of: session, to: [peer.applicationID])
            sendResume(of: session, to: peer.applicationID)
        }

        // Una actividad también puede estar hospedada por un invitado. En ese
        // caso el host de la room no puede reconstruirla por sí solo; el dueño
        // de la actividad publica su descriptor a los participantes directos.
        for session in joinedRooms
        where session.contains(peer.applicationID)
            && session.activities.values.contains(where: {
                $0.isHost(identity.applicationID)
                    && $0.descriptor.includes(peer.applicationID)
            }) {
            sendResume(
                of: session,
                to: peer.applicationID,
                onlyActivitiesHostedByLocal: true
            )
        }

        // Al recuperar el host, el invitado vuelve a solicitar la aceptación si
        // la caída fue temporal. La ruta existente es idempotente y devuelve el
        // descriptor completo de las actividades.
        for session in joinedRooms
        where session.descriptor.hostApplicationID == peer.applicationID
            && (wasRecovering || session.accessState != .joined) {

            send(
                .joinRoomRequest(JoinRoomRequestPayload(
                    roomID: session.roomID,
                    displayName: identity.displayName
                )),
                to: [peer.applicationID],
                roomID: session.roomID
            )
        }

        // El historial explícito completa el snapshot corto. El host ofrece la
        // conversación agregada; un guest solo ofrece sus propios mensajes para
        // que el host siga siendo el agregador y cada emisor su autoridad.
        for session in sessions.values where session.contains(peer.applicationID) {
            sendChatHistory(
                of: session,
                to: peer.applicationID,
                onlyMessagesAuthoredByLocal: !session.isLocalHost
            )
            outboxes[session.roomID]?.replay(to: peer.applicationID)
        }
    }

    func requestRoomDirectory(from peer: ConnectedPeer) {
        guard peer.supports(.rooms) else { return }
        send(
            .roomDirectoryRequest,
            to: [peer.applicationID],
            roomID: RoomID()
        )
    }

    func handlePeerDisconnected(applicationID: String, reason: String?) {
        connectedPeers.removeValue(forKey: applicationID)
        var isMemberOfAnyRoom = false

        for session in sessions.values {
            guard session.contains(applicationID) else {
                session.removeJoinRequests(for: applicationID)
                continue
            }

            isMemberOfAnyRoom = true
            // Una pérdida del socket no es una salida de la room. Se conservan
            // membresía, chat y actividades hasta que expire la gracia.
        }

        if isMemberOfAnyRoom {
            beginTemporaryRecovery(for: applicationID, scheduleAttempt: true)
        } else {
            cancelRecoveryIfUnused(for: applicationID)
        }
    }

    func handleLifecycle(_ lifecycle: ConnectivityLifecycle) {
        switch lifecycle {
        case .suspended:
            // El transporte se cerrará, pero la presencia lógica no cambia. Al
            // volver a active se intentará recuperar cada miembro conservado.
            connectedPeers.removeAll()
            for session in sessions.values {
                for member in session.remoteMembers {
                    beginTemporaryRecovery(for: member.applicationID, scheduleAttempt: false)
                }
            }

        case .active:
            reconcilePhysicalPeers()
            for applicationID in recoveryDeadlines.keys {
                scheduleRecoveryAttempt(for: applicationID)
            }
            reconnectMissingMembers()

        case .disconnected:
            connectedPeers.removeAll()
            reconcilePhysicalPeers()
            for session in sessions.values {
                for member in session.remoteMembers where connectedPeers[member.applicationID] == nil {
                    beginTemporaryRecovery(for: member.applicationID, scheduleAttempt: true)
                }
            }

        case .idle, .reconnecting:
            break
        }
    }

    /// Punto de entrada de todo envelope recibido. El orden de validación es
    /// conexión física, room, membresía, canal y por último payload tipado.
    func route(_ envelope: RoomEnvelope, from peer: ConnectedPeer) {
        connectedPeers[peer.applicationID] = peer

        if envelope.channel == .control {
            guard remember(envelope.messageID, for: envelope.roomID) else { return }
            handleControl(envelope, from: peer)
            return
        }

        guard let session = sessions[envelope.roomID] else { return }
        guard session.contains(peer.applicationID),
              let member = session.member(peer.applicationID) else { return }

        switch envelope.channel {
        case .control:
            break

        case .chat:
            guard session.features.hasChat,
                  remember(envelope.messageID, for: envelope.roomID) else { return }
            session.chat?.receive(payload: envelope.payload, from: member)

        case .activity:
            guard let activityID = envelope.activityID,
                  let activity = session.activity(activityID),
                  activity.descriptor.includes(peer.applicationID),
                  remember(envelope.messageID, for: envelope.roomID) else { return }
            activity.receive(payload: envelope.payload, from: member)

        case .fileTransfer:
            guard session.features.hasFileTransfer,
                  remember(envelope.messageID, for: envelope.roomID) else { return }
            fileTransferHandler?(envelope, member, session)
        }
    }
}

// MARK: - Mensajes de control

@MainActor
private extension RoomCoordinator {

    func handleControl(_ envelope: RoomEnvelope, from peer: ConnectedPeer) {
        guard let message = try? envelope.decodePayload(as: RoomControlMessage.self) else { return }

        switch message {

        // MARK: Directorio

        case .roomDirectoryRequest:
            send(
                .roomDirectory(RoomDirectoryPayload(
                    hostDisplayName: identity.displayName,
                    rooms: advertisedRoomDescriptors
                )),
                to: [peer.applicationID],
                roomID: envelope.roomID
            )

        case .roomDirectory(let payload):
            guard let endpointID = endpointID(for: peer.applicationID) else { return }

            let validDescriptors = payload.rooms.filter {
                $0.hostApplicationID == peer.applicationID
            }
            let roomIDs = Set(validDescriptors.map(\.id))

            for descriptor in validDescriptors where sessions[descriptor.id] == nil {
                discoveredRooms[descriptor.id] = DiscoveredRoom(
                    descriptor: descriptor,
                    advertisedBy: endpointID,
                    hostDisplayName: payload.hostDisplayName,
                    discoveredAt: discoveredRooms[descriptor.id]?.discoveredAt ?? Date()
                )
            }

            // El directorio completo sí permite saber qué rooms han terminado,
            // incluso cuando el anuncio TXT solo contenía las primeras tres.
            for (roomID, room) in discoveredRooms
            where room.advertisedBy == endpointID && !roomIDs.contains(roomID) {
                discoveredRooms.removeValue(forKey: roomID)
            }

        // MARK: Membresía

        case .joinRoomRequest(let payload):
            handleJoinRequest(payload, from: peer)

        case .joinRoomAccepted(let payload):
            handleJoinAccepted(payload, from: peer)

        case .joinRoomRejected(let payload):
            guard let session = sessions[payload.roomID],
                  session.descriptor.hostApplicationID == peer.applicationID else { return }
            session.setAccessState(.rejected(reason: payload.reason))
            sessions.removeValue(forKey: payload.roomID)
            outboxes.removeValue(forKey: payload.roomID)
            receivedEnvelopeIDs.removeValue(forKey: payload.roomID)
            receivedEnvelopeOrder.removeValue(forKey: payload.roomID)
            cancelRecoveryIfUnused(for: peer.applicationID)
            // `join(_:)` marca la room como activa de forma optimista mientras
            // espera la respuesta del host. Si rechaza, hay que revertir eso:
            // si no, activeRoomID quedaría apuntando a una sesión ya eliminada.
            if activeRoomID == payload.roomID { activeRoomID = nil }
            finishJoin(payload.roomID, result: .failure(RoomError.joinRejected(payload.reason)))

        case .leaveRoom(let payload):
            guard let session = sessions[payload.roomID] else { return }
            if session.isLocalHost {
                remove(applicationID: peer.applicationID, from: session)
            } else {
                var members = session.members
                members.removeAll { $0.applicationID == peer.applicationID }
                session.apply(members: members)
            }

        case .roomMembershipChanged(let payload):
            guard let session = sessions[payload.descriptor.id],
                  payload.descriptor.hostApplicationID == peer.applicationID else { return }
            session.apply(descriptor: payload.descriptor)
            session.apply(members: payload.members)
            if session.accessState != .joined { session.setAccessState(.joined) }
            connectToMembers(of: session)

        case .roomResume(let payload):
            handleRoomResume(payload, from: peer, roomID: envelope.roomID)

        case .chatHistory(let payload):
            handleChatHistory(payload, from: peer, roomID: envelope.roomID)

        case .roomClosed(let payload):
            guard let session = sessions[payload.roomID],
                  session.descriptor.hostApplicationID == peer.applicationID else { return }
            session.removeAllActivities(reason: payload.reason)
            session.setAccessState(.closed(reason: payload.reason))
            sessions.removeValue(forKey: payload.roomID)
            outboxes.removeValue(forKey: payload.roomID)
            receivedEnvelopeIDs.removeValue(forKey: payload.roomID)
            receivedEnvelopeOrder.removeValue(forKey: payload.roomID)
            discoveredRooms.removeValue(forKey: payload.roomID)
            cancelRecoveryIfUnused(for: peer.applicationID)
            // Igual que en `leave`: no reasignamos a otra sesión por orden de
            // diccionario. Si el usuario quiere volver a otra sala, la UI la
            // activará explícitamente al navegar a ella.
            if activeRoomID == payload.roomID { activeRoomID = nil }
            noticeHandler?(.roomClosed(P2PRoomClosedNotice(
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
            guard let session = sessions[payload.roomID] else { return }
            session.removeActivity(payload.activityID, reason: payload.reason)

        case .activityLeft(let payload):
            guard let session = sessions[payload.roomID],
                  let activity = session.activity(payload.activityID),
                  let member = session.member(peer.applicationID) else { return }
            activity.participantDidLeave(member)

        case .activityEnded(let payload):
            guard let session = sessions[payload.roomID],
                  let activity = session.activity(payload.activityID),
                  activity.isHost(peer.applicationID) else { return }
            session.removeActivity(payload.activityID, reason: payload.reason)
        }
    }

    // MARK: Entrada

    /// Mezcla un chunk de historial. El host puede agregar mensajes de todos
    /// los miembros actuales; cualquier otro peer solo puede aportar mensajes
    /// cuyo autor sea él mismo.
    func handleChatHistory(
        _ payload: ChatHistoryPayload,
        from peer: ConnectedPeer,
        roomID: RoomID
    ) {
        guard let session = sessions[roomID],
              session.features.hasChat,
              session.contains(peer.applicationID),
              payload.roomID == roomID,
              payload.messages.count <= P2PLimits.recoveryChatMessageLimit,
              let chat = session.chat
        else { return }

        let messages = validatedChatHistoryMessages(
            payload.messages,
            from: peer,
            in: session
        )
        guard chat.merge(messages: messages), session.isLocalHost else { return }

        // Cada chunk puede llegar por separado. Republicar después de cada
        // merge es idempotente y garantiza que los peers que ya están online
        // converjan incluso si no reciben el mismo chunk original.
        for member in session.remoteMembers {
            sendChatHistory(of: session, to: member.applicationID)
        }
    }

    /// Valida y normaliza mensajes recibidos por un canal de recuperación.
    /// La identidad del envelope determina quién puede aportar contenido; el
    /// `senderDisplayName` incrustado nunca se considera confiable.
    func validatedChatHistoryMessages(
        _ messages: [ChatMessage],
        from peer: ConnectedPeer,
        in session: RoomSession,
        members: [RoomMember]? = nil
    ) -> [ChatMessage] {
        guard messages.count <= P2PLimits.recoveryChatMessageLimit else { return [] }

        let knownMembers = members ?? session.members
        let memberIDs = Set(knownMembers.map(\.applicationID))
        let isRoomHost = peer.applicationID == session.descriptor.hostApplicationID
        var messageIDs = Set<UUID>()
        var validatedMessages: [ChatMessage] = []
        validatedMessages.reserveCapacity(messages.count)

        for original in messages {
            guard messageIDs.insert(original.id).inserted,
                  original.roomID == session.roomID,
                  !original.senderApplicationID.isEmpty,
                  original.body.count <= 4_000
            else { continue }

            if original.senderApplicationID == "system" {
                guard isRoomHost,
                      original.kind == .systemInfo,
                      original.attachment == nil,
                      original.invitation == nil
                else { continue }

                var message = original
                message.senderDisplayName = "Sistema"
                validatedMessages.append(message)
                continue
            }

            guard memberIDs.contains(original.senderApplicationID),
                  original.kind != .systemInfo
            else { continue }

            if !isRoomHost,
               original.senderApplicationID != peer.applicationID {
                continue
            }

            switch original.kind {
            case .text:
                guard original.attachment == nil else { continue }

            case .attachment:
                guard let attachment = original.attachment,
                      original.invitation == nil,
                      attachment.fileSize > 0,
                      attachment.fileSize <= P2PLimits.maximumTransferBytes,
                      !attachment.fileName.isEmpty,
                      attachment.fileName.utf8.count <= 512,
                      !attachment.mimeType.isEmpty,
                      attachment.mimeType.utf8.count <= 256,
                      !attachment.checksum.isEmpty,
                      attachment.checksum.utf8.count <= 256
                else { continue }

            case .systemInfo:
                continue
            }

            if let invitation = original.invitation,
               invitation.roomID != session.roomID {
                continue
            }

            guard let member = knownMembers.first(where: {
                $0.applicationID == original.senderApplicationID
            }) else { continue }

            var message = original
            message.senderDisplayName = member.displayName
            validatedMessages.append(message)
        }

        return validatedMessages
    }

    /// Envía la conversación retenida en chunks que caben en un envelope de
    /// control. Un guest solo envía sus propios mensajes; el host envía el
    /// historial agregado que mantiene en su sesión.
    func sendChatHistory(
        of session: RoomSession,
        to applicationID: String,
        onlyMessagesAuthoredByLocal: Bool = false
    ) {
        guard session.features.hasChat,
              let chat = session.chat else { return }

        let messages = chat.messages.filter {
            !onlyMessagesAuthoredByLocal
                || $0.senderApplicationID == identity.applicationID
        }
        guard !messages.isEmpty else { return }

        var chunk: [ChatMessage] = []
        for message in messages {
            let candidate = chunk + [message]
            if candidate.count <= P2PLimits.recoveryChatMessageLimit,
               chatHistoryFits(candidate, roomID: session.roomID) {
                chunk = candidate
                continue
            }

            if !chunk.isEmpty {
                send(
                    .chatHistory(ChatHistoryPayload(
                        roomID: session.roomID,
                        messages: chunk
                    )),
                    to: [applicationID],
                    roomID: session.roomID
                )
                chunk.removeAll(keepingCapacity: true)
            }

            guard chatHistoryFits([message], roomID: session.roomID) else { continue }
            chunk = [message]
        }

        guard !chunk.isEmpty else { return }
        send(
            .chatHistory(ChatHistoryPayload(
                roomID: session.roomID,
                messages: chunk
            )),
            to: [applicationID],
            roomID: session.roomID
        )
    }

    func chatHistoryFits(_ messages: [ChatMessage], roomID: RoomID) -> Bool {
        let payload = ChatHistoryPayload(roomID: roomID, messages: messages)
        guard let encoded = try? P2PCoder.encode(RoomControlMessage.chatHistory(payload)) else {
            return false
        }
        return encoded.count <= P2PLimits.maximumEnvelopeBytes
    }

    /// Aplica el estado autoritativo del host y después deja que el journal
    /// reinyecte los envelopes posteriores al snapshot. Un invitado que hospeda
    /// una actividad puede enviar un resume parcial solo de esa actividad.
    func handleRoomResume(
        _ payload: RoomResumePayload,
        from peer: ConnectedPeer,
        roomID: RoomID
    ) {
        guard let session = sessions[roomID],
              payload.descriptor.id == roomID,
              payload.descriptor.hostApplicationID == session.descriptor.hostApplicationID,
              payload.members.count <= P2PLimits.recoveryMemberLimit,
              payload.activities.count <= P2PLimits.recoveryActivityLimit,
              payload.chatMessages.count <= P2PLimits.recoveryChatMessageLimit
        else { return }

        let payloadMemberIDs = payload.members.map(\.applicationID)
        let payloadMemberSet = Set(payloadMemberIDs)
        guard payloadMemberIDs.count == payloadMemberSet.count,
              payloadMemberSet.contains(payload.descriptor.hostApplicationID),
              payloadMemberSet.contains(identity.applicationID),
              payload.members.contains(where: {
                  $0.applicationID == payload.descriptor.hostApplicationID && $0.isHost
              }),
              payload.descriptor.memberCount == payload.members.count,
              payload.descriptor.capacity.map({ payload.members.count <= $0 }) ?? true,
              payload.activities.allSatisfy({ activity in
                  activity.roomID == roomID
                      && payloadMemberSet.contains(activity.hostApplicationID)
                      && activity.participantIDs.isSubset(of: payloadMemberSet)
              })
        else { return }

        let isRoomHost = peer.applicationID == session.descriptor.hostApplicationID
        let isValidActivityHost = payload.activities.allSatisfy {
            isRoomHost || $0.hostApplicationID == peer.applicationID
        }
        guard isValidActivityHost else { return }

        // Se valida el historial contra la membresía que el host está a punto
        // de publicar, antes de mutar descriptor, miembros o actividades.
        let validMessages = validatedChatHistoryMessages(
            payload.chatMessages,
            from: peer,
            in: session,
            members: isRoomHost ? payload.members : nil
        )

        if isRoomHost {
            session.apply(descriptor: payload.descriptor)
            session.apply(members: payload.members)
        }

        let activeDescriptors = payload.activities.filter {
            $0.isActive
                && $0.includes(identity.applicationID)
                && (isRoomHost || $0.hostApplicationID == peer.applicationID)
        }
        let activeIDs = Set(activeDescriptors.map(\.id))

        // Solo se reconcilian las actividades que controla el peer que envió
        // este snapshot. Las actividades de otros invitados no aparecen en el
        // snapshot del host de la room y deben conservarse.
        let staleActivities = session.activities.values.filter {
            $0.isHost(peer.applicationID) && !activeIDs.contains($0.id)
        }
        for activity in staleActivities {
            session.removeActivity(
                activity.id,
                reason: "La actividad ya no está activa."
            )
        }

        for descriptor in activeDescriptors {
            instantiateActivity(descriptor, in: session)
        }

        let didMerge = session.chat?.merge(messages: validMessages) ?? false

        if isRoomHost {
            session.setAccessState(.joined)
            connectToMembers(of: session)
        }

        // Un guest puede haber conservado mensajes propios que el host todavía
        // no tenía. Una vez agregados, el host vuelve a publicar la conversación
        // convergente al resto de la room.
        if session.isLocalHost && !isRoomHost && didMerge {
            for member in session.remoteMembers {
                sendChatHistory(of: session, to: member.applicationID)
            }
        }
    }

    func handleJoinRequest(_ payload: JoinRoomRequestPayload, from peer: ConnectedPeer) {
        guard let session = sessions[payload.roomID], session.isLocalHost else {
            send(
                .joinRoomRejected(JoinRoomRejectedPayload(
                    roomID: payload.roomID,
                    reason: "La sala ya no existe."
                )),
                to: [peer.applicationID],
                roomID: payload.roomID
            )
            return
        }

        // Reentrada de un miembro que ya estaba: se le reafirma la membresía.
        if session.contains(peer.applicationID) {
            sendAcceptance(of: session, to: peer.applicationID)
            return
        }

        guard !session.descriptor.isFull else {
            send(
                .joinRoomRejected(JoinRoomRejectedPayload(
                    roomID: payload.roomID,
                    reason: RoomError.roomFull.localizedDescription
                )),
                to: [peer.applicationID],
                roomID: payload.roomID
            )
            return
        }

        switch session.descriptor.accessPolicy {
        case .open:
            admit(applicationID: peer.applicationID, displayName: payload.displayName, to: session)

        case .approval:
            let request = RoomJoinRequest(
                roomID: payload.roomID,
                applicationID: peer.applicationID,
                displayName: payload.displayName
            )
            guard session.enqueueJoinRequest(request) else { return }

            noticeHandler?(.joinRequest(P2PJoinRequestNotice(
                requestID: request.id,
                roomID: request.roomID,
                displayName: request.displayName
            )))
        }
    }

    func handleJoinAccepted(_ payload: JoinRoomAcceptedPayload, from peer: ConnectedPeer) {
        guard payload.descriptor.hostApplicationID == peer.applicationID else { return }

        // Un RoomID nunca debe cambiar de anfitrión. Así un payload remoto no
        // puede reutilizar el identificador de una room local y reemplazarla.
        if let existing = sessions[payload.descriptor.id],
           existing.descriptor.hostApplicationID != peer.applicationID {
            return
        }

        let session = sessions[payload.descriptor.id]
            ?? makeSession(descriptor: payload.descriptor, accessState: .joined)

        session.apply(descriptor: payload.descriptor)
        session.apply(members: payload.members)
        session.setAccessState(.joined)
        sessions[payload.descriptor.id] = session
        activeRoomID = payload.descriptor.id

        // Actividades ya en marcha cuando entramos.
        for descriptor in payload.activities where descriptor.isActive {
            instantiateActivity(descriptor, in: session)
        }

        connectToMembers(of: session)
        if peer.applicationID == session.descriptor.hostApplicationID {
            sendChatHistory(
                of: session,
                to: peer.applicationID,
                onlyMessagesAuthoredByLocal: true
            )
        }
        finishJoin(payload.descriptor.id, result: .success(session))
    }

    func admit(applicationID: String, displayName: String, to session: RoomSession) {
        var members = session.members
        if !members.contains(where: { $0.applicationID == applicationID }) {
            members.append(RoomMember(
                applicationID: applicationID,
                displayName: displayName,
                role: .guest
            ))
        }
        session.apply(members: members)
        session.removeJoinRequests(for: applicationID)

        // Debe ir antes de la aceptación: así el descriptor que recibe el recién
        // llegado ya lo incluye como participante.
        admitToOpenActivities(applicationID: applicationID, in: session)

        sendAcceptance(of: session, to: applicationID)
        // El resto de la sala recibe la lista nueva y abre conexión con el recién
        // llegado, completando la malla.
        sendMembership(
            of: session,
            to: session.remoteMembers.map(\.applicationID).filter { $0 != applicationID }
        )
        publishAdvertisement()
    }

    /// Incorpora a un miembro nuevo a las actividades que hospedamos y siguen
    /// abiertas. Sin esto, quien entra después de crearse la partida nunca queda
    /// en `participantIDs` y sus mensajes se descartan al enrutarlos.
    func admitToOpenActivities(applicationID: String, in session: RoomSession) {
        guard let member = session.member(applicationID) else { return }

        for activity in session.activities.values
        where activity.isHost(identity.applicationID)
            && activity.descriptor.admitsRoomMembers
            && activity.descriptor.state == .lobby
            && !activity.descriptor.includes(applicationID) {

            var descriptor = activity.descriptor
            descriptor.participantIDs.insert(applicationID)
            activity.apply(descriptor: descriptor)
            activity.participantDidJoin(member)

            send(
                .activityStarted(ActivityLifecyclePayload(descriptor: descriptor)),
                to: descriptor.participantIDs.filter { $0 != identity.applicationID }.sorted(),
                roomID: session.roomID
            )
        }
    }

    func remove(applicationID: String, from session: RoomSession) {
        var members = session.members
        members.removeAll { $0.applicationID == applicationID }
        session.apply(members: members)
        session.removeJoinRequests(for: applicationID)
        cancelRecoveryIfUnused(for: applicationID)
        sendMembership(of: session, to: session.remoteMembers.map(\.applicationID))
        publishAdvertisement()
    }

    func sendAcceptance(of session: RoomSession, to applicationID: String) {
        send(
            .joinRoomAccepted(JoinRoomAcceptedPayload(
                descriptor: session.descriptor,
                members: session.members,
                activities: session.activities.values.map(\.descriptor).filter(\.isActive)
            )),
            to: [applicationID],
            roomID: session.roomID
        )
        sendChatHistory(of: session, to: applicationID)
    }

    func sendMembership(of session: RoomSession, to applicationIDs: [String]) {
        guard !applicationIDs.isEmpty else { return }
        send(
            .roomMembershipChanged(RoomMembershipPayload(
                descriptor: session.descriptor,
                members: session.members
            )),
            to: applicationIDs,
            roomID: session.roomID
        )
    }

    func sendResume(
        of session: RoomSession,
        to applicationID: String,
        onlyActivitiesHostedByLocal: Bool = false
    ) {
        let resumableChatMessages = session.chat?.messages.filter {
            !onlyActivitiesHostedByLocal || $0.senderApplicationID == identity.applicationID
        } ?? []
        var chatMessages = Array(
            resumableChatMessages.suffix(P2PLimits.recoveryChatMessageLimit)
        )
        let activities = Array(
            session.activities.values
                .filter { activity in
                    !onlyActivitiesHostedByLocal || activity.isHost(identity.applicationID)
                }
                .map(\.descriptor)
                .filter(\.isActive)
                .prefix(P2PLimits.recoveryActivityLimit)
        )

        // El límite se calcula sobre el payload codificado, no sobre el número
        // de mensajes: caracteres Unicode y metadatos pueden variar mucho.
        while true {
            let payload = RoomResumePayload(
                descriptor: session.descriptor,
                members: session.members,
                activities: activities,
                chatMessages: chatMessages
            )
            let encodedSize = (try? P2PCoder.encode(RoomControlMessage.roomResume(payload)))?.count ?? Int.max
            guard encodedSize > P2PLimits.maximumEnvelopeBytes,
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
            to: [applicationID],
            roomID: session.roomID
        )
    }

    // MARK: Actividades

    func handleActivityAnnouncement(
        _ descriptor: ActivityDescriptor,
        from peer: ConnectedPeer,
        publishesNotice: Bool
    ) {
        guard let session = sessions[descriptor.roomID],
              session.features.hasActivities,
              descriptor.hostApplicationID == peer.applicationID,
              descriptor.includes(identity.applicationID) else { return }

        let isNewActivity = session.activity(descriptor.id) == nil
        instantiateActivity(descriptor, in: session)

        guard publishesNotice,
              isNewActivity,
              descriptor.state == .lobby,
              session.activity(descriptor.id) != nil else { return }

        let hostDisplayName = session.member(descriptor.hostApplicationID)?.displayName ?? "El anfitrión"
        noticeHandler?(.activityInvitation(P2PActivityInvitationNotice(
            activityID: descriptor.id,
            roomID: descriptor.roomID,
            kind: descriptor.kind,
            hostDisplayName: hostDisplayName
        )))
    }

    func handleActivityJoinRequest(_ payload: ActivityMembershipPayload, from peer: ConnectedPeer) {
        guard let session = sessions[payload.roomID],
              let activity = session.activity(payload.activityID),
              activity.isHost(identity.applicationID) else { return }

        guard activity.descriptor.state == .lobby else {
            send(
                .activityJoinRejected(ActivityRejectionPayload(
                    roomID: payload.roomID,
                    activityID: payload.activityID,
                    reason: "La partida ya ha empezado."
                )),
                to: [peer.applicationID],
                roomID: payload.roomID
            )
            return
        }

        var descriptor = activity.descriptor
        descriptor.participantIDs.insert(peer.applicationID)
        activity.apply(descriptor: descriptor)

        if let member = session.member(peer.applicationID) {
            activity.participantDidJoin(member)
        }

        send(
            .activityJoinAccepted(ActivityLifecyclePayload(descriptor: descriptor)),
            to: descriptor.participantIDs.filter { $0 != identity.applicationID }.sorted(),
            roomID: payload.roomID
        )
    }

    func instantiateActivity(_ descriptor: ActivityDescriptor, in session: RoomSession) {
        if let existing = session.activity(descriptor.id) {
            // La misma actividad puede llegar por `activityStarted` y después por
            // `joinRoomAccepted` al reconectar. Reutilizarla conserva su buffer
            // de mensajes y cualquier estado local asociado.
            existing.apply(descriptor: descriptor)
            return
        }

        guard let activity = registry.makeActivity(for: session.makeActivityContext(for: descriptor))
        else { return }
        session.register(activity)
    }
}

// MARK: - Malla, anuncio y utilidades

@MainActor
private extension RoomCoordinator {

    func makeSession(descriptor: RoomDescriptor, accessState: RoomAccessState) -> RoomSession {
        let roomID = descriptor.id
        let outbox = RoomOutbox(
            roomID: roomID,
            transport: transport,
            identity: identity,
            recipients: { [weak self] in
                self?.sessions[roomID]?.remoteMembers.map(\.applicationID) ?? []
            }
        )

        outboxes[roomID] = outbox

        return RoomSession(
            descriptor: descriptor,
            identity: identity,
            outbox: outbox,
            accessState: accessState
        )
    }

    func reconcilePhysicalPeers() {
        for peer in transport.connectedPeers {
            handlePeerConnected(peer)
        }
    }

    /// Abre conexión con los miembros de una room que todavía no están
    /// conectados. La tarea es única por `applicationID`, aunque el peer esté
    /// en varias rooms.
    func connectToMembers(of session: RoomSession) {
        for member in session.remoteMembers where connectedPeers[member.applicationID] == nil {
            beginTemporaryRecovery(for: member.applicationID, scheduleAttempt: true)
        }
    }

    func reconnectMissingMembers() {
        for session in sessions.values {
            connectToMembers(of: session)
        }
    }

    func beginTemporaryRecovery(for applicationID: String, scheduleAttempt: Bool) {
        guard sessions.values.contains(where: { $0.contains(applicationID) }) else {
            cancelRecoveryIfUnused(for: applicationID)
            return
        }

        if recoveryDeadlines[applicationID] == nil {
            recoveryDeadlines[applicationID] = Date().addingTimeInterval(
                P2PLimits.temporaryDisconnectGracePeriod
            )
        }

        if scheduleAttempt {
            scheduleRecoveryAttempt(for: applicationID)
        }
    }

    func scheduleRecoveryAttempt(for applicationID: String) {
        guard recoveryTasks[applicationID] == nil,
              recoveryDeadlines[applicationID] != nil else { return }

        recoveryTasks[applicationID] = Task { @MainActor [weak self] in
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
                      let deadline = self.recoveryDeadlines[applicationID]
                else { return }

                guard Date() < deadline else {
                    self.expireTemporaryRecovery(for: applicationID)
                    return
                }
                guard self.connectedPeers[applicationID] == nil else { return }

                guard let advertisement = self.advertisement(for: applicationID) else {
                    continue
                }

                // `connect` espera al handshake físico. Si lo consigue, el
                // evento `peerConnected` cancela esta tarea y dispara el resume.
                if let peer = try? await self.transport.connect(to: advertisement) {
                    self.handlePeerConnected(peer)
                    return
                }
            }

            while !Task.isCancelled {
                guard let self,
                      let deadline = self.recoveryDeadlines[applicationID]
                else { return }

                guard Date() < deadline else {
                    self.expireTemporaryRecovery(for: applicationID)
                    return
                }
                guard self.connectedPeers[applicationID] == nil else { return }

                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }

                guard let advertisement = self.advertisement(for: applicationID) else {
                    continue
                }
                if let peer = try? await self.transport.connect(to: advertisement) {
                    self.handlePeerConnected(peer)
                    return
                }
            }
        }
    }

    func expireTemporaryRecovery(for applicationID: String) {
        guard let deadline = recoveryDeadlines[applicationID],
              Date() >= deadline else { return }

        recoveryDeadlines.removeValue(forKey: applicationID)
        recoveryTasks.removeValue(forKey: applicationID)?.cancel()

        guard connectedPeers[applicationID] == nil else { return }

        for session in sessions.values where session.contains(applicationID) {
            if session.isLocalHost {
                // La pérdida solo se vuelve una expulsión real después de la
                // ventana completa sin conseguir restablecer el peer.
                remove(applicationID: applicationID, from: session)
            } else if session.descriptor.hostApplicationID == applicationID {
                session.setAccessState(.reconnecting)
                session.chat?.appendSystemMessage("Se ha perdido la conexión con el anfitrión.")
                session.removeAllActivities(reason: "Se perdió la conexión con el anfitrión.")
            } else {
                var members = session.members
                members.removeAll { $0.applicationID == applicationID }
                session.apply(members: members)
            }
        }
    }

    func cancelRecoveryIfUnused(for applicationID: String) {
        guard !sessions.values.contains(where: { $0.contains(applicationID) }) else { return }
        recoveryTasks.removeValue(forKey: applicationID)?.cancel()
        recoveryDeadlines.removeValue(forKey: applicationID)
    }

    func advertisement(for applicationID: String) -> PeerAdvertisement? {
        advertisements.values.first { $0.applicationID == applicationID }
    }

    func endpointID(for applicationID: String) -> TransportPeerID? {
        advertisement(for: applicationID)?.endpointID
    }

    func remember(_ messageID: UUID, for roomID: RoomID) -> Bool {
        var ids = receivedEnvelopeIDs[roomID, default: []]
        guard ids.insert(messageID).inserted else { return false }

        var order = receivedEnvelopeOrder[roomID, default: []]
        if order.count >= P2PLimits.recoveryJournalLimit,
           let oldest = order.first {
            order.removeFirst()
            ids.remove(oldest)
        }
        order.append(messageID)
        receivedEnvelopeIDs[roomID] = ids
        receivedEnvelopeOrder[roomID] = order
        return true
    }

    func publishAdvertisement() {
        transport.updateAdvertisement(AdvertisementRecord(
            applicationID: identity.applicationID,
            displayName: identity.displayName,
            rooms: advertisedRoomDescriptors,
            totalRoomCount: hostedRooms.count
        ))
    }

    func send(_ message: RoomControlMessage, to applicationIDs: [String], roomID: RoomID) {
        guard !applicationIDs.isEmpty,
              let envelope = try? RoomEnvelope(
                  roomID: roomID,
                  channel: .control,
                  senderApplicationID: identity.applicationID,
                  message: message
              ),
              envelope.payload.count <= P2PLimits.maximumEnvelopeBytes
        else { return }

        for applicationID in applicationIDs where applicationID != identity.applicationID {
            transport.enqueue(envelope, to: applicationID)
        }
    }

    func broadcast(_ message: RoomControlMessage, in session: RoomSession) {
        send(message, to: session.remoteMembers.map(\.applicationID), roomID: session.roomID)
    }

    // MARK: Continuaciones de entrada

    func scheduleJoinTimeout(for roomID: RoomID) {
        joinTimeoutTasks[roomID]?.cancel()
        joinTimeoutTasks[roomID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: P2PLimits.joinTimeout)
            } catch {
                return
            }
            self?.finishJoin(roomID, result: .failure(RoomError.joinTimedOut))
        }
    }

    func finishJoin(_ roomID: RoomID, result: Result<RoomSession, Error>) {
        joinTimeoutTasks.removeValue(forKey: roomID)?.cancel()
        guard let continuation = joinContinuations.removeValue(forKey: roomID) else { return }

        switch result {
        case .success(let session):
            continuation.resume(returning: session)
        case .failure(let error):
            // Una entrada fallida no debe dejar una sesión fantasma en el registro.
            if sessions[roomID]?.accessState == .awaitingApproval {
                sessions.removeValue(forKey: roomID)
            }
            continuation.resume(throwing: error)
        }
    }
}
