//
//  NexoPermissions.swift
//  Nexo
//

import Foundation
import Network
import OSLog

// MARK: - NexoPermissionState

/// State of a permission required for P2P communication.
public enum NexoPermissionState: String, Sendable, Equatable, CaseIterable {
    /// Permission state not yet determined.
    case unknown
    /// Permission granted and available.
    case granted
    /// Permission denied by the user or the system.
    case denied
    /// Permission restricted by device policy (MDM, parental controls).
    case restricted
    /// The device doesn't support this capability.
    case unsupported
}

// MARK: - NexoPermissionKind

/// Permission types Nexo may require.
public enum NexoPermissionKind: String, Sendable, CaseIterable {
    /// Local network permission (Bonjour, mDNS). Required to discover peers.
    case localNetwork
    /// Bluetooth permission (future). Could serve as a fallback.
    case bluetooth
    /// Wi-Fi Aware / AWDL permission (implicit in localNetwork on iOS).
    case peerToPeerWiFi
}

// MARK: - NexoPermissionsStatus

/// Aggregated state of all permissions needed for P2P.
@MainActor
@Observable
public final class NexoPermissionsStatus {
    /// Local network permission state.
    public private(set) var localNetwork: NexoPermissionState = .unknown
    /// Date of the last permission check.
    public private(set) var lastChecked: Date?
    /// Whether all required permissions are granted.
    public var isFullyGranted: Bool {
        localNetwork == .granted
    }
    /// Whether any critical permission is denied.
    public var hasCriticalDenial: Bool {
        localNetwork == .denied || localNetwork == .restricted
    }
    
    fileprivate func update(localNetwork: NexoPermissionState) {
        self.localNetwork = localNetwork
        self.lastChecked = Date()
    }
}

// MARK: - NexoPermissionsChecker

/// Checks the permissions needed for P2P communication.
///
/// iOS requests the "Local Network" permission automatically when the app
/// uses Bonjour or connects to devices on the local network. This checker
/// verifies proactively, detects user denial, and provides guidance for
/// re-enabling the permission in Settings.
@MainActor
public final class NexoPermissionsChecker {
    
    private static let logger = Logger(subsystem: "com.zafir.nexo", category: "permissions")
    
    /// Observable permission state.
    public let status = NexoPermissionsStatus()
    
    /// Callback fired when permission state changes.
    public var onPermissionChange: (@MainActor @Sendable (NexoPermissionKind, NexoPermissionState) -> Void)?
    
    private var checkTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    
    public init() {}
    
    deinit {
        checkTask?.cancel()
        monitorTask?.cancel()
    }
    
    // MARK: - Public API
    
    /// Checks the current state of all required permissions.
    ///
    /// Performs a minimal probe connection to determine whether local network
    /// permission is available. On iOS this can trigger the permission dialog
    /// on first use.
    public func checkPermissions() async {
        checkTask?.cancel()
        checkTask = Task { @MainActor in
            await checkLocalNetworkPermission()
        }
        await checkTask?.value
    }
    
    /// Checks only the local network permission.
    public func checkLocalNetworkPermission() async {
        let state = await LocalNetworkProber.probe()
        let previousState = status.localNetwork
        status.update(localNetwork: state)
        
        if state != previousState {
            Self.logger.info("Local network permission changed: \(previousState.rawValue) → \(state.rawValue)")
            onPermissionChange?(.localNetwork, state)
        }
    }
    
    /// Starts continuous monitoring of permission state.
    ///
    /// Detects when the user changes permissions in Settings while the app
    /// is in the foreground.
    public func startMonitoring(interval: TimeInterval = 5.0) {
        stopMonitoring()
        
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.checkLocalNetworkPermission()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }
    
    /// Stops continuous monitoring.
    public func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }
    
    /// Guidance to help the user enable permissions.
    public var settingsGuidance: NexoPermissionsGuidance {
        NexoPermissionsGuidance(localNetworkState: status.localNetwork)
    }
}

// MARK: - LocalNetworkProber

/// Isolated probing to avoid concurrency issues with NWBrowser callbacks.
private actor LocalNetworkProber {
    
    /// Attempts a minimal network operation to check the permission.
    ///
    /// iOS provides no direct API for local network permission status; the
    /// only reliable way is to attempt an operation and watch for a policy error.
    static func probe() async -> NexoPermissionState {
        await withCheckedContinuation { continuation in
            let browser = NWBrowser(
                for: .bonjour(type: "_nexo-probe._tcp", domain: nil),
                using: NWParameters()
            )
            
            // Actor-owned state guards against resuming the continuation twice
            let state = ProbeState()
            
            browser.stateUpdateHandler = { browserState in
                Task {
                    await state.handleBrowserState(browserState, browser: browser, continuation: continuation)
                }
            }
            
            browser.start(queue: .global())
            
            // Timeout: if no response within 3 seconds, assume granted
            Task {
                try? await Task.sleep(for: .seconds(3))
                await state.resumeIfNeeded(with: .granted, browser: browser, continuation: continuation)
            }
        }
    }
}

/// Probe state handled in a thread-safe way.
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
        NexoLocalNetworkPermission.isDenied(error)
    }
}

// MARK: - NexoPermissionsGuidance

/// Guidance for the user on how to enable permissions.
public struct NexoPermissionsGuidance: Sendable {
    
    /// Whether user action is needed.
    public let needsUserAction: Bool
    
    /// Title shown to the user.
    public let title: String
    
    /// Explaining message.
    public let message: String
    
    /// Steps to enable the permission in Settings.
    public let steps: [String]
    
    /// Whether Settings can be opened directly.
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
    
    /// URL to open the app's settings (if available).
    public var settingsURL: URL? {
        URL(string: "App-prefs:")
    }
}

// MARK: - LocalNetworkPermissionState Conversion

public extension LocalNetworkPermissionState {
    
    /// Converts to NexoPermissionState for unified use.
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
    
    /// Converts to LocalNetworkPermissionState for transport compatibility.
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
