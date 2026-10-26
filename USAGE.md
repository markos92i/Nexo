# Guía de uso de Nexo

Comunicación P2P en iOS/macOS sin Internet. Esta guía asume el modelo actual:
cifrado PSK, identidad de dispositivo gestionada por la librería, sin TOFU.

## Índice

1. [Configuración inicial](#configuración-inicial)
2. [Permisos](#permisos)
3. [Identidad y cifrado](#identidad-y-cifrado)
4. [Descubrimiento y conexión](#descubrimiento-y-conexión)
5. [Salas y chat](#salas-y-chat)
6. [Actividades (juegos)](#actividades-juegos)
7. [Transferencia de archivos](#transferencia-de-archivos)

---

## Configuración inicial

### Info.plist

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Nexo necesita la red local para descubrir y conectar con dispositivos cercanos.</string>
<key>NSBonjourServices</key>
<array>
    <string>_nexo._tcp</string>
    <string>_nexo._udp</string>
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
    displayName: identity.displayName
)
let rooms = RoomService(transport: transport, identity: identity)
```

> La seguridad vive en el secreto: quien no lo conoce no se conecta. Para
> confirmar que estás en la sala correcta, compara el `room.shortCode` de viva voz.

---

## Descubrimiento y conexión

```swift
transport.start(advertising: true, browsing: true)

Task {
    for await event in transport.events {
        switch event {
        case .advertisementFound(let ad, _): print("Visto: \(ad.displayName)")
        case .peerConnected(let peer, _):    print("Conectado: \(peer.displayName)")
        case .peerDisconnected(let id, _, _): print("Desconectado: \(id)")
        default: break
        }
    }
}
```

El enrutado de salas lo consume `RoomService` internamente; tu app observa las
salas por `rooms.snapshots` y `rooms.notices`.

---

## Salas y chat

```swift
// Crear
let room = rooms.createRoom(name: "Partida", features: .full, accessPolicy: .open)

// Unirse a una descubierta
let joined = try await rooms.join(discoveredRoom)

// Observar el estado de una sala (snapshots Sendable para la UI)
Task {
    for await snapshot in room.snapshots {
        render(messages: snapshot.chatMessages, members: snapshot.members)
    }
}

// Chat
room.chat?.send(text: "Hola a todos")
```

Aprobación de entrada (política `.approval`):

```swift
for await notice in rooms.notices {
    if case .joinRequest(let request) = notice {
        rooms.respond(to: /* RoomJoinRequest */, accept: true)
    }
}
```

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

---

## Transferencia de archivos

Las transferencias van por el canal principal (cifrado con PSK), troceadas con
control de flujo. Requieren `RoomFeatures.fileTransfer` y enchufar el servicio:

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

## Límites del protocolo

| Parámetro | Límite |
|-----------|--------|
| Mensaje máximo | 512 KB |
| Archivo máximo | 25 MB |
| Chunk de transferencia | 32 KB |
| Historial de chat | 500 mensajes |
| Timeout de handshake | 12 s |
| Timeout de join | 30 s |
| Gracia de reconexión | 60 s |

## Requisitos

- iOS 26+ / macOS 26+, Swift 6.4+
- Network framework con soporte P2P
- Sin dependencias externas (CryptoKit del sistema para PSK)
