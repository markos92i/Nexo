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
///
/// Nothing here is tied to the main actor. Bonjour churn, TXT decoding,
/// connection bookkeeping, frame traffic and lane draining all belong to the
/// transport's own executor, so a device-rich room can never cost the app a
/// frame. The consequences for callers:
///
/// - `start`, `stop`, `updateAdvertisement`, `refreshDiscovery`, `disconnect`
///   and `enqueue` are synchronous and nonisolated *by contract*: they hand
///   the work over and return. They stay synchronous because game state is
///   sent from the render cadence, and a hop per message would both cost
///   more and stop preserving the order the sender chose.
/// - `epoch` and `connectedPeers` are readable synchronously for the same
///   reason: event filters and reconciliation run inside main-actor code that
///   cannot suspend, like a background-expiration handler.
/// - `events` is delivered on whichever executor the consumer picks. The app
///   reads it on the main actor because what it does with an event is publish
///   observable state.
public protocol PeerTransport: AnyObject, Sendable {

    /// Single event stream. Has one consumer: the app's connectivity manager.
    var events: AsyncStream<PeerTransportEvent> { get }

    /// Generation assigned synchronously when starting a new session or stopping.
    /// Repeating `start` with unchanged flags may reuse the current generation.
    var epoch: UInt64 { get }

    /// Peers with a completed handshake, indexed by `applicationID`.
    var connectedPeers: [ConnectedPeer] { get }

    // MARK: Lifecycle

    func start(advertising: Bool, browsing: Bool)
    func stop()

    /// Updates the published TXT record without restarting the listener, so
    /// switching rooms never drops open connections.
    func updateAdvertisement(_ record: AdvertisementRecord)

    /// Re-runs discovery: rebuilds any listener that died and restarts the
    /// browsers. A fresh Bonjour query always returns the peers' current TXT,
    /// which is the only way to heal a missed advertisement update.
    ///
    /// Established connections survive it.
    func refreshDiscovery()

    // MARK: Connections

    /// Opens a connection to the given advertisement, or reuses an existing
    /// live connection to that `applicationID`.
    @discardableResult
    func connect(to advertisement: PeerAdvertisement) async throws -> ConnectedPeer

    /// Closes the physical connection to a peer. Only the manager should call
    /// this: leaving a room never closes the connection.
    func disconnect(applicationID: String, reason: NexoReason?)

    // MARK: Sending

    /// Queues an envelope for a specific peer. Sending is asynchronous and
    /// respects the lanes and coalescing configured on the envelope.
    func enqueue(_ envelope: RoomEnvelope, to applicationID: String)
}