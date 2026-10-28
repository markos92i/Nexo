//
//  RoomService.swift
//  Nexo
//

import Foundation
import OSLog

// MARK: - RoomTransferHandling

/// Vista mínima del servicio de transferencias que el coordinador de salas
/// necesita para reconciliar y limpiar transfers ligadas a una sala.
///
/// `FileTransferService` (Fase 6) todavía no existe en esta capa. En lugar de
/// acoplar `RoomService` a su tipo concreto, el coordinador invoca únicamente los
/// métodos declarados aquí y guarda la dependencia como opcional. Mientras sea
/// `nil`, cada punto de uso omite la llamada (los `guard let`/`?.` simplemente no
/// hacen nada), de modo que la Fase 6 enchufa el servicio real sin tocar el
/// enrutado de salas.
///
/// Conforma además `TransferURLProviding` para que, cuando exista, `Room` pueda
/// resolver las URLs locales en su snapshot a través de la misma instancia.
@NexoActor
public protocol RoomTransferHandling: TransferURLProviding {
    /// Cancela todas las transferencias (subidas y bajadas) de una sala.
    func cancelAll(in room: Room)
    /// Reajusta los destinatarios de las subidas de la sala tras un cambio de
    /// membresía.
    func reconcileMembers(in room: Room)
    /// Procesa un envelope del canal `.fileTransfer` recibido de un miembro.
    func handle(envelope: Envelope, from member: RoomMember, in room: Room)
}

// MARK: - RoomsSnapshot

/// Snapshot estructural del registro de salas: qué sesiones existen, qué salas
/// cercanas aún pueden unirse y cuál está activa.
///
/// El detalle vive en `Room.snapshots`: esto solo indica al consumidor qué
/// sesiones observar y qué aspecto tiene la lista de salas.
public struct RoomsSnapshot: Sendable {
    public let sessionIDs: [RoomID]
    /// Salas cercanas que aún no se han unido. Una sala con una entrada en curso
    /// sigue aquí, con su progreso en `joinProgress`.
    public let availableRooms: [DiscoveredRoom]
    public let activeRoomID: RoomID?
    public let sessionInstances: [RoomID: UUID]
    /// Entradas en curso iniciadas por el usuario con `join(_:)`.
    public let joinProgress: [RoomID: JoinProgress]
    public let revision: UInt64

    public init(
        sessionIDs: [RoomID],
        availableRooms: [DiscoveredRoom],
        activeRoomID: RoomID?,
        sessionInstances: [RoomID: UUID] = [:],
        joinProgress: [RoomID: JoinProgress] = [:],
        revision: UInt64 = 0
    ) {
        self.sessionIDs = sessionIDs
        self.availableRooms = availableRooms
        self.activeRoomID = activeRoomID
        self.sessionInstances = sessionInstances
        self.joinProgress = joinProgress
        self.revision = revision
    }
}

// MARK: - JoinProgress

/// Fase de una entrada a sala en curso, para mostrar el progreso en la UI.
public enum JoinProgress: Sendable, Equatable {
    /// Abriendo la conexión cifrada con el host.
    case connecting
    /// Conectado; esperando a que el host acepte (o a la aceptación automática
    /// de una sala abierta).
    case awaitingApproval
}

// MARK: - RoomService

/// Capa lógica de salas. No sabe nada de Network framework: habla con el
/// transporte a través del contrato `Transport` y con el dominio a través de
/// `Room`.
///
/// Topología: **malla**. El host presenta a los miembros entre sí enviando la
/// lista de membresía, y cada miembro abre una conexión directa con quien más
/// pueda ver vía Bonjour. Ningún mensaje depende de que el host lo retransmita, y
/// una sola conexión física sirve a todas las salas compartidas con ese peer.
@NexoActor
public final class RoomService {

    // MARK: - Estado observable

    /// Salas a las que pertenece el usuario, como host o invitado.
    public internal(set) var sessions: [RoomID: Room] = [:]
    /// Salas anunciadas por peers cercanos, aún no unidas.
    public var discoveredRooms: [RoomID: DiscoveredRoom] { discovery.rooms }
    /// Última sala con la que el usuario interactuó. La UI de primera parte se
    /// centra en una sala activa, pero el registro admite varias.
    public internal(set) var activeRoomID: RoomID?

    /// Pasos de entrada y salida de salas. Filtra por `category:rooms`.
    nonisolated static let log = Logger(subsystem: "com.nexo", category: "rooms")

    // MARK: - Dependencias

