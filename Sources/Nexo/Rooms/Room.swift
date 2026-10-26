import Foundation

// MARK: - RoomEvent

/// Se guarda independiente del chat para que la app pueda localizar los eventos
/// al mostrarlos.
public struct RoomEvent: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let kind: RoomEventKind

    public init(id: UUID = UUID(), timestamp: Date = Date(), kind: RoomEventKind) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
    }
}

public enum RoomEventKind: Sendable {
    case localJoined
    case memberJoined(displayName: String)
    case memberLeft(displayName: String)
    case hostChanged
    case hostConnectionLost
}

// MARK: - TransferURLProviding

/// Vista mínima del servicio de transferencias que la sala necesita para su
/// snapshot. La implementa `FileTransferService` (Fase 6) sin que `Room` dependa
/// de su tipo concreto.
@NexoActor
public protocol TransferURLProviding: AnyObject {
    func localFileURLs(for transferIDs: Set<UUID>) -> [UUID: URL]
}

// MARK: - RoomSnapshot

/// Snapshot `Sendable` del estado de una sala, para consumo fuera de `NexoActor`.
public struct RoomSnapshot: Sendable {
    public let roomID: RoomID
    public let descriptor: RoomDescriptor
    public let members: [RoomMember]
    public let accessState: RoomAccessState
    public let events: [RoomEvent]
    public let isLocalHost: Bool
    public let canStartActivity: Bool
    public let pendingJoinRequests: [RoomJoinRequest]
    public let chatMessages: [ChatMessage]
    public let chatTransfers: [UUID: FileTransferState]
    public let activityDescriptors: [ActivityDescriptor]
    public let localTransferURLs: [UUID: URL]
    public let revision: UInt64

    public init(
        roomID: RoomID,
        descriptor: RoomDescriptor,
        members: [RoomMember],
        accessState: RoomAccessState,
        events: [RoomEvent],
        isLocalHost: Bool,
        canStartActivity: Bool,
        pendingJoinRequests: [RoomJoinRequest],
        chatMessages: [ChatMessage],
        chatTransfers: [UUID: FileTransferState],
        activityDescriptors: [ActivityDescriptor],
        localTransferURLs: [UUID: URL] = [:],
        revision: UInt64 = 0
    ) {
        self.roomID = roomID
        self.descriptor = descriptor
        self.members = members
        self.accessState = accessState
        self.events = events
        self.isLocalHost = isLocalHost
        self.canStartActivity = canStartActivity
        self.pendingJoinRequests = pendingJoinRequests
        self.chatMessages = chatMessages
        self.chatTransfers = chatTransfers
        self.activityDescriptors = activityDescriptors
        self.localTransferURLs = localTransferURLs
        self.revision = revision
    }
}

// MARK: - Room

/// Una sala viva: miembros, chat y actividades.
///
/// Sobrevive a la navegación entre la lista de salas, el chat, el lobby de un
/// juego, el juego y su resultado. Salir de una actividad destruye la actividad,
/// no la sala.
@NexoActor
public final class Room: Identifiable {

    // MARK: - Identidad

    public nonisolated let roomID: RoomID
    public nonisolated let instanceID = UUID()
    public nonisolated var id: RoomID { roomID }
    public private(set) var descriptor: RoomDescriptor

    // MARK: - Estado

    public var members: [RoomMember] { membership.members }
    public private(set) var accessState: RoomAccessState
    public private(set) var pendingJoinRequests: [RoomJoinRequest] = []
    public private(set) var activities: [ActivityID: any Activity] = [:]
    public private(set) var events: [RoomEvent] = []

    public let chat: RoomChat?
    let outbox: RoomOutbox

