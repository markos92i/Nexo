import Foundation

// MARK: - Activity

/// Una actividad es algo que ocurre *dentro* de una sala, no una sala en sí.
///
/// El transporte y la capa de salas tratan su payload como opaco: cada actividad
/// define y decodifica sus propios mensajes. Añadir un juego nuevo nunca toca una
/// capa inferior.
@NexoActor
public protocol Activity: AnyObject {

    var descriptor: ActivityDescriptor { get }

    /// Payload del canal `.activity` dirigido a esta actividad.
    func receive(payload: Data, from member: RoomMember)

    /// Un participante entra o sale de la actividad sin salir de la sala.
    func participantDidJoin(_ member: RoomMember)
    func participantDidLeave(_ member: RoomMember)

    /// La actividad termina. Solo se destruye la actividad; la sala y sus otras
    /// actividades siguen vivas.
    func activityDidEnd(reason: DisconnectReason)

    /// Aplica un descriptor actualizado recibido del host.
    func apply(descriptor: ActivityDescriptor)

    /// Estado completo actual de la actividad, serializado, o `nil` si no aplica.
    /// Nexo lo reenvía a quien se reconecta y al asumir la autoridad tras una
    /// migración, para que el estado del juego sobreviva.
    func stateSnapshotPayload() -> Data?

    /// Se llama cuando cambia el descriptor, para que la sala republique su snapshot.
    var onDescriptorChange: (@NexoActor () -> Void)? { get set }
}

public extension Activity {
    var id: ActivityID { descriptor.id }
    var kind: ActivityKind { descriptor.kind }
    var roomID: RoomID { descriptor.roomID }

    func isHost(_ deviceID: DeviceID) -> Bool {
        descriptor.hostDeviceID == deviceID
    }

    /// Por defecto una actividad no aporta snapshot (sobrevive solo si emite
    /// estado a mano). `GenericActivity` lo deriva de `currentStateSnapshot()`.
    func stateSnapshotPayload() -> Data? { nil }
}

// MARK: - ActivityRecipients

/// Destino de un mensaje de actividad. Lo decide la app en cada envío, como
/// optimización y privacidad (información oculta entre un subconjunto).
public enum ActivityRecipients: Sendable {
    /// Difusión a todos los participantes (excepto el local).
    case everyone
    /// Uno a uno.
    case member(DeviceID)
    /// Un subconjunto concreto.
    case members([DeviceID])
}

// MARK: - ActivityContext

/// Todo lo que una actividad necesita para funcionar, ya acotado a su sala.
public struct ActivityContext {
    public let descriptor: ActivityDescriptor
    public let identity: LocalIdentity
    /// El emisor de la sala. La actividad siempre envía con su propio `activityID`.
    public let outbox: RoomOutbox
    /// Miembros vivos de la sala, resueltos en cada consulta.
    public let members: @NexoActor () -> [RoomMember]
    /// Termina esta actividad a través de la sala que la posee. `nil` si ninguna
    /// sala la posee.
    public let endActivity: (@NexoActor (DisconnectReason) -> Void)?

    /// `true` si el usuario local es la autoridad de esta actividad.
    public var isLocalHost: Bool {
        descriptor.hostDeviceID == identity.deviceID
    }

    /// Participantes de la actividad excluyendo al usuario local. Se pasa el
    /// `descriptor` porque puede cambiar al entrar nuevos miembros a una abierta.
    @NexoActor
    public func participants(for descriptor: ActivityDescriptor) -> [RoomMember] {
        members().filter {
            descriptor.includes($0.deviceID) && $0.deviceID != identity.deviceID
        }
    }
}

// MARK: - ActivityRegistry

/// Fábrica de actividades por tipo.
///
/// Punto de extensión para juegos futuros: registra una fábrica al arranque y la
/// capa de salas puede instanciar la actividad correcta al recibir un anuncio sin
/// conocer ningún juego concreto. Se inyecta en el servicio, no es un singleton.
@NexoActor
public final class ActivityRegistry {

    public typealias Factory = @NexoActor (ActivityContext) -> any Activity

    private var factories: [ActivityKind: Factory] = [:]

    public init() {}

    public func register(_ kind: ActivityKind, factory: @escaping Factory) {
        factories[kind] = factory
    }

    public func isRegistered(_ kind: ActivityKind) -> Bool {
        factories[kind] != nil
    }

    /// Instancia la actividad descrita, o `nil` si esta build no la conoce (p. ej.
    /// un peer más nuevo propone un juego que esta build no tiene).
    public func makeActivity(for context: ActivityContext) -> (any Activity)? {
        factories[context.descriptor.kind]?(context)
    }
}
