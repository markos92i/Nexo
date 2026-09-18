//
//  PermissionsTests.swift
//  Nexo
//

import Foundation
import Testing
@testable import Nexo

// MARK: - NexoPermissionState Tests

@Test func permissionStateConversions() {
    // LocalNetworkPermissionState → NexoPermissionState
    #expect(LocalNetworkPermissionState.unknown.asNexoPermissionState == .unknown)
    #expect(LocalNetworkPermissionState.available.asNexoPermissionState == .granted)
    #expect(LocalNetworkPermissionState.denied.asNexoPermissionState == .denied)
    
    // NexoPermissionState → LocalNetworkPermissionState
    #expect(NexoPermissionState.unknown.asLocalNetworkPermissionState == .unknown)
    #expect(NexoPermissionState.granted.asLocalNetworkPermissionState == .available)
    #expect(NexoPermissionState.denied.asLocalNetworkPermissionState == .denied)
    #expect(NexoPermissionState.restricted.asLocalNetworkPermissionState == .denied)
    #expect(NexoPermissionState.unsupported.asLocalNetworkPermissionState == .unknown)
}

@Test func permissionsGuidanceForDenied() {
    let guidance = NexoPermissionsGuidance(localNetworkState: .denied)
    
    #expect(guidance.needsUserAction == true)
    #expect(guidance.title == "Red local deshabilitada")
    #expect(guidance.steps.isEmpty == false)
    #expect(guidance.canOpenSettings == true)
}

@Test func permissionsGuidanceForGranted() {
    let guidance = NexoPermissionsGuidance(localNetworkState: .granted)
    
    #expect(guidance.needsUserAction == false)
    #expect(guidance.title == "Listo para conectar")
    #expect(guidance.steps.isEmpty == true)
}

@Test func permissionsGuidanceForUnknown() {
    let guidance = NexoPermissionsGuidance(localNetworkState: .unknown)
    
    #expect(guidance.needsUserAction == false)
    #expect(guidance.title == "Verificando permisos")
}

@Test @MainActor func permissionsStatusComputedProperties() {
    let status = NexoPermissionsStatus()
    
    // Estado inicial
    #expect(status.localNetwork == .unknown)
    #expect(status.isFullyGranted == false)
    #expect(status.hasCriticalDenial == false)
}
