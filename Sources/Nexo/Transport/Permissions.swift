import Foundation
import Network
import OSLog

// MARK: - PermissionState

/// Estado de un permiso requerido para la comunicación P2P.
public enum PermissionState: String, Sendable, Equatable, CaseIterable {
    case unknown
    case granted
    case denied
    /// Restringido por política del dispositivo (MDM, controles parentales).
    case restricted
    /// El dispositivo no soporta esta capacidad.
    case unsupported
}

// MARK: - PermissionKind

/// Tipos de permiso que Nexo puede requerir.
public enum PermissionKind: String, Sendable, CaseIterable {
    /// Permiso de red local (Bonjour, mDNS). Necesario para descubrir peers.
    case localNetwork
}

// MARK: - PermissionsStatus

/// Estado agregado de los permisos necesarios para P2P.
@NexoActor
public final class PermissionsStatus {
    public private(set) var localNetwork: PermissionState = .unknown
    public private(set) var lastChecked: Date?

    public var isFullyGranted: Bool { localNetwork == .granted }
    public var hasCriticalDenial: Bool {
        localNetwork == .denied || localNetwork == .restricted
    }

    fileprivate func update(localNetwork: PermissionState) {
        self.localNetwork = localNetwork
        self.lastChecked = Date()
    }
}

// MARK: - PermissionsChecker

/// Comprueba los permisos necesarios para la comunicación P2P.
///
/// iOS solicita el permiso de "Red local" automáticamente cuando la app usa
/// Bonjour o conecta con dispositivos de la red local. Este checker verifica de
/// forma proactiva, detecta la denegación del usuario y ofrece una guía para
/// reactivar el permiso en Ajustes.
@NexoActor
public final class PermissionsChecker {

    private static let logger = Logger(subsystem: "com.nexo", category: "permissions")

    public let status = PermissionsStatus()

    /// Callback que se dispara al cambiar el estado del permiso.
    public var onPermissionChange: (@NexoActor @Sendable (PermissionKind, PermissionState) -> Void)?

    private var checkTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    public init() {}

    deinit {
        checkTask?.cancel()
        monitorTask?.cancel()
    }

    /// Comprueba el estado actual de los permisos requeridos.
    public func checkPermissions() async {
        checkTask?.cancel()
        checkTask = Task { @NexoActor in
            await checkLocalNetworkPermission()
        }
        await checkTask?.value
    }

    /// Comprueba solo el permiso de red local.
    public func checkLocalNetworkPermission() async {
        let state = await LocalNetworkProber.probe()
        let previousState = status.localNetwork
        status.update(localNetwork: state)

        if state != previousState {
            Self.logger.info("Local network permission: \(previousState.rawValue) → \(state.rawValue)")
            onPermissionChange?(.localNetwork, state)
        }
    }

    /// Inicia la monitorización continua del estado del permiso.
    public func startMonitoring(interval: TimeInterval = 5.0) {
        stopMonitoring()
        monitorTask = Task { @NexoActor [weak self] in
            while !Task.isCancelled {
                await self?.checkLocalNetworkPermission()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    /// Guía para ayudar al usuario a conceder los permisos.
    public var settingsGuidance: PermissionsGuidance {
        PermissionsGuidance(localNetworkState: status.localNetwork)
    }
}

// MARK: - LocalNetworkProber

/// Sondeo aislado para evitar problemas de concurrencia con los callbacks de NWBrowser.
private actor LocalNetworkProber {

    /// Intenta una operación de red mínima para comprobar el permiso.
    ///
    /// iOS no ofrece API directa para el estado del permiso de red local; la
    /// única vía fiable es intentar una operación y observar un error de política.
    static func probe() async -> PermissionState {
        await withCheckedContinuation { continuation in
            let browser = NWBrowser(
                for: .bonjour(type: "_nexo-probe._tcp", domain: nil),
                using: NWParameters()
            )
            let state = ProbeState()

            browser.stateUpdateHandler = { browserState in
                Task { await state.handleBrowserState(browserState, browser: browser, continuation: continuation) }
            }
            browser.start(queue: .global())

            Task {
                try? await Task.sleep(for: .seconds(3))
                await state.resumeIfNeeded(with: .granted, browser: browser, continuation: continuation)
            }
        }
    }
}

/// Estado del sondeo manejado de forma segura.
private actor ProbeState {
    private var hasResumed = false

    func handleBrowserState(
        _ state: NWBrowser.State,
        browser: NWBrowser,
        continuation: CheckedContinuation<PermissionState, Never>
    ) {
        switch state {
        case .ready:
            resumeIfNeeded(with: .granted, browser: browser, continuation: continuation)
        case .failed(let error):
            let permissionState: PermissionState = LocalNetworkDenial.isDenied(error) ? .denied : .granted
            resumeIfNeeded(with: permissionState, browser: browser, continuation: continuation)
        case .cancelled, .setup, .waiting:
            break
        @unknown default:
            break
        }
    }

    func resumeIfNeeded(
        with result: PermissionState,
        browser: NWBrowser,
        continuation: CheckedContinuation<PermissionState, Never>
    ) {
        guard !hasResumed else { return }
        hasResumed = true
        browser.cancel()
        continuation.resume(returning: result)
    }
}

// MARK: - PermissionsGuidance

/// Guía para el usuario sobre cómo conceder los permisos.
public struct PermissionsGuidance: Sendable {
    public let needsUserAction: Bool
    public let canOpenSettings: Bool
    public let localNetworkState: PermissionState

    public init(localNetworkState: PermissionState) {
        self.canOpenSettings = true
        self.localNetworkState = localNetworkState
        switch localNetworkState {
        case .denied, .restricted:
            self.needsUserAction = true
        case .unknown, .granted, .unsupported:
            self.needsUserAction = false
        }
    }

    /// URL para abrir los Ajustes de la app (si está disponible).
    public var settingsURL: URL? {
        URL(string: "App-prefs:")
    }
}

// MARK: - LocalNetworkDenial

/// Detecta si un error de Network corresponde a permiso de red local denegado.
enum LocalNetworkDenial {
    /// mDNSResponder envuelve el permiso de red local denegado en un error DNS NoAuth.
    static func isDenied(_ error: any Error) -> Bool {
        if let nwError = error as? NWError {
            switch nwError {
            case .posix(.EACCES), .posix(.EPERM): return true
            case .dns(let code) where code == -65555: return true
            default: break
            }
        }
        let description = String(describing: error) + " " + error.localizedDescription
        return description.localizedCaseInsensitiveContains("PolicyDenied")
            || description.localizedCaseInsensitiveContains("policy denied")
            || description.localizedCaseInsensitiveContains("LocalNetwork")
            || description.localizedCaseInsensitiveContains("NoAuth")
    }
}

// MARK: - Conversión con LocalNetworkPermission

public extension LocalNetworkPermission {
    var asPermissionState: PermissionState {
        switch self {
        case .unknown: .unknown
        case .available: .granted
        case .denied: .denied
        }
    }
}

public extension PermissionState {
    var asLocalNetworkPermission: LocalNetworkPermission {
        switch self {
        case .unknown, .unsupported: .unknown
        case .granted: .available
        case .denied, .restricted: .denied
        }
    }
}
