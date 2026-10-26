# Guía de migración (app que usaba la versión anterior de Nexo)

Esta versión es un rewrite. Aquí tienes el antes → después de todo lo que tu app
toca. Los cambios son mayormente mecánicos (renombrados + `DeviceID`).

## 1. Arranque de la pila

**Antes:**
```swift
let appID = getOrCreateApplicationID()                 // lo inventabas tú
let tls = try NexoLocalTLSIdentity.loadOrCreate(applicationID: appID)
let identity = LocalP2PIdentity(applicationID: appID, displayName: name)
let transport = NetworkPeerTransport(
    applicationID: appID, displayName: name,
    tlsConfiguration: tls.makeTLSConfiguration(),
    localCertificateFingerprint: tls.fingerprint
)
let coordinator = RoomCoordinator(transport: transport, identity: identity)
```

**Ahora:**
```swift
let identity = try LocalIdentity.loadOrCreate(displayName: name)   // Nexo gestiona el DeviceID
let crypto = SessionCrypto(appSecret: "tu-secreto-de-app")         // constante de tu app
let transport = NetworkTransport(
    crypto: crypto,
    deviceID: identity.deviceID,
    displayName: identity.displayName
)
let rooms = RoomService(transport: transport, identity: identity)
transport.start(advertising: true, browsing: true)
```

Ya no generas ni persistes el ID: lo hace `LocalIdentity`. Ya no hay certificados.

## 2. Renombrados de tipos (busca y reemplaza)

| Antes | Ahora |
|---|---|
| `RoomCoordinator` | `RoomService` |
| `RoomSession` | `Room` |
| `NetworkPeerTransport` | `NetworkTransport` |
| `PeerTransport` (protocolo) | `Transport` |
| `LocalP2PIdentity` | `LocalIdentity` |
| `ChatRoomSession` | se accede como `room.chat` (tipo `RoomChat`) |
| `RoomActivity` (protocolo) | `Activity` |
| `RoomActivityRegistry` | `ActivityRegistry` (inyectado, nunca `.shared`) |
| `NexoReason` | `DisconnectReason` |
| `PeerTransportEvent` | `TransportEvent` |
| `P2PNotice` | `RoomNotice` |
| `RoomEnvelope` | `Envelope` |
| `applicationID` (String) | `deviceID` (`DeviceID`) |

## 3. `applicationID: String` → `DeviceID`

Es el cambio más extendido. Donde antes pasabas o comparabas un `String` de
`applicationID`, ahora es un `DeviceID` (envoltorio de UUID). Para mostrarlo o
serializarlo a texto: `deviceID.description`. Para reconstruirlo:
`DeviceID(string:)`.

`RoomMember.applicationID` → `RoomMember.deviceID`.
`ConnectedPeer.applicationID` → `ConnectedPeer.deviceID`.

## 4. Verificación de peers (TOFU): ELIMINADA

Si tu app tenía UI de verificación —huellas emoji, palabras, QR, "identidad
cambiada", `NexoPeerVerificationService`, `markAsVerified`, etc.— **todo eso ya no
existe**. La seguridad vive en el PSK: quien no conoce `appSecret` (+ `roomCode`
si lo usas) no se conecta. Para que el usuario confirme que está en la sala
correcta, muéstrale `room.roomID.shortCode` y que lo comparen de viva voz.

Borra de tu app: pantallas de verificación, escaneo de QR de identidad, alertas de
cambio de fingerprint.

## 5. Salas

| Antes | Ahora |
|---|---|
| `coordinator.createRoom(name:features:accessPolicy:capacity:)` | `rooms.createRoom(name:features:activityKind:accessPolicy:capacity:)` (devuelve `Room`) |
| `try await coordinator.join(room)` | `try await rooms.join(room)` — ahora `throws(RoomError)` |
| `coordinator.leave(roomID)` | `rooms.leave(roomID)` |
| `coordinator.respond(to:accept:)` | `rooms.respond(to:accept:reason:)` |

Observar una sala (igual que antes, por `AsyncStream`):
```swift
for await snapshot in room.snapshots {
    // snapshot.members, snapshot.chatMessages, snapshot.activityDescriptors, ...
}
```

## 6. Chat

**Antes:** `session.chat?.send(text)` / `chat.messages`
**Ahora:** `room.chat?.send(text: "...")` / `room.chat?.messages`
(el parámetro es `text:` con etiqueta). Adjuntos: `room.chat?.send(attachment:caption:)`.

