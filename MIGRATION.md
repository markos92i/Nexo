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
    displayName: identity.displayName,
    service: ServiceType("tu-app")                                 // → _tu-app._tcp
)
let rooms = RoomService(transport: transport, identity: identity) // consume transport.events
transport.start(advertising: true, browsing: true)
```

Ya no generas ni persistes el ID: lo hace `LocalIdentity`. Ya no hay certificados.

Cada app necesita su propio `ServiceType` (1–15 caracteres: minúsculas, dígitos y
guiones). Con el mismo tipo, dos apps se ven pero no conectan, porque sus PSK no
coinciden. `ServiceType.nexo` es solo para tests.

### Eventos del transporte y segundo plano

`RoomService` lee `transport.events` desde su init. Tu app **no** debe iterarlo
ni reenviarle eventos: si tenías un bucle `for await event in transport.events`,
bórralo.
Para pintar anuncios o peers, usa `rooms.transportEvents` (admite varios
suscriptores y ya viene aplicado) o `RoomsModel`.

Para suspender al pasar a segundo plano:
```swift
transport.stop()
rooms.suspend()   // conserva la membresía para recuperarla al volver
```

`RoomsModel(service: rooms)` es opcional: una copia `@Observable` en el hilo
principal del estado de las salas (`availableRooms`, `joinProgress`,
`roomStates`, `notices`…), para no escribir esas suscripciones en cada app.

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

Mientras dura una entrada, `rooms.joinProgress[roomID]` indica la fase y la sala
sigue en `availableRooms`. Para cancelarla, cancela la `Task` que espera
`join(_:)`. Los errores posibles están en [USAGE.md](USAGE.md#unirse-a-una-sala).

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
- Los eventos emitidos antes de que haya lector (hasta 256) se entregan en orden
  al primero que lea `events`.

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
let writer = try await rooms.openByteStream(to: rivalDeviceID, in: roomID)
for block in datosDensos { try await writer.send(block) }
try await writer.finish()

// el otro lado (un único consumidor):
for await incoming in rooms.incomingByteStreams {
    // incoming.descriptor.roomID, incoming.senderDeviceID, incoming.stream
    for try await chunk in incoming.stream { aplicar(chunk) }
}
```
Va por una segunda conexión TCP con el mismo peer, cifrada con la misma PSK, así
que no retrasa el chat ni las órdenes del juego. Solo se entregan streams de
miembros unidos a la sala. Detalles y límites en [USAGE.md](USAGE.md#streams-binarios).

## 10. Permisos

| Antes | Ahora |
|---|---|
| `NexoPermissionsChecker` | `PermissionsChecker` |
| `NexoPermissionState` | `PermissionState` |
| `NexoPermissionsGuidance` | `PermissionsGuidance` |
| `checker.status.hasCriticalDenial` | igual |

## 11. Info.plist

Declara solo el tipo de tu `ServiceType` y el de la comprobación de permisos:
```xml
<key>NSBonjourServices</key>
<array>
    <string>_tu-app._tcp</string>
    <string>_nexo-probe._tcp</string>
</array>
```
(Antes: `_zafir-nearby._tcp` / `_udp`.) Ya no hace falta ninguna entrada `_udp`.

---

## Si venías de una versión anterior de este rewrite

- **Tipo Bonjour**: `ProtocolInfo.serviceType` y `ProtocolInfo.quicServiceType` ya
  no existen. Pasa `service: ServiceType("tu-app")` a `NetworkTransport` y deja en
  el Info.plist solo `_tu-app._tcp` y `_nexo-probe._tcp` (quita `_nexo._tcp` y
  `_nexo._udp`).
- **QUIC eliminado**: con una PSK externa, el TLS de Apple solo negocia TLS 1.2 y
  QUIC exige TLS 1.3, así que el handshake fallaba siempre. Los streams binarios
  van ahora por TCP con la misma API de sala:

  | Antes | Ahora |
  |---|---|
  | `QUICByteStream` | `ByteStreamWriter` (`cancel()` ya no lanza) |
  | `QUICIncomingStream` | `IncomingByteStream` (añade `senderDeviceID`) |
  | `QUICChannelError` | `ByteStreamError` |
  | `QUICChannel` | sin equivalente público |

- **Eventos**: `rooms.handle(_:)` ahora es interno. Borra el bucle sobre
  `transport.events` y suscríbete a `rooms.transportEvents`. Para suspender, cambia
  `rooms.handle(.lifecycleChanged(.suspended, …))` + `forgetDiscoveredPeers()` por
  `transport.stop()` + `rooms.suspend()`.
- **Nuevos `RoomError` al entrar**: muéstralos en la UI.
  `hostUnreachable(reason)` (no se pudo conectar con el host) y `connectionLost`
  (se cortó mientras esperabas). `peerUnavailable` ya solo significa que el host
  dejó de anunciarse, y `joinTimedOut` que no respondió a tiempo.
- **Entrada en curso**: la sala ya no desaparece de `availableRooms` mientras
  esperas aprobación; píntala con `joinProgress[room.id]` (`.connecting` /
  `.awaitingApproval`). Para cancelar, cancela la `Task` que espera `join(_:)`.
- **Nuevo `RoomNotice.joinRequestResolved`**: añádelo a los `switch` exhaustivos y
  úsalo para retirar el aviso de una solicitud que ya no está pendiente.
- **Eventos de actividad**: `GenericActivity.events` guarda lo emitido antes del
  primer lector, así que puedes quitar los reenvíos periódicos de estado "por si
  acaso".
- **"No puedo unirme a la sala de otro dispositivo"**: era un fallo de Nexo, ya
  corregido. Con el framer de longitud, `isComplete` marca el final de cada
  mensaje y se trataba como fin de la conexión, que se cerraba justo después del
  hello. Los logs de BoringSSL "Clearing PSK identity" eran solo el cierre, no un
  rechazo de la PSK.

---

## Checklist rápido para las pruebas

- [ ] Sustituir arranque de la pila con tu `ServiceType` (sección 1).
- [ ] Quitar cualquier bucle sobre `transport.events`; suspender con
      `transport.stop()` + `rooms.suspend()` (1).
- [ ] Reemplazar nombres de tipos (sección 2) y `applicationID`→`deviceID` (3).
- [ ] Borrar toda la UI/lógica de verificación TOFU (4).
- [ ] Ajustar actividades: `events` en vez de `handleMessage`, `send(_, to:)` (7).
- [ ] Instanciar y `bindTransfers` el `FileTransferService` reteniéndolo (8).
- [ ] Actualizar Info.plist: solo `_tu-app._tcp` y `_nexo-probe._tcp` (11).
- [ ] (Opcional) Usar `RoomsModel` para el estado en SwiftUI (1).
