# Diseño — Rewrite de Nexo

## Visión general

Nexo se reorganiza en **cuatro capas** con dependencias estrictamente
descendentes. Cada capa conoce solo el contrato de la de abajo, nunca al revés.
La capa inferior no sabe qué es una sala; la capa de salas no sabe qué es un
juego.

```
┌─────────────────────────────────────────────────────────────┐
│  Capa 4 — Actividades (extensibilidad)                        │
│  Activity, GenericActivity<Message>, ActivityRegistry         │
│  El consumidor define juegos aquí. Payload opaco hacia abajo. │
├─────────────────────────────────────────────────────────────┤
│  Capa 3 — Salas (dominio)                                     │
│  RoomService (fachada) → colaboradores especializados         │
│  Room, RoomChat, RoomOutbox, FileTransfer                     │
├─────────────────────────────────────────────────────────────┤
│  Capa 2 — Protocolo                                           │
│  Envelope, ControlMessage, modelos Codable, errores tipados   │
├─────────────────────────────────────────────────────────────┤
│  Capa 1 — Transporte (neutral)                                │
│  Transport (protocolo) → NetworkTransport                     │
│  Descubrimiento Bonjour, conexiones, cifrado PSK, lanes, QUIC │
└─────────────────────────────────────────────────────────────┘
```

**Principio rector del rewrite**: la *forma* (tipos, nombres, fronteras,
concurrencia, errores) se reescribe limpia; los *algoritmos* de red probados
(recuperación, migración de host, mesh, coalescing, presupuesto TXT) se portan
preservando su comportamiento observable.

### Decisión: iOS 26 vs 27

Se mantiene **iOS 26 mínimo**. Revisado el soporte de PSK: en Network framework
PSK opera sobre TLS 1.2, y no hay evidencia de que iOS 27 habilite PSK sobre TLS
1.3 ni de que aporte otra mejora concreta para este caso. Subir a 27 reduciría el
público sin beneficio claro. Si durante la implementación de la capa de cifrado
se descubre un beneficio concreto en 27, se reconsidera entonces.

---

## Nomenclatura

Se abandona la mezcla actual (`Nexo*`, `P2P*`, `Room*` sin criterio). Regla:

- **Sin prefijo** para los tipos de dominio público (`Transport`, `Room`,
  `Activity`, `Envelope`, `DeviceID`, `RoomID`). El `import Nexo` ya da el
  espacio de nombres.
- **Prefijo `Network`** solo para la implementación concreta sobre
  `Network.framework` (`NetworkTransport`), para distinguirla del contrato.
- Los errores tipados se nombran `<Operación>Error` o `<Capa>Error`
  (`TransportError`, `RoomError`, `ActivityError`, `IdentityError`,
  `FileTransferError`).

Tabla de renombrados principales:

| Actual | Nuevo | Motivo |
|---|---|---|
| `PeerTransport` | `Transport` | El prefijo "Peer" es redundante; todo es peer. |
| `NetworkPeerTransport` | `NetworkTransport` | Igual. |
| `RoomCoordinator` (God object) | `RoomService` + colaboradores | Descomposición. |
| `LocalP2PIdentity` | `LocalIdentity` | "P2P" es redundante en una lib P2P. |
| `NexoLocalTLSIdentity` | (eliminado) | Reemplazado por `SessionCrypto` (PSK). |
| `NexoPeerVerificationService` | (eliminado) | Sin TOFU. |
| `NexoTLSConfiguration` | `SessionCrypto` | Encapsula PSK, `Sendable` real. |
| `applicationID` (String) | `DeviceID` | Tipo fuerte, generado por la lib. |
| `NexoReason` | `DisconnectReason` | Lo que es: razón de corte/rechazo. |
| `P2PProtocolInfo` | `ProtocolInfo` | — |
| `P2PLimits` | `Limits` | — |
| `RoomActivity` (protocolo) | `Activity` | — |
| `ActivityKind` | `ActivityKind` | Se mantiene. |

> Nota: `applicationID` como String se sustituye por el tipo `DeviceID` en toda
> la pila. En el protocolo serializado se codifica como su UUID subyacente para
> mantener compatibilidad de formato.

---

## Capa 1 — Transporte

### Contrato `Transport`

