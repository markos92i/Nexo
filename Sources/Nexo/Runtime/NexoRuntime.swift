//
//  NexoRuntime.swift
//  Nexo
//
//  Punto de entrada para una app: monta la pila de Nexo, decide cuándo debe
//  estar la red encendida y lo expone como estado observable para SwiftUI.
//

import Foundation
import Observation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

private let runtimeLog = Logger(subsystem: "com.nexo", category: "runtime")

// MARK: - ConnectivityState

/// Lo único que la UI necesita saber de la conectividad.
public enum ConnectivityState: Equatable, Sendable {
    /// Nadie está ejecutando `run()`.
    case stopped
    /// En marcha; la red se está levantando.
    case starting
    /// Anunciando y buscando.
    case online
    /// De vuelta del segundo plano, reconstruyendo conexiones.
    case reconnecting
    /// En segundo plano con la red parada; las salas se conservan.
    case suspended
    /// El multijugador no puede funcionar ahora mismo.
    case unavailable(UnavailableReason)

    public enum UnavailableReason: Equatable, Sendable {
        /// El Keychain no ha dado la identidad permanente del dispositivo.
        case identity
        /// El usuario ha denegado el acceso a la red local.
        case localNetworkDenied
        /// La pila de red falló y dejó de reintentar.
        case networkFailure
    }
}

// MARK: - NexoRuntime

/// Monta y mantiene viva la pila de Nexo para una app.
///
/// Construirlo no tiene efectos: solo lee la identidad del Keychain. La red
/// funciona mientras al menos un llamador esté dentro de `run()` (normalmente un
/// `.task` de la pantalla raíz), y cancelar esa tarea es como termina: las salas
/// se cierran y la sesión se descarta. El resto de la app solo informa de hechos
/// (`isInBackground`, `retry()`); un único bucle los convierte en transiciones,
/// de una en una y en orden.
///
/// La identidad debe ser permanente: si el Keychain no la da, la red no arranca
/// (`.unavailable(.identity)`) y se reintenta con cada hecho nuevo.
///
/// `RoomState` es lo que la app guarda por sala (ver `RoomsModel`).
@MainActor
@Observable
public final class NexoRuntime<RoomState: Sendable> {

    // MARK: Estado observable

    public private(set) var state: ConnectivityState = .stopped
    public private(set) var localNetworkPermission: LocalNetworkPermission = .unknown
    public private(set) var localDisplayName: String

    /// La app lo informa al cambiar de fase. En iOS, con salas abiertas, se pide
    /// tiempo extra al sistema y después se suspende la red; en macOS las apps
    /// ocultas siguen funcionando y no se suspende nada.
    public var isInBackground = false {
        didSet { if isInBackground != oldValue { wake() } }
    }

    /// La pila en marcha, o `nil` sin multijugador.
    private var stack: Stack?

    // MARK: Hechos que reconcilia el bucle

    @ObservationIgnored private var identity: LocalIdentity?
    @ObservationIgnored private var avatar: String?
    @ObservationIgnored private var runners = 0
    @ObservationIgnored private var hasNetworkFailed = false
    @ObservationIgnored private var hasGraceExpired = false
    @ObservationIgnored private var simulatesIdentityFailure: Bool

    @ObservationIgnored private let makeTransport: @MainActor (LocalIdentity, String) -> any Transport
    @ObservationIgnored private let registerActivities: @NexoActor @Sendable (RoomService) -> Void
    @ObservationIgnored private let makeRoomState: @Sendable (RoomSnapshot, RoomState?, DeviceID) -> RoomState
    @ObservationIgnored private let monitorsPermissions: Bool
    @ObservationIgnored private let wakeup: AsyncStream<Void>.Continuation
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var noticeContinuations: [UUID: AsyncStream<RoomNotice>.Continuation] = [:]
    @ObservationIgnored private var pendingNotices: [RoomNotice] = []
    #if canImport(UIKit)
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #else
    @ObservationIgnored private var appNapActivity: (any NSObjectProtocol)?
    #endif

    // MARK: - Estado derivado

