# Nexo

![Swift 6.4](https://img.shields.io/badge/Swift-6.4-F05138?logo=swift&logoColor=white)
![iOS 26+](https://img.shields.io/badge/iOS-26%2B-007AFF)
![SPM](https://img.shields.io/badge/SPM-Compatible-blue)

A peer-to-peer rooms library for iOS built on Network framework's structured API (Bonjour + TCP). Nexo handles discovery, connections, room membership and typed message delivery — it has no idea what a chat message or a game move looks like. That part is entirely up to you.

## What Nexo knows about

- **Transport** — Bonjour advertising/browsing, one physical connection per peer, reconnection handling. `PeerTransport` is a protocol, so the default `NetworkPeerTransport` can be swapped in tests.
- **Rooms** — logical spaces that survive reconnects. A room is not a socket: several rooms can share the same physical connection to a peer, and a room's membership, host authority and features (`chat`, `activities`, `fileTransfer`) are independent of the transport.
- **Activities** — anything that happens *inside* a room. An activity's payload is opaque `Data` to every layer below it; Nexo only routes it to the right `RoomActivity` instance. Activities can be `isExclusive` (a game — only one at a time) or not (e.g. chat, which can run alongside anything).
- **Delivery** — reliable in-order envelopes by default, plus a `coalescingKey` for latest-wins state (board snapshots, cursor positions) so a stale update never sits in front of an authoritative one.

## What Nexo does **not** know about

Sudoku, chess, chat bubbles, display names' language, or any other product concept. Every one of those is built on top, in your app, using the extension points below.

## Installation

Add Nexo as a local Swift package and link the `Nexo` product to your app target.

## Core types

```
PeerTransport            neutral transport contract (NetworkPeerTransport implements it)
└── RoomCoordinator      logical rooms: discovery, membership, host authority
    └── RoomSession      one room: members + live activities
        └── RoomActivity one instance per activity (chat, a game, ...)
```

- `RoomOutbox` is the only way to send — it's scoped to one room, so nothing you write can leak a message into the wrong room.
- `ActivityKind` is an open, `String`-backed identifier. Nexo ships none. Your app declares its own:

```swift
extension ActivityKind {
    static let sudoku = ActivityKind("sudoku")
}
```

## Adding a new activity

1. Define a `Codable` message enum for it. It travels as opaque payload; no other layer needs to know about it.
2. Subclass `GenericActivity<YourMessage>` — it already handles decoding, buffering messages that arrive before your UI is ready, and coalesced sending.
3. Register a factory:

```swift
RoomActivityRegistry.shared.register(.yourKind) { context in
    YourActivity(context: context)
}
```

No change to the transport, the envelope format, or `RoomCoordinator` is ever required.

## Design notes

- Peers identify themselves with a self-declared `applicationID` — it is **not verified**. Treat every remote payload as untrusted.
- `NetworkPeerTransport` encrypts traffic when supplied with `NexoTLSConfiguration`; the Zafir app creates that configuration automatically for every device.
- Bonjour TXT records are capped at 255 bytes per entry — anything published there is budgeted in UTF-8 bytes.

## Documentation

- **[USAGE.md](USAGE.md)** — Complete usage guide with examples for permissions, TLS, verification, rooms, chat, file transfer, and activities.
- **[Security](Sources/Nexo/Documentation.docc/Security.md)** — TOFU encryption model, identity verification, and security best practices.
- **[Communication Architecture](Sources/Nexo/Documentation.docc/CommunicationArchitecture.md)** — Hybrid TCP/JSON + QUIC/binary transport design.

## Permissions

Before using Nexo, check that Local Network permission is granted:

```swift
let checker = NexoPermissionsChecker()
await checker.checkPermissions()

if checker.status.hasCriticalDenial {
    let guidance = checker.settingsGuidance
    // Show guidance.title, guidance.message, guidance.steps
}
```

## Peer Verification (TOFU)

Nexo uses Trust On First Use, similar to SSH:

```swift
let verificationService = NexoPeerVerificationService(applicationID: myID)

// Check peer state
let state = verificationService.verify(connectedPeer)

switch state {
case .unknown:
    // First connection - show acceptance UI
case .trustedOnFirstUse:
    // Known peer, encrypted connection
case .verified:
    // Peer verified out-of-band
case .identityChanged:
    // ⚠️ Fingerprint changed - possible MITM
}

// Visual fingerprint for verification
let info = verificationService.identityInfo(for: peer)
print(info.emojiFingerprint)  // "🍎🐶🌸⭐🍇🦊🌻🌙"
```

## Local P2P identity

The normal app flow requires no backend or certificate bundle. `NexoLocalTLSIdentity.loadOrCreate(applicationID:)` generates a P-256 key in Keychain, creates a self-signed X.509 certificate locally, and exposes the resulting `sec_identity_t` through `makeTLSConfiguration()`. The private key never leaves the device.

The encrypted handshake exchanges the certificate public-key fingerprint. The app stores fingerprints accepted from the room menu in Keychain. TLS protects an unpaired connection, but the room lock is shown as verified only after every remote participant has been paired locally.

## Managed-fleet TLS

For a controlled device fleet, use a private CA and issue one mTLS identity per device. The generator at `Scripts/generate-production-pki.sh` writes credentials outside the repository by default and refuses to overwrite an existing output directory.

```sh
Scripts/generate-production-pki.sh /secure/path/nexo-production zafir-device-01
```

Distribute only the device `.p12` and its password to that device. Keep the CA private key offline or in a secrets manager, and distribute only `NexoProductionCA.cert.pem` to the application. Import the identity into Keychain, convert it with `sec_identity_create`, and configure Nexo with a validator that trusts this CA or pins the device public key. Do not ship the CA private key, password files, or generated PKCS#12 files in the app source tree.

The generated leaf certificate has `serverAuth` and `clientAuth` EKUs and these SANs:

- `urn:zafir:nexo:device:<device-name>`
- `<device-name>.local`

Generate a new leaf for every device. Do not reuse `zafir-device-01` credentials across the fleet.