```swift
public protocol Transport: Sendable {
    var events: AsyncStream<TransportEvent> { get }
    var epoch: UInt64 { get }
    var connectedPeers: [ConnectedPeer] { get }

    func start(advertising: Bool, browsing: Bool)
    func stop()
    func updateAdvertisement(_ record: AdvertisementRecord)
    func refreshDiscovery()

    func connect(to advertisement: PeerAdvertisement) async throws(TransportError) -> ConnectedPeer
    func disconnect(deviceID: DeviceID, reason: DisconnectReason?)

    func enqueue(_ envelope: Envelope, to deviceID: DeviceID)
}
```

Se conserva el diseño actual (acertado): métodos síncronos que encolan y
retornan, lectura síncrona de `epoch`/`connectedPeers`, un único `AsyncStream`
de eventos con `epoch` embebida. Cambios:

- `connect` pasa a **typed throws** (`throws(TransportError)`).
- `AnyObject` se elimina del protocolo; `Sendable` basta.
- IDs de peer pasan a `DeviceID`.

### `NetworkTransport` (actor)

Implementación sobre Network framework, confinada a su propio `actor` (como hoy).
Se porta la lógica existente de:
- Gestión de listener/browser Bonjour con reintentos por pieza.
- Una conexión física por peer (`Box` interno), descartando eventos de conexiones
  reemplazadas vía `connectionSessionID`.
- Cola de envío con lanes priorizados (`TransportSendQueue`) y coalescing.

**Eliminación de `@unchecked Sendable`**: el `Box` interno actual es `@unchecked
Sendable`. Al estar ya confinado al actor, se rediseña como tipo no-`Sendable`
que vive solo dentro del actor; las tareas hijas capturan únicamente identidad
inmutable (`connectionSessionID`, `DeviceID`), no el `Box`. Donde haga falta
estado compartido con un closure de C se usa `Mutex` (ya se hace en varios sitios).

### Cifrado: `SessionCrypto` (PSK)

Reemplaza `NexoTLSConfiguration` + `NexoLocalTLSIdentity` + swift-certificates.

```swift
public struct SessionCrypto: Sendable {
    // Secreto de app (compilado en el binario del consumidor).
    public init(appSecret: Data)
    // Secreto de app + código de sala → PSK aislada por sala.
    public init(appSecret: Data, roomCode: String)
}
```

Derivación:

```
PSK      = HMAC-SHA256(key: appSecret, message: roomCode ?? "")
pskHint  = SHA256(PSK).prefix(16)   // identificador público del PSK, no secreto
```

Aplicación al transporte (patrón oficial de Apple para P2P):

```swift
sec_protocol_options_add_pre_shared_key(options, pskDispatchData, hintDispatchData)
sec_protocol_options_append_tls_ciphersuite(options, TLS_PSK_WITH_AES_128_GCM_SHA256)
```

- `appSecret` lo aporta el consumidor (constante de su app). La librería no lo
  genera ni lo persiste.
- `roomCode` sale del `shortCode` del `RoomID` (o uno elegido por el host).
- `SessionCrypto` es `Sendable` de verdad: solo contiene `Data` inmutable. No hay
  `sec_identity_t` que envolver, así que desaparece el `@unchecked Sendable`.

**Implicación en el descubrimiento**: con PSK, el cifrado depende del `roomCode`,
pero una conexión física sirve a varias salas. Decisión de diseño: se establece
**un canal cifrado por combinación app+sala** cuando el consumidor usa salas
aisladas, o **un canal por app** cuando solo hay `appSecret`. El detalle de cómo
Bonjour anuncia salas sin revelar el `roomCode` (se anuncia el `RoomID` público,
no el secreto) se preserva del diseño actual: el TXT ya publica `RoomID`, no claves.

> Punto a validar en implementación con dos dispositivos: el flujo exacto de
> selección de PSK cuando un peer ve varias salas del mismo host. Enfoque previsto:
> el `roomCode` se negocia por el `RoomID` ya visible en el anuncio; si el intento
> de conexión usa el PSK equivocado, el handshake falla y se reintenta con el de la
> sala objetivo.

### QUIC para streaming binario de alta velocidad

