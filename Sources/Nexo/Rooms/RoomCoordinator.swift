//
//  RoomCoordinator.swift
//  Nexo
//

import Foundation

// MARK: - RoomsSnapshot

/// Structural snapshot of the room registry: which sessions exist, which
/// nearby rooms can still be joined and which room is active.
///
/// Detail lives in `RoomSession.snapshots`: this only tells a consumer which
/// sessions to observe and what the room list looks like.
public struct RoomsSnapshot: Sendable {
    public let sessionIDs: [RoomID]
    public let availableRooms: [DiscoveredRoom]
    public let activeRoomID: RoomID?
    public let sessionInstances: [RoomID: UUID]
    public let revision: UInt64

    public init(
        sessionIDs: [RoomID],
        availableRooms: [DiscoveredRoom],
        activeRoomID: RoomID?,
        sessionInstances: [RoomID: UUID] = [:],
        revision: UInt64 = 0
    ) {
        self.sessionIDs = sessionIDs
        self.availableRooms = availableRooms
        self.activeRoomID = activeRoomID
        self.sessionInstances = sessionInstances
        self.revision = revision
    }
}

// MARK: - RoomCoordinator

/// Logical layer for rooms. Knows nothing about Network framework: talks to
/// the transport through the `PeerTransport` contract and to the domain
/// through `RoomSession`.
///
/// Topology: **mesh**. The host introduces members to each other by sending
/// the membership list, and each member opens a direct connection to whoever
/// else it can see via Bonjour. No message ever depends on the host relaying
/// it, and one physical connection serves every room shared with that peer.
@NexoActor
public final class RoomCoordinator {

    // MARK: - Observable state

    /// Rooms the user belongs to, either as host or guest.
    public private(set) var sessions: [RoomID: RoomSession] = [:]
    /// Rooms advertised by nearby peers, not yet joined.
    public var discoveredRooms: [RoomID: DiscoveredRoom] { directory.rooms }
    /// Last room the user interacted with. The first-party UI focuses on one
    /// active room, but the registry supports several.
    public private(set) var activeRoomID: RoomID?

    // MARK: - Dependencies

    private let transport: any PeerTransport
    private let identity: LocalP2PIdentity
    private let registry: RoomActivityRegistry

    // MARK: - Internal state

    private var directory = RoomDirectory()
    private var connectedPeers: [String: ConnectedPeer] = [:]
    private struct PendingJoin {
        let id: UUID
        let hostApplicationID: String
        var continuation: CheckedContinuation<RoomSession, Error>?
        let isRecovery: Bool
        var roomToJoin: DiscoveredRoom?
        var originalSessionInstanceID: UUID?
        var connectionSessionID: UUID?
        var sessionInstanceID: UUID?
        var connectionTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
    }
    private var pendingJoins: [RoomID: PendingJoin] = [:]
    /// Senders retained for recovery replay while their rooms are active.
    private var outboxes: [RoomID: RoomOutbox] = [:]

    /// A physical drop doesn't immediately change logical membership. Keyed
    /// by `applicationID` because one connection serves several rooms.
    private var recoveryTasks: [String: Task<Void, Never>] = [:]
    private var recoveryDeadlines: [String: Date] = [:]
    private var hostMigrationTasks: [String: Task<Void, Never>] = [:]

    /// Replays keep the same messageID. This registry makes recovery
    /// idempotent for activities that know nothing about the transport.
    private struct ReceivedEnvelopeKey: Hashable {
        let sender: String
        let messageID: UUID
    }
    private var receivedEnvelopeIDs: Set<ReceivedEnvelopeKey> = []
    private var receivedEnvelopeOrder: [ReceivedEnvelopeKey] = []
    private let directoryRequestRoomID = RoomID()

    public let transfers: FileTransferService
    private var noticeContinuations: [UUID: AsyncStream<P2PNotice>.Continuation] = [:]
    private var snapshotContinuations: [UUID: AsyncStream<RoomsSnapshot>.Continuation] = [:]
    private var revision: UInt64 = 0

    /// Each consumer owns its subscription; cancelling a view cannot stop others.
    public var notices: AsyncStream<P2PNotice> {
        let token = UUID()
        let pair = AsyncStream.makeStream(of: P2PNotice.self, bufferingPolicy: .bufferingOldest(256))
        pair.continuation.onTermination = { [weak self] _ in
            Task { @NexoActor [weak self] in
                self?.noticeContinuations.removeValue(forKey: token)
            }
        }
        noticeContinuations[token] = pair.continuation
        return pair.stream
    }

    /// Each subscription starts with the latest complete structural state.
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

    // MARK: - Derived

    public var activeRoom: RoomSession? {
        guard let activeRoomID else { return nil }
        return sessions[activeRoomID]
    }

    /// Session for an ID obtained from a snapshot.
    public func session(_ roomID: RoomID) -> RoomSession? {
        sessions[roomID]
    }

    /// Current structural snapshot, for a consumer that subscribes after the
    /// registry already changed.
    public func currentRoomsSnapshot() -> RoomsSnapshot {
        roomsSnapshot()
    }

    private func roomsSnapshot() -> RoomsSnapshot {
        RoomsSnapshot(
            sessionIDs: sessions.keys.sorted { $0.description < $1.description },
            availableRooms: availableRooms,
            activeRoomID: activeRoomID,
            sessionInstances: sessions.mapValues(\.instanceID),
            revision: revision
        )
    }

    private func publishRooms() {
        revision &+= 1
        let snapshot = roomsSnapshot()
        for continuation in snapshotContinuations.values { continuation.yield(snapshot) }
    }

    private func publishNotice(_ notice: P2PNotice) {
        for continuation in noticeContinuations.values { continuation.yield(notice) }
    }

