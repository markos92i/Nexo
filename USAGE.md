# Guía de uso de Nexo

Comunicación P2P en iOS/macOS sin Internet. Esta guía asume el modelo actual:
cifrado PSK, identidad de dispositivo gestionada por la librería, sin TOFU.

## Índice

1. [Configuración inicial](#configuración-inicial)
2. [Permisos](#permisos)
3. [Identidad y cifrado](#identidad-y-cifrado)
4. [Descubrimiento y conexión](#descubrimiento-y-conexión)
5. [Estado en SwiftUI](#estado-en-swiftui)
6. [Salas y chat](#salas-y-chat)
7. [Actividades (juegos)](#actividades-juegos)
8. [Streams binarios](#streams-binarios)
9. [Transferencia de archivos](#transferencia-de-archivos)
10. [Diagnóstico](#diagnóstico)

---

## Configuración inicial

### Info.plist

Declara solo el tipo Bonjour de tu app (`ServiceType("mi-app").bonjourType`) y
`_nexo-probe._tcp`, que Nexo usa para comprobar el permiso de red local:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Nexo necesita la red local para descubrir y conectar con dispositivos cercanos.</string>
<key>NSBonjourServices</key>
<array>
    <string>_mi-app._tcp</string>
    <string>_nexo-probe._tcp</string>
</array>
```

```swift
import Nexo
```

---

## Permisos

```swift
@MainActor
final class PermissionsManager {
    let checker = PermissionsChecker()

    func checkOnLaunch() async {
        await checker.checkPermissions()
        if checker.status.hasCriticalDenial {
            let guidance = checker.settingsGuidance
            // guidance.needsUserAction, guidance.settingsURL
        }
    }

    func startMonitoring() {
        checker.onPermissionChange = { kind, state in
            print("Permiso \(kind) → \(state)")
        }
        checker.startMonitoring(interval: 5)
    }
}
```

---

## Identidad y cifrado

Nexo genera y persiste un `DeviceID` único por instalación. El cifrado es PSK:
un secreto de app (constante tuya) y, si quieres aislar salas, un código de sala.

```swift
let identity = try LocalIdentity.loadOrCreate(displayName: deviceName)

// Canal común de app (todas las salas comparten PSK):
let crypto = SessionCrypto(appSecret: "mi-secreto-de-app")

// O canal aislado por sala:
// let crypto = SessionCrypto(appSecret: "mi-secreto-de-app", roomCode: room.shortCode)

let transport = NetworkTransport(
    crypto: crypto,
    deviceID: identity.deviceID,
    displayName: identity.displayName,
    service: ServiceType("mi-app")   // anuncia y busca _mi-app._tcp
)
let rooms = RoomService(transport: transport, identity: identity)
```

`ServiceType` admite de 1 a 15 caracteres: minúsculas ASCII, dígitos y guiones,
sin guion al principio ni al final (un nombre inválido hace saltar una
precondición). Usa uno propio: dos apps con el mismo tipo se ven pero no conectan,
porque sus PSK no coinciden. `ServiceType.nexo` es el valor por defecto y existe
solo para tests.

> La seguridad vive en el secreto: quien no lo conoce no se conecta. Para
> confirmar que estás en la sala correcta, compara el `room.shortCode` de viva voz.
> El secreto se puede extraer del binario: no lo uses como autenticación (ver
> [Seguridad](Sources/Nexo/Documentation.docc/Security.md)).

---

## Descubrimiento y conexión

```swift
transport.start(advertising: true, browsing: true)

Task {
    for await event in rooms.transportEvents {
        switch event {
        case .advertisementFound(let ad, _): print("Visto: \(ad.displayName)")
        case .peerConnected(let peer, _):    print("Conectado: \(peer.displayName)")
        case .peerDisconnected(let id, _, _): print("Desconectado: \(id)")
        default: break
        }
    }
}
```

`RoomService` consume `transport.events` desde su init y aplica cada evento a las
salas. Tu app **no** debe iterar `transport.events`: le quitaría eventos a Nexo.
`rooms.transportEvents` admite varios suscriptores y entrega cada evento después
de aplicarlo, sin los que quedaron de una sesión ya parada (epoch anterior) y sin
los envelopes recibidos (`.received`).

Al pasar a segundo plano, para el transporte y suspende las salas. La membresía
se conserva para recuperarla al volver:

```swift
transport.stop()
rooms.suspend()        // olvida anuncios y peers, conserva las salas
// al volver a primer plano:
transport.start(advertising: true, browsing: true)
```

---

## Estado en SwiftUI

`RoomsModel` es opcional: una copia `@MainActor @Observable` del estado de
`RoomService`, lista para usar en vistas. Expone `lifecycle`,
`localNetworkPermission`, `advertisements`, `connectedPeers`, `sessionIDs`,
`availableRooms`, `activeRoomID`, `joinProgress` y `roomStates`.

```swift
// Guarda el RoomSnapshot de cada sala tal cual
let model = RoomsModel(service: rooms)

// O deriva un estado propio por sala. `makeState` corre en NexoActor, fuera del
// hilo principal, y recibe el estado anterior para reutilizar trabajo.
let model = RoomsModel(service: rooms) { snapshot, previous in
    ChatState(snapshot: snapshot, previous: previous)
}

model.onTransportEvent = { event in /* lógica propia ante cambios de red */ }
model.onRoomsChanged = { /* cambió la lista de salas o alguna sala */ }
```

`model.notices` entrega los mismos avisos que `rooms.notices`, con una garantía
más: cuando llega un aviso, `roomStates` ya refleja lo que anuncia (una
`.joinRequest` ya está en `pendingJoinRequests`). Al suspender el transporte,
llama a `model.clearPeers()`.

---

## Salas y chat

```swift
// Crear
let room = rooms.createRoom(name: "Partida", features: .full, accessPolicy: .open)

// Observar el estado de una sala (snapshots Sendable para la UI)
Task {
    for await snapshot in room.snapshots {
        render(messages: snapshot.chatMessages, members: snapshot.members)
    }
}

// Chat
room.chat?.send(text: "Hola a todos")
```

### Unirse a una sala

```swift
let joinTask = Task {
    do {
        let joined = try await rooms.join(discoveredRoom)
        open(joined)
    } catch {
        show(error)   // RoomError
    }
}

// Botón "Cancelar": Nexo retira la solicitud en el host.
joinTask.cancel()
```

Mientras la entrada está en curso, la sala sigue en `availableRooms` y
`joinProgress[room.id]` indica la fase: `.connecting` (abriendo la conexión con
el host, hasta 15 s) y `.awaitingApproval` (esperando respuesta, hasta 120 s).
Solo desaparece de la lista cuando ya estás dentro. Al cancelar, `join` lanza
`.transportFailure(.connectionClosed)`; si la cancelación fue del usuario, no
hace falta mostrar nada.

| Error | Qué ha pasado |
|---|---|
| `peerUnavailable` | El host ya no se anuncia, o su anuncio no corresponde a la sala. |
| `hostUnreachable(reason)` | No se pudo conectar con el host; `.handshakeTimedOut` si se agotaron los 15 s. |
| `connectionLost` | Se cortó la conexión con el host mientras esperabas su respuesta. |
| `joinTimedOut` | El host no respondió a tiempo. |
| `joinRejected(reason)` | El host rechazó la entrada. |
| `roomFull` | La sala está llena. |

### Aprobación de entrada (política `.approval`)

```swift
for await notice in rooms.notices {
    switch notice {
    case .joinRequest(let request):
        showToast(request)            // request.requestID == RoomJoinRequest.id
    case .joinRequestResolved(let request):
        hideToast(request.requestID)  // se respondió, se retiró o la sala se cerró
    case .activityInvitation, .roomClosed:
        break
    }
}

// Al pulsar Aceptar en el aviso:
func accept(_ notice: JoinRequestNotice) {
    guard let request = rooms.session(notice.roomID)?.pendingJoinRequests
        .first(where: { $0.id == notice.requestID }) else { return }
    rooms.respond(to: request, accept: true)
}
```

`.joinRequestResolved` llega siempre que una solicitud sale de la cola, por
cualquier motivo: la respondiste aquí o en otra pantalla, el invitado canceló o se
desconectó, o la sala se cerró. Úsalo para retirar el aviso.

---

## Actividades (juegos)

```swift
extension ActivityKind { static let sudoku = ActivityKind("sudoku") }

enum SudokuMessage: Codable, Sendable {
    case move(row: Int, col: Int, value: Int)
    case board(SudokuBoard)
}

final class SudokuActivity: GenericActivity<SudokuMessage> {
    private var board = SudokuBoard()

    // Nexo reenvía este estado al reconectar / migrar host:
    override func currentStateSnapshot() -> SudokuMessage? { .board(board) }
}

rooms.registerActivity(.sudoku) { context in SudokuActivity(context: context) }

// Iniciar
let activity = try rooms.startActivity(kind: .sudoku, in: room.roomID)

// Consumir eventos
if let sudoku = activity as? SudokuActivity {
    Task {
        for await event in sudoku.events {
            if case .message(let msg, let from) = event { apply(msg, from) }
        }
    }
    // Enviar, con destino explícito
    sudoku.send(.move(row: 0, col: 1, value: 5), to: .everyone)
    sudoku.sendState(.board(board), coalescingKey: "board")  // estado reemplazable
}
```

Los eventos que llegan antes de que alguien lea `events` se guardan (hasta 256) y
se entregan en orden al primer lector. Por ejemplo, si otro jugador marca "listo"
mientras tu vista aún se está montando, ese evento no se pierde, así que no hace
falta reenviar el estado cada pocos segundos por si alguien no lo recibió.

---

## Streams binarios

Para datos densos (un mapa generado, estado de juego complejo, media) sin pasar
por JSON. Van por una segunda conexión TCP con el mismo peer, cifrada con la
misma TLS-PSK, así que enviar 10 MB no retrasa el chat ni las órdenes del juego.

```swift
// Emisor: el destinatario debe ser miembro de la sala
let writer = try await rooms.openByteStream(
    to: rivalDeviceID, in: room.roomID, mimeType: "application/x-map", name: "mapa"
)
for block in blocks {
    try await writer.send(block)   // vuelve cuando el sistema acepta los bytes
}
try await writer.finish()          // o `await writer.cancel()` para abortar

// Receptor: un único consumidor para toda la app
Task {
    for await incoming in rooms.incomingByteStreams {
        // incoming.descriptor (roomID, mimeType, name), incoming.senderDeviceID
        Task {
            for try await chunk in incoming.stream { apply(chunk) }
        }
    }
}
```

- `openByteStream` lanza `RoomError` (`roomNotFound`, `notAMember`,
  `transportFailure`); el writer lanza `ByteStreamError`.
- `send` trocea en frames de 64 KB. Las escrituras son secuenciales: esperar a
  cada `send` frena al productor si el receptor va lento. Dos `send` a la vez en
  el mismo writer lanzan `.concurrentWrite`.
- Hasta 8 streams abiertos a la vez en cada sentido por peer; el noveno lanza
  `.capacityExceeded`.
- Si un lector acumula unos 16 MB sin leer (256 trozos), Nexo cancela solo ese
  stream. Si el lector deja de iterar, el escritor recibe `.closed` en su
  siguiente `send`.
- `RoomService` solo entrega streams cuyo emisor es miembro unido de
  `descriptor.roomID`; el resto se descarta y el emisor recibe la cancelación.

---

## Transferencia de archivos

Las transferencias van por la conexión de control (cifrada con PSK), troceadas
con control de flujo. Requieren `RoomFeatures.fileTransfer` y enchufar el servicio:

```swift
let transfers = FileTransferService()
rooms.bindTransfers(transfers)   // retén `transfers` tú: RoomService lo referencia débilmente

let attachment = try await transfers.offer(
    fileURL: url, mimeType: "image/jpeg", in: room
)
room.chat?.send(attachment: attachment, caption: "Mira esto")

// Progreso
if let state = transfers.state(of: attachment.transferID) { /* .transferring(progress) ... */ }
```

---

## Diagnóstico

Nexo escribe en OSLog con el subsistema `com.nexo`:

| Categoría | Qué registra |
|---|---|
| `connection` | Cada conexión física: apertura, cambios de estado, `waiting`, hello recibido, quién la cerró y por qué, despedida o fin de datos del otro lado. |
| `rooms` | Pasos de cada entrada a sala y sus fallos. |
| `transport` | Fallos generales de la pila de red (listener o browser caídos). |
| `permissions` | Comprobaciones del permiso de red local. |

En la app Consola, filtra por `subsystem:com.nexo` y `category:connection`. Desde
Terminal:

```sh
log stream --predicate 'subsystem == "com.nexo" AND category == "connection"' --level info
```

Los mensajes de BoringSSL del tipo "Clearing PSK identity" aparecen al cerrar
cualquier conexión TLS. No indican que se rechazara la PSK; el motivo real del
cierre está en la línea `closed … reason=` de `connection`.

---

## Límites del protocolo

| Parámetro | Límite |
|-----------|--------|
| Mensaje máximo | 512 KB |
| Archivo máximo | 25 MB |
| Chunk de transferencia | 32 KB |
| Frame de stream binario | 64 KB |
| Streams binarios simultáneos por peer y sentido | 8 |
| Historial de chat | 500 mensajes |
| Timeout de handshake | 12 s |
| Conexión con el host al entrar (`joinConnectTimeout`) | 15 s |
| Respuesta del host al entrar (`joinApprovalTimeout`) | 120 s |
| Re-entrada automática tras reconectar (`joinTimeout`) | 30 s |
| Gracia de reconexión | 60 s |

## Requisitos

- iOS 26+ / macOS 26+, Swift 6.4+
- Network framework con soporte P2P
- Sin dependencias externas (CryptoKit del sistema para PSK)