    public var localDeviceID: DeviceID? { identity?.deviceID }
    public var rooms: RoomService? { stack?.rooms }
    public var transfers: FileTransferService? { stack?.transfers }
    public var model: RoomsModel<RoomState>? { stack?.model }
    /// Cambia cada vez que una sesión nueva sustituye a la anterior.
    public var sessionID: ObjectIdentifier? { stack.map(ObjectIdentifier.init) }

    /// Por qué las pantallas de multijugador no pueden funcionar ahora. Deja fuera
    /// el permiso de red local denegado, que tiene su propio aviso con camino a
    /// Ajustes.
    public var blockingUnavailableReason: ConnectivityState.UnavailableReason? {
        guard case .unavailable(let reason) = state, reason != .localNetworkDenied else { return nil }
        return reason
    }

    public var advertisements: [PeerAdvertisement] { model?.advertisements ?? [] }
    public var connectedPeers: [ConnectedPeer] { model?.connectedPeers ?? [] }
    public var sessionIDs: [RoomID] { model?.sessionIDs ?? [] }
    public var availableRooms: [DiscoveredRoom] { model?.availableRooms ?? [] }
    public var activeRoomID: RoomID? { model?.activeRoomID }
    public var joinProgress: [RoomID: JoinProgress] { model?.joinProgress ?? [:] }
    public var roomStates: [RoomID: RoomState] { model?.roomStates ?? [:] }

