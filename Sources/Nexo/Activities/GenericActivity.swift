import Foundation

// MARK: - ActivityEvent

public enum ActivityEvent<Message: Sendable>: Sendable {
    case message(Message, RoomMember)
    case participantJoined(RoomMember)
    case participantLeft(RoomMember)
    case descriptorUpdated(ActivityDescriptor)
    case ended(DisconnectReason)
}

// MARK: - GenericActivity

/// Base para una actividad tipada (un juego).
///
/// Decodifica los mensajes de la app, los entrega por una `AsyncStream` estándar
/// y envía con destino explícito. El coalescing latest-wins para estado
/// reemplazable ya lo hace la cola de envío del transporte en emisión, así que el
/// receptor no re-coalesce: la UI consume los eventos en orden.
///
/// Para que el estado del juego sobreviva a reconexiones y migración de host, la
/// subclase sobreescribe `currentStateSnapshot()`.
@NexoActor
open class GenericActivity<Message: Codable & Sendable>: Activity {

    public private(set) var descriptor: ActivityDescriptor
    public let context: ActivityContext
    public var onDescriptorChange: (@NexoActor () -> Void)?

    /// Flujo de eventos para la UI. Su cancelación desconecta al lector sin
    /// afectar a la actividad.
    ///
    /// Los eventos que llegan antes de que haya ningún lector (por ejemplo, el
    /// "listo" de otro jugador que entra mientras la UI aún se engancha) se
    /// guardan y se entregan al primer lector, en orden. Sin esto la app tendría
    /// que reenviar su estado periódicamente por si alguien se lo perdió.
    public nonisolated var events: AsyncStream<ActivityEvent<Message>> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: ActivityEvent<Message>.self,
            bufferingPolicy: .bufferingNewest(Self.pendingEventLimit)
        )
        continuation.onTermination = { [weak self] _ in
            Task { @NexoActor in self?.continuations.removeValue(forKey: id) }
        }
        Task { @NexoActor [weak self] in
            guard let self else { continuation.finish(); return }
            for event in self.pendingEvents { continuation.yield(event) }
            self.pendingEvents.removeAll()
            if self.isEnded {
                continuation.finish()
            } else {
                self.continuations[id] = continuation
            }
        }
        return stream
    }
    private var continuations: [UUID: AsyncStream<ActivityEvent<Message>>.Continuation] = [:]
    /// Eventos emitidos sin lectores, a la espera del primero.
    private var pendingEvents: [ActivityEvent<Message>] = []
    private nonisolated static var pendingEventLimit: Int { 256 }
    private var isEnded = false

    public var isLocalHost: Bool { descriptor.hostDeviceID == context.identity.deviceID }
    public var localDisplayName: String { context.identity.displayName }
    public var localDeviceID: DeviceID { context.identity.deviceID }
    public var participants: [RoomMember] { context.participants(for: descriptor) }

    public init(context: ActivityContext) {
        self.context = context
        self.descriptor = context.descriptor
    }

    // MARK: - Envío

    /// Envía un mensaje al destino indicado, de forma fiable y en orden.
    public func send(_ message: Message, to recipients: ActivityRecipients = .everyone) {
        guard !isEnded else { return }
        let targets = resolve(recipients)
        guard !targets.isEmpty else { return }
        context.outbox.send(message, channel: .activity, activityID: descriptor.id, to: targets)
    }

    /// Envía estado reemplazable (p. ej. snapshot de tablero) con coalescing
    /// latest-wins: un snapshot nuevo reemplaza al pendiente en la cola.
    public func sendState(_ message: Message, coalescingKey: String, to recipients: ActivityRecipients = .everyone) {
        guard !isEnded else { return }
        let targets = resolve(recipients)
        guard !targets.isEmpty else { return }
        context.outbox.sendCoalesced(
            message,
            channel: .activity,
            activityID: descriptor.id,
            coalescingKey: coalescingKey,
            to: targets
        )
    }

    private func resolve(_ recipients: ActivityRecipients) -> [DeviceID] {
        let participantIDs = participants.map(\.deviceID)
        switch recipients {
        case .everyone:
            return participantIDs
        case .member(let deviceID):
            return participantIDs.contains(deviceID) ? [deviceID] : []
        case .members(let ids):
            let allowed = Set(participantIDs)
            return ids.filter { allowed.contains($0) }
        }
    }

    // MARK: - Estado para supervivencia (la app lo sobreescribe)

    /// Estado completo actual del juego. Por defecto `nil`. La subclase lo
    /// devuelve para que Nexo lo reenvíe en reconexión y migración.
    open func currentStateSnapshot() -> Message? { nil }

    public func stateSnapshotPayload() -> Data? {
        guard let snapshot = currentStateSnapshot() else { return nil }
        return try? WireCoder.encode(snapshot)
    }

    // MARK: - Control de estado (host)

    public func setState(_ state: ActivityState) {
        guard !isEnded, isLocalHost, descriptor.state != state else { return }
        descriptor.state = state
        emit(.descriptorUpdated(descriptor))
        onDescriptorChange?()
    }

    // MARK: - Activity (recepción, ciclo de vida)

    public func receive(payload: Data, from member: RoomMember) {
        guard !isEnded, let message = try? WireCoder.decode(Message.self, from: payload) else { return }
        emit(.message(message, member))
    }

    public func participantDidJoin(_ member: RoomMember) {
        guard !isEnded else { return }
        descriptor.participantIDs.insert(member.deviceID)
        emit(.participantJoined(member))
        onDescriptorChange?()
    }

    public func participantDidLeave(_ member: RoomMember) {
        guard !isEnded else { return }
        descriptor.participantIDs.remove(member.deviceID)
        emit(.participantLeft(member))
        onDescriptorChange?()
    }

    public func activityDidEnd(reason: DisconnectReason) {
        guard !isEnded else { return }
        isEnded = true
        emit(.ended(reason))
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
    }

    public func apply(descriptor: ActivityDescriptor) {
        guard !isEnded else { return }
        self.descriptor = descriptor
        emit(.descriptorUpdated(descriptor))
        onDescriptorChange?()
    }

    /// Termina la actividad a través de la sala que la posee, para que la sesión
    /// la descarte y se avise a los participantes. Si nada la posee, termina local.
    public func end(reason: DisconnectReason) {
        guard !isEnded else { return }
        if let endActivity = context.endActivity {
            endActivity(reason)
            guard !isEnded else { return }
        }
        descriptor.state = .cancelled
        activityDidEnd(reason: reason)
        onDescriptorChange?()
    }

    private func emit(_ event: ActivityEvent<Message>) {
        guard !continuations.isEmpty else {
            if pendingEvents.count == Self.pendingEventLimit { pendingEvents.removeFirst() }
            pendingEvents.append(event)
            return
        }
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }
}
