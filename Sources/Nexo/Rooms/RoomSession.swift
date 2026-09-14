//
//  RoomSession.swift
//  Project Dark
//
//  Created by Marcos del Castillo Camacho on 11/09/2026.
//

import Foundation

// MARK: - RoomSession

/// Room viva: miembros, chat y actividades.
///
/// Sobrevive a la navegación entre la lista de salas, el chat, el lobby de una
/// partida, la partida y el resultado. Salir de una actividad destruye la
/// actividad, no la sesión.
@MainActor
@Observable
public final class RoomSession: Identifiable {

    // MARK: - Identidad

    public let roomID: RoomID
    public private(set) var descriptor: RoomDescriptor

    /// `nonisolated` porque `roomID` es inmutable: leer la identidad de la sesión
    /// desde fuera del actor principal no puede provocar una carrera.
    public nonisolated var id: RoomID { roomID }

    // MARK: - Estado

    public private(set) var members: [RoomMember] = []
    public private(set) var accessState: RoomAccessState
    /// Solicitudes pendientes de aprobación. Es una cola por room: el host puede
    /// gobernar varias rooms con colas independientes.
    public private(set) var pendingJoinRequests: [RoomJoinRequest] = []
    /// Actividades vivas, indexadas por identificador.
    public private(set) var activities: [ActivityID: any RoomActivity] = [:]

    public let chat: ChatRoomSession?

    private let identity: LocalP2PIdentity
    private let outbox: RoomOutbox

    // MARK: - Derivados

    public var isLocalHost: Bool { descriptor.hostApplicationID == identity.applicationID }
    public var localRole: RoomRole { isLocalHost ? .host : .guest }
    public var features: RoomFeatures { descriptor.features }
    public var name: String { descriptor.name }

    public var host: RoomMember? {
        members.first { $0.applicationID == descriptor.hostApplicationID }
    }

    /// Miembros distintos del usuario local.
    public var remoteMembers: [RoomMember] {
        members.filter { $0.applicationID != identity.applicationID }
    }

    /// Actividad principal para una UI que solo muestra una partida a la vez.
    /// Ignora las no exclusivas (p. ej. un chat), que pueden convivir con ella.
    public var primaryActivity: (any RoomActivity)? {
        activities.values.first { $0.descriptor.isActive && $0.descriptor.isExclusive }
            ?? activities.values.first { $0.descriptor.isExclusive }
    }

    public var canStartActivity: Bool {
        features.hasActivities
            && activities.values.allSatisfy { !$0.descriptor.isActive || !$0.descriptor.isExclusive }
    }

    // MARK: - Init

    public init(
        descriptor: RoomDescriptor,
        identity: LocalP2PIdentity,
        outbox: RoomOutbox,
        accessState: RoomAccessState,
        members: [RoomMember] = []
    ) {
        self.roomID = descriptor.id
        self.descriptor = descriptor
        self.identity = identity
        self.outbox = outbox
        self.accessState = accessState
        self.members = members
        // El índice se rellena aquí también para que `contains` sea fiable antes
        // de la primera actualización de membresía.
        self.memberCache = Self.index(members)
        self.chat = descriptor.features.hasChat
            ? ChatRoomSession(roomID: descriptor.id, outbox: outbox, identity: identity)
            : nil
    }

    // MARK: - Membresía

    public func apply(descriptor: RoomDescriptor) {
        self.descriptor = descriptor
    }

