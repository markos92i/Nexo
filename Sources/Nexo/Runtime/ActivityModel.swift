//
//  ActivityModel.swift
//  Nexo
//

import Foundation
import Synchronization

// MARK: - ActivityModel

/// Una actividad usada desde el hilo principal, lista para un view model.
///
/// Es a `GenericActivity` lo que `RoomsModel` es a `RoomService`: copia en el
/// hilo principal el descriptor, entrega los eventos ahí y acepta envíos sin
/// `await`. Los envíos van por un buzón que preserva el orden, y si dos estados
/// reemplazables con la misma clave esperan a salir, solo sale el último.
@MainActor
public final class ActivityModel<Message: Codable & Sendable> {
    public typealias Handler = @MainActor (ActivityModel<Message>, ActivityEvent<Message>) -> Void

    public private(set) var descriptor: ActivityDescriptor
    public private(set) var isLocalHost: Bool
    public var id: ActivityID { descriptor.id }

    private let underlying: GenericActivity<Message>
    private let localDeviceID: DeviceID
    private let coalescingKey: @Sendable (Message) -> String?
    private let mailbox = Mailbox()
    private var sendTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var handler: Handler?
    private var observationID = UUID()

    /// - Parameter coalescingKey: clave de los mensajes reemplazables (un
    ///   snapshot de tablero, una posición). `nil` para los que deben llegar
    ///   todos y en orden.
    public init(
        _ activity: GenericActivity<Message>,
        coalescingKey: @escaping @Sendable (Message) -> String? = { _ in nil }
    ) async {
        self.underlying = activity
        self.coalescingKey = coalescingKey
        let localDeviceID = await activity.localDeviceID
        let descriptor = await activity.descriptor
        self.localDeviceID = localDeviceID
        self.descriptor = descriptor
        self.isLocalHost = descriptor.hostDeviceID == localDeviceID
        let mailbox = mailbox
        sendTask = Task { @NexoActor in
            for await _ in mailbox.wakeups {
                guard !Task.isCancelled else { return }
                while let command = mailbox.pop() {
                    switch command {
                    case .send(let message, let key, let recipients):
                        if let key {
                            activity.sendState(message, coalescingKey: key, to: recipients)
                        } else {
                            activity.send(message, to: recipients)
                        }
                    case .state(let state):
                        activity.setState(state)
                    case .overflow:
                        activity.end(reason: .connectionFailed)
                        return
                    }
                }
            }
        }
    }

    isolated deinit {
        eventTask?.cancel()
        mailbox.finish()
        sendTask?.cancel()
    }

    public func isHost(_ deviceID: DeviceID) -> Bool {
        descriptor.hostDeviceID == deviceID
    }

    /// Empieza a entregar eventos. Llamarlo otra vez cambia el handler sin perder
    /// los eventos que ya estaban en camino.
    public func start(_ handler: @escaping Handler) {
        self.handler = handler
        guard eventTask == nil else { return }
        let observationID = UUID()
        self.observationID = observationID
        let events = underlying.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self, self.observationID == observationID else { return }
                if case .descriptorUpdated(let descriptor) = event {
                    self.descriptor = descriptor
                    self.isLocalHost = descriptor.hostDeviceID == self.localDeviceID
                }
                self.handler?(self, event)
            }
            guard let self, self.observationID == observationID else { return }
            self.eventTask = nil
        }
    }

    public func stop() {
        observationID = UUID()
        handler = nil
        eventTask?.cancel()
        eventTask = nil
    }

    public func send(_ message: Message, to recipients: ActivityRecipients = .everyone) {
        mailbox.push(.send(message, coalescingKey(message), recipients))
    }

    /// Solo el host de la actividad puede cambiar su estado.
    public func setState(_ state: ActivityState) {
        mailbox.push(.state(state))
    }

    // MARK: - Mailbox

    private final class Mailbox: Sendable {
        enum Command: Sendable {
            case send(Message, String?, ActivityRecipients)
            case state(ActivityState)
            case overflow

            /// Dos envíos reemplazables son intercambiables si van al mismo
            /// destino con la misma clave.
            var replacementKey: String? {
                guard case .send(_, let key?, let recipients) = self else { return nil }
                return "\(recipients.replacementTag):\(key)"
            }
        }

        private struct State {
            var pending: [Command] = []
            var isClosed = false
        }

        /// Más envíos sin salir indica un bucle desbocado: se termina la actividad.
        private static var limit: Int { 256 }

        let wakeups: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation
        private let state = Mutex(State())

        init() {
            (wakeups, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        }

        func push(_ command: Command) {
            state.withLock { state in
                guard !state.isClosed else { return }
                if let key = command.replacementKey {
                    for index in state.pending.indices.reversed() {
                        guard state.pending[index].replacementKey != nil else { break }
                        if state.pending[index].replacementKey == key {
                            state.pending.remove(at: index)
                            break
                        }
                    }
                }
                guard state.pending.count < Self.limit else {
                    state.pending = [.overflow]
                    state.isClosed = true
                    return
                }
                state.pending.append(command)
            }
            continuation.yield(())
        }

        func pop() -> Command? {
            state.withLock { state in
                guard !state.pending.isEmpty else { return nil }
                return state.pending.removeFirst()
            }
        }

        func finish() {
            state.withLock { $0.isClosed = true }
            continuation.finish()
        }
    }
}

private extension ActivityRecipients {
    var replacementTag: String {
        switch self {
        case .everyone: "*"
        case .member(let deviceID): deviceID.description
        case .members(let ids): ids.map(\.description).sorted().joined(separator: ",")
        }
    }
}
