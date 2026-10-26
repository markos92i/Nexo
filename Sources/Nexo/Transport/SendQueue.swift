import Foundation

/// Cola de envío acotada y consciente de prioridad para una conexión física.
actor SendQueue {
    typealias Sender = @Sendable (Envelope) async throws -> Void
    typealias FailureHandler = @Sendable (any Error) async -> Void

    private static let maximumPendingCount = 256
    private static let maximumPendingBytes = 4 * 1024 * 1024
    private var lanes: [TransportLane: [Envelope]] = [:]
    private var pendingBytes = 0
    private var drainTask: Task<Void, Never>?
    private var isStopped = false
    private var consecutiveNonTransferSends = 0
    private let transferStarvationGuard = 12
    private let send: Sender
    private let onFailure: FailureHandler

    var pendingCount: Int { lanes.values.reduce(0) { $0 + $1.count } }

    init(send: @escaping Sender, onFailure: @escaping FailureHandler) {
        self.send = send
        self.onFailure = onFailure
    }

    deinit { drainTask?.cancel() }

    func enqueue(_ envelope: Envelope) async {
        guard !isStopped else { return }
        let lane = envelope.lane
        let replacement = lanes[lane]?.firstIndex { envelope.canReplace($0) }
        let previousBytes = replacement.flatMap { lanes[lane]?[$0].transportBudgetBytes } ?? 0
        let nextBytes = pendingBytes - previousBytes + envelope.transportBudgetBytes
        guard envelope.payload.count <= Limits.maximumEnvelopeBytes,
              nextBytes <= Self.maximumPendingBytes,
              replacement != nil || pendingCount < Self.maximumPendingCount else {
            stop()
            await onFailure(TransportError.connectionFailed(.connectionFailed))
            return
        }
        if let replacement {
            lanes[lane]?[replacement] = envelope
        } else {
            lanes[lane, default: []].append(envelope)
        }
        pendingBytes = nextBytes
        startDrainingIfNeeded()
    }

    func stop() {
        isStopped = true
        drainTask?.cancel()
        drainTask = nil
        lanes.removeAll()
        pendingBytes = 0
    }

    private func startDrainingIfNeeded() {
        guard drainTask == nil else { return }
        let send = send
        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                // El await del socket no debe retener la cola que posee esta tarea.
                guard let envelope = await self?.dequeue() else { return }
                do {
                    try await send(envelope)
                } catch {
                    await self?.failed(error)
                    return
                }
            }
        }
    }

    private func failed(_ error: any Error) async {
        guard !isStopped else { return }
        stop()
        await onFailure(error)
    }

    private func dequeue() -> Envelope? {
        guard !isStopped else { return nil }
        for lane in nextLaneOrder() {
            guard var queue = lanes[lane], !queue.isEmpty else { continue }
            let envelope = queue.removeFirst()
            lanes[lane] = queue.isEmpty ? nil : queue
            pendingBytes -= envelope.transportBudgetBytes
            consecutiveNonTransferSends = lane == .transfer ? 0 : consecutiveNonTransferSends + 1
            return envelope
        }
        drainTask = nil
        return nil
    }

    private func nextLaneOrder() -> [TransportLane] {
        let naturalOrder = TransportLane.allCases.sorted()
        guard consecutiveNonTransferSends >= transferStarvationGuard,
              lanes[.transfer]?.isEmpty == false else { return naturalOrder }
        return [.transfer] + naturalOrder.filter { $0 != .transfer }
    }
}

extension Envelope {
    /// Incluye strings retenidos y overhead de framing, no solo bytes de payload.
    var transportBudgetBytes: Int {
        payload.count + senderDeviceID.description.utf8.count + (coalescingKey?.utf8.count ?? 0) + 512
    }

    func canReplace(_ previous: Envelope) -> Bool {
        deliveryMode == .unreliable && previous.deliveryMode == .unreliable
            && coalescingKey != nil && coalescingKey == previous.coalescingKey
            && roomID == previous.roomID && activityID == previous.activityID
            && channel == previous.channel && senderDeviceID == previous.senderDeviceID
    }
}
