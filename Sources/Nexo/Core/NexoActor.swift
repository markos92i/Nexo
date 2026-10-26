import Foundation

/// Ejecutor serial de toda la lógica de Nexo.
///
/// Mantiene el estado de salas, chat, actividades, transferencias e identidad
/// fuera del hilo principal. La app vuelve al hilo principal cuando necesita
/// publicar snapshots para la UI.
@globalActor
public actor NexoActor {
    public static let shared = NexoActor()
    private init() {}
}