    let transport: any Transport
    /// Capacidad binaria del transporte, resuelta una vez en el init para evitar
    /// castear un existencial a otro existencial en caliente (dispara un crash del
    /// frontend de Swift 6.4).
    let binaryTransport: (any BinaryStreamOpening)?
    let identity: LocalIdentity
    let registry: ActivityRegistry
    let store: any MessageStore
    /// Servicio de transferencias opcional (Fase 6). Mientras sea `nil`, el
    /// enrutado de `.fileTransfer` se ignora y la reconciliación se omite.
    private(set) weak var transfers: (any RoomTransferHandling)?

    // MARK: - Estado interno

    let discovery = DiscoveryService()
    var connectedPeers: [DeviceID: ConnectedPeer] = [:]

    struct PendingJoin {
        let id: UUID
        let hostDeviceID: DeviceID
        var continuation: CheckedContinuation<Room, any Error>?
        let isRecovery: Bool
        var roomToJoin: DiscoveredRoom?
        var originalSessionInstanceID: UUID?
        var connectionSessionID: UUID?
        var sessionInstanceID: UUID?
        var connectionTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
    }
    var pendingJoins: [RoomID: PendingJoin] = [:]
    /// Emisores retenidos para replay de recuperación mientras sus salas viven.
    var outboxes: [RoomID: RoomOutbox] = [:]

    /// Una caída física no cambia de inmediato la membresía lógica. Indexado por
    /// `DeviceID` porque una conexión sirve a varias salas.
    var recoveryTasks: [DeviceID: Task<Void, Never>] = [:]
    var recoveryDeadlines: [DeviceID: Date] = [:]
    var hostMigrationTasks: [DeviceID: Task<Void, Never>] = [:]

    /// Los replays conservan el mismo messageID. Este registro hace la
    /// recuperación idempotente para actividades que no saben nada del transporte.
    struct ReceivedEnvelopeKey: Hashable {
        let sender: DeviceID
        let messageID: UUID
    }
    var receivedEnvelopeIDs: Set<ReceivedEnvelopeKey> = []
    var receivedEnvelopeOrder: [ReceivedEnvelopeKey] = []
    let directoryRequestRoomID = RoomID()

    private var noticeContinuations: [UUID: AsyncStream<RoomNotice>.Continuation] = [:]
    private var snapshotContinuations: [UUID: AsyncStream<RoomsSnapshot>.Continuation] = [:]
    private var transportEventContinuations: [UUID: AsyncStream<TransportEvent>.Continuation] = [:]
    private var revision: UInt64 = 0
    private var eventTask: Task<Void, Never>?
    private var byteStreamTask: Task<Void, Never>?
    private let incomingByteStreamPair = AsyncStream.makeStream(
        of: IncomingByteStream.self,
        bufferingPolicy: .bufferingOldest(16)
    )

