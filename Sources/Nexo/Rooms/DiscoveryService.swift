import Foundation

// MARK: - DiscoveryService

/// Descubrimiento de salas: directorio, anuncios Bonjour y filtrado por actividad.
///
/// Colaborador de bajo acoplamiento del servicio de salas: trabaja sobre su propio
/// estado (el `RoomDirectory`) y apenas toca la membresía o las sesiones vivas.
@NexoActor
final class DiscoveryService {

    private var directory = RoomDirectory()

    // MARK: - Lectura

    var rooms: [RoomID: DiscoveredRoom] { directory.rooms }

    func advertisement(for deviceID: DeviceID) -> PeerAdvertisement? {
        directory.advertisement(for: deviceID)
    }

    func advertisement(forEndpoint endpointID: TransportPeerID) -> PeerAdvertisement? {
        directory.advertisements[endpointID]
    }

    // MARK: - Actualización desde el transporte

    func update(_ advertisement: PeerAdvertisement) {
        directory.update(advertisement)
    }

    func remove(_ endpointID: TransportPeerID) {
        directory.remove(endpointID)
    }

    /// Fusiona el catálogo autoritativo de un peer. Devuelve los IDs que el peer
    /// anuncia, o `nil` si el payload es inválido.
    func update(
        _ payload: RoomDirectoryPayload,
        from peer: ConnectedPeer,
        joinedIDs: Set<RoomID>
    ) -> Set<RoomID>? {
        directory.update(payload, from: peer, joinedIDs: joinedIDs)
    }

    func removeRoom(_ roomID: RoomID) {
        directory.removeRoom(roomID)
    }

    func suspend(keeping roomIDs: Set<RoomID>) {
        directory.suspend(keeping: roomIDs)
    }

    func clear() {
        directory.clear()
    }

    // MARK: - Consultas de presentación

    /// Salas disponibles para unirse, en orden estable. `activeSessions` filtra
    /// las que el usuario ya tiene unidas o esperando aprobación.
    func availableRooms(
        isJoinedOrAwaiting: (RoomID) -> Bool
    ) -> [DiscoveredRoom] {
        directory.rooms.values
            .filter { !isJoinedOrAwaiting($0.id) }
            .sorted { lhs, rhs in
                if lhs.name == rhs.name { return lhs.id.description < rhs.id.description }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// Salas que ofrecen la actividad dada. Lo que usa el lobby de un juego para
    /// listar partidas sin pasar por el chat.
    func availableRooms(
        for kind: ActivityKind,
        isJoinedOrAwaiting: (RoomID) -> Bool
    ) -> [DiscoveredRoom] {
        availableRooms(isJoinedOrAwaiting: isJoinedOrAwaiting)
            .filter { $0.activityKind == kind && $0.features.hasActivities }
    }
}
