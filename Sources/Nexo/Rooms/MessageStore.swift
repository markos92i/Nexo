import Foundation

// MARK: - MessageStore

/// Almacén del historial de chat de las salas.
///
/// Abstracción estrecha para que la persistencia sea una decisión inyectable. La
/// implementación por defecto (`InMemoryMessageStore`) es **efímera**: el
/// historial vive en memoria y se pierde al cerrar la app. Una implementación en
/// disco futura solo tiene que cumplir este protocolo, sin tocar `RoomChat`.
///
/// La deduplicación y el recorte de ventana son política de dominio y viven en
/// `RoomChat`, no aquí: el store solo guarda y entrega.
@NexoActor
public protocol MessageStore: AnyObject {
    func messages(for roomID: RoomID) -> [ChatMessage]
    func append(_ message: ChatMessage, to roomID: RoomID)
    func replaceAll(_ messages: [ChatMessage], for roomID: RoomID)
    func clear(_ roomID: RoomID)
}

// MARK: - InMemoryMessageStore

/// Almacén efímero en memoria. Implementación por defecto.
@NexoActor
public final class InMemoryMessageStore: MessageStore {
    private var byRoom: [RoomID: [ChatMessage]] = [:]

    public init() {}

    public func messages(for roomID: RoomID) -> [ChatMessage] {
        byRoom[roomID] ?? []
    }

    public func append(_ message: ChatMessage, to roomID: RoomID) {
        byRoom[roomID, default: []].append(message)
    }

    public func replaceAll(_ messages: [ChatMessage], for roomID: RoomID) {
        byRoom[roomID] = messages
    }

    public func clear(_ roomID: RoomID) {
        byRoom.removeValue(forKey: roomID)
    }
}
