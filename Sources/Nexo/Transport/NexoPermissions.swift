//
//  NexoPermissions.swift
//  Nexo
//

import Foundation
import Network
import OSLog

// MARK: - NexoPermissionState

/// Estado de un permiso requerido para la comunicación P2P.
public enum NexoPermissionState: String, Sendable, Equatable, CaseIterable {
    /// El estado del permiso aún no se ha determinado.
    case unknown
    /// El permiso está concedido y disponible.
    case granted
    /// El permiso fue denegado por el usuario o el sistema.
    case denied
    /// El permiso está restringido por políticas del dispositivo (MDM, parental controls).
    case restricted
    /// El dispositivo no soporta esta funcionalidad.
    case unsupported
}

// MARK: - NexoPermissionKind

/// Tipos de permisos que Nexo puede requerir.
public enum NexoPermissionKind: String, Sendable, CaseIterable {
    /// Permiso de red local (Bonjour, mDNS). Requerido para descubrir peers.
    case localNetwork
    /// Permiso de Bluetooth (futuro). Podría usarse como fallback.
    case bluetooth
    /// Permiso de Wi-Fi Aware / AWDL (implícito en localNetwork en iOS).
    case peerToPeerWiFi
}

// MARK: - NexoPermissionsStatus

/// Estado agregado de todos los permisos necesarios para P2P.
@MainActor
@Observable
public final class NexoPermissionsStatus {
    /// Estado del permiso de red local.
    public private(set) var localNetwork: NexoPermissionState = .unknown
    /// Fecha del último chequeo de permisos.
    public private(set) var lastChecked: Date?
    /// Si todos los permisos requeridos están concedidos.
    public var isFullyGranted: Bool {
        localNetwork == .granted
    }
    /// Si algún permiso crítico está denegado.
    public var hasCriticalDenial: Bool {
        localNetwork == .denied || localNetwork == .restricted
    }
    
    fileprivate func update(localNetwork: NexoPermissionState) {
        self.localNetwork = localNetwork
        self.lastChecked = Date()
    }
}

// MARK: - NexoPermissionsChecker

/// Verificador de permisos necesarios para comunicación P2P.
///
/// En iOS, el permiso de "Local Network" se solicita automáticamente cuando
/// la app intenta usar Bonjour o conectarse a dispositivos en la red local.
/// Este checker permite:
/// - Verificar proactivamente si el permiso está disponible
/// - Detectar cuándo el usuario ha denegado el permiso
/// - Proporcionar orientación sobre cómo habilitarlo en Ajustes
///
/// ## Uso típico
/// ```swift
/// let checker = NexoPermissionsChecker()
/// await checker.checkPermissions()
///
/// if checker.status.hasCriticalDenial {
///     // Mostrar UI explicando cómo habilitar en Ajustes
/// }
/// ```
@MainActor
public final class NexoPermissionsChecker {
    
    private static let logger = Logger(subsystem: "com.zafir.nexo", category: "permissions")
    
    /// Estado observable de permisos.
    public let status = NexoPermissionsStatus()
    
    /// Callback cuando cambia el estado de permisos.
    public var onPermissionChange: (@MainActor @Sendable (NexoPermissionKind, NexoPermissionState) -> Void)?
    
    private var checkTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    
    public init() {}
    
    deinit {
        checkTask?.cancel()
        monitorTask?.cancel()
    }
    
    // MARK: - Public API
    
    /// Verifica el estado actual de todos los permisos necesarios.
    ///
    /// Esta operación intenta una conexión de prueba mínima para determinar
    /// si el permiso de red local está disponible. En iOS, esto puede
    /// disparar el diálogo de permiso si es la primera vez.
    public func checkPermissions() async {
        checkTask?.cancel()
        checkTask = Task { @MainActor in
            await checkLocalNetworkPermission()
        }
        await checkTask?.value
    }
    
    /// Verifica solo el permiso de red local.
    public func checkLocalNetworkPermission() async {
        let state = await LocalNetworkProber.probe()
        let previousState = status.localNetwork
        status.update(localNetwork: state)
        
        if state != previousState {
            Self.logger.info("Local network permission changed: \(previousState.rawValue) → \(state.rawValue)")
            onPermissionChange?(.localNetwork, state)
        }
    }
    
    /// Inicia monitoreo continuo del estado de permisos.
    ///
    /// Útil para detectar cuando el usuario cambia permisos en Ajustes
    /// mientras la app está en primer plano.
    public func startMonitoring(interval: TimeInterval = 5.0) {
        stopMonitoring()
        
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.checkLocalNetworkPermission()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }
    
    /// Detiene el monitoreo continuo.
    public func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }
    
    /// Información para guiar al usuario a habilitar permisos.
    public var settingsGuidance: NexoPermissionsGuidance {
        NexoPermissionsGuidance(localNetworkState: status.localNetwork)
    }
}

// MARK: - LocalNetworkProber