Canal binario separado del canal principal TCP/PSK, para datos densos y de alta
frecuencia: streaming de estado de juego complejo (muchos datos por frame),
media, o archivos grandes. Ventajas sobre el canal principal: sin overhead de
JSON, sin head-of-line blocking con control/chat, control de flujo propio de QUIC.

**Cifrado con PSK, igual que el canal principal** (NO certificados). Se confirmó
en el SDK que `NWProtocolQUIC.Options.securityProtocolOptions` permite
`sec_protocol_options_add_pre_shared_key`. Los streams QUIC con la API clásica se
manejan con `NWMultiplexGroup` + `NWConnectionGroup`: cada stream es una
`NWConnection` extraída del grupo (`extractConnection`/`newConnectionHandler`). Se
elimina toda la autenticación por fingerprint de certificado del QUIC antiguo
(innecesaria con PSK: la pertenencia la garantiza el handshake PSK).

Renombrados: `NexoQUICBinaryTransport` → `QUICChannel`, `NexoByteStream` →
`ByteStream`. El `@unchecked Sendable` de `ByteStream.Source` se elimina
confinando la continuación en un actor o `Mutex`.

**Canal binario como servicio de la sala (no de la actividad).** El tubo binario
de alta velocidad se pide al nivel de sala (`RoomService`/`Room`), no desde dentro
de la actividad. Razón de producto: siempre hay sala de por medio (se crea, la
gente se une, y ahí dentro se juega); el transporte —normal y binario— lo provee
la sala, igual que el chat y la membresía. La actividad es inquilina de la sala y
no conoce el `QUICChannel`.

```swift
let stream = try await roomService.openByteStream(to: rival, in: roomID, descriptor: ...)
for chunk in frames { try await stream.send(chunk) }
```

**Riesgo y fallback.** PSK sobre QUIC usa TLS 1.3, y el soporte PSK de Apple era
históricamente TLS 1.2; que el handshake QUIC+PSK negocie solo se confirma en
hardware. Si no levanta, la actividad cae al canal principal TCP/PSK para esos
datos (más lento pero funcional). Las transferencias de archivos del chat ya van
por el canal principal por chunks (32 KB, ventana + ACKs), así que no dependen de
QUIC; QUIC las acelera cuando está disponible.

### Eventos

```swift
public enum TransportEvent: Sendable {
    case advertisementFound(PeerAdvertisement, epoch: UInt64)
    case advertisementUpdated(PeerAdvertisement, epoch: UInt64)
    case advertisementLost(TransportPeerID, epoch: UInt64)
    case peerConnected(ConnectedPeer, epoch: UInt64)
    case peerDisconnected(deviceID: DeviceID, reason: DisconnectReason?, epoch: UInt64)
    case received(Envelope, from: ConnectedPeer, epoch: UInt64)
    case lifecycleChanged(ConnectivityLifecycle, epoch: UInt64)
    case localNetworkPermissionChanged(LocalNetworkPermission, epoch: UInt64)
}
```

Idéntico al actual salvo nombres. `connectedPeers` deja de exponer
`certificateFingerprint` (ya no hay cert); si se quiere un identificador del canal
se expone `pskHint` (derivado público del PSK), que confirma "misma sala", no
identidad de dispositivo.

---

## Capa 2 — Protocolo

Se portan los modelos `Codable` (`Envelope`, `ControlMessage` y payloads,
`RoomDescriptor`, `RoomMember`, `ActivityDescriptor`, etc.) con decodificación
tolerante ya presente (`decodeIfPresent` para campos nuevos). Cambios:

- `RoomError` se **extrae** de `RoomControlMessage.swift` a su propio archivo de
  errores; los mensajes de protocolo no comparten archivo con los errores.
- `NexoReason` → `DisconnectReason`, se mantiene `Codable/Sendable/Equatable`.
- `P2PCoder` → `WireCoder`, mismos coders JSON reutilizados.
- Lanes (`TransportLane`), canales (`Channel`), `DeliveryMode`, coalescing: se
  conservan íntegros (son correctos y clave para el rendimiento del juego).

El formato de cable (wire format) se mantiene compatible salvo el cambio de
`applicationID` String ↔ `DeviceID` UUID, que se codifica como UUID.

---

## Capa 3 — Salas: descomposición del God object

`RoomCoordinator` (2132 líneas) se parte en una **fachada** `RoomService` que
delega en colaboradores. La fachada mantiene la API pública; los colaboradores son
`internal`. Todos corren en `@NexoActor` (se mantiene el nombre por familiaridad).

