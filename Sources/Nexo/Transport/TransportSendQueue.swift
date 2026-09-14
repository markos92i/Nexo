//
//  TransportSendQueue.swift
//  Nexo
//

import Foundation

// MARK: - TransportSendQueue

/// Send queue for one physical connection.
///
/// Solves two problems TCP doesn't solve on its own:
///
/// 1. **Lanes.** An image transfer must not delay a game order or a
///    membership message. The queue always drains by lane priority.
/// 2. **Latest-wins coalescing.** Board snapshots are full, replaceable
///    state: if one is still queued when the next arrives, it's replaced in
///    place. This way a stale snapshot never sits ahead of a `finishOrder`,
///    and no backlog builds up when the link saturates.
@MainActor
public final class TransportSendQueue {

    public typealias Sender = @MainActor (RoomEnvelope) async throws -> Void
    public typealias FailureHandler = @MainActor (Error) -> Void

    // MARK: - State

    private var lanes: [TransportLane: [RoomEnvelope]] = [:]
    private var drainTask: Task<Void, Never>?
    private var isStopped = false

    /// Consecutive sends served from lanes above `.transfer`. Stops a
    /// continuous stream of snapshots from starving a transfer.
    private var consecutiveNonTransferSends = 0
    private let transferStarvationGuard = 12

    private let send: Sender
    private let onFailure: FailureHandler

    /// Pending envelopes across every lane.
    public var pendingCount: Int { lanes.values.reduce(0) { $0 + $1.count } }

    // MARK: - Init

    public init(send: @escaping Sender, onFailure: @escaping FailureHandler) {
        self.send = send
        self.onFailure = onFailure
    }

    // MARK: - Public API

    public func enqueue(_ envelope: RoomEnvelope) {
        guard !isStopped else { return }

        let lane = envelope.lane

        if envelope.deliveryMode == .unreliable,
           let key = envelope.coalescingKey,
           let existingIndex = lanes[lane]?.firstIndex(where: { $0.coalescingKey == key }) {
            // Latest-wins: keep the position so the lane doesn't get reordered.
            lanes[lane]?[existingIndex] = envelope
        } else {
            lanes[lane, default: []].append(envelope)
        }

        startDrainingIfNeeded()
    }

    /// Discards anything pending and stops draining. The connection itself is closed separately.
    public func stop() {
        isStopped = true
        drainTask?.cancel()
        drainTask = nil
        lanes.removeAll()
    }

    // MARK: - Private Helpers

    private func startDrainingIfNeeded() {
        guard drainTask == nil else { return }

        drainTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                guard let envelope = self.dequeue() else {
                    self.drainTask = nil
                    return
                }

                do {
                    try await self.send(envelope)
                } catch is CancellationError {
                    self.drainTask = nil
                    return
                } catch {
                    self.drainTask = nil
                    self.onFailure(error)
                    return
                }
            }
        }
    }

    private func dequeue() -> RoomEnvelope? {
        guard !isStopped else { return nil }

        for lane in nextLaneOrder() {
            guard var queue = lanes[lane], !queue.isEmpty else { continue }

            let envelope = queue.removeFirst()
            lanes[lane] = queue.isEmpty ? nil : queue

            if lane == .transfer {
                consecutiveNonTransferSends = 0
            } else {
                consecutiveNonTransferSends += 1
            }

            return envelope
        }

        return nil
    }

    /// Order in which lanes are inspected for the next send. Normally natural
    /// priority; once the starvation threshold is hit, `.transfer` moves to
    /// the front so the transfer can progress.
    private func nextLaneOrder() -> [TransportLane] {
        let naturalOrder = TransportLane.allCases.sorted()

        guard consecutiveNonTransferSends >= transferStarvationGuard,
              lanes[.transfer]?.isEmpty == false else {
            return naturalOrder
        }

        return [.transfer] + naturalOrder.filter { $0 != .transfer }
    }
}
