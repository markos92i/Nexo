//
//  RoomEnvelope.swift
//  Project Dark
//
//  Created by Marcos del Castillo Camacho on 11/09/2026.
//

import Foundation

// MARK: - RoomChannel

/// Canal lógico multiplexado sobre la conexión física.
public enum RoomChannel: String, Codable, Sendable {
    /// Membresía, directorio y ciclo de vida de rooms y actividades.
    case control
    /// Mensajería de texto.
    case chat
    /// Payload opaco de una actividad. El envelope lleva `activityID`.
    case activity
    /// Oferta, chunks y control de transferencias de ficheros.
    case fileTransfer
}

// MARK: - DeliveryMode

/// Prioridad y política de descarte del envelope.
public enum DeliveryMode: String, Codable, Sendable {
    /// Se entrega en orden y nunca se descarta.
    case reliable
    /// Se puede descartar si queda obsoleto antes de salir de la cola.
    ///
    /// Network Framework sobre TCP entrega todo de forma fiable, así que el modo
    /// no relaja la garantía del socket: lo que hace es habilitar el
    /// *coalescing* latest-wins en `TransportSendQueue`, de modo que un snapshot
    /// viejo nunca ocupe sitio delante de una orden autoritativa.
    case unreliable
}

// MARK: - RoomEnvelope

/// Unidad de transporte de la capa de aplicación. Todo mensaje de room, chat,
/// actividad o transferencia viaja dentro de un envelope.
public struct RoomEnvelope: Codable, Sendable, Identifiable {
    public let protocolVersion: UInt8
    public let roomID: RoomID
    public let activityID: ActivityID?
    public let channel: RoomChannel
    public let messageID: UUID
    public let senderApplicationID: String
    /// Secuencia por emisor y canal. Permite descartar duplicados y detectar
    /// mensajes fuera de orden en el futuro.
    public let sequence: UInt64?
    public let deliveryMode: DeliveryMode
    /// Clave de coalescing para envelopes `.unreliable`. Dos envelopes con la
    /// misma clave son intercambiables: el nuevo sustituye al viejo en la cola.
    public let coalescingKey: String?
    public let payload: Data

    public var id: UUID { messageID }

    public init(
        roomID: RoomID,
        activityID: ActivityID? = nil,
        channel: RoomChannel,
        senderApplicationID: String,
        payload: Data,
        deliveryMode: DeliveryMode = .reliable,
        coalescingKey: String? = nil,
        sequence: UInt64? = nil,
        messageID: UUID = UUID(),
        protocolVersion: UInt8 = P2PProtocolInfo.currentVersion
    ) {
        self.protocolVersion = protocolVersion
        self.roomID = roomID
        self.activityID = activityID
        self.channel = channel
        self.messageID = messageID
        self.senderApplicationID = senderApplicationID
        self.sequence = sequence
        self.deliveryMode = deliveryMode
        self.coalescingKey = coalescingKey
        self.payload = payload
    }

    /// Construye un envelope codificando el mensaje tipado del canal.
    public init<Message: Encodable & Sendable>(
        roomID: RoomID,
        activityID: ActivityID? = nil,
        channel: RoomChannel,
        senderApplicationID: String,
        message: Message,
        deliveryMode: DeliveryMode = .reliable,
        coalescingKey: String? = nil,
        sequence: UInt64? = nil
    ) throws {
        self.init(
            roomID: roomID,
            activityID: activityID,
            channel: channel,
            senderApplicationID: senderApplicationID,
            payload: try P2PCoder.encode(message),
            deliveryMode: deliveryMode,
            coalescingKey: coalescingKey,
            sequence: sequence
        )
    }

    /// Decodifica el payload como el tipo esperado por el canal.
    public func decodePayload<Message: Decodable>(as type: Message.Type) throws -> Message {
        try P2PCoder.decode(type, from: payload)
    }

    /// Identidad de la lane en la que debe encolarse el envelope. Control y
    /// órdenes de juego no deben quedar detrás de una transferencia grande.
    public var lane: TransportLane {
        switch channel {
        case .control: .control
        case .chat: .interactive
        case .activity: deliveryMode == .unreliable ? .bulkState : .interactive
        case .fileTransfer: .transfer
        }
    }
}

// MARK: - TransportLane

/// Lanes lógicas dentro de una misma conexión física, en orden de prioridad.
public enum TransportLane: Int, Comparable, Sendable, CaseIterable {
    /// Membresía y ciclo de vida. Siempre primero.
    case control = 0
    /// Chat y órdenes autoritativas de juego.
    case interactive = 1
    /// Estado voluminoso y repetitivo, como los snapshots de tablero.
    case bulkState = 2
    /// Chunks de ficheros. Nunca debe bloquear a las demás.
    case transfer = 3

    public static func < (lhs: TransportLane, rhs: TransportLane) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - P2PCoder

/// Codificadores compartidos. Reutilizarlos evita crear un `JSONEncoder` por
/// mensaje, que era el coste dominante al enviar snapshots a 1 Hz por peer.
public enum P2PCoder {
    // Compartir una instancia evita la asignación de un coder por mensaje, que
    // era el coste dominante al difundir snapshots a varios peers.
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}