    public func apply(members: [RoomMember]) {
        // La lista llega de un peer remoto y no está autenticada: puede traer
        // identidades repetidas. Se deduplica antes de indexarla, porque un
        // `Dictionary(uniqueKeysWithValues:)` con claves repetidas aborta.
        let sanitized = Self.deduplicate(members)

        let previous = Set(self.members.map(\.applicationID))
        let updated = Set(sanitized.map(\.applicationID))

        self.members = sanitized
        self.descriptor.memberCount = sanitized.count

        for member in sanitized
        where !previous.contains(member.applicationID)
            && member.applicationID != identity.applicationID {
            chat?.memberDidJoin(member)
        }

        for applicationID in previous.subtracting(updated)
        where applicationID != identity.applicationID {
            guard let member = memberSnapshot(applicationID) else { continue }
            chat?.memberDidLeave(member)
            notifyActivitiesOfDeparture(member)
        }

        memberCache = Self.index(sanitized)
    }

    public func setAccessState(_ state: RoomAccessState) {
        accessState = state
    }

    public func member(_ applicationID: String) -> RoomMember? {
        memberCache[applicationID]
    }

    public func contains(_ applicationID: String) -> Bool {
        memberCache[applicationID] != nil
    }

    // MARK: - Solicitudes de entrada

    public func enqueueJoinRequest(_ request: RoomJoinRequest) -> Bool {
        guard !pendingJoinRequests.contains(where: { $0.applicationID == request.applicationID }) else {
            return false
        }
        pendingJoinRequests.append(request)
        return true
    }

    public func removeJoinRequest(_ id: UUID) -> RoomJoinRequest? {
        guard let index = pendingJoinRequests.firstIndex(where: { $0.id == id }) else { return nil }
        return pendingJoinRequests.remove(at: index)
    }

    public func removeJoinRequests(for applicationID: String) {
        pendingJoinRequests.removeAll { $0.applicationID == applicationID }
    }

    // MARK: - Actividades

    public func register(_ activity: any RoomActivity) {
        activities[activity.descriptor.id] = activity
    }

    public func activity(_ id: ActivityID) -> (any RoomActivity)? {
        activities[id]
    }

    public func activity(ofKind kind: ActivityKind) -> (any RoomActivity)? {
        activities.values.first { $0.descriptor.kind == kind && $0.descriptor.isActive }
    }

    public func removeActivity(_ id: ActivityID, reason: String) {
        guard let activity = activities.removeValue(forKey: id) else { return }
        activity.activityDidEnd(reason: reason)
    }

    public func removeAllActivities(reason: String) {
        let current = activities
        activities.removeAll()
        for activity in current.values {
            activity.activityDidEnd(reason: reason)
        }
    }

    /// Elimina únicamente las actividades que ya no aparecen en el snapshot
    /// autoritativo del host, conservando las demás instancias y su estado.
    public func removeActivities(notIncludedIn activeIDs: Set<ActivityID>, reason: String) {
        let staleIDs = activities.keys.filter { !activeIDs.contains($0) }
        for activityID in staleIDs {
            removeActivity(activityID, reason: reason)
        }
    }

    /// Contexto para instanciar una actividad con el ámbito de esta room.
    public func makeActivityContext(for descriptor: ActivityDescriptor) -> ActivityContext {
        ActivityContext(
            descriptor: descriptor,
            identity: identity,
            outbox: outbox,
            members: { [weak self] in self?.members ?? [] }
        )
    }

    // MARK: - Private Helpers

    private var memberCache: [String: RoomMember] = [:]

    private func memberSnapshot(_ applicationID: String) -> RoomMember? {
        memberCache[applicationID]
    }

    private func notifyActivitiesOfDeparture(_ member: RoomMember) {
        for activity in activities.values where activity.descriptor.includes(member.applicationID) {
            activity.participantDidLeave(member)
        }
    }

    /// Conserva la primera aparición de cada identidad.
    private static func deduplicate(_ members: [RoomMember]) -> [RoomMember] {
        var seen: Set<String> = []
        return members.filter { seen.insert($0.applicationID).inserted }
    }

    private static func index(_ members: [RoomMember]) -> [String: RoomMember] {
        var index: [String: RoomMember] = [:]
        for member in members where index[member.applicationID] == nil {
            index[member.applicationID] = member
        }
        return index
    }
}