## 7. Actividades (juegos)

**Antes:**
```swift
final class SudokuActivity: GenericActivity<SudokuMessage> {
    override func handleMessage(_ m: SudokuMessage, from member: RoomMember) { ... }
    func makeMove(...) { send(.move(...)) }
}
RoomActivityRegistry.shared.register(.sudoku) { ctx in SudokuActivity(context: ctx) }
```

**Ahora:**
```swift
final class SudokuActivity: GenericActivity<SudokuMessage> {
    // los mensajes llegan por el AsyncStream `events`, no por un override:
    override func currentStateSnapshot() -> SudokuMessage? { .board(board) }  // opcional, para reconexión
}
rooms.registerActivity(.sudoku) { ctx in SudokuActivity(context: ctx) }       // sin .shared

// consumir mensajes:
for await event in activity.events {
    switch event {
    case .message(let msg, let from): aplicar(msg, from)
    case .participantJoined, .participantLeft, .descriptorUpdated, .ended: break
    }
}

// enviar, con DESTINO EXPLÍCITO (nuevo):
activity.send(.move(...), to: .everyone)            // a todos
activity.send(secreto, to: .member(rivalDeviceID))  // a uno
activity.send(.move(...), to: .members([a, b]))      // a varios
activity.sendState(.board(b), coalescingKey: "board") // estado reemplazable (latest-wins)
```

Cambios clave de actividades:
- Los mensajes entrantes llegan por `activity.events` (AsyncStream), **no** por un
  `override func handleMessage`.
- `send` ahora exige **a quién** (`ActivityRecipients`): `.everyone` / `.member` /
  `.members`.
- `currentStateSnapshot()` (opcional): devuelve el estado completo del juego;
  Nexo lo reenvía al reconectar y al migrar el host, para que la partida sobreviva.

## 8. Transferencia de archivos

El servicio se instancia y se enchufa (antes venía dentro del coordinator):
```swift
let transfers = FileTransferService()
rooms.bindTransfers(transfers)        // IMPORTANTE: retén `transfers` tú (referencia fuerte);
                                      // RoomService lo guarda débilmente.
let attachment = try await transfers.offer(fileURL: url, mimeType: "image/jpeg", in: room)
room.chat?.send(attachment: attachment, caption: "...")
```
`offer`/`state(of:)`/`localFileURL(for:)` siguen igual, pero reciben `Room` (no
`RoomSession`).

## 9. Streaming binario de alta velocidad (NUEVO)

No existía como API de app. Ahora, para datos densos (estado de juego complejo):
```swift
let stream = try await rooms.openByteStream(to: rivalDeviceID, in: roomID)
for frame in datosDensos { try await stream.send(frame) }
try await stream.finish()

// el otro lado:
for await incoming in rooms.incomingByteStreams {
    // incoming.descriptor.roomID, incoming.stream
    for try await chunk in incoming.stream { aplicar(chunk) }
}
```
⚠️ Esto usa QUIC+PSK, que es lo más incierto en hardware. Si falla, es lo primero
a mirar en las pruebas.

## 10. Permisos

| Antes | Ahora |
|---|---|
| `NexoPermissionsChecker` | `PermissionsChecker` |
| `NexoPermissionState` | `PermissionState` |
| `NexoPermissionsGuidance` | `PermissionsGuidance` |
| `checker.status.hasCriticalDenial` | igual |

## 11. Info.plist

Cambia el tipo de servicio Bonjour si lo tenías con el nombre viejo:
```xml
<key>NSBonjourServices</key>
<array>
    <string>_nexo._tcp</string>
    <string>_nexo._udp</string>
</array>
```
(Antes: `_zafir-nearby._tcp` / `_udp`.)

---

## Checklist rápido para las pruebas

- [ ] Sustituir arranque de la pila (sección 1).
- [ ] Reemplazar nombres de tipos (sección 2) y `applicationID`→`deviceID` (3).
- [ ] Borrar toda la UI/lógica de verificación TOFU (4).
- [ ] Ajustar actividades: `events` en vez de `handleMessage`, `send(_, to:)` (7).
- [ ] Instanciar y `bindTransfers` el `FileTransferService` reteniéndolo (8).
- [ ] Actualizar Info.plist (`_nexo._tcp`/`_udp`) (11).
