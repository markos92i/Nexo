# Arquitectura de comunicación

Nexo se organiza en cuatro capas con dependencias estrictamente descendentes.
Cada capa conoce solo el contrato de la de abajo.

```
Actividades   Activity, GenericActivity<Message>, ActivityRegistry
   │          (el consumidor define juegos aquí; payload opaco hacia abajo)
Salas         RoomService (fachada) + colaboradores; Room, RoomChat, RoomOutbox
   │          FileTransferService
Protocolo     Envelope, ControlMessage, modelos Codable, errores tipados
Transporte    Transport (protocolo) → NetworkTransport; Bonjour, PSK, QUIC
```

## Canales

Sobre una conexión física se multiplexan canales lógicos (`Channel`):

- **control** — membresía y ciclo de vida de salas/actividades.
- **chat** — mensajes de chat.
- **activity** — payload opaco de una actividad (lleva `activityID`).
- **fileTransfer** — chunks de transferencia de archivos.

Los envelopes se encolan en **carriles** priorizados (`TransportLane`): control >
interactivo (chat y órdenes de juego) > estado voluminoso > transferencias. Una
transferencia grande nunca bloquea una orden de juego.

## Dos transportes

- **Canal principal (TCP + PSK)** — control, chat, actividades y transferencias de
  archivos (troceadas con ventana + ACKs). Fiable y en orden.
- **Canal QUIC (PSK)** — streaming binario de alta velocidad para datos densos
  (estado de juego complejo, media). Sin overhead de JSON, sin head-of-line
  blocking con el control. Se pide al nivel de sala. Su disponibilidad en runtime
  depende de PSK+QUIC (ver Seguridad); si falla, se cae al canal principal.

## Entrega y recuperación

- **Fiable** (`.reliable`): en orden, nunca se descarta.
- **Estado reemplazable** (`.unreliable` + `coalescingKey`): latest-wins; un
  snapshot nuevo reemplaza al pendiente, nunca adelanta a una orden fiable.
- **Recuperación**: el `RoomOutbox` mantiene un journal breve; al reconectar un
  peer, se reenvían los mensajes conservando el `messageID`, y el receptor
  descarta duplicados (idempotente).

## Host y migración

El host es la autoridad de la sala (interno a Nexo). Si se vuelve inalcanzable, se
elige un sucesor determinista (`RoomHostElection`) a partir del orden de miembros,
con generaciones validables. El estado está replicado en cada peer, así que el
sucesor proclama su copia como autoritativa (`roomResume`) sin trasladar nada en
el momento de la caída.
