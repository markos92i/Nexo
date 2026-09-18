# Arquitectura de Comunicación Híbrida

Nexo usa un sistema de transporte dual optimizado para diferentes tipos de datos.

## Visión General

```
┌─────────────────────────────────────────────────────────────┐
│                      Capa de Aplicación                     │
├─────────────────────────────────────────────────────────────┤
│  RoomCoordinator  │  ChatSession  │  Activities  │  Files   │
├─────────────────────────────────────────────────────────────┤
│                         RoomOutbox                          │
│              (serialización, colas, coalescing)             │
├──────────────────────────┬──────────────────────────────────┤
│    Control Channel       │      Binary Channel              │
│   (TCP + TLS + JSON)     │    (QUIC + TLS + Frames)         │
├──────────────────────────┼──────────────────────────────────┤
│  • Mensajes pequeños     │  • Streams de datos grandes      │
│  • Orden garantizado     │  • Multiplexado                  │
│  • Latencia baja         │  • Throughput alto               │
│  • Metadatos             │  • Binarios sin encoding         │
└──────────────────────────┴──────────────────────────────────┘
                              │
                      ┌───────┴───────┐
                      │    Bonjour    │
                      │   (mDNS/DNS-SD)│
                      └───────────────┘
```

## Canal de Control (TCP + JSON)

El canal principal usa TCP con framing JSON sobre TLS:

```swift
Coder(P2PFrame.self, using: .json) {
    TLS {
        TCP { IP() }
    }
}
```

### Características

- **Confiable**: TCP garantiza entrega y orden
- **Estructurado**: JSON permite tipos Codable arbitrarios
- **Bajo overhead para mensajes pequeños**: headers mínimos
- **Conexión persistente**: una conexión por peer sirve todas las salas

### Tipos de Mensajes

| Canal | Uso | Ejemplo |
|-------|-----|---------|
| `.control` | Gestión de salas, membresía | JoinRoom, LeaveRoom |
| `.chat` | Mensajes de texto | ChatMessage |
| `.activity` | Estado de juegos/actividades | GameMove, BoardState |
| `.fileTransfer` | Metadatos de archivos | FileOffer, FileChunk |

### Formato de Frame

```swift
struct P2PFrame: Codable {
    let kind: Kind          // hello, envelope, goodbye
    var hello: HelloBody?
    var envelope: RoomEnvelope?
    var goodbye: GoodbyeBody?
}

struct RoomEnvelope: Codable {
    let protocolVersion: UInt8
    let roomID: RoomID
    let activityID: ActivityID?
    let channel: RoomChannel
    let messageID: UUID
    let senderApplicationID: String
    let sequence: UInt64?
    let deliveryMode: DeliveryMode
    let coalescingKey: String?
    let payload: Data       // JSON del mensaje específico
}
```

## Canal Binario (QUIC)

Para datos grandes, Nexo abre streams QUIC paralelos:

```swift
QUIC(alpn: ["nexo-binary-v1"]) {
    UDP { IP() }
}
```

### Características

- **Multiplexado**: Múltiples streams independientes
- **Sin head-of-line blocking**: Un stream lento no bloquea otros
- **0-RTT**: Reconexiones rápidas
- **Binario nativo**: Sin encoding Base64

### Cuándo usar QUIC

| Escenario | Canal |
|-----------|-------|
| Mensaje de chat de texto | TCP/JSON |
| Imagen adjunta en chat | QUIC |
| Movimiento de juego | TCP/JSON |
| Estado completo del tablero | TCP/JSON (coalescado) |
| Archivo grande (>100KB) | QUIC |
| Stream de audio en vivo | QUIC |

### Formato de Frame Binario

```swift
struct NexoBinaryFrame {
    enum Kind: UInt8 {
        case open = 1       // Inicio de stream
        case data = 2       // Chunk de datos
        case finish = 3     // Fin normal
        case cancel = 4     // Cancelación
        case handshake = 5  // Autenticación QUIC
    }
    
    let kind: Kind
    let streamID: UUID
    let payload: Data
}

// Wire format: [4B length][1B kind][16B UUID][payload...]
```

## Coalescing y Prioridad

### Coalescing

Para datos que se actualizan frecuentemente (posición del cursor, estado de juego), Nexo fusiona mensajes pendientes:

```swift
outbox.sendCoalesced(
    boardState,
    channel: .activity,
    coalescingKey: "board-\(gameID)"
)
```

Si un nuevo estado llega antes de enviar el anterior, el antiguo se descarta. Esto evita que estados obsoletos bloqueen la cola.

### Prioridad por Lanes

```swift
enum TransportLane: Int {
    case control = 0      // Membresía, siempre primero
    case interactive = 1  // Chat, órdenes de juego
    case bulkState = 2    // Snapshots grandes
    case transfer = 3     // Archivos, nunca bloquea otros
}
```

## Handshake Completo

```
Dispositivo A                           Dispositivo B
     │                                       │
     │◄──────── Bonjour Discovery ──────────►│
     │                                       │
     │──────── TCP Connect ─────────────────►│
     │◄─────── TCP Accept ──────────────────│
     │                                       │
     │◄──────── TLS Handshake ─────────────►│
     │    (certificados autofirmados)        │
     │                                       │
     │──────── Hello (appID, caps) ─────────►│
     │◄─────── Hello (appID, caps) ─────────│
     │                                       │
     │     [Conexión de control lista]       │
     │                                       │
     │──────── JoinRoomRequest ─────────────►│
     │◄─────── JoinRoomAccepted ────────────│
     │                                       │
     │──────── QUIC Connect ────────────────►│
     │◄─────── QUIC Accept ─────────────────│
     │◄─────── QUIC Handshake ─────────────►│
     │                                       │
     │     [Canales TCP y QUIC listos]       │
```

## Reconexión y Recuperación

Nexo mantiene la membresía lógica durante desconexiones temporales:

```swift
// Configuración
P2PLimits.temporaryDisconnectGracePeriod = 60  // segundos
P2PLimits.recoveryJournalRetention = 60
P2PLimits.recoveryChatMessageLimit = 100
```

Al reconectar:
1. El host reenvía membresía actual
2. El host reenvía historial de chat reciente
3. Las actividades reinician desde su último estado conocido

## Límites de Protocolo

```swift
enum P2PLimits {
    static let maximumEnvelopeBytes = 512 * 1024  // 512KB por mensaje
    static let maximumTransferBytes = 25 * 1024 * 1024  // 25MB por archivo
    static let transferChunkBytes = 32 * 1024  // 32KB chunks
    static let transferWindowChunks = 8  // Backpressure
}
```

## Mejores Prácticas

### Para Juegos

```swift
// Movimientos: confiable, en orden
outbox.send(move, channel: .activity)

// Estado del tablero: último gana
outbox.sendCoalesced(
    fullBoardState,
    channel: .activity,
    coalescingKey: "board"
)
```

### Para Chat con Imágenes

```swift
// 1. Enviar metadatos por TCP
let attachment = try fileService.offer(imageData, in: session)
chatSession.send("¡Mira esta foto!", attachment: attachment)

// 2. La imagen viaja por QUIC automáticamente
// FileTransferService maneja la transferencia
```

### Para Streaming en Vivo

```swift
// Abrir stream QUIC dedicado
let stream = try await transport.openBinaryStream(
    to: peer.applicationID,
    descriptor: NexoStreamDescriptor(
        roomID: roomID,
        mimeType: "audio/opus",
        name: "voice"
    )
)

// Enviar chunks de audio
for await audioChunk in audioSource {
    try await stream.send(audioChunk)
}
try await stream.finish()
```