/// Probing aislado para evitar problemas de concurrencia con NWBrowser callbacks.
private actor LocalNetworkProber {
    
    /// Intenta una operación de red mínima para verificar el permiso.
    ///
    /// iOS no proporciona una API directa para consultar el estado del
    /// permiso de red local. La única forma fiable es intentar una
    /// operación y observar si falla con un error de política.
    static func probe() async -> NexoPermissionState {
        await withCheckedContinuation { continuation in
            let browser = NWBrowser(
                for: .bonjour(type: "_nexo-probe._tcp", domain: nil),
                using: NWParameters()
            )
            
            // Usamos una referencia a actor para manejar el estado de "ya respondido"
            let state = ProbeState()
            
            browser.stateUpdateHandler = { browserState in
                Task {
                    await state.handleBrowserState(browserState, browser: browser, continuation: continuation)
                }
            }
            
            browser.start(queue: .global())
            
            // Timeout: si no hay respuesta en 3 segundos, asumimos granted
            Task {
                try? await Task.sleep(for: .seconds(3))
                await state.resumeIfNeeded(with: .granted, browser: browser, continuation: continuation)
            }
        }
    }
}

/// Estado del probe manejado de forma thread-safe.
private actor ProbeState {
    private var hasResumed = false
    
    func handleBrowserState(
        _ state: NWBrowser.State,
        browser: NWBrowser,
        continuation: CheckedContinuation<NexoPermissionState, Never>
    ) {
        switch state {
        case .ready:
            resumeIfNeeded(with: .granted, browser: browser, continuation: continuation)
            
        case .failed(let error):
            let permissionState = isPermissionDeniedError(error) ? NexoPermissionState.denied : .granted
            resumeIfNeeded(with: permissionState, browser: browser, continuation: continuation)
            
        case .cancelled, .setup, .waiting:
            break
            
        @unknown default:
            break
        }
    }
    
    func resumeIfNeeded(
        with result: NexoPermissionState,
        browser: NWBrowser,
        continuation: CheckedContinuation<NexoPermissionState, Never>
    ) {
        guard !hasResumed else { return }
        hasResumed = true
        browser.cancel()
        continuation.resume(returning: result)
    }
    
    private func isPermissionDeniedError(_ error: NWError) -> Bool {
        switch error {
        case .posix(.EACCES), .posix(.EPERM):
            return true
        default:
            let description = String(describing: error)
            return description.localizedCaseInsensitiveContains("PolicyDenied")
                || description.localizedCaseInsensitiveContains("policy denied")
                || description.localizedCaseInsensitiveContains("LocalNetwork")
        }
    }
}

// MARK: - NexoPermissionsGuidance

/// Orientación para el usuario sobre cómo habilitar permisos.
public struct NexoPermissionsGuidance: Sendable {
    
    /// Si se necesita acción del usuario.
    public let needsUserAction: Bool
    
    /// Título para mostrar al usuario.
    public let title: String
    
    /// Mensaje explicativo.
    public let message: String
    
    /// Pasos para habilitar el permiso en Ajustes.
    public let steps: [String]
    
    /// Si se puede abrir Ajustes directamente.
    public let canOpenSettings: Bool
    
    public init(localNetworkState: NexoPermissionState) {
        self.canOpenSettings = true
        
        switch localNetworkState {
        case .denied:
            self.needsUserAction = true
            self.title = "Red local deshabilitada"
            self.message = "Nexo necesita acceso a la red local para descubrir dispositivos cercanos y comunicarse con ellos."
            self.steps = [
                "Abre Ajustes en tu iPhone",
                "Busca la app en la lista",
                "Activa \"Red local\""
            ]
        case .restricted:
            self.needsUserAction = true
            self.title = "Acceso restringido"
            self.message = "El acceso a la red local está restringido en este dispositivo. Contacta al administrador si es un dispositivo gestionado."
            self.steps = []
        case .unknown:
            self.needsUserAction = false
            self.title = "Verificando permisos"
            self.message = "Comprobando el acceso a la red local..."
            self.steps = []
        case .granted, .unsupported:
            self.needsUserAction = false
            self.title = "Listo para conectar"
            self.message = "Todos los permisos necesarios están habilitados."
            self.steps = []
        }
    }
    
    /// URL para abrir los ajustes de la app (si está disponible).
    public var settingsURL: URL? {
        URL(string: "App-prefs:")
    }
}

// MARK: - LocalNetworkPermissionState Conversion

public extension LocalNetworkPermissionState {
    
    /// Convierte a NexoPermissionState para uso unificado.
    var asNexoPermissionState: NexoPermissionState {
        switch self {
        case .unknown:
            return .unknown
        case .available:
            return .granted
        case .denied:
            return .denied
        }
    }
}

public extension NexoPermissionState {
    
    /// Convierte a LocalNetworkPermissionState para compatibilidad con el transporte.
    var asLocalNetworkPermissionState: LocalNetworkPermissionState {
        switch self {
        case .unknown, .unsupported:
            return .unknown
        case .granted:
            return .available
        case .denied, .restricted:
            return .denied
        }
    }
}
