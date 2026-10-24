//
//  RoomSession.swift
//  Nexo
//

import Foundation

// MARK: - RoomEvent

/// Retained independently of chat so the app can localize events when displayed.
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

// MARK: - RoomSnapshot

/// Sendable snapshot of a room's state for consumption off `NexoActor`.
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

// MARK: - RoomSession

/// A live room: members, chat and activities.
///
/// Survives navigation across the room list, chat, a game's lobby, the game
/// itself and its result. Leaving an activity destroys the activity, not the session.
@NexoActor
public final class RoomSession: Identifiable {

    // MARK: - Identity

    public nonisolated let roomID: RoomID
    public nonisolated let instanceID = UUID()
    public nonisolated var id: RoomID { roomID }
    public private(set) var descriptor: RoomDescriptor

    // MARK: - State

    public var members: [RoomMember] { membership.members }
    public private(set) var accessState: RoomAccessState
    /// Pending approval requests. Scoped per room: a host can govern several
    /// rooms with independent queues.
    public private(set) var pendingJoinRequests: [RoomJoinRequest] = []
    /// Live activities, indexed by ID.
    public private(set) var activities: [ActivityID: any RoomActivity] = [:]
    public private(set) var events: [RoomEvent] = []

    public let chat: ChatRoomSession?
    let outbox: RoomOutbox

    /// Changes to the room's visible state, for consumers that cannot read an
    /// actor-isolated object (the UI). Keeps only the latest snapshot: a slower
    /// consumer never has to render intermediate states.
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
    private weak var transferService: FileTransferService?

    private let membership: RoomMembership
    private let identity: LocalP2PIdentity

    // MARK: - Derived

    public var isLocalHost: Bool { descriptor.hostApplicationID == identity.applicationID }
    public var localRole: RoomRole { isLocalHost ? .host : .guest }
    public var features: RoomFeatures { descriptor.features }
    public var name: String { descriptor.name }

    public var host: RoomMember? {
        membership.member(descriptor.hostApplicationID)
    }

    /// Members other than the local user.
    public var remoteMembers: [RoomMember] {
        members.filter { $0.applicationID != identity.applicationID }
    }

    /// The primary activity for a UI that only shows one game at a time.
    /// Ignores non-exclusive ones (e.g. chat), which can run alongside it.
    public var primaryActivity: (any RoomActivity)? {
        activities.values.first { $0.descriptor.isActive && $0.descriptor.isExclusive }
            ?? activities.values.first { $0.descriptor.isExclusive }
    }

    /// Kind of the game being played right now, for a room that didn't declare
    /// one. Ordered so the advertised value doesn't depend on dictionary order.
    public var liveActivityKind: ActivityKind? {
        activities.values
            .map(\.descriptor.kind)
            .min { $0.rawValue < $1.rawValue }
    }

    public var canStartActivity: Bool {
        features.hasActivities
            && activities.values.allSatisfy { !$0.descriptor.isActive || !$0.descriptor.isExclusive }
    }

    // MARK: - Init

    public init(
        descriptor: RoomDescriptor,
        identity: LocalP2PIdentity,
        outbox: RoomOutbox,
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
            ? ChatRoomSession(roomID: descriptor.id, outbox: outbox, identity: identity, membership: membership)
            : nil
        self.chat = chat

        // Chat and transfers mutate their own state; the room is the single
        // place that turns those changes into room snapshots.
        chat?.onChange = { [weak self] in self?.publishSnapshot() }
    }

    // MARK: - Snapshot