    /// Eventos del transporte ya aplicados a las salas, para la presentación
    /// (anuncios, peers conectados, estado de la red). No incluye los envelopes
    /// recibidos: esos solo los consume Nexo. Cada suscriptor recibe todos los
    /// eventos desde que se suscribe.
    public var transportEvents: AsyncStream<TransportEvent> {
        let token = UUID()
        let pair = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .unbounded)
        pair.continuation.onTermination = { [weak self] _ in
            Task { @NexoActor [weak self] in
                self?.transportEventContinuations.removeValue(forKey: token)
            }
        }
        transportEventContinuations[token] = pair.continuation
        return pair.stream
    }

    /// Cada consumidor posee su suscripción; cancelar una vista no para a las demás.
    public var notices: AsyncStream<RoomNotice> {
        let token = UUID()
        let pair = AsyncStream.makeStream(of: RoomNotice.self, bufferingPolicy: .bufferingOldest(256))
        pair.continuation.onTermination = { [weak self] _ in
            Task { @NexoActor [weak self] in
                self?.noticeContinuations.removeValue(forKey: token)
            }
        }
        noticeContinuations[token] = pair.continuation
        return pair.stream
    }

    /// Cada suscripción arranca con el último estado estructural completo.
    public var snapshots: AsyncStream<RoomsSnapshot> {
        let token = UUID()
        let pair = AsyncStream.makeStream(of: RoomsSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        pair.continuation.onTermination = { [weak self] _ in
            Task { @NexoActor [weak self] in
                self?.snapshotContinuations.removeValue(forKey: token)
            }
        }
        snapshotContinuations[token] = pair.continuation
        pair.continuation.yield(roomsSnapshot())
        return pair.stream
    }

    // MARK: - Derivados

    public var activeRoom: Room? {
        guard let activeRoomID else { return nil }
        return sessions[activeRoomID]
    }

    /// Sesión para un ID obtenido de un snapshot.
    public func session(_ roomID: RoomID) -> Room? {
        sessions[roomID]
    }

    /// Snapshot estructural actual, para un consumidor que se suscribe después de
    /// que el registro ya cambió.
    public func currentRoomsSnapshot() -> RoomsSnapshot {
        roomsSnapshot()
    }

    func roomsSnapshot() -> RoomsSnapshot {
        RoomsSnapshot(
            sessionIDs: sessions.keys.sorted { $0.description < $1.description },
            availableRooms: availableRooms,
            activeRoomID: activeRoomID,
            sessionInstances: sessions.mapValues(\.instanceID),
            joinProgress: joinProgress,
            revision: revision
        )
    }

    /// Entradas en curso iniciadas con `join(_:)`. Las re-entradas automáticas
    /// tras una reconexión no cuentan: la sala ya está unida.
    public var joinProgress: [RoomID: JoinProgress] {
        pendingJoins.compactMapValues { operation in
            guard !operation.isRecovery else { return nil }
            return operation.roomToJoin == nil ? .awaitingApproval : .connecting
        }
    }

    func publishRooms() {
        revision &+= 1
        let snapshot = roomsSnapshot()
        for continuation in snapshotContinuations.values { continuation.yield(snapshot) }
    }

    func publishNotice(_ notice: RoomNotice) {
        for continuation in noticeContinuations.values { continuation.yield(notice) }
    }

    public var hostedRooms: [Room] {
        sessions.values
            .filter(\.isLocalHost)
            .sorted { lhs, rhs in
                lhs.roomID.description < rhs.roomID.description
            }
    }

    public var joinedRooms: [Room] {
        sessions.values
            .filter { !$0.isLocalHost }
            .sorted { lhs, rhs in
                lhs.roomID.description < rhs.roomID.description
            }
    }

    /// Descriptores publicados en el anuncio de Bonjour.
    ///
    /// Una sala creada desde chat no declara un tipo, así que en su lugar se
    /// anuncia el juego que está jugando ahora: eso es lo que la pone en la lista
    /// de salas cercanas de ese juego. Se deriva aquí en vez de almacenarse,
    /// porque escribirlo en el descriptor dejaría el tipo cuando la actividad
    /// termine.
    public var advertisedRoomDescriptors: [RoomDescriptor] {
        hostedRooms.map { session in
            guard session.descriptor.activityKind == nil,
                  let liveKind = session.liveActivityKind else { return session.descriptor }

            var descriptor = session.descriptor
            descriptor.activityKind = liveKind
            return descriptor
        }
    }

    /// Salas descubiertas listas para mostrar, en orden estable.
    /// Una sala en espera de aprobación sigue en la lista: la UI la pinta con su
    /// `joinProgress` en vez de hacerla desaparecer.
    public var availableRooms: [DiscoveredRoom] {
        discovery.availableRooms(isJoined: isJoined)
    }

    /// Salas descubiertas que ofrecen la actividad dada. Lo que usa el lobby de un
    /// juego para listar partidas sin pasar por el chat.
    public func availableRooms(for kind: ActivityKind) -> [DiscoveredRoom] {
        discovery.availableRooms(for: kind, isJoined: isJoined)
    }

    /// Una sesión que se está reconectando no oculta la sala: si el host sigue
    /// anunciándola, el usuario debe poder volver a entrar.
    private func isJoined(_ roomID: RoomID) -> Bool {
        sessions[roomID]?.accessState == .joined
    }

    /// Pide el catálogo autoritativo de salas a cada peer conectado. El TXT de
    /// Bonjour puede truncarse y no reconcilia salas que desaparecieron mientras
    /// la conexión física siguió abierta.
    public func refreshRoomDirectories() {
        for peer in connectedPeers.values {
            requestRoomDirectory(from: peer)
        }
    }

    // MARK: - Init

    public init(
        transport: any Transport,
        identity: LocalIdentity,
        registry: ActivityRegistry? = nil,
        store: (any MessageStore)? = nil
    ) {
        self.transport = transport
        let binaryTransport = transport as? any BinaryStreamOpening
        self.binaryTransport = binaryTransport
        self.identity = identity
        self.registry = registry ?? ActivityRegistry()
        self.store = store ?? InMemoryMessageStore()

        // El servicio es el único lector de los eventos del transporte: la app no
        // tiene que reenviarlos, y no puede olvidarse de hacerlo.
        let events = transport.events
        eventTask = Task { @NexoActor [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
                self.forward(event)
            }
        }

        if let incoming = binaryTransport?.incomingByteStreams {
            byteStreamTask = Task { @NexoActor [weak self] in
                for await stream in incoming {
                    guard let self else { return }
                    self.admitIncomingByteStream(stream)
                }
            }
        }
    }

    /// Solo entrega streams de miembros unidos a la sala que declara el stream.
    private func admitIncomingByteStream(_ incoming: IncomingByteStream) {
        guard let session = sessions[incoming.descriptor.roomID],
              session.accessState == .joined,
              session.contains(incoming.senderDeviceID),
              incoming.senderDeviceID != identity.deviceID else {
            // Dejar de iterar el stream lo cancela y avisa al emisor.
            return
        }
        incomingByteStreamPair.continuation.yield(incoming)
    }

    private func forward(_ event: TransportEvent) {
        if case .received = event { return }
        guard event.epoch == transport.epoch else { return }
        for continuation in transportEventContinuations.values { continuation.yield(event) }
    }

    /// Prepara las salas para que el transporte se pare de forma temporal (por
    /// ejemplo, al pasar a segundo plano). La membresía se conserva para
    /// recuperarse al volver. Llamar después de `transport.stop()`.
    public func suspend() {
        handleLifecycle(.suspended)
        forgetDiscoveredPeers()
    }

    /// Enchufa el servicio de transferencias (Fase 6). Antes de llamarlo, el
    /// enrutado de `.fileTransfer` se ignora.
    public func bindTransfers(_ service: any RoomTransferHandling) {
        transfers = service
        for session in sessions.values {
            session.bindTransfers(service)
        }
    }

    isolated deinit {
        for operation in pendingJoins.values {
            operation.connectionTask?.cancel()
            operation.timeoutTask?.cancel()
            operation.continuation?.resume(throwing: CancellationError())
        }
        eventTask?.cancel()
        byteStreamTask?.cancel()
        incomingByteStreamPair.continuation.finish()
        for task in recoveryTasks.values { task.cancel() }
        for task in hostMigrationTasks.values { task.cancel() }
        for continuation in noticeContinuations.values { continuation.finish() }
        for continuation in snapshotContinuations.values { continuation.finish() }
        for continuation in transportEventContinuations.values { continuation.finish() }
    }

    public func registerActivity(_ kind: ActivityKind, factory: @escaping ActivityRegistry.Factory) {
        registry.register(kind, factory: factory)
    }

    public func supportsActivity(_ kind: ActivityKind) -> Bool {
        registry.isRegistered(kind)
    }

    // MARK: - Crear una sala

    /// Crea una sala alojada localmente.
    ///
    /// `features` es lo que lo hace flexible: `.chatOnly` para una sala de chat,
    /// `.gameOnly` para saltar directo a un juego sin chat, `.full` para ambos.
    @discardableResult
    public func createRoom(
        name: String,
        features: RoomFeatures = .full,
        activityKind: ActivityKind? = nil,
        accessPolicy: RoomAccessPolicy = .open,
        capacity: Int? = nil
    ) -> Room {
        var descriptor = RoomDescriptor(
            name: name,
            hostDeviceID: identity.deviceID,
            features: features,
            activityKind: activityKind,
            accessPolicy: accessPolicy,
            memberCount: 1,
            capacity: capacity
        )

        // RoomID por defecto es un UUID, pero que una colisión improbable no
        // reemplace una sesión local existente en el diccionario.
        while sessions[descriptor.id] != nil {
            descriptor = RoomDescriptor(
                name: name,
                hostDeviceID: identity.deviceID,
                features: features,
                activityKind: activityKind,
                accessPolicy: accessPolicy,
                memberCount: 1,
                capacity: capacity
            )
        }

        let session = makeSession(descriptor: descriptor, accessState: .joined)
        apply([identity.member(role: .host)], to: session)
        sessions[descriptor.id] = session
        activeRoomID = descriptor.id

        publishAdvertisement()
        publishRooms()
        return session
    }

    public func setActiveRoom(_ roomID: RoomID?) {
        activeRoomID = roomID
        publishRooms()
    }

    /// Olvida el descubrimiento sin tocar las salas. Se usa al suspender: los
    /// anuncios expiran, pero la membresía se conserva para recuperarse al volver
    /// a primer plano.
    public func forgetDiscoveredPeers() {
        discovery.suspend(keeping: Set(sessions.keys))
        connectedPeers.removeAll()
        publishRooms()
    }

    /// Cierra todas las salas. Lo usa el gestor al cerrar sesión o al parar la pila.
    public func closeAll(reason: DisconnectReason) {
        for task in recoveryTasks.values { task.cancel() }
        recoveryTasks.removeAll()
        recoveryDeadlines.removeAll()
        for task in hostMigrationTasks.values { task.cancel() }
        hostMigrationTasks.removeAll()

        for session in sessions.values {
            transfers?.cancelAll(in: session)
            session.removeAllJoinRequests()
            session.removeAllActivities(reason: reason)
            session.setAccessState(.closed(reason: reason))
        }

        for roomID in Array(pendingJoins.keys) {
            finishJoin(roomID, result: .failure(RoomError.transportFailure(reason)), publishes: false)
        }

        sessions.removeAll()
        outboxes.removeAll()
        receivedEnvelopeIDs.removeAll()
        receivedEnvelopeOrder.removeAll()
        discovery.clear()
        connectedPeers.removeAll()
        activeRoomID = nil
        publishRooms()
    }

    // MARK: - Fábrica de sesiones y membresía compartida

    func apply(_ members: [RoomMember], to session: Room) {
        session.apply(members: members)
        transfers?.reconcileMembers(in: session)
    }

    // MARK: - Canal binario de alta velocidad (servicio de sala)

    /// Abre un stream binario de alta velocidad (QUIC) hacia un miembro de la sala,
    /// para datos densos (estado de juego complejo, media). Es un servicio de la
    /// sala: requiere que el peer sea miembro y que el transporte ofrezca la
    /// capacidad `BinaryStreamOpening` (el `NetworkTransport` sí; un mock no).
    ///
    /// El par consume estos streams por `incomingByteStreams`.
    /// - Note: usa `throws` sin tipar (no `throws(RoomError)`) a propósito: la
    ///   combinación de typed throws + async + mapeo en `catch` dispara un crash
    ///   de SILGen en el frontend de Swift 6.4. El error lanzado sigue siendo
    ///   siempre un `RoomError`.
    public func openByteStream(
        to deviceID: DeviceID,
        in roomID: RoomID,
        mimeType: String = "application/octet-stream",
        name: String? = nil
    ) async throws -> ByteStreamWriter {
        guard let session = sessions[roomID] else { throw RoomError.roomNotFound }
        guard session.accessState == .joined else { throw RoomError.notAMember }
        guard session.contains(deviceID), deviceID != identity.deviceID else { throw RoomError.notAMember }
        guard let binary = binaryTransport else {
            throw RoomError.transportFailure(.binaryStreamsUnsupported)
        }
        let descriptor = ByteStreamDescriptor(roomID: roomID, mimeType: mimeType, name: name)
        let result: Result<ByteStreamWriter, TransportError>
        do {
            result = .success(try await binary.openByteStream(to: deviceID, descriptor: descriptor))
        } catch {
            result = .failure(error)
        }
        switch result {
        case .success(let stream): return stream
        case .failure(let error): throw RoomError.transportFailure(error.disconnectReason)
        }
    }

    /// Streams binarios entrantes de todos los peers (si el transporte los ofrece).
    /// Cada stream trae su `ByteStreamDescriptor` (incluye el `roomID`) y el
    /// emisor. Un único consumidor.
    public var incomingByteStreams: AsyncStream<IncomingByteStream> {
        incomingByteStreamPair.stream
    }

    func makeSession(descriptor: RoomDescriptor, accessState: RoomAccessState) -> Room {
        let roomID = descriptor.id
        let outbox = RoomOutbox(
            roomID: roomID,
            transport: transport,
            identity: identity,
            isPeerAdmitted: { [weak self] in self?.isPeerAdmitted($0) ?? false }
        )

        outboxes[roomID] = outbox

        let session = Room(
            descriptor: descriptor,
            identity: identity,
            outbox: outbox,
            store: store,
            accessState: accessState
        )
        if let transfers {
            session.bindTransfers(transfers)
        }
        session.onJoinRequestsRemoved = { [weak self] removed in
            for request in removed {
                self?.publishNotice(.joinRequestResolved(JoinRequestNotice(
                    requestID: request.id,
                    roomID: request.roomID,
                    displayName: request.displayName
                )))
            }
        }
        return session
    }
}