**La descomposición fina NO se congela en este diseño.** Separar mal es peor que
no separar: si dos "colaboradores" acaban leyendo y escribiendo el mismo estado
central (`sessions`, `connectedPeers`, `pendingJoins`) constantemente, no se ha
desacoplado nada, solo se ha repartido el God object en varios archivos acoplados.
La granularidad real (si son 2, 3 o 5 piezas y dónde van las fronteras) debe salir
de un **análisis de acoplamiento sobre el código real**, no de la intuición.

Por eso la Capa 3 se implementa en dos sub-fases:

#### 4a — Descubrimiento separado (confirmado)

`DiscoveryService` se formaliza como colaborador limpio. Es el candidato de menor
riesgo: trabaja sobre su propio estado (el directorio de salas, los anuncios) y
apenas toca la membresía ni las sesiones vivas. De hecho `RoomDirectory` **ya es un
tipo separado** en el código actual (`Rooms/RoomDirectory.swift`); el coordinador
solo lo usa. La frontera ya existe, solo se formaliza.

```
DiscoveryService (@NexoActor, internal)
    directorio de salas, anuncios Bonjour, filtrado por actividad
    (porta RoomDirectory + advertisedRoomDescriptors)
```

> **openByteStream cableado**: `RoomService.openByteStream(to:in:)` + capacidad
> opcional `BinaryStreamOpening` del transporte. El `NetworkTransport` gestiona un
> `QUICChannel` por peer (endpoint de servicio Bonjour `_nexo._udp` derivado del
> deviceID), bidireccional: los streams entrantes se reenvían a
> `incomingByteStreams`. Pendiente solo de validación PSK+QUIC en hardware.

#### 4b — Resto del coordinador (descomposición acordada tras análisis)

El análisis de acoplamiento sobre el código real mostró que enrutado, membresía,
recuperación y migración comparten el mismo estado central (`sessions` +
`connectedPeers`) de forma intensa: separarlos en objetos independientes sería
acoplamiento disfrazado (se pasarían los diccionarios constantemente). Solo dos
fronteras tienen estado compartido bajo. Descomposición final: **3 piezas**.

```
RoomService (@NexoActor, fachada pública)
│  Posee el estado central: sessions, connectedPeers, pendingJoins, outboxes.
│  API pública: createRoom, join, leave, startActivity, snapshots, notices.
│  La lógica de membresía + recuperación + migración es UN núcleo cohesionado
│  (comparten demasiado estado para separarlos sin dañarlos), pero se organiza
│  en extensiones por tema para que se lea separada:
│    RoomService.swift              (estado, init, API pública, snapshots)
│    RoomService+Membership.swift   (join/leave/approval/admit, mesh)
│    RoomService+Recovery.swift     (journal, deadlines, replay, lifecycle)
│    RoomService+Migration.swift    (elección + aplicación de migración de host)
│    RoomService+TransportEvents.swift (handle(_:) de eventos del transporte)
│
├── DiscoveryService        ✅ ya extraído (4a). Frontera limpia.
│
├── EnvelopeRouter          valida y despacha cada envelope entrante. Frontera
│                           limpia: es (envelope, peer) → efecto; no posee estado,
│                           lo recibe. Aísla el `switch` gigante de control.
│
└── ActivityCoordinator     ciclo de vida de actividades + reconciliación. Las
                            actividades tienen autoridad propia (distinta del host
                            de sala), así que su lógica es separable con poco
                            estado compartido.
```

La deduplicación de mensajes recibidos (`receivedEnvelopeIDs`) vive junto al
`EnvelopeRouter`; el journal de reenvío sigue en `RoomOutbox`.

Se descartó la opción de 5 controladores (MembershipController, RecoveryController,
HostMigration como objetos separados) porque el análisis mostró que no reduce el
acoplamiento real, solo añade archivos.

### `Room` (antes `RoomSession`)

Se porta casi igual (está bien diseñado): estado de una sala viva, snapshots
`Sendable` por `AsyncStream` (buffering newest-1), chat opcional según features.
Cambios:
- Minimizar superficie: `record`, `enqueueJoinRequest`, `apply(descriptor:)`,
  `makeActivityContext`, etc. pasan de `public` a `internal` (son mecánica del
  service, no del consumidor).
