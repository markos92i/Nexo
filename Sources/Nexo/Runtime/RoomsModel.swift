//
//  RoomsModel.swift
//  Nexo
//

import Foundation
import Observation

// MARK: - RoomsModel

/// Copia observable, en el hilo principal, del estado de `RoomService`, lista
/// para SwiftUI.
///
/// Evita que cada app escriba el mismo código: suscribirse a los snapshots,
/// seguir cada sala con su instancia, descartar revisiones viejas y repartir los
/// avisos. `RoomState` es lo que la app guarda por sala: el propio
/// `RoomSnapshot`, o un tipo derivado que se calcula fuera del hilo principal
/// (por ejemplo, el chat ya ordenado).
@MainActor
@Observable
public final class RoomsModel<RoomState: Sendable> {

    // MARK: Estado observable

    public private(set) var lifecycle: ConnectivityLifecycle = .idle
    public private(set) var localNetworkPermission: LocalNetworkPermission = .unknown
    public private(set) var advertisements: [PeerAdvertisement] = []
    public private(set) var connectedPeers: [ConnectedPeer] = []
    public private(set) var sessionIDs: [RoomID] = []
    public private(set) var availableRooms: [DiscoveredRoom] = []
    public private(set) var activeRoomID: RoomID?
    public private(set) var joinProgress: [RoomID: JoinProgress] = [:]
    public private(set) var roomStates: [RoomID: RoomState] = [:]

    // MARK: Ganchos para la app

    /// Se llama tras aplicar cada evento del transporte, para la lógica propia de
    /// la app (por ejemplo, reaccionar a una caída de la red).
    @ObservationIgnored public var onTransportEvent: ((TransportEvent) -> Void)?
    /// Se llama tras cambiar la lista de salas o el estado de alguna sala.
    @ObservationIgnored public var onRoomsChanged: (() -> Void)?

    // MARK: Estado interno

    @ObservationIgnored private let service: RoomService
    @ObservationIgnored private let makeState: @Sendable (RoomSnapshot, RoomState?) -> RoomState
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var sessionInstances: [RoomID: UUID] = [:]
    @ObservationIgnored private var roomRevisions: [RoomID: UInt64] = [:]
    @ObservationIgnored private var sessionTasks: [RoomID: Task<Void, Never>] = [:]
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var noticeContinuations: [UUID: AsyncStream<RoomNotice>.Continuation] = [:]
    /// Avisos llegados sin nadie escuchando; se entregan al primer suscriptor.
    @ObservationIgnored private var pendingNotices: [RoomNotice] = []

    // MARK: Init

    /// - Parameter makeState: deriva el estado de una sala a partir de su
    ///   snapshot y del estado anterior (para reutilizar trabajo). Se ejecuta en
    ///   `NexoActor`, fuera del hilo principal.
    public init(
        service: RoomService,
        makeState: @escaping @Sendable (RoomSnapshot, RoomState?) -> RoomState
    ) {
        self.service = service
        self.makeState = makeState
        start()
    }

    isolated deinit {
        for task in tasks { task.cancel() }
        for task in sessionTasks.values { task.cancel() }
        for continuation in noticeContinuations.values { continuation.finish() }
    }

    // MARK: API