    /// Avisos de salas de la sesión que esté en marcha, a través de cambios de
    /// sesión. Un aviso sin suscriptores espera al primero.
    public var notices: AsyncStream<RoomNotice> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: RoomNotice.self, bufferingPolicy: .bufferingOldest(256))
        noticeContinuations[id] = continuation
        for notice in pendingNotices { continuation.yield(notice) }
        pendingNotices.removeAll()
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.noticeContinuations.removeValue(forKey: id) }
        }
        return stream
    }

    // MARK: - Init

    /// - Parameters:
    ///   - appSecret: secreto compilado en la app del que se deriva la PSK.
    ///   - service: tipo Bonjour de la app; debe estar en `NSBonjourServices`.
    ///   - registerActivities: registra los juegos de la app. Se ejecuta antes
    ///     de arrancar la red, así que no llega ninguna actividad desconocida.
    ///   - makeRoomState: deriva el estado de cada sala (ver `RoomsModel`); recibe
    ///     además el `DeviceID` local.
    public convenience init(
        appSecret: String,
        service: ServiceType,
        displayName: String,
        avatar: String? = nil,
        registerActivities: @escaping @NexoActor @Sendable (RoomService) -> Void,
        makeRoomState: @escaping @Sendable (RoomSnapshot, RoomState?, DeviceID) -> RoomState
    ) {
        self.init(
            displayName: displayName,
            avatar: avatar,
            identity: nil,
            monitorsPermissions: true,
            registerActivities: registerActivities,
            makeRoomState: makeRoomState
        ) { identity, name in
            NetworkTransport(
                crypto: SessionCrypto(appSecret: appSecret),
                deviceID: identity.deviceID,
                displayName: name,
                service: service
            )
        }
    }

    init(
        displayName: String,
        avatar: String?,
        identity: LocalIdentity?,
        monitorsPermissions: Bool,
        registerActivities: @escaping @NexoActor @Sendable (RoomService) -> Void,
        makeRoomState: @escaping @Sendable (RoomSnapshot, RoomState?, DeviceID) -> RoomState,
        makeTransport: @escaping @MainActor (LocalIdentity, String) -> any Transport
    ) {
        self.localDisplayName = displayName
        self.avatar = avatar
        self.monitorsPermissions = monitorsPermissions
        self.registerActivities = registerActivities
        self.makeRoomState = makeRoomState
        self.makeTransport = makeTransport
        #if DEBUG
        // Lanza la app con `-NexoSimulateIdentityFailure` para ver el estado
        // "no disponible": falla la primera lectura y el siguiente intento no.
        self.simulatesIdentityFailure = ProcessInfo.processInfo.arguments.contains("-NexoSimulateIdentityFailure")
        #else
        self.simulatesIdentityFailure = false
        #endif
        let (signals, wakeup) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.wakeup = wakeup
        self.identity = identity ?? loadIdentity()
        loop = Task { [weak self] in
            for await _ in signals {
                await self?.reconcile()
            }
        }
    }

    isolated deinit {
        wakeup.finish()
        loop?.cancel()
        for continuation in noticeContinuations.values { continuation.finish() }
    }

    // MARK: - Vida

    /// Mantiene el multijugador en marcha mientras viva la tarea que llama. Varias
    /// ventanas pueden ejecutarlo a la vez; la red se para al terminar la última.
    public func run() async {
        runners += 1
        wake()
        let (untilCancelled, keepAlive) = AsyncStream.makeStream(of: Never.self)
        for await _ in untilCancelled {}
        keepAlive.finish()
        runners -= 1
        wake()
    }

    /// Vuelve a intentar lo que tenga el multijugador no disponible.
    public func retry() {
        hasNetworkFailed = false
        wake()
    }

    /// Reconstruye un listener caído y vuelve a pedir las salas cercanas.
    public func refreshDiscovery() {
        guard let stack else { return }
        Task { await stack.refreshDiscovery() }
    }

    // MARK: - Perfil y salas

    public func setDisplayName(_ name: String) {
        guard name != localDisplayName else { return }
        localDisplayName = name
        guard let stack else { return }
        Task { await stack.setDisplayName(name) }
    }

    public func setAvatar(_ avatar: String?) {
        self.avatar = avatar
        guard let stack else { return }
        Task { await stack.setAvatar(avatar) }
    }

    public func republishAdvertisement() {
        guard let stack else { return }
        Task { await stack.republishAdvertisement() }
    }

    public func setActiveRoom(_ roomID: RoomID) {
        guard let rooms else { return }
        Task { @NexoActor in rooms.setActiveRoom(roomID) }
    }

    public func leaveRoom(_ roomID: RoomID) {
        guard let rooms else { return }
        Task { @NexoActor in rooms.leave(roomID) }
    }

    // MARK: - Reconciliación

    private func wake() {
        wakeup.yield()
    }

    /// Ajusta la realidad a los hechos. Solo se ejecuta en el bucle, así que dos
    /// transiciones nunca se solapan.
    private func reconcile() async {
        guard runners > 0 else {
            endBackgroundGrace()
            if let stack {
                self.stack = nil
                await stack.close()
            }
            updateAppNapActivity()
            state = .stopped
            return
        }

        if identity == nil { identity = await loadIdentityOffMain() }
        guard let identity else {
            state = .unavailable(.identity)
            return
        }

        let stack = await stackCreatingIfNeeded(identity: identity)
        defer { updateAppNapActivity() }

        if isInBackground {
            #if canImport(UIKit)
            guard stack.isTransportRunning else { return }
            // Con salas abiertas, pide tiempo extra para que un cambio rápido de
            // app no las tire; suspende al agotarse o si no hay nada que conservar.
            if !stack.model.sessionIDs.isEmpty, !hasGraceExpired {
                beginBackgroundGrace()
                return
            }
            await stack.suspend()
            endBackgroundGrace()
            state = .suspended
            return
            #else
            // En macOS una app oculta sigue ejecutándose: no hay nada que suspender.
            #endif
        }

        endBackgroundGrace()
        hasGraceExpired = false
        if localNetworkPermission == .denied {
            state = .unavailable(.localNetworkDenied)
        } else if hasNetworkFailed {
            state = .unavailable(.networkFailure)
        } else if !stack.isTransportRunning {
            state = state == .suspended ? .reconnecting : .starting
            await stack.start()
        } else if case .unavailable = state {
            // La causa desapareció (reintento, permiso concedido): arranca de nuevo.
            state = .starting
            await stack.recover()
        }
    }

    private func stackCreatingIfNeeded(identity: LocalIdentity) async -> Stack {
        if let stack { return stack }
        let deviceID = identity.deviceID
        let makeRoomState = makeRoomState
        let stack = Stack(
            identity: identity,
            transport: makeTransport(identity, localDisplayName),
            monitorsPermissions: monitorsPermissions,
            makeRoomState: { snapshot, previous in makeRoomState(snapshot, previous, deviceID) },
            onTransportEvent: { [weak self] event in self?.apply(event) },
            onPermissionChange: { [weak self] permission in
                self?.setLocalNetworkPermission(permission.asLocalNetworkPermission)
            },
            onNotice: { [weak self] notice in self?.deliver(notice) }
        )
        await stack.prepare(registerActivities: registerActivities)
        self.stack = stack
        return stack
    }

    /// Lectura síncrona del init: así `localDeviceID` existe desde el primer
    /// momento (los juegos en solitario lo usan). Es una sola lectura de Keychain.
    private func loadIdentity() -> LocalIdentity? {
        if consumeSimulatedFailure() { return nil }
        return Self.readIdentity(displayName: localDisplayName, avatar: avatar)
    }

    /// Los reintentos leen el Keychain fuera del hilo principal.
    private func loadIdentityOffMain() async -> LocalIdentity? {
        if consumeSimulatedFailure() { return nil }
        return await Self.readIdentityConcurrently(displayName: localDisplayName, avatar: avatar)
    }

    private func consumeSimulatedFailure() -> Bool {
        guard simulatesIdentityFailure else { return false }
        simulatesIdentityFailure = false
        runtimeLog.error("Device identity unavailable: simulated failure")
        return true
    }

    @concurrent
    private nonisolated static func readIdentityConcurrently(displayName: String, avatar: String?) async -> LocalIdentity? {
        readIdentity(displayName: displayName, avatar: avatar)
    }

    private nonisolated static func readIdentity(displayName: String, avatar: String?) -> LocalIdentity? {
        do {
            return try LocalIdentity.loadOrCreate(displayName: displayName, avatar: avatar)
        } catch {
            runtimeLog.error("Device identity unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Segundo plano

    private func beginBackgroundGrace() {
        #if canImport(UIKit)
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "nexo.transport.grace") { [weak self] in
            // iOS exige terminar la tarea dentro de este handler; el bucle
            // suspende después el transporte.
            MainActor.assumeIsolated {
                self?.hasGraceExpired = true
                self?.endBackgroundGrace()
                self?.wake()
            }
        }
        #endif
    }

    private func endBackgroundGrace() {
        #if canImport(UIKit)
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
        #endif
    }

    /// En macOS, mientras haya salas abiertas, evita que App Nap retrase los
    /// temporizadores y la red de una app oculta.
    private func updateAppNapActivity() {
        #if !canImport(UIKit)
        let needsActivity = stack?.isTransportRunning == true && !(stack?.model.sessionIDs.isEmpty ?? true)
        if needsActivity, appNapActivity == nil {
            appNapActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Nexo rooms are open"
            )
        } else if !needsActivity, let activity = appNapActivity {
            ProcessInfo.processInfo.endActivity(activity)
            appNapActivity = nil
        }
        #endif
    }

    // MARK: - Avisos de la pila

    private func apply(_ event: TransportEvent) {
        switch event {
        case .lifecycleChanged(.active, _):
            hasNetworkFailed = false
            if state == .starting || state == .reconnecting { state = .online }
        case .lifecycleChanged(.disconnected, _):
            hasNetworkFailed = true
            wake()
        case .localNetworkPermissionChanged(let permission, _):
            setLocalNetworkPermission(permission)
        default:
            break
        }
    }

    private func setLocalNetworkPermission(_ permission: LocalNetworkPermission) {
        guard permission != localNetworkPermission else { return }
        let wasDenied = localNetworkPermission == .denied
        localNetworkPermission = permission
        // Conceder el acceso es la señal para reintentar una pila que falló por él.
        if wasDenied, permission == .available { hasNetworkFailed = false }
        wake()
    }

    private func deliver(_ notice: RoomNotice) {
        guard !noticeContinuations.isEmpty else {
            if pendingNotices.count == 256 { pendingNotices.removeFirst() }
            pendingNotices.append(notice)
            return
        }
        for continuation in noticeContinuations.values { continuation.yield(notice) }
    }

    // MARK: - Stack

    /// Una pila de Nexo en marcha. Solo sabe ejecutar las transiciones; cuándo
    /// ejecutarlas lo decide el bucle del runtime.
    @MainActor
    private final class Stack {
        let identity: LocalIdentity
        let rooms: RoomService
        let transfers: FileTransferService
        let permissions: PermissionsChecker
        let model: RoomsModel<RoomState>
        private let transport: any Transport
        private let monitorsPermissions: Bool
        private let onPermissionChange: @MainActor @Sendable (PermissionState) -> Void
        private var noticeTask: Task<Void, Never>?
        private var retentionTask: Task<Void, Never>?
        private(set) var isTransportRunning = false

        init(
            identity: LocalIdentity,
            transport: any Transport,
            monitorsPermissions: Bool,
            makeRoomState: @escaping @Sendable (RoomSnapshot, RoomState?) -> RoomState,
            onTransportEvent: @escaping (TransportEvent) -> Void,
            onPermissionChange: @escaping @MainActor @Sendable (PermissionState) -> Void,
            onNotice: @escaping (RoomNotice) -> Void
        ) {
            let rooms = RoomService(transport: transport, identity: identity)
            let transfers = FileTransferService()
            self.identity = identity
            self.transport = transport
            self.rooms = rooms
            self.transfers = transfers
            self.permissions = PermissionsChecker()
            self.monitorsPermissions = monitorsPermissions
            self.onPermissionChange = onPermissionChange
            self.model = RoomsModel(service: rooms, makeState: makeRoomState)
            model.onTransportEvent = onTransportEvent
            // Los adjuntos que el chat aún enseña no se pueden borrar al podar. Una
            // ráfaga de cambios se agrupa en una sola pasada.
            let (changes, changed) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
            model.onRoomsChanged = { changed.yield() }
            retentionTask = Task { @NexoActor in
                for await _ in changes {
                    await Self.retainVisibleTransfers(rooms: rooms, transfers: transfers)
                }
            }
            let notices = model.notices
            noticeTask = Task {
                for await notice in notices { onNotice(notice) }
            }
        }

        isolated deinit {
            noticeTask?.cancel()
            retentionTask?.cancel()
        }

        /// Registra juegos y servicios. Termina antes del primer `start()`.
        func prepare(registerActivities: @escaping @NexoActor @Sendable (RoomService) -> Void) async {
            let callback = onPermissionChange
            // El servicio de transferencias se guarda aquí con referencia fuerte:
            // `RoomService` solo lo referencia débilmente.
            await Self.prepare(rooms: rooms, transfers: transfers, permissions: permissions, register: registerActivities) { state in
                Task { @MainActor in callback(state) }
            }
        }

        func start() async {
            guard !isTransportRunning else { return }
            isTransportRunning = true
            await Self.start(transport: transport, permissions: monitorsPermissions ? permissions : nil)
            await republishAdvertisement()
        }

        /// Arranca de nuevo el transporte tras rendirse. Mismos parámetros, así
        /// que las conexiones que sobrevivieron se conservan.
        func recover() async {
            isTransportRunning = true
            await Self.start(transport: transport, permissions: monitorsPermissions ? permissions : nil)
            await Self.refresh(transport: transport, rooms: rooms)
            await republishAdvertisement()
        }

        /// Para la red pero conserva las salas, para recuperarlas al volver.
        func suspend() async {
            guard isTransportRunning else { return }
            isTransportRunning = false
            model.clearPeers()
            await Self.suspend(transport: transport, rooms: rooms, permissions: permissions)
        }

        /// Termina la sesión: cierra las salas y avisa a los peers.
        func close() async {
            isTransportRunning = false
            noticeTask?.cancel()
            retentionTask?.cancel()
            model.clearPeers()
            await Self.close(transport: transport, rooms: rooms, permissions: permissions)
        }

        func refreshDiscovery() async {
            guard isTransportRunning else { return }
            await Self.refresh(transport: transport, rooms: rooms)
            await republishAdvertisement()
        }

        func republishAdvertisement() async {
            await Self.publish(identity: identity, transport: transport, rooms: rooms)
        }

        func setDisplayName(_ name: String) async {
            await Self.update(identity) { $0.displayName = name }
            await republishAdvertisement()
        }

        func setAvatar(_ avatar: String?) async {
            await Self.update(identity) { $0.avatar = avatar }
        }

        // MARK: Trabajo en NexoActor

        @NexoActor
        private static func prepare(
            rooms: RoomService,
            transfers: FileTransferService,
            permissions: PermissionsChecker,
            register: @NexoActor @Sendable (RoomService) -> Void,
            onPermissionChange: @escaping @NexoActor @Sendable (PermissionState) -> Void
        ) {
            rooms.bindTransfers(transfers)
            register(rooms)
            permissions.onPermissionChange = { _, state in onPermissionChange(state) }
        }

        @NexoActor
        private static func start(transport: any Transport, permissions: PermissionsChecker?) {
            transport.start(advertising: true, browsing: true)
            permissions?.startMonitoring()
        }

        @NexoActor
        private static func suspend(transport: any Transport, rooms: RoomService, permissions: PermissionsChecker) {
            transport.stop()
            rooms.suspend()
            permissions.stopMonitoring()
        }

        @NexoActor
        private static func close(transport: any Transport, rooms: RoomService, permissions: PermissionsChecker) {
            rooms.closeAll(reason: .sessionEnded)
            transport.stop()
            permissions.stopMonitoring()
        }

        @NexoActor
        private static func refresh(transport: any Transport, rooms: RoomService) {
            transport.refreshDiscovery()
            rooms.refreshRoomDirectories()
        }

        @NexoActor
        private static func publish(identity: LocalIdentity, transport: any Transport, rooms: RoomService) {
            transport.updateAdvertisement(AdvertisementRecord(
                deviceID: identity.deviceID,
                displayName: identity.displayName,
                rooms: rooms.advertisedRoomDescriptors,
                totalRoomCount: rooms.hostedRooms.count
            ))
        }

        @NexoActor
        private static func update(_ identity: LocalIdentity, _ change: @NexoActor @Sendable (LocalIdentity) -> Void) {
            change(identity)
        }

        @NexoActor
        private static func retainVisibleTransfers(rooms: RoomService, transfers: FileTransferService) async {
            let visible = Set(rooms.sessions.values.flatMap {
                $0.chat?.messages.compactMap(\.attachment?.transferID) ?? []
            })
            await transfers.retainTransfers(visible)
        }
    }
}

