import Foundation

// MARK: - Frame

/// La unidad que realmente viaja por el socket.
///
/// Un struct plano con un `kind` y cuerpos opcionales en vez de un enum con
/// valores asociados, para que el JSON tenga una sola capa y los cuerpos de
/// control nunca queden anidados ni en base64.
public struct Frame: Codable, Sendable {

    public enum Kind: String, Codable, Sendable {
        /// Intercambio de identidad y capacidades.
        case hello
        /// Un envelope de aplicación, ya enrutable por sala.
        case envelope
        /// Cierre ordenado, para que el peer no tenga que esperar un timeout.
        case goodbye
    }

    public let kind: Kind
    public var hello: HelloBody?
    public var envelope: Envelope?
    public var goodbye: GoodbyeBody?

    // MARK: Factorías

    public static func hello(_ body: HelloBody) -> Frame {
        Frame(kind: .hello, hello: body)
    }

    public static func envelope(_ envelope: Envelope) -> Frame {
        Frame(kind: .envelope, envelope: envelope)
    }

    public static func goodbye(reason: DisconnectReason) -> Frame {
        Frame(kind: .goodbye, goodbye: GoodbyeBody(reason: reason))
    }
}

// MARK: - HelloBody

/// Identidad declarada por el peer.
///
/// No hay autenticación a este nivel: `deviceID` lo auto-declara el remoto. El
/// cifrado PSK ya garantiza que solo peers con el mismo secreto de app+sala
/// completan el handshake; el `deviceID` solo identifica y deduplica peers.
public struct HelloBody: Codable, Sendable {
    public let protocolVersion: UInt8
    public let minimumProtocolVersion: UInt8
    public let deviceID: DeviceID
    public let displayName: String
    /// Derivado público de la PSK local; debe coincidir con el del peer.
    public let pskHint: String?
    public let capabilities: [Capability]
    /// Para qué abre el emisor esta conexión. `nil` equivale a `.control`, así
    /// que un peer que no envía el campo sigue siendo compatible.
    public let purpose: ConnectionPurpose?

    public init(
        deviceID: DeviceID,
        displayName: String,
        pskHint: String? = nil,
        purpose: ConnectionPurpose = .control,
        protocolVersion: UInt8 = ProtocolInfo.currentVersion,
        minimumProtocolVersion: UInt8 = ProtocolInfo.minimumVersion,
        capabilities: Set<Capability> = ProtocolInfo.capabilities
    ) {
        self.protocolVersion = protocolVersion
        self.minimumProtocolVersion = minimumProtocolVersion
        self.deviceID = deviceID
        self.displayName = displayName
        self.pskHint = pskHint
        self.purpose = purpose
        self.capabilities = Array(capabilities)
    }
}

// MARK: - ConnectionPurpose

/// Uso de una conexión física. Un peer tiene una conexión de control (envelopes)
/// y, si abre streams binarios, una segunda conexión dedicada a ellos para que
/// el volumen binario nunca retrase el control ni el chat.
public enum ConnectionPurpose: String, Codable, Sendable {
    case control
    case byteStreams
}

// MARK: - GoodbyeBody

public struct GoodbyeBody: Codable, Sendable, Equatable {
    public let reason: DisconnectReason

    public init(reason: DisconnectReason) {
        self.reason = reason
    }
}
