//
//  P2PFrame.swift
//  Project Dark
//
//  Created by Marcos del Castillo Camacho on 11/09/2026.
//

import Foundation

// MARK: - P2PFrame

/// Unidad que viaja realmente por el socket.
///
/// Es una estructura plana con un `kind` y cuerpos opcionales en vez de un enum
/// con valores asociados: así el JSON tiene una sola capa y los cuerpos de
/// control no acaban anidados ni en base64.
public struct P2PFrame: Codable, Sendable {

    public enum Kind: String, Codable, Sendable {
        /// Presentación e intercambio de identidad y capacidades.
        case hello
        /// Envelope de aplicación ya enrutable por room.
        case envelope
        /// Cierre ordenado. Evita que el peer tenga que esperar un timeout.
        case goodbye
    }

    public let kind: Kind
    public var hello: HelloBody?
    public var envelope: RoomEnvelope?
    public var goodbye: GoodbyeBody?

    // MARK: Factories

    public static func hello(_ body: HelloBody) -> P2PFrame {
        P2PFrame(kind: .hello, hello: body)
    }

    public static func envelope(_ envelope: RoomEnvelope) -> P2PFrame {
        P2PFrame(kind: .envelope, envelope: envelope)
    }

    public static func goodbye(reason: String) -> P2PFrame {
        P2PFrame(kind: .goodbye, goodbye: GoodbyeBody(reason: reason))
    }
}

// MARK: - HelloBody

/// Identidad declarada por el peer.
///
/// No hay autenticación: `applicationID` es un identificador que el remoto envía
/// sobre sí mismo y nadie verifica. Basta para identificar y deduplicar peers en
/// una red local de confianza, pero no impide que un peer se haga pasar por otro.
public struct HelloBody: Codable, Sendable {
    public let protocolVersion: UInt8
    public let minimumProtocolVersion: UInt8
    public let applicationID: String
    public let displayName: String
    public let capabilities: [P2PCapability]

    public init(
        applicationID: String,
        displayName: String,
        protocolVersion: UInt8 = P2PProtocolInfo.currentVersion,
        minimumProtocolVersion: UInt8 = P2PProtocolInfo.minimumVersion,
        capabilities: Set<P2PCapability> = P2PProtocolInfo.capabilities
    ) {
        self.protocolVersion = protocolVersion
        self.minimumProtocolVersion = minimumProtocolVersion
        self.applicationID = applicationID
        self.displayName = displayName
        self.capabilities = Array(capabilities)
    }
}

// MARK: - GoodbyeBody

public struct GoodbyeBody: Codable, Sendable {
    public let reason: String
}
