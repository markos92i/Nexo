//
//  RoomActivity.swift
//  Project Dark
//
//  Created by Marcos del Castillo Camacho on 11/09/2026.
//

import Foundation

// MARK: - RoomActivity

/// Una actividad es algo que ocurre *dentro* de una room, no una room aparte.
///
/// El transporte y el `RoomCoordinator` tratan su payload como opaco: cada
/// actividad define y decodifica sus propios mensajes. Añadir un juego nuevo no
/// toca ninguna capa inferior.
@MainActor
public protocol RoomActivity: AnyObject {

    var descriptor: ActivityDescriptor { get }

    /// Payload del canal `.activity` dirigido a esta actividad.
    func receive(payload: Data, from member: RoomMember)

    /// Un participante entra o sale de la actividad, sin abandonar la room.
    func participantDidJoin(_ member: RoomMember)
    func participantDidLeave(_ member: RoomMember)

    /// La actividad termina. Solo se destruye la actividad: la room y su chat
    /// siguen vivos.
    func activityDidEnd(reason: String)

    /// Refleja un descriptor actualizado recibido del host.
    func apply(descriptor: ActivityDescriptor)
}

public extension RoomActivity {
    var id: ActivityID { descriptor.id }
    var kind: ActivityKind { descriptor.kind }
    var roomID: RoomID { descriptor.roomID }

    func isHost(_ applicationID: String) -> Bool {
        descriptor.hostApplicationID == applicationID
    }
}

// MARK: - ActivityContext

/// Todo lo que una actividad necesita para funcionar, ya acotado a su room.
public struct ActivityContext {
    public let descriptor: ActivityDescriptor
    public let identity: LocalP2PIdentity
    /// Emisor de la room. La actividad envía siempre con su propio `activityID`.
    public let outbox: RoomOutbox
    /// Miembros vivos de la room, resuelto en cada consulta.
    public let members: @MainActor () -> [RoomMember]

    /// `true` si el usuario local manda en esta actividad.
    public var isLocalHost: Bool {
        descriptor.hostApplicationID == identity.applicationID
    }

    /// Participantes de la actividad excluyendo al usuario local. El descriptor
    /// se recibe de la actividad porque puede cambiar cuando se incorporan
    /// miembros nuevos a una actividad abierta.
    @MainActor
    public func participants(for descriptor: ActivityDescriptor) -> [RoomMember] {
        members().filter {
            descriptor.includes($0.applicationID) && $0.applicationID != identity.applicationID
        }
    }
}

// MARK: - RoomActivityRegistry

/// Fábrica de actividades por tipo.
///
/// Es el punto de extensión para juegos futuros: se registra una factoría al
/// arrancar y el `RoomCoordinator` puede instanciar la actividad correcta al
/// recibir un `activityStarted`, sin conocer ningún juego concreto.
@MainActor
public final class RoomActivityRegistry {

    public typealias Factory = @MainActor (ActivityContext) -> any RoomActivity

    public static let shared = RoomActivityRegistry()

    private var factories: [ActivityKind: Factory] = [:]

    private init() {}

    // MARK: - Public API

    public func register(_ kind: ActivityKind, factory: @escaping Factory) {
        factories[kind] = factory
    }

    public func isRegistered(_ kind: ActivityKind) -> Bool {
        factories[kind] != nil
    }

    /// Instancia la actividad descrita, o `nil` si esta build no la conoce (por
    /// ejemplo, un peer más moderno propone un juego que aquí no existe).
    public func makeActivity(for context: ActivityContext) -> (any RoomActivity)? {
        factories[context.descriptor.kind]?(context)
    }
}
