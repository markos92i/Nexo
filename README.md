# Nexo

![Swift 6.4](https://img.shields.io/badge/Swift-6.4-F05138?logo=swift&logoColor=white)
![iOS 26+](https://img.shields.io/badge/iOS-26%2B-007AFF)
![SPM](https://img.shields.io/badge/SPM-Compatible-blue)

Librería P2P para iOS/macOS construida sobre Network framework (Bonjour + TCP, y
QUIC para streaming binario). Nexo resuelve lo **estándar** de cualquier app P2P
—descubrimiento, conexiones cifradas, salas de N participantes, coordinación de
host y su migración automática, entrega de mensajes y recuperación tras caídas— y
deja que **cada app** defina lo suyo encima: qué son los mensajes, cómo se
orquesta un juego y a quién se envía cada cosa.

Nexo no sabe qué es un chat, un sudoku o un movimiento de ajedrez. Eso lo pones tú.

## Qué resuelve Nexo (estándar)

- **Transporte** — descubrimiento Bonjour, una conexión física por peer,
  reconexión. `Transport` es un protocolo, así que el `NetworkTransport` por
  defecto se puede sustituir por un mock en tests.
- **Cifrado PSK** — el canal se cifra con una clave precompartida derivada de un
  secreto de app (y opcionalmente un código de sala). Sin certificados, sin
  servidor. Quien no conoce el secreto no completa el handshake.
- **Salas** — espacios lógicos de N participantes que sobreviven a reconexiones.
  Una sala no es un socket: varias salas comparten la conexión física a un peer, y
  la membresía, la autoridad de host y las capacidades (`chat`, `activities`,
  `fileTransfer`) son independientes del transporte.
- **Host interno y migración** — alguien es la autoridad de la sala (admite
  miembros, lista canónica). Si cae, otro toma el relevo automáticamente sin que la
  app lo note. La partida no se cae.
- **Entrega** — mensajes fiables y en orden por defecto, más estado reemplazable
  (`coalescingKey`) latest-wins para snapshots (tablero, posiciones) que nunca
  quedan detrás de una orden autoritativa. Destino explícito por mensaje: a uno, a
  varios o a todos.
- **Recuperación** — journal con replay idempotente por `messageID`, para que una
  caída breve de Wi-Fi no rompa el hilo.

## Qué pone tu app encima

- Los **mensajes**: Nexo transporta `Data` opaco; tu juego define su propio enum
  `Codable` y Nexo ni lo mira.
- La **orquestación** del juego: turnos, reglas, inicio y fin de partida, y quién
  es el árbitro (si lo necesitas). La autoridad del *juego* es tuya; el host de
  Nexo solo mantiene viva la *sala*.
- **A quién** se envía cada cosa (optimización y privacidad).

## Arquitectura

```
Transport            contrato de transporte neutral (NetworkTransport lo implementa)
└── RoomService      salas lógicas: descubrimiento, membresía, host, recuperación
    └── Room         una sala: miembros + chat + actividades vivas
        └── Activity una instancia por actividad (chat, un juego, ...)
```

Capas con dependencias solo hacia abajo: el transporte no sabe qué es una sala; la
sala no sabe qué es un juego.

## Instalación

Añade Nexo como paquete Swift local y enlaza el producto `Nexo` a tu target.

## Puesta en marcha

```swift
import Nexo

// 1. Identidad de dispositivo (la genera y persiste Nexo en Keychain)
let identity = try LocalIdentity.loadOrCreate(displayName: UIDevice.current.name)

// 2. Cifrado PSK: secreto de app (constante tuya) + opcional código de sala
let crypto = SessionCrypto(appSecret: "mi-secreto-de-app")

// 3. Transporte y servicio de salas
let transport = NetworkTransport(crypto: crypto, deviceID: identity.deviceID,
                                 displayName: identity.displayName)
let rooms = RoomService(transport: transport, identity: identity)

transport.start(advertising: true, browsing: true)
```

## Crear una actividad (juego)

```swift
// 1. Identificador del tipo
extension ActivityKind { static let sudoku = ActivityKind("sudoku") }

// 2. Mensajes del juego (opacos para Nexo)
enum SudokuMessage: Codable, Sendable {
    case move(row: Int, col: Int, value: Int)
    case board(SudokuBoard)
}

// 3. Subclase de GenericActivity
final class SudokuActivity: GenericActivity<SudokuMessage> {
    override func currentStateSnapshot() -> SudokuMessage? { .board(currentBoard) }
}

// 4. Registrar la fábrica
rooms.registerActivity(.sudoku) { context in SudokuActivity(context: context) }
```

Enviar con destino explícito:

```swift
activity.send(.move(row: 0, col: 1, value: 5), to: .everyone)   // a todos
activity.send(secret, to: .member(rivalDeviceID))               // a uno
activity.sendState(.board(board), coalescingKey: "board")       // estado reemplazable
```

## Seguridad

El modelo es **secreto compartido**: quien conoce `appSecret` (+ `roomCode` si se
usa) entra y descifra; quien no, no completa el handshake. No hay identidad
criptográfica por dispositivo ni verificación TOFU: comparar el código de sala en
persona ES la verificación. Trata todo payload remoto como no confiable.

## Permisos

```swift
let checker = PermissionsChecker()
await checker.checkPermissions()
if checker.status.hasCriticalDenial {
    // Mostrar checker.settingsGuidance (title/steps/settingsURL)
}
```

Info.plist:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Nexo necesita la red local para descubrir dispositivos cercanos.</string>
<key>NSBonjourServices</key>
<array>
    <string>_nexo._tcp</string>
    <string>_nexo._udp</string>
</array>
```

## Documentación

- **[USAGE.md](USAGE.md)** — guía de uso con ejemplos.
- **[Seguridad](Sources/Nexo/Documentation.docc/Security.md)** — modelo PSK.
- **[Arquitectura de comunicación](Sources/Nexo/Documentation.docc/CommunicationArchitecture.md)**.