    /// Creates a Sendable snapshot of the current state for consumption off `NexoActor`.
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
            localTransferURLs: transferService?.localFileURLs(for: Set(chat?.transfers.keys.map { $0 } ?? [])) ?? [:],
            revision: revision
        )
    }

    func bindTransfers(_ service: FileTransferService) {
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

    isolated deinit {
        snapshotTask?.cancel()
        for continuation in snapshotContinuations.values { continuation.finish() }
    }

    // MARK: - Membership

    public func apply(descriptor: RoomDescriptor) {
        self.descriptor = descriptor
        publishSnapshot()
    }

    public func apply(members: [RoomMember]) {
        let previousMembers = membership.members
        let previousIDs = Set(previousMembers.map(\.applicationID))

        membership.update(members)
        let updatedMembers = membership.members
        let updatedIDs = Set(updatedMembers.map(\.applicationID))
        descriptor.memberCount = updatedMembers.count

        for member in updatedMembers where !previousIDs.contains(member.applicationID) {
            if member.applicationID == identity.applicationID {
                record(.localJoined)
            } else {
                record(.memberJoined(displayName: member.displayName))
            }
        }

        for member in previousMembers
        where !updatedIDs.contains(member.applicationID) && member.applicationID != identity.applicationID {
            record(.memberLeft(displayName: member.displayName))
            notifyActivitiesOfDeparture(member)
        }

        publishSnapshot()
    }

    public func setAccessState(_ state: RoomAccessState) {
        accessState = state
        publishSnapshot()
    }

    public func member(_ applicationID: String) -> RoomMember? {
        membership.member(applicationID)
    }

    public func contains(_ applicationID: String) -> Bool {
        membership.contains(applicationID)
    }

    // MARK: - Events

    func record(_ kind: RoomEventKind) {
        events.append(RoomEvent(kind: kind))
        if events.count > P2PLimits.chatHistoryLimit {
            events.removeFirst(events.count - P2PLimits.chatHistoryLimit)
        }
        publishSnapshot()
    }

    public func clearChatHistory() {
        chat?.clearHistory()
        events.removeAll()
        publishSnapshot()
    }

    // MARK: - Join requests

    public func enqueueJoinRequest(_ request: RoomJoinRequest) -> Bool {
        guard !pendingJoinRequests.contains(where: { $0.applicationID == request.applicationID }) else {
            return false
        }
        pendingJoinRequests.append(request)
        publishSnapshot()
        return true
    }

    public func removeJoinRequest(_ id: UUID) -> RoomJoinRequest? {
        guard let index = pendingJoinRequests.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = pendingJoinRequests.remove(at: index)
        publishSnapshot()
        return removed
    }

    public func removeJoinRequests(for applicationID: String) {
        let before = pendingJoinRequests.count
        pendingJoinRequests.removeAll { $0.applicationID == applicationID }
        if pendingJoinRequests.count != before { publishSnapshot() }
    }

    // MARK: - Activities

    public func register(_ activity: any RoomActivity) {
        activities[activity.descriptor.id] = activity
        activity.onDescriptorChange = { [weak self] in self?.publishSnapshot() }
        publishSnapshot()
    }

    public func activity(_ id: ActivityID) -> (any RoomActivity)? {
        activities[id]
    }

    public func activity(ofKind kind: ActivityKind) -> (any RoomActivity)? {
        activities.values.first { $0.descriptor.kind == kind && $0.descriptor.isActive }
    }

    public func removeActivity(_ id: ActivityID, reason: NexoReason) {
        guard let activity = activities.removeValue(forKey: id) else { return }
        activity.activityDidEnd(reason: reason)
        publishSnapshot()
    }

    public func removeAllActivities(reason: NexoReason) {
        guard !activities.isEmpty else { return }
        let current = activities
        activities.removeAll()
        for activity in current.values {
            activity.activityDidEnd(reason: reason)
        }
        publishSnapshot()
    }

    /// Removes only the activities no longer present in the host's
    /// authoritative snapshot, keeping the rest and their state.
    public func removeActivities(notIncludedIn activeIDs: Set<ActivityID>, reason: NexoReason) {
        let staleIDs = activities.keys.filter { !activeIDs.contains($0) }
        for activityID in staleIDs {
            removeActivity(activityID, reason: reason)
        }
    }

    /// Context to instantiate an activity scoped to this room.
    public func makeActivityContext(
        for descriptor: ActivityDescriptor,
        endActivity: (@NexoActor (NexoReason) -> Void)? = nil
    ) -> ActivityContext {
        ActivityContext(
            descriptor: descriptor,
            identity: identity,
            outbox: outbox,
            members: { [weak self] in self?.members ?? [] },
            endActivity: endActivity
        )
    }

    // MARK: - Private Helpers

    private func notifyActivitiesOfDeparture(_ member: RoomMember) {
        for activity in activities.values where activity.descriptor.includes(member.applicationID) {
            activity.participantDidLeave(member)
        }
    }
}
