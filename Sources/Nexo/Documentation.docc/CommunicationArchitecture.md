# Arquitectura de comunicación

Nexo se organiza en cuatro capas con dependencias estrictamente descendentes.
Cada capa conoce solo el contrato de la de abajo.

```
Actividades   Activity, GenericActivity<Message>, ActivityRegistry
   │          (el consumidor define juegos aquí; payload opaco hacia abajo)
Salas         RoomService (fachada) + colaboradores; Room, RoomChat, RoomOutbox
   │          FileTransferService, RoomsModel (copia observable para SwiftUI)
Protocolo     Envelope, ControlMessage, modelos Codable, errores tipados
Transporte    Transport (protocolo) → NetworkTransport; Bonjour, TCP, TLS-PSK
```

`RoomService` es el único lector de `Transport.events`: empieza a consumirlo en su
init. Ese flujo no tiene límite de búfer, porque perder un `peerConnected` o un
`peerDisconnected` desincronizaría la lista de peers. La presentación se suscribe
a `RoomService.transportEvents`, que reemite cada evento ya aplicado.

## Descubrimiento

Cada app anuncia y busca su propio tipo Bonjour (`ServiceType`, p. ej.
`_project-dark._tcp`). El TXT del anuncio lleva el nombre del dispositivo y hasta
tres salas; el resto se piden por `roomDirectory` al conectar. Publicar el TXT
registra otra vez el servicio en Bonjour, así que solo se hace cuando su contenido
cambia de verdad.

## Canales

Sobre la conexión de control se multiplexan canales lógicos (`Channel`):

- **control** — membresía y ciclo de vida de salas/actividades.
- **chat** — mensajes de chat.
- **activity** — payload opaco de una actividad (lleva `activityID`).
- **fileTransfer** — chunks de transferencia de archivos.

Los envelopes se encolan en **carriles** priorizados (`TransportLane`): control >
interactivo (chat y órdenes de juego) > estado voluminoso > transferencias. Una
transferencia grande nunca bloquea una orden de juego.

## Dos conexiones por peer

Ambas son TCP con la misma TLS-PSK. El hello de cada conexión declara su
propósito (`ConnectionPurpose`):

- **Control (`.control`)** — control, chat, actividades y transferencias de
  archivos (troceadas con ventana + ACKs). Fiable y en orden. Es la que emite
  `peerConnected` / `peerDisconnected`.
- **Binaria (`.byteStreams`)** — streams binarios (`openByteStream`) en frames de
  64 KB, sin JSON. Se abre con el primer stream (la abra quien la abra, la usan los
  dos sentidos) y solo se acepta de un peer que ya tiene conexión de control, de
  la que hereda la identidad. Admite hasta 8 streams simultáneos por sentido. Nunca emite
  `peerConnected` y se cierra cuando se cierra la de control. Así, enviar un mapa
  de varios MB no retrasa el chat ni las órdenes del juego.

No se usa QUIC: con una PSK externa, el TLS de Apple solo negocia TLS 1.2 y QUIC
exige TLS 1.3, así que el handshake falla siempre con
`NO_SUPPORTED_VERSIONS_ENABLED` (comprobado en macOS 27 por loopback).

## Ciclo de vida de una conexión

- Una conexión en `.waiting` no se cierra en el acto: suele ser pasajero, por
  ejemplo mientras AWDL levanta el enlace entre dos iPhone. El timeout de
  handshake (12 s) pone el límite. Solo un permiso de red local denegado la cierra
  de inmediato.
- Con el framer de longitud, `isComplete` en `receiveMessage` marca el final de
  cada mensaje, no del flujo. Solo un contexto final (o una lectura vacía y
  completa) es fin de datos del otro lado.
- Cada apertura, cambio de estado, hello y cierre (con quién lo inició y por qué)
  queda en OSLog, subsistema `com.nexo`, categoría `connection`.

## Entrega y recuperación

- **Fiable** (`.reliable`): en orden, nunca se descarta.
- **Estado reemplazable** (`.unreliable` + `coalescingKey`): latest-wins; un
  snapshot nuevo reemplaza al pendiente, nunca adelanta a una orden fiable.
- **Recuperación**: el `RoomOutbox` mantiene un journal breve; al reconectar un
  peer, se reenvían los mensajes conservando el `messageID`, y el receptor
  descarta duplicados (idempotente).
- **Eventos de actividad sin lector**: `GenericActivity.events` guarda hasta 256
  eventos emitidos antes de que haya lector y se los entrega, en orden, al
  primero.

## Host y migración

El host es la autoridad de la sala (interno a Nexo). Si se vuelve inalcanzable, se
elige un sucesor determinista (`RoomHostElection`) a partir del orden de miembros,
con generaciones validables. El estado está replicado en cada peer, así que el
sucesor proclama su copia como autoritativa (`roomResume`) sin trasladar nada en
el momento de la caída.

## Entrada a una sala

1. `join(_:)` conecta con el host (`JoinProgress.connecting`, hasta 15 s). Si no
   lo consigue, lanza `hostUnreachable`.
2. Envía la solicitud y espera respuesta (`.awaitingApproval`, hasta 120 s). Si la
   conexión cae, lanza `connectionLost`; si el host no contesta, `joinTimedOut`.
3. Cancelar la tarea que espera `join(_:)` retira la solicitud en el host, que
   emite `RoomNotice.joinRequestResolved` para que su UI quite el aviso.

Las re-entradas automáticas tras una reconexión usan `Limits.joinTimeout` (30 s)
y no aparecen en `joinProgress`.