- El doble canal callback+stream (`onChange`/`onDescriptorChange` + `snapshots`)
  se unifica: los colaboradores internos pueden usar un callback `internal`, pero
  el **consumidor** solo ve `AsyncStream`. Nunca callbacks en API pública.

### `RoomOutbox`

Se porta íntegro (diseño correcto: emisor por-sala, journal de recuperación,
coalescing). Solo renombrados de tipos.

### Persistencia del historial de chat (abstracción, efímero por defecto)

El historial de chat es **efímero** en esta versión (vive en memoria, se pierde al
cerrar la app). Pero para que añadir persistencia a futuro sea *inyectar una
implementación* y no *reescribir `RoomChat`*, el acceso al historial pasa desde el
principio por una abstracción estrecha:

```swift
@NexoActor
public protocol MessageStore: Sendable {
    func messages(for roomID: RoomID) -> [ChatMessage]
    func append(_ message: ChatMessage, to roomID: RoomID)
    func replaceAll(_ messages: [ChatMessage], for roomID: RoomID)
    func clear(_ roomID: RoomID)
}
```

- **Hoy**: única implementación `InMemoryMessageStore` (por defecto; el consumidor
  no ve nada nuevo, el chat sigue siendo efímero).
- **Mañana**: una `DiskMessageStore` (SQLite/archivos) que cumpla el mismo
  protocolo, inyectada en el init del servicio. Cero cambios en `RoomChat`.

`RoomChat` deja de poseer el array de mensajes directamente; se lo pide al store.
La deduplicación y el recorte de ventana siguen en `RoomChat` (son política de
dominio, no de almacenamiento).

### Supervivencia del estado del juego en reconexión y migración de host

El estado se **replica** en cada peer mientras juega; no hay un único punto donde
viva. En una migración de host el sucesor ya tiene su copia y la proclama
autoritativa vía `roomResume`. Nexo migra automáticamente lo que conoce: el
historial de chat y el **descriptor** de la actividad (participantes, estado
lobby/running).

El **contenido** del juego (tablero, cartas, posiciones) es `Data` opaco para Nexo.
Para que sobreviva, la actividad lo expone explícitamente en vez de depender del
efecto colateral del coalescing:

```swift
open class GenericActivity<Message> {
    /// La app devuelve aquí su estado completo actual (o nil si no aplica).
    /// Nexo lo reenvía automáticamente a quien se reconecta y cuando esta
    /// instancia asume la autoridad de la actividad tras una migración.
    open func currentStateSnapshot() -> Message? { nil }
}
```

Así la persistencia-en-reconexión deja de ser magia implícita: el desarrollador
del juego tiene un punto obvio donde declarar "este es mi estado". Internamente
Nexo lo envía con `coalescingKey` latest-wins por el journal de recuperación ya
existente. Si la app no implementa `currentStateSnapshot`, el comportamiento es el
actual (sobrevive solo si la app emite snapshots a mano).

### Errores de sala (typed throws)

```swift
public enum RoomError: Error, Sendable, Equatable { ... }   // extraído a archivo propio

public func join(_ room: DiscoveredRoom) async throws(RoomError) -> Room
public func startActivity(...) throws(RoomError) -> any Activity
```

---

## Capa 4 — Actividades

### `Activity` (protocolo) y `GenericActivity<Message>`

El protocolo `Activity` se porta igual (contrato correcto). La pieza que se
**rediseña** es el stream de eventos manual.

**Problema actual**: `GenericActivity` reimplementa a mano un AsyncStream con
coalescing (`ActivityEventStorage`, ~100 líneas de `CheckedContinuation`, waiters,
barrera de orden). Es la pieza más propensa a bugs del repo.

**Rediseño**: el coalescing latest-wins ya ocurre en la capa de transporte
(`TransportSendQueue` en el emisor y `coalescingKey` en el envelope). En el lado
receptor, los eventos a la UI no necesitan re-coalescing: la UI consume snapshots
newest-1 por `AsyncStream` igual que `Room`. Por tanto `ActivityEventStorage` se
sustituye por un `AsyncStream` estándar con `bufferingPolicy: .bufferingNewest(n)`
por clave cuando aplique, o dos streams (uno fiable sin pérdida para mensajes de
orden, uno newest-1 para estado reemplazable). Esto elimina la cola manual.

