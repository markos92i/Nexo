//
//  GenericActivity.swift
//  Nexo
//

import Foundation

// MARK: - ActivityEvent

public enum ActivityEvent<Message: Sendable>: Sendable {
    case message(Message, RoomMember)
    case participantJoined(RoomMember)
    case participantLeft(RoomMember)
    case descriptorUpdated(ActivityDescriptor)
    case ended(NexoReason)
}

// MARK: - ActivityEventStream

/// A single-consumer queue whose cancellation detaches the reader, not the activity.
public struct ActivityEventStream<Message: Sendable>: AsyncSequence, Sendable {
    public typealias Element = ActivityEvent<Message>
    fileprivate let storage: ActivityEventStorage<Message>

    public struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let storage: ActivityEventStorage<Message>

        public mutating func next() async -> Element? {
            await storage.next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(storage: storage)
    }
}

@NexoActor
fileprivate final class ActivityEventStorage<Message: Sendable> {
    struct Entry {
        let event: ActivityEvent<Message>
        let key: String?
        let byteCount: Int
    }

    private var pending: [Entry] = []
    private var bufferedBytes = 0
    private var waiter: (id: UUID, continuation: CheckedContinuation<ActivityEvent<Message>?, Never>)?
    private var isFinished = false

    func next() async -> ActivityEvent<Message>? {
        let id = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            if !pending.isEmpty {
                let entry = pending.removeFirst()
                bufferedBytes -= entry.byteCount
                return entry.event
            }
            guard !isFinished else { return nil }
            return await withCheckedContinuation { continuation in
                waiter?.continuation.resume(returning: nil)
                waiter = (id, continuation)
            }
        } onCancel: {
            Task { @NexoActor [weak self] in
                guard let self, self.waiter?.id == id else { return }
                self.waiter?.continuation.resume(returning: nil)
                self.waiter = nil
            }
        }
    }

    func yield(_ event: ActivityEvent<Message>, key: String? = nil, byteCount: Int = 256) -> Bool {
        guard !isFinished else { return true }
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: event)
            return true
        }
        if let key {
            // Reliable events are barriers: a newer state cannot overtake an order.
            for index in pending.indices.reversed() {
                guard pending[index].key != nil else { break }
                if pending[index].key == key {
                    bufferedBytes -= pending.remove(at: index).byteCount
                    break
                }
            }
        }
        guard pending.count < 256, bufferedBytes + byteCount <= 4 * 1_024 * 1_024 else {
            pending.removeAll()
            bufferedBytes = 0
            return false
        }
        pending.append(Entry(event: event, key: key, byteCount: byteCount))
        bufferedBytes += byteCount
        return true
    }

    func finish() {
        isFinished = true
        waiter?.continuation.resume(returning: nil)
        waiter = nil
    }

    isolated deinit {
        waiter?.continuation.resume(returning: nil)
    }
}

// MARK: - GenericActivity

@NexoActor
open class GenericActivity<Message: Codable & Sendable>: RoomActivity {
    public private(set) var descriptor: ActivityDescriptor
    public nonisolated let events: ActivityEventStream<Message>
    public var onDescriptorChange: (@NexoActor () -> Void)?
    public let context: ActivityContext

    private let eventStorage: ActivityEventStorage<Message>
    private let coalescingKey: @Sendable (Message) -> String?
    private var isEnded = false

    public var isLocalHost: Bool { descriptor.hostApplicationID == context.identity.applicationID }
    public var localDisplayName: String { context.identity.displayName }
    public var localApplicationID: String { context.identity.applicationID }
    public var participants: [RoomMember] { context.participants(for: descriptor) }

    public init(
        context: ActivityContext,
        coalescingKey: @escaping @Sendable (Message) -> String? = { _ in nil }
    ) {
        self.context = context
        self.descriptor = context.descriptor
        self.coalescingKey = coalescingKey
        let storage = ActivityEventStorage<Message>()
        self.eventStorage = storage
        self.events = ActivityEventStream(storage: storage)
    }

    public func send(_ message: Message, coalescingKey: String? = nil, to member: RoomMember? = nil) {
        guard !isEnded else { return }
        let recipients = member.map { [$0.applicationID] } ?? participants.map(\.applicationID)
        guard !recipients.isEmpty else { return }
        if let coalescingKey {
            context.outbox.sendCoalesced(
                message,
                channel: .activity,
                activityID: descriptor.id,
                coalescingKey: coalescingKey,
                to: recipients
            )
        } else {
            context.outbox.send(message, channel: .activity, activityID: descriptor.id, to: recipients)
        }
    }

    public func setState(_ state: ActivityState) {
        guard !isEnded, isLocalHost, descriptor.state != state else { return }
        descriptor.state = state
        emit(.descriptorUpdated(descriptor))
        onDescriptorChange?()
    }

    public func receive(payload: Data, from member: RoomMember) {
        guard !isEnded, let message = try? P2PCoder.decode(Message.self, from: payload) else { return }
        let key = coalescingKey(message).map { "\(member.applicationID):\($0)" }
        emit(.message(message, member), key: key, byteCount: payload.count)
    }

    public func participantDidJoin(_ member: RoomMember) {
        guard !isEnded else { return }
        descriptor.participantIDs.insert(member.applicationID)
        emit(.participantJoined(member))
        onDescriptorChange?()
    }

    public func participantDidLeave(_ member: RoomMember) {
        guard !isEnded else { return }
        descriptor.participantIDs.remove(member.applicationID)
        emit(.participantLeft(member))
        onDescriptorChange?()
    }

    public func activityDidEnd(reason: NexoReason) {
        guard !isEnded else { return }
        isEnded = true
        if !eventStorage.yield(.ended(reason)) {
            _ = eventStorage.yield(.ended(reason))
        }
        eventStorage.finish()
    }

    public func apply(descriptor: ActivityDescriptor) {
        guard !isEnded else { return }
        self.descriptor = descriptor
        emit(.descriptorUpdated(descriptor))
        onDescriptorChange?()
    }

    /// Ends the activity through the room that owns it, so the session drops
    /// it and the other participants are told. Falls back to a local end when
    /// nothing owns the activity.
    public func end(reason: NexoReason) {
        guard !isEnded else { return }
        if let endActivity = context.endActivity {
            endActivity(reason)
            guard !isEnded else { return }
        }
        descriptor.state = .cancelled
        activityDidEnd(reason: reason)
        onDescriptorChange?()
    }

    private func emit(_ event: ActivityEvent<Message>, key: String? = nil, byteCount: Int = 256) {
        guard eventStorage.yield(event, key: key, byteCount: byteCount) else {
            end(reason: .connectionFailed)
            return
        }
    }
}