    /// Cambios del estado visible, para consumidores que no pueden leer un objeto
    /// aislado al actor (la UI). Conserva solo el snapshot más reciente.
    public var snapshots: AsyncStream<RoomSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: RoomSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield(snapshot())
        if case .closed = accessState {
            continuation.finish()
        } else {
            snapshotContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @NexoActor in self?.snapshotContinuations.removeValue(forKey: id) }
            }
        }
        return stream
    }
    private var snapshotContinuations: [UUID: AsyncStream<RoomSnapshot>.Continuation] = [:]
    private var snapshotTask: Task<Void, Never>?
    private var revision: UInt64 = 0
    private weak var transferService: (any TransferURLProviding)?

    private let membership: RoomMembership
    private let identity: LocalIdentity

    // MARK: - Derivados

    public var isLocalHost: Bool { descriptor.hostDeviceID == identity.deviceID }
    public var localRole: RoomRole { isLocalHost ? .host : .guest }
    public var features: RoomFeatures { descriptor.features }
    public var name: String { descriptor.name }

    public var host: RoomMember? { membership.member(descriptor.hostDeviceID) }

    /// Miembros distintos del usuario local.
    public var remoteMembers: [RoomMember] {
        members.filter { $0.deviceID != identity.deviceID }
    }

    /// La actividad principal para una UI que solo muestra un juego a la vez.
    public var primaryActivity: (any Activity)? {
        activities.values.first { $0.descriptor.isActive && $0.descriptor.isExclusive }
            ?? activities.values.first { $0.descriptor.isExclusive }
    }

    /// Tipo del juego que se está jugando ahora, para una sala que no declaró uno.
    public var liveActivityKind: ActivityKind? {
        activities.values.map(\.descriptor.kind).min { $0.rawValue < $1.rawValue }
    }

    public var canStartActivity: Bool {
        features.hasActivities
            && activities.values.allSatisfy { !$0.descriptor.isActive || !$0.descriptor.isExclusive }
    }

    // MARK: - Init

    init(
        descriptor: RoomDescriptor,
        identity: LocalIdentity,
        outbox: RoomOutbox,
        store: any MessageStore,
        accessState: RoomAccessState,
        members: [RoomMember] = []
    ) {
        self.roomID = descriptor.id
        self.descriptor = descriptor
        self.identity = identity
        self.outbox = outbox
        self.accessState = accessState
        let membership = RoomMembership(members: members)
        self.membership = membership
        let chat = descriptor.features.hasChat
            ? RoomChat(roomID: descriptor.id, store: store, outbox: outbox, identity: identity, membership: membership)
            : nil
        self.chat = chat

        chat?.onChange = { [weak self] in self?.publishSnapshot() }
    }

    // MARK: - Snapshot

    public func snapshot() -> RoomSnapshot {
        RoomSnapshot(
            roomID: roomID,
            descriptor: descriptor,
            members: membership.members,
            accessState: accessState,
            events: events,
            isLocalHost: isLocalHost,
            canStartActivity: canStartActivity,
            pendingJoinRequests: pendingJoinRequests,
            chatMessages: chat?.messages ?? [],
            chatTransfers: chat?.transfers ?? [:],
            activityDescriptors: activities.values.map(\.descriptor),
            localTransferURLs: transferService?.localFileURLs(for: Set(chat?.transfers.keys ?? [:].keys)) ?? [:],
            revision: revision
        )
    }

    func bindTransfers(_ service: any TransferURLProviding) {
        transferService = service
    }

    private func publishSnapshot() {
        revision &+= 1
        guard snapshotTask == nil, !snapshotContinuations.isEmpty else { return }
        snapshotTask = Task { @NexoActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.snapshotTask = nil
            let snapshot = self.snapshot()
            for continuation in self.snapshotContinuations.values {
                continuation.yield(snapshot)
                if case .closed = snapshot.accessState { continuation.finish() }
            }
            if case .closed = snapshot.accessState { self.snapshotContinuations.removeAll() }
        }
    }

    deinit {
        snapshotTask?.cancel()
        for continuation in snapshotContinuations.values { continuation.finish() }
    }

    // MARK: - Membresía (internal: mecánica del servicio)

    func apply(descriptor: RoomDescriptor) {
        self.descriptor = descriptor
        publishSnapshot()
    }

    func apply(members: [RoomMember]) {
        let previousMembers = membership.members
        let previousIDs = Set(previousMembers.map(\.deviceID))

        membership.update(members)
        let updatedMembers = membership.members
        let updatedIDs = Set(updatedMembers.map(\.deviceID))
        descriptor.memberCount = updatedMembers.count

        for member in updatedMembers where !previousIDs.contains(member.deviceID) {
            if member.deviceID == identity.deviceID {
                record(.localJoined)
            } else {
                record(.memberJoined(displayName: member.displayName))
            }
        }

        for member in previousMembers
        where !updatedIDs.contains(member.deviceID) && member.deviceID != identity.deviceID {
            record(.memberLeft(displayName: member.displayName))
            notifyActivitiesOfDeparture(member)
        }

        publishSnapshot()
    }

    func setAccessState(_ state: RoomAccessState) {
        accessState = state
        publishSnapshot()
    }

    public func member(_ deviceID: DeviceID) -> RoomMember? {
        membership.member(deviceID)
    }

    public func contains(_ deviceID: DeviceID) -> Bool {
        membership.contains(deviceID)
    }

    // MARK: - Eventos

    func record(_ kind: RoomEventKind) {
        events.append(RoomEvent(kind: kind))
        if events.count > Limits.chatHistoryLimit {
            events.removeFirst(events.count - Limits.chatHistoryLimit)
        }
        publishSnapshot()
    }

    public func clearChatHistory() {
        chat?.clearHistory()
        events.removeAll()
        publishSnapshot()
    }

    // MARK: - Solicitudes de entrada (internal)

    func enqueueJoinRequest(_ request: RoomJoinRequest) -> Bool {
        guard !pendingJoinRequests.contains(where: { $0.deviceID == request.deviceID }) else {
            return false
        }
        pendingJoinRequests.append(request)
        publishSnapshot()
        return true
    }

    func removeJoinRequest(_ id: UUID) -> RoomJoinRequest? {
        guard let index = pendingJoinRequests.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = pendingJoinRequests.remove(at: index)
        publishSnapshot()
        return removed
    }

    func removeJoinRequests(for deviceID: DeviceID) {
        let before = pendingJoinRequests.count
        pendingJoinRequests.removeAll { $0.deviceID == deviceID }
        if pendingJoinRequests.count != before { publishSnapshot() }
    }

    // MARK: - Actividades (internal)

    func register(_ activity: any Activity) {
        activities[activity.descriptor.id] = activity
        activity.onDescriptorChange = { [weak self] in self?.publishSnapshot() }
        publishSnapshot()
    }

    public func activity(_ id: ActivityID) -> (any Activity)? {
        activities[id]
    }

    public func activity(ofKind kind: ActivityKind) -> (any Activity)? {
        activities.values.first { $0.descriptor.kind == kind && $0.descriptor.isActive }
    }

    func removeActivity(_ id: ActivityID, reason: DisconnectReason) {
        guard let activity = activities.removeValue(forKey: id) else { return }
        activity.activityDidEnd(reason: reason)
        publishSnapshot()
    }

    func removeAllActivities(reason: DisconnectReason) {
        guard !activities.isEmpty else { return }
        let current = activities
        activities.removeAll()
        for activity in current.values {
            activity.activityDidEnd(reason: reason)
        }
        publishSnapshot()
    }

    func removeActivities(notIncludedIn activeIDs: Set<ActivityID>, reason: DisconnectReason) {
        let staleIDs = activities.keys.filter { !activeIDs.contains($0) }
        for activityID in staleIDs {
            removeActivity(activityID, reason: reason)
        }
    }

    /// Contexto para instanciar una actividad acotada a esta sala.
    func makeActivityContext(
        for descriptor: ActivityDescriptor,
        endActivity: (@NexoActor (DisconnectReason) -> Void)? = nil
    ) -> ActivityContext {
        ActivityContext(
            descriptor: descriptor,
            identity: identity,
            outbox: outbox,
            members: { [weak self] in self?.members ?? [] },
            endActivity: endActivity
        )
    }

    // MARK: - Privados

    private func notifyActivitiesOfDeparture(_ member: RoomMember) {
        for activity in activities.values where activity.descriptor.includes(member.deviceID) {
            activity.participantDidLeave(member)
        }
    }
}