```swift
public enum ActivityEvent<Message: Sendable>: Sendable {
    case message(Message, RoomMember)
    case participantJoined(RoomMember)
    case participantLeft(RoomMember)
    case descriptorUpdated(ActivityDescriptor)
    case ended(DisconnectReason)
}

@NexoActor
open class GenericActivity<Message: Codable & Sendable>: Activity {
    public nonisolated var events: AsyncStream<ActivityEvent<Message>> { ... }
    public func send(_ message: Message, coalescingKey: String? = nil, to member: RoomMember? = nil)
    ...
}
```

> A validar: si se requiere la "barrera de orden" exacta del código actual (un
> estado nuevo no adelanta a un mensaje fiable encolado), se consigue con dos
> streams separados por `DeliveryMode` en vez de la lógica de barrera manual. Es
> más simple y preserva la garantía.

### Frontera Nexo / app (decisión de producto)

Lo que Nexo resuelve de forma **estándar** (igual para toda app): descubrimiento,
conexiones cifradas, el concepto de sala de N participantes, **quién es el host y
su migración automática**, la mecánica de entrega (a uno / a varios / broadcast;
fiable o estado reemplazable) y la recuperación tras caídas.

Lo que pone **cada app** encima: qué *son* los mensajes (payload opaco para Nexo),
la *orquestación* del juego (turnos, reglas, inicio/fin de partida) y *a quién* se
envía cada cosa.

Consecuencias de diseño:

- **El host es un detalle interno de Nexo.** Mantiene viva la sala (admite
  miembros, lista canónica, arbitraje de sala) y migra solo si se cae, sin que la
  app lo note. La **API pública de actividades NO expone el host de la sala.**
- **La autoridad del juego es de la app, no de Nexo.** Si un juego necesita árbitro
  (validar jugadas, turno), lo elige la app a su nivel. Puede coincidir o no con el
  host de Nexo. Para ello la actividad tiene su propia autoridad opcional
  (`hostDeviceID` de la actividad), desacoplada del host de la sala.
- **Destino explícito por mensaje** en el outbox de la actividad, como optimización
  y privacidad (información oculta entre un subconjunto de jugadores):

  ```swift
  activity.send(message, to: .everyone)           // broadcast al grupo
  activity.send(message, to: .member(deviceID))   // uno a uno
  activity.send(message, to: .members([a, b]))    // subconjunto
  // combinable con entrega fiable (por defecto) o estado reemplazable (coalescing)
  activity.send(snapshot, to: .everyone, coalescingKey: "board")
  ```

- **Tipo de servicio Bonjour configurable por app**: el `serviceType` es un
  parámetro de configuración del transporte (no una constante), para que dos apps
  distintas basadas en Nexo no se descubran entre sí.

### `ActivityRegistry`

Se porta igual, ya está bien (fábrica por `kind`, inyectado en el init del
service, **sin singleton** pese a lo que dice el README actual). El README se
corrige.

---

## Identidad: `LocalIdentity` + `DeviceID`

```swift
public struct DeviceID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
}

@NexoActor
public final class LocalIdentity {
    public let deviceID: DeviceID
    public var displayName: String
    public var avatar: String?

    // Genera o recupera el DeviceID persistido en Keychain.
    public static func loadOrCreate(displayName: String)
        async throws(IdentityError) -> LocalIdentity
}
```

- El `DeviceID` se genera una vez (UUID) y se persiste en Keychain
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), recuperándose en arranques
  posteriores. Sustituye al `applicationID` que antes inventaba el consumidor.
- Se elimina toda la maquinaria de certificado/clave P-256/X.509 de
  `LocalP2PIdentity`. La identidad ya no es criptográfica; el cifrado lo da el PSK.

---

## Modelo de concurrencia (resumen)

| Tipo | Mecanismo | Nota |
|---|---|---|
| `NetworkTransport` | `actor` propio | Confina Bonjour, conexiones, colas. |
| `RoomService` + colaboradores | `@NexoActor` | Un ejecutor serial para la lógica. |
| `Room`, `RoomChat`, `Activity` | `@NexoActor` | — |
| `SessionCrypto`, `DeviceID`, modelos | `struct Sendable` | Inmutables. |
| Estado compartido con closures de C | `Mutex` | Sin `@unchecked Sendable`. |
| Entrega de eventos al consumidor | `AsyncStream` | Único paradigma público. |

