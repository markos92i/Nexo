//
//  TransportSendQueue.swift
//  Project Dark
//
//  Created by Marcos del Castillo Camacho on 11/09/2026.
//

import Foundation

// MARK: - TransportSendQueue

/// Cola de envío de una conexión física.
///
/// Resuelve dos problemas que TCP no resuelve por sí solo:
///
/// 1. **Lanes.** Una transferencia de imagen no debe retrasar una orden de juego
///    ni un mensaje de membresía. La cola drena siempre por prioridad de lane.
/// 2. **Coalescing latest-wins.** Los snapshots de tablero son estado completo y
///    sustituible: si uno todavía está en la cola cuando llega el siguiente, se
///    reemplaza en su posición. Así un snapshot viejo nunca ocupa sitio delante
///    de un `finishOrder` y no se acumula backlog al saturarse el enlace.
@MainActor
public final class TransportSendQueue {

    public typealias Sender = @MainActor (RoomEnvelope) async throws -> Void
    public typealias FailureHandler = @MainActor (Error) -> Void

    // MARK: - Estado

    private var lanes: [TransportLane: [RoomEnvelope]] = [:]
    private var drainTask: Task<Void, Never>?
    private var isStopped = false

    /// Envíos consecutivos servidos desde lanes por encima de `.transfer`. Evita
    /// que un flujo continuo de snapshots deje una transferencia sin avanzar.
    private var consecutiveNonTransferSends = 0
    private let transferStarvationGuard = 12

    private let send: Sender
    private let onFailure: FailureHandler

    /// Envelopes pendientes en todas las lanes.
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
            // Latest-wins: se conserva la posición para no reordenar la lane.
            lanes[lane]?[existingIndex] = envelope
        } else {
            lanes[lane, default: []].append(envelope)
        }

        startDrainingIfNeeded()
    }

    /// Descarta lo pendiente y detiene el drenado. La conexión se cierra aparte.
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

    /// Orden de inspección de lanes para el siguiente envío. Normalmente es la
    /// prioridad natural; cuando se alcanza el umbral de inanición, `.transfer`
    /// pasa al frente para que la transferencia progrese.
    private func nextLaneOrder() -> [TransportLane] {
        let naturalOrder = TransportLane.allCases.sorted()

        guard consecutiveNonTransferSends >= transferStarvationGuard,
              lanes[.transfer]?.isEmpty == false else {
            return naturalOrder
        }

        return [.transfer] + naturalOrder.filter { $0 != .transfer }
    }
}