#if DEBUG
// MARK: - Previews

extension NexoRuntime {
    /// Runtime para previews: identidad temporal y un transporte que nunca toca
    /// la red, así que el canvas no busca dispositivos ni pide permisos. Las salas
    /// funcionan en local si la preview ejecuta `run()`.
    public static func preview(
        displayName: String = "Preview",
        registerActivities: @escaping @NexoActor @Sendable (RoomService) -> Void = { _ in },
        makeRoomState: @escaping @Sendable (RoomSnapshot, RoomState?, DeviceID) -> RoomState
    ) -> NexoRuntime {
        NexoRuntime(
            displayName: displayName,
            avatar: nil,
            identity: .temporary(displayName: displayName),
            monitorsPermissions: false,
            registerActivities: registerActivities,
            makeRoomState: makeRoomState
        ) { _, _ in PreviewTransport() }
    }
}

/// Transporte que no descubre nada, no conecta con nadie y descarta cada envío.
final class PreviewTransport: Transport {
    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation

    var epoch: UInt64 { 0 }
    var connectedPeers: [ConnectedPeer] { [] }

    init() {
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    deinit { continuation.finish() }

    func start(advertising: Bool, browsing: Bool) {}
    func stop() {}
    func updateAdvertisement(_ record: AdvertisementRecord) {}
    func refreshDiscovery() {}
    func disconnect(deviceID: DeviceID, reason: DisconnectReason?) {}
    func enqueue(_ envelope: Envelope, to deviceID: DeviceID) {}

    func connect(to advertisement: PeerAdvertisement) async throws(TransportError) -> ConnectedPeer {
        throw .peerNotDiscovered
    }
}
#endif
