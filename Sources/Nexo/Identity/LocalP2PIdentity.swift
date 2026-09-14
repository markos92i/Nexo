//
//  LocalP2PIdentity.swift
//  Nexo
//

import Foundation

// MARK: - LocalP2PIdentity

/// Identidad local observable. El nombre visible es editable por el usuario y se
/// propaga al registro TXT de Bonjour y a los mensajes salientes.
///
/// `applicationID` es responsabilidad de quien use el paquete: no es una
/// credencial, se envía tal cual en el `hello` y nadie la verifica, así que
/// sirve para identificar y deduplicar, no para autorizar frente a un peer
/// malicioso.
@MainActor
@Observable
public final class LocalP2PIdentity {

    public let applicationID: String
    public var displayName: String

    public init(applicationID: String, displayName: String) {
        self.applicationID = applicationID
        self.displayName = displayName
    }

    public func member(role: RoomRole) -> RoomMember {
        RoomMember(applicationID: applicationID, displayName: displayName, role: role)
    }
}

