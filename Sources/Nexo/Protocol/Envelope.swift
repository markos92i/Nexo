import Foundation

// MARK: - Channel

/// Canal lógico multiplexado sobre la conexión física.
public enum Channel: String, Codable, Sendable {
    case control
    case chat
    /// Payload de actividad opaco. El envelope lleva además `activityID`.
    case activity
    case fileTransfer
}

// MARK: - DeliveryMode

/// Prioridad y política de descarte de un envelope.
public enum DeliveryMode: String, Codable, Sendable {
    /// Entregado en orden, nunca descartado.
    case reliable
    /// Puede descartarse si queda obsoleto antes de salir de la cola.
    ///
    /// Network framework sobre TCP sigue entregando todo de forma fiable, así que
    /// esto no relaja la garantía del socket: habilita el coalescing latest-wins
    /// en la cola de envío, para que un snapshot obsoleto nunca quede delante de
    /// una orden autoritativa.
    case unreliable
}

// MARK: - TransportLane

/// Carriles lógicos dentro de una conexión física, en orden de prioridad.
public enum TransportLane: Int, Comparable, Sendable, CaseIterable {
    /// Membresía y ciclo de vida. Siempre primero.
    case control = 0
    /// Chat y órdenes autoritativas de juego.
    case interactive = 1
    /// Estado voluminoso y repetitivo, como snapshots de tablero.
    case bulkState = 2
    /// Chunks de archivo. Nunca deben bloquear a los demás.
    case transfer = 3

    public static func < (lhs: TransportLane, rhs: TransportLane) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Envelope

/// Unidad de transporte de capa de aplicación. Todo mensaje de sala, chat,
/// actividad o transferencia viaja dentro de uno de estos.
public struct Envelope: Codable, Sendable, Identifiable {
    public let protocolVersion: UInt8
    public let roomID: RoomID
    public let activityID: ActivityID?
    public let channel: Channel
    public let messageID: UUID
    public let senderDeviceID: DeviceID
    /// Secuencia por emisor y canal. Habilita detección de duplicados/desorden.
    public let sequence: UInt64?
    public let deliveryMode: DeliveryMode
    /// Clave de coalescing para envelopes `.unreliable`. Dos envelopes con la
    /// misma clave son intercambiables: el más nuevo reemplaza al más viejo en la cola.
    public let coalescingKey: String?
    public let payload: Data

    public var id: UUID { messageID }

    public init(
        roomID: RoomID,
        activityID: ActivityID? = nil,
        channel: Channel,
        senderDeviceID: DeviceID,
        payload: Data,
        deliveryMode: DeliveryMode = .reliable,
        coalescingKey: String? = nil,
        sequence: UInt64? = nil,
        messageID: UUID = UUID(),
        protocolVersion: UInt8 = ProtocolInfo.currentVersion
    ) {
        self.protocolVersion = protocolVersion
        self.roomID = roomID
        self.activityID = activityID
        self.channel = channel
        self.messageID = messageID
        self.senderDeviceID = senderDeviceID
        self.sequence = sequence
        self.deliveryMode = deliveryMode
        self.coalescingKey = coalescingKey
        self.payload = payload
    }

    /// Construye un envelope codificando el mensaje tipado del canal.
    public init(
        roomID: RoomID,
        activityID: ActivityID? = nil,
        channel: Channel,
        senderDeviceID: DeviceID,
        message: some Encodable & Sendable,
        deliveryMode: DeliveryMode = .reliable,
        coalescingKey: String? = nil,
        sequence: UInt64? = nil
    ) throws {
        self.init(
            roomID: roomID,
            activityID: activityID,
            channel: channel,
            senderDeviceID: senderDeviceID,
            payload: try WireCoder.encode(message),
            deliveryMode: deliveryMode,
            coalescingKey: coalescingKey,
            sequence: sequence
        )
    }

    /// Decodifica el payload como el tipo esperado por el canal.
    public func decodePayload<Message: Decodable>(as type: Message.Type) throws -> Message {
        try WireCoder.decode(type, from: payload)
    }

    /// Carril en el que debe encolarse este envelope. Las órdenes de control y de
    /// juego nunca deben quedar detrás de una transferencia grande.
    public var lane: TransportLane {
        switch channel {
        case .control: .control
        case .chat: .interactive
        case .activity: deliveryMode == .unreliable ? .bulkState : .interactive
        case .fileTransfer: .transfer
        }
    }
}
