//
//  PeerTransport.swift
//  Nexo
//

import Foundation

// MARK: - PeerTransport

/// Contract for the physical transport, independent of Network framework.
///
/// The transport doesn't know what a room is: it only discovers devices,
/// keeps one connection per peer, and delivers opaque envelopes. All logical
/// routing lives in `RoomCoordinator`.
@MainActor
public protocol PeerTransport: AnyObject {

    /// Single event stream. Has one consumer: the app's connectivity manager.
    var events: AsyncStream<PeerTransportEvent> { get }

    /// Current epoch. Incremented on every `start`/`stop` to discard events
    /// from a previous session.
    var epoch: UInt64 { get }

    /// Peers with a completed handshake, indexed by `applicationID`.
    var connectedPeers: [ConnectedPeer] { get }

    // MARK: Lifecycle

    func start(advertising: Bool, browsing: Bool)
    func stop()

    /// Updates the published TXT record without restarting the listener, so
    /// switching rooms never drops open connections.
    func updateAdvertisement(_ record: AdvertisementRecord)

    // MARK: Connections

    /// Opens a connection to the given advertisement, or reuses an existing
    /// live connection to that `applicationID`.
    @discardableResult
    func connect(to advertisement: PeerAdvertisement) async throws -> ConnectedPeer

    /// Closes the physical connection to a peer. Only the manager should call
    /// this: leaving a room never closes the connection.
    func disconnect(applicationID: String, reason: String?)

    // MARK: Sending

    /// Queues an envelope for a specific peer. Sending is asynchronous and
    /// respects the lanes and coalescing configured on the envelope.
    func enqueue(_ envelope: RoomEnvelope, to applicationID: String)
}