Regla dura: **cero `@unchecked Sendable` en tipos propios**. Los tres actuales
(`Box`, `ByteStream.Source`, `NexoLocalTLSIdentity`) desaparecen: los dos primeros
por confinamiento en actor + `Mutex`, el tercero por eliminación completa.

---

## Estrategia de tests

- **Transporte mock**: `MockTransport: Transport` que emite eventos programados y
  captura envelopes encolados, para conducir salas/chat/actividades sin red real.
  Es la pieza que más faltaba: hoy no hay tests de integración de las salas.
- **Unitarios portados/nuevos**:
  - Derivación PSK: mismo `appSecret`+`roomCode` → mismo PSK; distinto `roomCode` →
    distinto PSK.
  - `DeviceID` persiste y se recupera.
  - Presupuesto TXT de Bonjour (porta la lógica de `CompactRoom`).
  - `RoomHostElection`: sucesor determinista y validación.
  - Dedupe idempotente de envelopes en recuperación.
- **Integración con mock**: crear sala → unir dos peers mock → enviar chat →
  iniciar actividad → simular caída y recuperación → verificar replay idempotente.

Herramienta: `swift-testing` (nativo en el toolchain) en vez de XCTest, salvo que
haya razón para XCTest.

---

## Plan de migración (orden de implementación)

El rewrite se hace de abajo arriba, compilando y testeando en cada escalón, para
no perder nunca el estado "compila verde":

1. **Protocolo + modelos + errores tipados** (capa 2). Sin dependencias; base de
   todo lo demás. Incluye `DeviceID`, `DisconnectReason`, `WireCoder`.
2. **Identidad** (`LocalIdentity` + `DeviceID` en Keychain) y **`SessionCrypto`
   (PSK)**. Eliminar dependencia de swift-certificates en `Package.swift`.
3. **Transporte** (`Transport` + `NetworkTransport`), con PSK integrado y QUIC
   aislado. Eliminar `@unchecked Sendable` del `Box`.
4. **Salas**, en dos sub-fases:
   - **4a**: `Room`, `RoomOutbox`, `RoomChat` y `DiscoveryService` (separación
     confirmada, bajo riesgo).
   - **4b**: análisis de acoplamiento del resto del coordinador → propuesta de
     descomposición revisada → implementación de `RoomService` + colaboradores,
     portando los algoritmos de recovery/migración/mesh.
5. **Actividades**: `Activity`, `GenericActivity` con stream estándar,
   `ActivityRegistry`.
6. **Transferencias**: `FileTransfer` sobre QUIC/fallback.
7. **Permisos**: `LocalNetworkPermission` checker (porta `NexoPermissions`).
8. **Tests** (mock transport + unitarios) y **limpieza**: borrar archivos viejos,
   actualizar README/USAGE, verificar build sin warnings bajo concurrencia estricta.

Cada escalón deja el paquete compilando. Los archivos antiguos se van sustituyendo,
no coexistiendo indefinidamente, para no duplicar superficie.

---

## Lo que se elimina

- Dependencias: `swift-certificates`, `swift-asn1` (y `swift-crypto` si no queda
  uso; `CryptoKit` cubre HMAC/SHA256).
- Archivos: `NexoPeerVerification.swift` (TOFU, formatters, QR, trust store),
  la generación de certificado/clave en `LocalP2PIdentity`, `NexoTLSConfiguration`
  basada en `sec_identity_t`.
- Conceptos: estados de verificación, "identidad cambiada", fingerprint por
  certificado, huella emoji/palabras.

## Lo que se preserva (comportamiento)

- Topología mesh con presentación de miembros por el host.
- Recuperación por journal con replay idempotente por `messageID`.
- Migración de host determinista con generaciones validables.
- Coalescing latest-wins por lane para estado de juego.
- Presupuesto de bytes de Bonjour TXT (255 B/entrada, UTF-8, sin partir chars).
- Snapshots `Sendable` newest-1 a la UI.
- Decodificación tolerante de campos nuevos (compatibilidad entre versiones).