    /// Avisos de salas (solicitudes, invitaciones, cierres). Cuando llega un
    /// aviso, el estado de la sala ya incluye lo que anuncia: una solicitud ya
    /// está en `pendingJoinRequests`.
    public var notices: AsyncStream<RoomNotice> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: RoomNotice.self, bufferingPolicy: .bufferingOldest(256))
        noticeContinuations[id] = continuation
        for notice in pendingNotices { continuation.yield(notice) }
        pendingNotices.removeAll()
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.noticeContinuations.removeValue(forKey: id) }
        }
        return stream
    }

    /// Olvida anuncios y peers, por ejemplo al suspender el transporte.
    public func clearPeers() {
        advertisements.removeAll()
        connectedPeers.removeAll()
    }

    // MARK: Suscripciones

    private func start() {
        let service = service
        let makeState = makeState

        tasks.append(Task { @NexoActor [weak self] in
            for await event in service.transportEvents {
                guard let self else { return }
                await self.apply(event)
            }
        })

        tasks.append(Task { @NexoActor [weak self] in
            for await snapshot in service.snapshots {
                guard let self else { return }
                await self.apply(snapshot)
            }
        })

        tasks.append(Task { @NexoActor [weak self] in
            for await notice in service.notices {
                // Captura el estado en el mismo paso del actor que el aviso.
                let rooms = service.currentRoomsSnapshot()
                let session = service.session(notice.roomID)
                let room = session.map { session in
                    let snapshot = session.snapshot()
                    return (makeState(snapshot, nil), snapshot.revision, session.instanceID)
                }
                guard let self else { return }
                await self.deliver(notice, rooms: rooms, room: room)
            }
        })
    }

    private func observeSession(_ roomID: RoomID, instanceID: UUID) {
        let service = service
        let makeState = makeState
        sessionTasks[roomID] = Task { @NexoActor [weak self] in
            guard let session = service.session(roomID), session.instanceID == instanceID else { return }
            var previous: RoomState?
            for await snapshot in session.snapshots {
                guard !Task.isCancelled else { return }
                let state = makeState(snapshot, previous)
                previous = state
                guard let self else { return }
                await self.apply(state, revision: snapshot.revision, roomID: roomID, instanceID: instanceID)
            }
        }
    }

    // MARK: Aplicación

    private func apply(_ event: TransportEvent) {
        switch event {
        case .advertisementFound(let advertisement, _), .advertisementUpdated(let advertisement, _):
            if let index = advertisements.firstIndex(where: { $0.endpointID == advertisement.endpointID }) {
                advertisements[index] = advertisement
            } else {
                advertisements.append(advertisement)
            }
        case .advertisementLost(let endpointID, _):
            advertisements.removeAll { $0.endpointID == endpointID }
        case .peerConnected(let peer, _):
            connectedPeers.removeAll { $0.deviceID == peer.deviceID }
            connectedPeers.append(peer)
        case .peerDisconnected(let deviceID, _, _):
            connectedPeers.removeAll { $0.deviceID == deviceID }
        case .lifecycleChanged(let state, _):
            lifecycle = state
        case .localNetworkPermissionChanged(let state, _):
            localNetworkPermission = state
        case .received:
            break
        }
        onTransportEvent?(event)
    }

    private func apply(_ snapshot: RoomsSnapshot) {
        guard snapshot.revision >= revision else { return }
        revision = snapshot.revision
        sessionIDs = snapshot.sessionIDs
        availableRooms = snapshot.availableRooms
        activeRoomID = snapshot.activeRoomID
        joinProgress = snapshot.joinProgress

        // Una sala recreada (otra instancia) empieza de cero.
        for roomID in Array(sessionTasks.keys) where sessionInstances[roomID] != snapshot.sessionInstances[roomID] {
            sessionTasks.removeValue(forKey: roomID)?.cancel()
            roomStates.removeValue(forKey: roomID)
            roomRevisions.removeValue(forKey: roomID)
        }
        sessionInstances = snapshot.sessionInstances
        for (roomID, instanceID) in sessionInstances where sessionTasks[roomID] == nil {
            observeSession(roomID, instanceID: instanceID)
        }
        onRoomsChanged?()
    }

    private func apply(_ state: RoomState, revision: UInt64, roomID: RoomID, instanceID: UUID) {
        guard sessionInstances[roomID] == instanceID,
              roomRevisions[roomID].map({ $0 <= revision }) ?? true
        else { return }
        roomRevisions[roomID] = revision
        roomStates[roomID] = state
        onRoomsChanged?()
    }

    private func deliver(_ notice: RoomNotice, rooms: RoomsSnapshot, room: (RoomState, UInt64, UUID)?) {
        apply(rooms)
        if let (state, revision, instanceID) = room {
            apply(state, revision: revision, roomID: notice.roomID, instanceID: instanceID)
        }
        guard !noticeContinuations.isEmpty else {
            if pendingNotices.count == 256 { pendingNotices.removeFirst() }
            pendingNotices.append(notice)
            return
        }
        for continuation in noticeContinuations.values { continuation.yield(notice) }
    }
}

extension RoomsModel where RoomState == RoomSnapshot {
    /// Modelo que guarda el snapshot de cada sala tal cual.
    public convenience init(service: RoomService) {
        self.init(service: service) { snapshot, _ in snapshot }
    }
}