    func scheduleHostMigration(for applicationID: String) {
        guard hostMigrationTasks[applicationID] == nil else { return }
        hostMigrationTasks[applicationID] = Task { @NexoActor [weak self] in
            do {
                try await Task.sleep(for: P2PLimits.hostMigrationDelay)
            } catch {
                return
            }
            guard let self,
                  self.connectedPeers[applicationID] == nil else { return }
            for session in self.sessions.values where session.contains(applicationID) {
                if session.descriptor.hostApplicationID == applicationID {
                    _ = self.migrateRoomHost(after: applicationID, in: session)
                } else {
                    self.migrateActivities(hostedBy: applicationID, in: session)
                }
            }
            self.hostMigrationTasks.removeValue(forKey: applicationID)
        }
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

    /// Descriptors published in the Bonjour advertisement.
    ///
    /// A room created from chat has no declared kind, so the game it is playing
    /// right now is advertised instead: that is what puts it in the game's list
    /// of nearby rooms. Derived here rather than stored, because writing it back
    /// into the descriptor would leave the kind behind when the activity ends.
    public var advertisedRoomDescriptors: [RoomDescriptor] {
        hostedRooms.map { session in
            guard session.descriptor.activityKind == nil,
                  let liveKind = session.liveActivityKind else { return session.descriptor }

            var descriptor = session.descriptor
            descriptor.activityKind = liveKind
            return descriptor
        }
    }

    /// Discovered rooms ready to display, in a stable order.
    public var availableRooms: [DiscoveredRoom] {
        discoveredRooms.values
            // A session that's reconnecting must not hide the room: if the
            // host still advertises it, the user must be able to rejoin.
            .filter { room in
                guard let session = sessions[room.id] else { return true }
                return session.accessState != .joined && session.accessState != .awaitingApproval
            }
            .sorted { lhs, rhs in
                if lhs.name == rhs.name { return lhs.id.description < rhs.id.description }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// Discovered rooms offering the given activity. What a game's lobby uses
    /// to list matches without going through chat.
    public func availableRooms(for kind: ActivityKind) -> [DiscoveredRoom] {
        availableRooms.filter { $0.activityKind == kind && $0.features.hasActivities }
    }

    /// Requests the authoritative room catalog from every currently connected
    /// peer. Bonjour's TXT record can be truncated and won't reconcile rooms
    /// that disappeared while the physical connection stayed open.
    public func refreshRoomDirectories() {
        for peer in connectedPeers.values {
            requestRoomDirectory(from: peer)
        }
    }

    // MARK: - Init

    public init(
        transport: any PeerTransport,
        identity: LocalP2PIdentity,
        registry: RoomActivityRegistry? = nil
    ) {
        self.transport = transport
        self.identity = identity
        self.registry = registry ?? RoomActivityRegistry()
        self.transfers = FileTransferService()
    }

    isolated deinit {
        for operation in pendingJoins.values {
            operation.connectionTask?.cancel()
            operation.timeoutTask?.cancel()
            operation.continuation?.resume(throwing: CancellationError())
        }
        for task in recoveryTasks.values { task.cancel() }
        for task in hostMigrationTasks.values { task.cancel() }
        for continuation in noticeContinuations.values { continuation.finish() }
        for continuation in snapshotContinuations.values { continuation.finish() }
    }

    public func registerActivity(_ kind: ActivityKind, factory: @escaping RoomActivityRegistry.Factory) {
        registry.register(kind, factory: factory)
    }

    public func supportsActivity(_ kind: ActivityKind) -> Bool {
        registry.isRegistered(kind)
    }

    // MARK: - Creating a room

    /// Creates a locally-hosted room.
    ///
    /// `features` is what makes this flexible: `.chatOnly` for a chat room,
    /// `.gameOnly` to jump straight into a game with no chat, `.full` for both.
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

        // RoomID defaults to a UUID, but don't let an improbable collision
        // replace an existing local session in the dictionary.
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
        apply([identity.member(role: .host)], to: session)
        sessions[descriptor.id] = session
        activeRoomID = descriptor.id

        publishAdvertisement()
        publishRooms()
        return session
    }

    // MARK: - Joining a room

    /// Requests to join a discovered room. Returns the session once the host
    /// accepts, or throws if it rejects or doesn't respond.
    @discardableResult
    public func join(_ room: DiscoveredRoom) async throws -> RoomSession {
        if let existing = sessions[room.id], existing.accessState == .joined {
            activeRoomID = room.id
            publishRooms()
            return existing
        }

        guard pendingJoins[room.id] == nil else {
            throw RoomError.joinRejected(.duplicateConnection)
        }
        if let existing = sessions[room.id] {
            guard existing.descriptor.hostApplicationID == room.descriptor.hostApplicationID,
                  existing.descriptor.hostGeneration == room.descriptor.hostGeneration else {
                throw RoomError.peerUnavailable
            }
        }
        guard let advertisement = directory.advertisements[room.advertisedBy],
              advertisement.applicationID == room.descriptor.hostApplicationID else {
            throw RoomError.peerUnavailable
        }
        guard !room.descriptor.isFull else { throw RoomError.roomFull }

        let requestID = UUID()
        // Reserve the room before any suspension, including cancellation-handler setup.
        pendingJoins[room.id] = PendingJoin(
            id: requestID,
            hostApplicationID: room.descriptor.hostApplicationID,
            continuation: nil,
            isRecovery: false,
            roomToJoin: room,
            originalSessionInstanceID: sessions[room.id]?.instanceID
        )
        scheduleJoinTimeout(for: room.id, requestID: requestID)
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
                            ? CancellationError() : RoomError.transportFailure(NexoReason(error: error))
                        self?.finishJoin(room.id, requestID: requestID, result: .failure(failure))
                    }
                }
            }
        } onCancel: {
            Task { @NexoActor [weak self] in
                self?.finishJoin(room.id, requestID: requestID, result: .failure(CancellationError()))
            }
        }
    }

    // MARK: - Leaving a room

    /// Leaves the room. Doesn't close any physical connection: other rooms
    /// and activities sharing those peers keep working.
    public func leave(_ roomID: RoomID) {
        guard let session = sessions[roomID] else {
            finishJoin(roomID, result: .failure(RoomError.roomNotFound))
            return
        }
        let remoteApplicationIDs = session.remoteMembers.map(\.applicationID)

        transfers.cancelAll(in: session)
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
                to: remoteApplicationIDs,
                roomID: roomID
            )
        }

        discardSession(roomID, publishes: false)
        finishJoin(roomID, result: .failure(RoomError.roomNotFound), publishes: false)
        publishAdvertisement()
        publishRooms()
    }

    public func setActiveRoom(_ roomID: RoomID?) {
        activeRoomID = roomID
        publishRooms()
    }

    /// Forgets discovery without touching rooms. Used on suspend: advertisements
    /// expire, but membership is kept so it can be recovered on foreground return.
    public func forgetDiscoveredPeers() {
        directory.suspend(keeping: Set(sessions.keys))
        connectedPeers.removeAll()
        publishRooms()
    }

    /// Closes every room. Used by the manager on logout or when stopping the stack.
    public func closeAll(reason: NexoReason) {
        for task in recoveryTasks.values { task.cancel() }
        recoveryTasks.removeAll()
        recoveryDeadlines.removeAll()
        for task in hostMigrationTasks.values { task.cancel() }
        hostMigrationTasks.removeAll()

        for session in sessions.values {
            transfers.cancelAll(in: session)
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
        directory.clear()
        connectedPeers.removeAll()
        activeRoomID = nil
        publishRooms()
    }

    // MARK: - Join approval

    public func respond(to request: RoomJoinRequest, accept: Bool, reason: NexoReason? = nil) {
        guard let session = sessions[request.roomID],
              session.isLocalHost,
              let request = session.removeJoinRequest(request.id),
              let peer = connectedPeers[request.applicationID],
              request.connectionSessionID == nil || request.connectionSessionID == peer.connectionSessionID
        else { return }

        guard accept, !session.descriptor.isFull,
              session.members.count < P2PLimits.recoveryMemberLimit else {
            send(
                .joinRoomRejected(JoinRoomRejectedPayload(
                    roomID: request.roomID,
                    reason: accept ? .roomFull : (reason ?? .hostRejected),
                    requestID: request.requestID
                )),
                to: [request.applicationID],
                roomID: request.roomID
            )
            return
        }

        admit(
            applicationID: request.applicationID,
            displayName: request.displayName,
            avatar: request.avatar,
            to: session,
            requestID: request.requestID
        )
    }

    // MARK: - Activities

    private enum ActivityAnnouncement {
        case started
        case invitation
    }

    /// Starts an activity within the room. Only the given members
    /// participate; everyone else stays in chat as usual.
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

    /// Starts an activity from a conversation and announces an explicit
    /// invitation to the members included in it.
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
        guard session.features.hasActivities else { throw RoomError.featureUnavailable(.activities) }
        guard session.accessState == .joined else { throw RoomError.notAMember }
        guard session.activities.count < P2PLimits.recoveryActivityLimit,
              !isExclusive || session.canStartActivity else { throw RoomError.activityAlreadyRunning }

        // With no explicit list the activity stays open to the room: whoever
        // joins later is admitted only while it hasn't started.
        let admitsRoomMembers = participants == nil
        var participantIDs = Set(participants ?? session.members.map(\.applicationID))
        participantIDs.insert(identity.applicationID)
        guard participantIDs.isSubset(of: Set(session.members.map(\.applicationID))) else {
            throw RoomError.notAMember
        }

        let descriptor = ActivityDescriptor(
            roomID: roomID,
            kind: kind,
            hostApplicationID: identity.applicationID,
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

        // A room that didn't declare a kind starts advertising the one it is
        // playing, so it shows up in that game's list of nearby rooms.
        republishIfHosting(session)

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

    /// Ends the activity. The room and its chat remain intact.
    public func endActivity(_ activityID: ActivityID, in roomID: RoomID, reason: NexoReason) {
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

        // The room survives the activity, so the advertised kind goes with it.
        republishIfHosting(session)
    }
}

// MARK: - Transport events

@NexoActor
public extension RoomCoordinator {

    func handle(_ event: PeerTransportEvent) {
        guard event.epoch == transport.epoch else { return }
        switch event {
        case .advertisementFound(let advertisement, _), .advertisementUpdated(let advertisement, _):
            handleAdvertisement(advertisement)
        case .advertisementLost(let endpointID, _):
            handleAdvertisementLost(endpointID)
        case .peerConnected(let peer, _):
            handlePeerConnected(peer)
        case .peerDisconnected(let applicationID, let reason, _):
            handlePeerDisconnected(applicationID: applicationID, reason: reason)
        case .received(let envelope, let peer, _):
            route(envelope, from: peer)
        case .lifecycleChanged(let lifecycle, _):
            handleLifecycle(lifecycle)
        case .localNetworkPermissionChanged:
            break
        }
    }

    internal func handleAdvertisement(_ advertisement: PeerAdvertisement) {
        directory.update(advertisement)
        publishRooms()
        if advertisement.isCompatible { reconnectMissingMembers() }
    }

    internal func handleAdvertisementLost(_ endpointID: TransportPeerID) {
        directory.remove(endpointID)
        publishRooms()
    }

    internal func handlePeerConnected(_ peer: ConnectedPeer) {
        let wasRecovering = recoveryDeadlines.removeValue(forKey: peer.applicationID) != nil
        recoveryTasks.removeValue(forKey: peer.applicationID)?.cancel()
        hostMigrationTasks.removeValue(forKey: peer.applicationID)?.cancel()

        if connectedPeers[peer.applicationID]?.connectionSessionID == peer.connectionSessionID {
            return
        }
        connectedPeers[peer.applicationID] = peer
        for operation in Array(pendingJoins.values) where operation.hostApplicationID == peer.applicationID {
            if let room = operation.roomToJoin {
                completeJoinConnection(to: room, host: peer, requestID: operation.id)
            }
        }

        // Bonjour can only advertise a subset of rooms. The handshake lets us
        // request the full catalog without opening another physical connection.
        requestRoomDirectory(from: peer)

        // The host reaffirms membership, active activities and the short chat
        // history before replaying activity messages.
        for session in hostedRooms where session.contains(peer.applicationID) {
            sendMembership(of: session, to: [peer.applicationID])
            sendResume(of: session, to: peer.applicationID)
        }

        // An activity can also be hosted by a guest. In that case the room's
        // host can't rebuild it alone; the activity's owner publishes its
        // descriptor directly to its participants.
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

        // When the host recovers, the guest re-requests acceptance if the drop
        // was temporary. The existing route is idempotent and returns the
        // activities' full descriptor.
        for session in joinedRooms
        where session.descriptor.hostApplicationID == peer.applicationID
            && (wasRecovering || session.accessState != .joined) {

            beginRecoveryJoin(in: session, from: peer)
        }

        // Explicit history completes the short resume snapshot. The host
        // offers the aggregated conversation; a guest only offers its own
        // messages so the host stays the aggregator and each sender its own authority.
        for session in sessions.values where session.contains(peer.applicationID) {
            sendChatHistory(of: session, to: peer.applicationID)
            outboxes[session.roomID]?.replay(to: peer.applicationID)
        }
    }

    func requestRoomDirectory(from peer: ConnectedPeer) {
        guard peer.supports(.rooms) else { return }
        send(
            .roomDirectoryRequest,
            to: [peer.applicationID],
            roomID: directoryRequestRoomID
        )
    }

    internal func handlePeerDisconnected(applicationID: String, reason: NexoReason?) {
        connectedPeers.removeValue(forKey: applicationID)
        for (roomID, operation) in pendingJoins where operation.hostApplicationID == applicationID {
            finishJoin(roomID, requestID: operation.id, result: .failure(RoomError.peerUnavailable))
        }
        var isMemberOfAnyRoom = false

        for session in sessions.values {
            guard session.contains(applicationID) else {
                session.removeJoinRequests(for: applicationID)
                continue
            }

            isMemberOfAnyRoom = true
            // A socket drop is not leaving the room. Membership, chat and
            // activities are kept until the grace period expires.
        }

        if isMemberOfAnyRoom {
            beginTemporaryRecovery(for: applicationID, scheduleAttempt: true)
            scheduleHostMigration(for: applicationID)
        } else {
            cancelRecoveryIfUnused(for: applicationID)
        }
    }

    internal func handleLifecycle(_ lifecycle: ConnectivityLifecycle) {
        switch lifecycle {
        case .suspended:
            // The transport will close, but logical presence doesn't change.
            // On return to active, each retained member is recovered.
            connectedPeers.removeAll()
            for session in sessions.values {
                for member in session.remoteMembers {
                    beginTemporaryRecovery(for: member.applicationID, scheduleAttempt: false)
                }
            }

        case .active:
            for applicationID in recoveryDeadlines.keys {
                scheduleRecoveryAttempt(for: applicationID)
            }
            reconnectMissingMembers()

        case .disconnected:
            connectedPeers.removeAll()
            for session in sessions.values {
                for member in session.remoteMembers where connectedPeers[member.applicationID] == nil {
                    beginTemporaryRecovery(for: member.applicationID, scheduleAttempt: true)
                }
            }

        case .idle, .reconnecting:
            break
        }
    }

    /// Entry point for every received envelope. Validation order is physical
    /// connection, room, membership, channel, and finally the typed payload.
    internal func route(_ envelope: RoomEnvelope, from peer: ConnectedPeer) {
        guard envelope.senderApplicationID == peer.applicationID,
              peer.applicationID != identity.applicationID,
              peer.supports(.rooms),
              P2PProtocolInfo.isCompatible(remoteVersion: envelope.protocolVersion),
              envelope.payload.count <= P2PLimits.maximumEnvelopeBytes,
              connectedPeers[peer.applicationID]?.connectionSessionID == peer.connectionSessionID
        else { return }

        if envelope.channel == .control {
            guard envelope.activityID == nil else { return }
            handleControl(envelope, from: peer)
            return
        }

        guard let session = sessions[envelope.roomID],
              hasMembership(in: session, from: peer),
              let member = session.member(peer.applicationID) else { return }

        switch envelope.channel {
        case .control:
            break

        case .chat:
            guard session.features.hasChat, peer.supports(.chat), envelope.activityID == nil,
                  remember(envelope.messageID, from: peer.applicationID) else { return }
            session.chat?.receive(payload: envelope.payload, from: member)

        case .activity:
            guard session.features.hasActivities, peer.supports(.activities),
                  let activityID = envelope.activityID,
                  let activity = session.activity(activityID),
                  activity.descriptor.includes(identity.applicationID),
                  activity.descriptor.includes(peer.applicationID),
                  remember(envelope.messageID, from: peer.applicationID) else { return }
            activity.receive(payload: envelope.payload, from: member)

        case .fileTransfer:
            guard session.features.hasFileTransfer, peer.supports(.fileTransfer), envelope.activityID == nil,
                  remember(envelope.messageID, from: peer.applicationID) else { return }
            transfers.handle(envelope: envelope, from: member, in: session)
        }
    }
}

// MARK: - Control messages

@NexoActor
private extension RoomCoordinator {

    func hasMembership(in session: RoomSession, from peer: ConnectedPeer) -> Bool {
        guard session.contains(identity.applicationID), session.contains(peer.applicationID) else { return false }
        switch session.accessState {
        case .joined, .suspended, .reconnecting: return true
        case .available, .awaitingApproval, .rejected, .closed: return false
        }
    }

    func allowsControl(_ message: RoomControlMessage, from peer: ConnectedPeer, roomID: RoomID) -> Bool {
        switch message {
        case .roomDirectoryRequest, .roomDirectory, .joinRoomRequest:
            return true
        case .joinRoomAccepted(let payload):
            return matchesPendingJoin(roomID, requestID: payload.requestID, from: peer)
        case .joinRoomRejected(let payload):
            return matchesPendingJoin(roomID, requestID: payload.requestID, from: peer)
        case .roomClosed:
            return sessions[roomID]?.descriptor.hostApplicationID == peer.applicationID
        case .leaveRoom:
            guard let session = sessions[roomID] else { return false }
            return hasMembership(in: session, from: peer)
                || (session.isLocalHost && session.pendingJoinRequests.contains { $0.applicationID == peer.applicationID })
        default:
            guard let session = sessions[roomID] else { return false }
            return hasMembership(in: session, from: peer)
        }
    }

    func handleControl(_ envelope: RoomEnvelope, from peer: ConnectedPeer) {
        guard let message = try? envelope.decodePayload(as: RoomControlMessage.self),
              message.roomID == nil || message.roomID == envelope.roomID,
              allowsControl(message, from: peer, roomID: envelope.roomID),
              remember(envelope.messageID, from: peer.applicationID) else { return }

        switch message {

        // MARK: Directory

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
            guard let roomIDs = directory.update(
                payload,
                from: peer,
                joinedIDs: Set(sessions.keys)
            ) else { return }

            // A host may restart and recreate a room with the same name but a
            // new ID. Its full directory is authoritative: discard any old
            // joined session that the host no longer advertises.
            let staleSessions = joinedRooms.filter {
                $0.descriptor.hostApplicationID == peer.applicationID
                    && !roomIDs.contains($0.roomID)
            }
            for session in staleSessions {
                let reason: NexoReason = .roomUnavailable
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
                publishNotice(.roomClosed(P2PRoomClosedNotice(
                    roomID: session.roomID,
                    reason: .roomUnavailable
                )))
            }

        // MARK: Membership

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
                remove(applicationID: peer.applicationID, from: session)
            } else {
                var members = session.members
                members.removeAll { $0.applicationID == peer.applicationID }
                apply(members, to: session)
            }

        case .roomMembershipChanged(let payload):
            guard let session = sessions[payload.descriptor.id],
                  RoomMembership.validates(payload.members, descriptor: payload.descriptor, roomID: session.roomID,
                                           requiring: [identity.applicationID, peer.applicationID]) else { return }
            if payload.descriptor.hostGeneration == session.descriptor.hostGeneration {
                guard peer.applicationID == session.descriptor.hostApplicationID,
                      payload.descriptor.hostApplicationID == session.descriptor.hostApplicationID else { return }
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
                  session.descriptor.hostApplicationID == peer.applicationID else { return }
            session.removeAllActivities(reason: payload.reason)
            session.setAccessState(.closed(reason: payload.reason))
            // Drop the room from discovery first: `discardSession` publishes
            // and would otherwise announce a room that no longer exists.
            directory.removeRoom(payload.roomID)
            discardSession(payload.roomID)
            publishNotice(.roomClosed(P2PRoomClosedNotice(
                roomID: payload.roomID,
                reason: payload.reason
            )))
            finishJoin(payload.roomID, result: .failure(RoomError.joinRejected(payload.reason)))

        // MARK: Activities

        case .activityStarted(let payload), .activityInvite(let payload):
            handleActivityAnnouncement(payload.descriptor, from: peer, publishesNotice: true)

        case .activityJoinAccepted(let payload):
            handleActivityAnnouncement(payload.descriptor, from: peer, publishesNotice: false)

        case .activityJoinRequest(let payload):
            handleActivityJoinRequest(payload, from: peer)

        case .activityJoinRejected(let payload):
            guard let session = sessions[payload.roomID],
                  let activity = session.activity(payload.activityID),
                  activity.isHost(peer.applicationID) else { return }
            session.removeActivity(payload.activityID, reason: payload.reason)
            republishIfHosting(session)

        case .activityLeft(let payload):
            guard let session = sessions[payload.roomID],
                  let activity = session.activity(payload.activityID),
                  activity.descriptor.includes(peer.applicationID),
                  let member = session.member(peer.applicationID) else { return }
            activity.participantDidLeave(member)

        case .activityEnded(let payload):
            guard let session = sessions[payload.roomID],
                  let activity = session.activity(payload.activityID),
                  activity.isHost(peer.applicationID) else { return }
            session.removeActivity(payload.activityID, reason: payload.reason)
            republishIfHosting(session)
        }
    }

    // MARK: Incoming

    /// Merges a history chunk. The host can aggregate messages from every
    /// current member; any other peer can only contribute its own messages.
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

        let messages = RoomChatHistory.validatedMessages(
            payload.messages,
            roomID: roomID,
            members: session.members,
            senderApplicationID: peer.applicationID,
            hostApplicationID: session.descriptor.hostApplicationID
        )
        guard chat.merge(messages: messages), session.isLocalHost else { return }

        // Chunks can arrive separately. Republishing after every merge is
        // idempotent and guarantees peers already online converge even if
        // they miss the original chunk.
        for member in session.remoteMembers {
            sendChatHistory(of: session, to: member.applicationID)
        }
    }

    /// Sends the retained conversation in chunks that fit a control envelope.
    /// A guest sends only its own messages; the host sends the aggregated
    /// history kept in its session.
    func sendChatHistory(of session: RoomSession, to applicationID: String) {
        guard session.features.hasChat,
              let chat = session.chat else { return }

        for payload in RoomChatHistory.chunks(
            chat.messages,
            roomID: session.roomID,
            senderApplicationID: identity.applicationID,
            hostApplicationID: session.descriptor.hostApplicationID
        ) {
            send(.chatHistory(payload), to: [applicationID], roomID: session.roomID)
        }
    }

    /// Applies the host's authoritative state, then lets the journal replay
    /// envelopes newer than the snapshot. A guest hosting an activity may send
    /// a partial resume scoped to just that activity.
    func handleRoomResume(
        _ payload: RoomResumePayload,
        from peer: ConnectedPeer,
        roomID: RoomID
    ) {
        guard let session = sessions[roomID],
              payload.descriptor.id == roomID,
              payload.descriptor.hostApplicationID == session.descriptor.hostApplicationID,
              payload.descriptor.hostGeneration == session.descriptor.hostGeneration,
              payload.members.count <= P2PLimits.recoveryMemberLimit,
              payload.activities.count <= P2PLimits.recoveryActivityLimit,
              payload.chatMessages.count <= P2PLimits.recoveryChatMessageLimit
        else { return }

        let isRoomHost = peer.applicationID == session.descriptor.hostApplicationID
        guard RoomMembership.validates(payload.members, descriptor: payload.descriptor, roomID: roomID,
                                       requiring: [identity.applicationID, peer.applicationID]),
              validatesActivities(payload.activities, roomID: roomID,
                                  members: isRoomHost ? payload.members : session.members),
              payload.activities.allSatisfy({ isRoomHost || $0.hostApplicationID == peer.applicationID })
        else { return }

        // The history is validated against the membership the host is about
        // to publish, before mutating descriptor, members or activities.
        let validMessages = RoomChatHistory.validatedMessages(
            payload.chatMessages,
            roomID: roomID,
            members: isRoomHost ? payload.members : session.members,
            senderApplicationID: peer.applicationID,
            hostApplicationID: session.descriptor.hostApplicationID
        )

        if isRoomHost {
            session.apply(descriptor: payload.descriptor)
            apply(payload.members, to: session)
        }

        let activeDescriptors = payload.activities.filter {
            $0.isActive
                && $0.includes(identity.applicationID)
                && (isRoomHost || $0.hostApplicationID == peer.applicationID)
        }
        let activeIDs = Set(activeDescriptors.map(\.id))

        // Only activities controlled by the peer that sent this snapshot are
        // reconciled. Other guests' activities don't appear in the room
        // host's snapshot and must be kept.
        let staleActivities = session.activities.values.filter {
            $0.isHost(peer.applicationID) && !activeIDs.contains($0.id)
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

        // A guest may have kept its own messages the host didn't have yet.
        // Once merged, the host republishes the converged conversation to the
        // rest of the room.
        if session.isLocalHost && !isRoomHost && didMerge {
            for member in session.remoteMembers {
                sendChatHistory(of: session, to: member.applicationID)
            }
        }
    }

    func validatesRoomMigration(
        _ descriptor: RoomDescriptor,
        members: [RoomMember],
        from peer: ConnectedPeer,
        in session: RoomSession
    ) -> Bool {
        let current = session.descriptor
        guard current.hostGeneration < UInt64.max,
              descriptor.hostGeneration == current.hostGeneration + 1,
              descriptor.hostApplicationID == peer.applicationID,
              connectedPeers[current.hostApplicationID] == nil,
              current.hostApplicationID != identity.applicationID,
              RoomMembership.validates(members, descriptor: descriptor, roomID: session.roomID,
                                       requiring: [identity.applicationID, peer.applicationID]),
              members.map(\.applicationID) == session.members.map(\.applicationID)
                  .filter({ $0 != current.hostApplicationID }),
              descriptor.name == current.name,
              descriptor.features == current.features,
              descriptor.activityKind == current.activityKind,
              descriptor.accessPolicy == current.accessPolicy,
              descriptor.capacity == current.capacity,
              descriptor.protocolVersion == current.protocolVersion,
              let election = RoomHostElection.successor(
                  in: session.members,
                  after: current.hostApplicationID,
                  availableApplicationIDs: Set(connectedPeers.keys).union([identity.applicationID])
              ) else { return false }
        return election.applicationID == peer.applicationID
    }

    func handleRoomHostChanged(
        _ payload: RoomHostChangedPayload,
        from peer: ConnectedPeer,
        roomID: RoomID
    ) {
        guard let session = sessions[roomID],
              payload.failedHostApplicationID == session.descriptor.hostApplicationID,
              validatesRoomMigration(payload.descriptor, members: payload.members, from: peer, in: session),
              RoomHostElection.validates(
                  RoomHostElection.Result(applicationID: peer.applicationID,
                                          skippedApplicationIDs: payload.skippedApplicationIDs),
                  in: session.members,
                  after: payload.failedHostApplicationID
              ) else { return }

        applyRoomMigration(payload.descriptor, members: payload.members, to: session)

        // A room successor may not even know a private activity. Only its own
        // activity authority can reconcile data; omissions never delete local activities.
        if validatesActivities(payload.activities, roomID: roomID, members: payload.members) {
            for descriptor in payload.activities where descriptor.hostApplicationID == peer.applicationID
                && descriptor.includes(identity.applicationID) {
                reconcileActivity(descriptor, from: peer, in: session)
            }
        }
    }

    func applyRoomMigration(_ descriptor: RoomDescriptor, members: [RoomMember], to session: RoomSession) {
        let migratedIDs = prepareActivityMigration(after: session.descriptor.hostApplicationID, in: session)
        session.apply(descriptor: descriptor)
        apply(members, to: session)
        session.setAccessState(.joined)
        session.record(.hostChanged)
        announceMigratedActivities(migratedIDs, in: session)
        connectToMembers(of: session)
        publishRooms()
    }

    func handleJoinRequest(_ payload: JoinRoomRequestPayload, from peer: ConnectedPeer) {
        guard let session = sessions[payload.roomID], session.isLocalHost else {
            send(
                .joinRoomRejected(JoinRoomRejectedPayload(
                    roomID: payload.roomID,
                    reason: .roomUnavailable,
                    requestID: payload.requestID
                )),
                to: [peer.applicationID],
                roomID: payload.roomID
            )
            return
        }

        // A member reconnecting who was already here: just reaffirm membership.
        if session.contains(peer.applicationID) {
            sendAcceptance(of: session, to: peer.applicationID, requestID: payload.requestID)
            return
        }

        guard !session.descriptor.isFull, session.members.count < P2PLimits.recoveryMemberLimit else {
            send(
                .joinRoomRejected(JoinRoomRejectedPayload(
                    roomID: payload.roomID,
                    reason: .roomFull,
                    requestID: payload.requestID
                )),
                to: [peer.applicationID],
                roomID: payload.roomID
            )
            return
        }

        switch session.descriptor.accessPolicy {
        case .open:
            admit(
                applicationID: peer.applicationID,
                displayName: payload.displayName,
                avatar: payload.avatar,
                to: session,
                requestID: payload.requestID
            )

        case .approval:
            if let existing = session.pendingJoinRequests.first(where: { $0.applicationID == peer.applicationID }) {
                guard existing.requestID != payload.requestID
                    || existing.connectionSessionID != peer.connectionSessionID else { return }
                session.removeJoinRequests(for: peer.applicationID)
            }
            let request = RoomJoinRequest(
                roomID: payload.roomID,
                applicationID: peer.applicationID,
                displayName: payload.displayName,
                avatar: payload.avatar,
                requestID: payload.requestID,
                connectionSessionID: peer.connectionSessionID
            )
            guard session.enqueueJoinRequest(request) else { return }

            publishNotice(.joinRequest(P2PJoinRequestNotice(
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
              peer.applicationID == session.descriptor.hostApplicationID,
              payload.descriptor.hostApplicationID == peer.applicationID,
              payload.descriptor.hostGeneration == session.descriptor.hostGeneration,
              RoomMembership.validates(payload.members, descriptor: payload.descriptor, roomID: roomID,
                                       requiring: [identity.applicationID, peer.applicationID]),
              validatesActivities(payload.activities, roomID: roomID, members: payload.members)
        else { return }

        session.apply(descriptor: payload.descriptor)
        apply(payload.members, to: session)
        session.setAccessState(.joined)
        activeRoomID = roomID

        // A room host can introduce activities, but cannot change another activity's authority.
        for descriptor in payload.activities where descriptor.isActive && descriptor.includes(identity.applicationID) {
            reconcileActivity(descriptor, from: peer, in: session)
        }

        connectToMembers(of: session)
        sendChatHistory(of: session, to: peer.applicationID)
        publishRooms()
        finishJoin(roomID, requestID: payload.requestID, result: .success(session))
    }

    func admit(
        applicationID: String,
        displayName: String,
        avatar: String?,
        to session: RoomSession,
        requestID: UUID?
    ) {
        var members = session.members
        if !members.contains(where: { $0.applicationID == applicationID }) {
            members.append(RoomMember(
                applicationID: applicationID,
                displayName: displayName,
                role: .guest,
                avatar: avatar
            ))
        }
        apply(members, to: session)
        session.removeJoinRequests(for: applicationID)

        // Must happen before acceptance: this way the descriptor the
        // newcomer receives already includes them as a participant.
        admitToOpenActivities(applicationID: applicationID, in: session)

        sendAcceptance(of: session, to: applicationID, requestID: requestID)
        // The rest of the room gets the new list and opens a connection to
        // the newcomer, completing the mesh.
        sendMembership(
            of: session,
            to: session.remoteMembers.map(\.applicationID).filter { $0 != applicationID }
        )
        publishAdvertisement()
    }

    /// Admits a new member into activities we host that are still open.
    /// Without this, whoever joins after a match was created never ends up in
    /// `participantIDs` and their messages get dropped when routed.
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

            // The newcomer asked to enter the room, so for them this is an
            // admission rather than an invitation: `.activityStarted` would make
            // their UI announce a game they just walked into.
            send(
                .activityJoinAccepted(ActivityLifecyclePayload(descriptor: descriptor)),
                to: [applicationID],
                roomID: session.roomID
            )
            send(
                .activityStarted(ActivityLifecyclePayload(descriptor: descriptor)),
                to: descriptor.participantIDs
                    .filter { $0 != identity.applicationID && $0 != applicationID }
                    .sorted(),
                roomID: session.roomID
            )
        }
    }

    func remove(applicationID: String, from session: RoomSession) {
        var members = session.members
        members.removeAll { $0.applicationID == applicationID }
        apply(members, to: session)
        session.removeJoinRequests(for: applicationID)
        cancelRecoveryIfUnused(for: applicationID)
        sendMembership(of: session, to: session.remoteMembers.map(\.applicationID))
        publishAdvertisement()
    }

    func sendAcceptance(of session: RoomSession, to applicationID: String, requestID: UUID?) {
        send(
            .joinRoomAccepted(JoinRoomAcceptedPayload(
                descriptor: session.descriptor,
                members: session.members,
                activities: session.activities.values.map(\.descriptor).filter {
                    $0.isActive && $0.includes(applicationID)
                },
                requestID: requestID
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
            $0.kind != .systemInfo
                && (!onlyActivitiesHostedByLocal || $0.senderApplicationID == identity.applicationID)
        } ?? []
        var chatMessages = Array(
            resumableChatMessages.suffix(P2PLimits.recoveryChatMessageLimit)
        )
        let activities = Array(
            session.activities.values
                .filter { activity in
                    activity.descriptor.includes(applicationID)
                        && (!onlyActivitiesHostedByLocal || activity.isHost(identity.applicationID))
                }
                .map(\.descriptor)
                .filter(\.isActive)
                .prefix(P2PLimits.recoveryActivityLimit)
        )

        // The limit is computed on the encoded payload, not the message
        // count: Unicode characters and metadata can vary a lot.
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

    // MARK: Activities

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
        guard reconcileActivity(descriptor, from: peer, in: session) else { return }

        guard publishesNotice,
              isNewActivity,
              descriptor.state == .lobby,
              session.activity(descriptor.id) != nil else { return }

        guard let hostDisplayName = session.member(descriptor.hostApplicationID)?.displayName else { return }
        publishNotice(.activityInvitation(P2PActivityInvitationNotice(
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
        guard activity.descriptor.admitsRoomMembers || activity.descriptor.includes(peer.applicationID) else {
            send(
                .activityJoinRejected(ActivityRejectionPayload(
                    roomID: payload.roomID,
                    activityID: payload.activityID,
                    reason: .hostRejected
                )),
                to: [peer.applicationID],
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

    func validatesActivities(_ descriptors: [ActivityDescriptor], roomID: RoomID, members: [RoomMember]) -> Bool {
        let memberIDs = Set(members.map(\.applicationID))
        return descriptors.count <= P2PLimits.recoveryActivityLimit
            && Set(descriptors.map(\.id)).count == descriptors.count
            && descriptors.allSatisfy {
                $0.roomID == roomID
                    && $0.participantIDs.isSubset(of: memberIDs)
                    && $0.includes($0.hostApplicationID)
            }
    }

    @discardableResult
    func reconcileActivity(_ descriptor: ActivityDescriptor, from peer: ConnectedPeer, in session: RoomSession) -> Bool {
        guard session.features.hasActivities,
              descriptor.includes(identity.applicationID),
              validatesActivities([descriptor], roomID: session.roomID, members: session.members) else { return false }
        if let activity = session.activity(descriptor.id) {
            let current = activity.descriptor
            guard descriptor.kind == current.kind,
                  descriptor.admitsRoomMembers == current.admitsRoomMembers,
                  descriptor.isExclusive == current.isExclusive,
                  descriptor.hostApplicationID == peer.applicationID else { return false }
            if descriptor.hostGeneration == current.hostGeneration {
                guard descriptor.hostApplicationID == current.hostApplicationID else { return false }
            } else {
                guard current.hostGeneration < UInt64.max,
                      descriptor.hostGeneration == current.hostGeneration + 1,
                      current.hostApplicationID != identity.applicationID,
                      connectedPeers[current.hostApplicationID] == nil,
                      descriptor.participantIDs == current.participantIDs
                          || descriptor.participantIDs == current.participantIDs.subtracting([current.hostApplicationID]),
                      let election = RoomHostElection.successor(
                          in: session.members.filter { current.includes($0.applicationID) },
                          after: current.hostApplicationID,
                          availableApplicationIDs: Set(connectedPeers.keys).union([identity.applicationID])
                      ), election.applicationID == peer.applicationID else { return false }
            }
        } else {
            guard descriptor.hostApplicationID == peer.applicationID
                || session.descriptor.hostApplicationID == peer.applicationID else { return false }
        }
        instantiateActivity(descriptor, in: session)
        return true
    }

    func instantiateActivity(_ descriptor: ActivityDescriptor, in session: RoomSession) {
        if let existing = session.activity(descriptor.id) {
            // The same activity can arrive via `activityStarted` and later via
            // `joinRoomAccepted` on reconnect. Reusing it preserves its
            // message buffer and any associated local state.
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

// MARK: - Mesh, advertisement and utilities

@NexoActor
private extension RoomCoordinator {

    func apply(_ members: [RoomMember], to session: RoomSession) {
        session.apply(members: members)
        transfers.reconcileMembers(in: session)
    }

    func makeSession(descriptor: RoomDescriptor, accessState: RoomAccessState) -> RoomSession {
        let roomID = descriptor.id
        let outbox = RoomOutbox(
            roomID: roomID,
            transport: transport,
            identity: identity,
            isPeerAdmitted: { [weak self] in self?.isPeerAdmitted($0) ?? false }
        )

        outboxes[roomID] = outbox

        let session = RoomSession(
            descriptor: descriptor,
            identity: identity,
            outbox: outbox,
            accessState: accessState
        )
        session.bindTransfers(transfers)
        return session
    }

    /// Opens connections to a room's members who aren't connected yet. The
    /// task is unique per `applicationID`, even if the peer is in several rooms.
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

        recoveryTasks[applicationID] = Task { @NexoActor [weak self] in
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

                // `connect` waits for the physical handshake. If it succeeds,
                // the `peerConnected` event cancels this task and triggers resume.
                _ = try? await self.transport.connect(to: advertisement)
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
                _ = try? await self.transport.connect(to: advertisement)
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
                migrateActivities(hostedBy: applicationID, in: session)
                // A drop only becomes a real removal after the full window
                // passes without recovering the peer.
                remove(applicationID: applicationID, from: session)
            } else if session.descriptor.hostApplicationID == applicationID {
                if !migrateRoomHost(after: applicationID, in: session) {
                    session.setAccessState(.reconnecting)
                    session.record(.hostConnectionLost)
                    session.removeAllActivities(reason: .hostConnectionLost)
                }
            } else {
                migrateActivities(hostedBy: applicationID, in: session)
                var members = session.members
                members.removeAll { $0.applicationID == applicationID }
                apply(members, to: session)
            }
        }
    }

    @discardableResult
    func migrateRoomHost(after failedHostApplicationID: String, in session: RoomSession) -> Bool {
        guard session.descriptor.hostApplicationID == failedHostApplicationID,
              session.descriptor.hostGeneration < UInt64.max,
              connectedPeers[failedHostApplicationID] == nil else { return false }
        let available = Set(connectedPeers.keys).union([identity.applicationID])
        guard let election = RoomHostElection.successor(
            in: session.members,
            after: failedHostApplicationID,
            availableApplicationIDs: available
        ) else { return false }

        guard election.applicationID == identity.applicationID else {
            migrateActivities(hostedBy: failedHostApplicationID, in: session)
            session.setAccessState(.reconnecting)
            publishRooms()
            return true
        }

        let members = session.members
            .filter { $0.applicationID != failedHostApplicationID }
            .map { member in
            RoomMember(
                applicationID: member.applicationID,
                displayName: member.displayName,
                role: member.applicationID == identity.applicationID ? .host : .guest,
                avatar: member.avatar
            )
        }

        let migratedIDs = prepareActivityMigration(after: failedHostApplicationID, in: session)
        var descriptor = session.descriptor
        descriptor.hostApplicationID = identity.applicationID
        descriptor.hostGeneration += 1
        descriptor.memberCount = members.count
        session.apply(descriptor: descriptor)
        session.setAccessState(.joined)
        session.record(.hostChanged)

        apply(members, to: session)
        let activities = session.activities.values.map(\.descriptor)

        let payload = RoomHostChangedPayload(
            failedHostApplicationID: failedHostApplicationID,
            skippedApplicationIDs: election.skippedApplicationIDs,
            descriptor: descriptor,
            members: members,
            activities: activities
        )
        broadcast(.roomHostChanged(payload), in: session)
        announceMigratedActivities(migratedIDs, in: session)
        connectToMembers(of: session)
        for member in session.remoteMembers {
            sendResume(of: session, to: member.applicationID)
        }
        publishAdvertisement()
        publishRooms()
        return true
    }

    func prepareActivityMigration(after failedHostApplicationID: String, in session: RoomSession) -> [ActivityID] {
        var migratedIDs: [ActivityID] = []
        let available = Set(connectedPeers.keys).union([identity.applicationID])
        // Elect while the old membership still contains the failed participant.
        for activity in session.activities.values where activity.isHost(failedHostApplicationID) {
            guard activity.descriptor.hostGeneration < UInt64.max,
                  let election = RoomHostElection.successor(
                      in: session.members.filter { activity.descriptor.includes($0.applicationID) },
                      after: failedHostApplicationID,
                      availableApplicationIDs: available
                  ) else { continue }
            var descriptor = activity.descriptor
            descriptor.hostApplicationID = election.applicationID
            descriptor.hostGeneration += 1
            activity.apply(descriptor: descriptor)
            migratedIDs.append(activity.id)
        }
        return migratedIDs
    }

    func announceMigratedActivities(_ activityIDs: [ActivityID], in session: RoomSession) {
        for activityID in activityIDs {
            guard let activity = session.activity(activityID), activity.isHost(identity.applicationID) else { continue }
            send(
                .activityStarted(ActivityLifecyclePayload(descriptor: activity.descriptor)),
                to: activity.descriptor.participantIDs.filter { $0 != identity.applicationID }.sorted(),
                roomID: session.roomID
            )
        }
    }

    func migrateActivities(hostedBy failedHostApplicationID: String, in session: RoomSession) {
        guard connectedPeers[failedHostApplicationID] == nil else { return }
        let available = Set(connectedPeers.keys).union([identity.applicationID])

        for activity in session.activities.values
        where activity.descriptor.hostApplicationID == failedHostApplicationID {
            let participants = session.members.filter {
                activity.descriptor.includes($0.applicationID)
            }
            guard activity.descriptor.hostGeneration < UInt64.max,
                  let election = RoomHostElection.successor(
                      in: participants,
                      after: failedHostApplicationID,
                      availableApplicationIDs: available
                  ), election.applicationID == identity.applicationID else { continue }

            var descriptor = activity.descriptor
            descriptor.hostApplicationID = identity.applicationID
            descriptor.hostGeneration += 1
            activity.apply(descriptor: descriptor)
            send(
                .activityStarted(ActivityLifecyclePayload(descriptor: descriptor)),
                to: descriptor.participantIDs.filter { $0 != identity.applicationID }.sorted(),
                roomID: session.roomID
            )
        }
    }

    func cancelRecoveryIfUnused(for applicationID: String) {
        guard !sessions.values.contains(where: { $0.contains(applicationID) }) else { return }
        recoveryTasks.removeValue(forKey: applicationID)?.cancel()
        recoveryDeadlines.removeValue(forKey: applicationID)
        hostMigrationTasks.removeValue(forKey: applicationID)?.cancel()
    }

    func advertisement(for applicationID: String) -> PeerAdvertisement? {
        directory.advertisement(for: applicationID)
    }

    func discardSession(_ roomID: RoomID, publishes: Bool = true) {
        if let session = sessions.removeValue(forKey: roomID) {
            transfers.cancelAll(in: session)
            for member in session.remoteMembers {
                cancelRecoveryIfUnused(for: member.applicationID)
            }
        }
        outboxes.removeValue(forKey: roomID)
        if activeRoomID == roomID { activeRoomID = nil }
        if publishes { publishRooms() }
    }

    func remember(_ messageID: UUID, from applicationID: String) -> Bool {
        let key = ReceivedEnvelopeKey(sender: applicationID, messageID: messageID)
        guard !receivedEnvelopeIDs.contains(key) else { return false }
        // Directory envelopes carry arbitrary room IDs; never allocate a room bucket.
        let perSenderLimit = P2PLimits.recoveryJournalLimit
        if receivedEnvelopeOrder.lazy.filter({ $0.sender == applicationID }).count >= perSenderLimit,
           let index = receivedEnvelopeOrder.firstIndex(where: { $0.sender == applicationID }) {
            receivedEnvelopeIDs.remove(receivedEnvelopeOrder.remove(at: index))
        }
        if receivedEnvelopeOrder.count >= perSenderLimit * 4 {
            receivedEnvelopeIDs.remove(receivedEnvelopeOrder.removeFirst())
        }
        receivedEnvelopeIDs.insert(key)
        receivedEnvelopeOrder.append(key)
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

    /// Republishes after the set of live activities changed in a room we host:
    /// the advertised kind is derived from it. Guests advertise nothing of it.
    func republishIfHosting(_ session: RoomSession) {
        guard session.isLocalHost else { return }
        publishAdvertisement()
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

        for applicationID in applicationIDs where isPeerAdmitted(applicationID) {
            transport.enqueue(envelope, to: applicationID)
        }
    }

    func isPeerAdmitted(_ applicationID: String) -> Bool {
        guard let peer = connectedPeers[applicationID], applicationID != identity.applicationID else { return false }
        return transport.connectedPeers.contains {
            $0.applicationID == applicationID && $0.connectionSessionID == peer.connectionSessionID
        }
    }

    func broadcast(_ message: RoomControlMessage, in session: RoomSession) {
        send(message, to: session.remoteMembers.map(\.applicationID), roomID: session.roomID)
    }

    // MARK: Join operations

    func completeJoinConnection(to room: DiscoveredRoom, host: ConnectedPeer, requestID: UUID) {
        guard let operation = pendingJoins[room.id], operation.id == requestID,
              operation.roomToJoin != nil,
              connectedPeers[host.applicationID]?.connectionSessionID == host.connectionSessionID else { return }
        guard sessions[room.id]?.instanceID == operation.originalSessionInstanceID else {
            finishJoin(room.id, requestID: requestID, result: .failure(RoomError.roomNotFound))
            return
        }
        if let previous = sessions[room.id] {
            guard previous.descriptor.hostApplicationID == room.descriptor.hostApplicationID,
                  previous.descriptor.hostGeneration == room.descriptor.hostGeneration else {
                finishJoin(room.id, requestID: requestID, result: .failure(RoomError.peerUnavailable))
                return
            }
        }
        guard host.applicationID == room.descriptor.hostApplicationID else {
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
        sendJoinRequest(roomID: room.id, to: host.applicationID, requestID: requestID)
    }

    func beginRecoveryJoin(in session: RoomSession, from peer: ConnectedPeer) {
        guard pendingJoins[session.roomID] == nil,
              session.contains(identity.applicationID) else { return }
        let requestID = UUID()
        pendingJoins[session.roomID] = PendingJoin(
            id: requestID,
            hostApplicationID: peer.applicationID,
            continuation: nil,
            isRecovery: true,
            connectionSessionID: peer.connectionSessionID,
            sessionInstanceID: session.instanceID
        )
        scheduleJoinTimeout(for: session.roomID, requestID: requestID)
        sendJoinRequest(roomID: session.roomID, to: peer.applicationID, requestID: requestID)
    }

    func sendJoinRequest(roomID: RoomID, to applicationID: String, requestID: UUID) {
        send(
            .joinRoomRequest(JoinRoomRequestPayload(
                roomID: roomID,
                displayName: identity.displayName,
                avatar: identity.avatar,
                requestID: requestID
            )),
            to: [applicationID],
            roomID: roomID
        )
    }

    func matchesPendingJoin(_ roomID: RoomID, requestID: UUID?, from peer: ConnectedPeer) -> Bool {
        guard let requestID, let operation = pendingJoins[roomID] else { return false }
        return operation.id == requestID
            && operation.hostApplicationID == peer.applicationID
            && operation.connectionSessionID == peer.connectionSessionID
            && operation.sessionInstanceID == sessions[roomID]?.instanceID
            && operation.sessionInstanceID != nil
    }

    func scheduleJoinTimeout(for roomID: RoomID, requestID: UUID) {
        pendingJoins[roomID]?.timeoutTask = Task { @NexoActor [weak self] in
            do {
                try await Task.sleep(for: P2PLimits.joinTimeout)
            } catch {
                return
            }
            self?.finishJoin(roomID, requestID: requestID, result: .failure(RoomError.joinTimedOut))
        }
    }

    func finishJoin(
        _ roomID: RoomID,
        requestID: UUID? = nil,
        result: Result<RoomSession, Error>,
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
                    if connectedPeers[operation.hostApplicationID]?.connectionSessionID == operation.connectionSessionID {
                        send(.leaveRoom(LeaveRoomPayload(roomID: roomID)), to: [operation.hostApplicationID], roomID: roomID)
                    }
                    session.removeAllActivities(reason: .sessionEnded)
                    session.setAccessState(.closed(reason: NexoReason(error: error)))
                    discardSession(roomID, publishes: publishes)
                }
            }
            operation.continuation?.resume(throwing: error)
        }
    }
}
