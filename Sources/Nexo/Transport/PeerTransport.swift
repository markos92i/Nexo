//
//  PeerTransport.swift
//  Project Dark
//
//  Created by Marcos del Castillo Camacho on 11/09/2026.
//

import Foundation

// MARK: - PeerTransport

/// Contrato del transporte físico, independiente de Network Framework.
///
/// El transporte no sabe qué es una room: solo descubre dispositivos, mantiene
/// una conexión por peer y entrega envelopes opacos. Todo el enrutamiento lógico
/// vive en `RoomCoordinator`.
@MainActor
public protocol PeerTransport: AnyObject {

    /// Flujo único de eventos. Tiene un solo consumidor: `P2PConnectivityManager`.
    var events: AsyncStream<PeerTransportEvent> { get }

    /// Época vigente. Se incrementa en cada `start`/`stop` para descartar
    /// eventos de una sesión anterior.
    var epoch: UInt64 { get }

    /// Peers con handshake completado, indexados por `applicationID`.
    var connectedPeers: [ConnectedPeer] { get }

    // MARK: Ciclo de vida

    func start(advertising: Bool, browsing: Bool)
    func stop()

    /// Actualiza el registro TXT publicado sin reiniciar el listener, de modo que
    /// cambiar de rooms no corta las conexiones abiertas.
    func updateAdvertisement(_ record: AdvertisementRecord)

    // MARK: Conexiones

    /// Abre una conexión con el anuncio indicado, o reutiliza la existente si ya
    /// hay una conexión viva con ese `applicationID`.
    @discardableResult
    func connect(to advertisement: PeerAdvertisement) async throws -> ConnectedPeer

    /// Cierra la conexión física con un peer. Solo debe usarla el manager: salir
    /// de una room nunca cierra la conexión.
    func disconnect(applicationID: String, reason: String?)

    // MARK: Envío

    /// Encola un envelope hacia un peer concreto. El envío es asíncrono y
    /// respeta las lanes y el coalescing configurados en el envelope.
    func enqueue(_ envelope: RoomEnvelope, to applicationID: String)
}
