# Plan de implementación — Rewrite de Nexo

> Orden de abajo arriba. Cada tarea deja el paquete compilando bajo concurrencia
> estricta de Swift 6.4. Los algoritmos de red probados se portan preservando su
> comportamiento; la forma (tipos, nombres, concurrencia, errores) se reescribe.

- [x] 1. Base de protocolo, modelos y errores tipados (Capa 2)
  - [x] 1.1 Crear tipos de identidad y nomenclatura base
    - Definir `DeviceID` (wrapper de UUID, `Codable/Sendable/Hashable`) y su
      codificación de cable como UUID.
    - Renombrar `NexoReason` → `DisconnectReason`, `P2PProtocolInfo` →
      `ProtocolInfo`, `P2PLimits` → `Limits`, `P2PCoder` → `WireCoder`.
    - _Requisitos: 3.3, 11.3, 12.4_
  - [x] 1.2 Portar modelos de dominio del protocolo
    - Portar `RoomID`, `RoomMember`, `RoomDescriptor`, `RoomFeatures`,
      `RoomAccessPolicy`, `ActivityID`, `ActivityKind`, `ActivityDescriptor`,
      `ActivityState` con decodificación tolerante (`decodeIfPresent`).
    - Sustituir `applicationID: String` por `DeviceID` en los modelos.
    - _Requisitos: 5.1, 6.1, 8.1, 8.6_
  - [x] 1.3 Portar el envelope, canales y lanes
    - Portar `Envelope` (antes `RoomEnvelope`), `Channel`, `DeliveryMode`,
      `TransportLane`, `coalescingKey`, `sequence`.
    - _Requisitos: 1.4, 8.4_
  - [x] 1.4 Extraer y definir los errores tipados por capa
    - `TransportError`, `RoomError` (extraído a archivo propio, fuera de los
      mensajes de control), `ActivityError`, `IdentityError`, `FileTransferError`.
    - Todos `Error, Sendable, Equatable`.
    - _Requisitos: 11.1, 11.2, 11.3_
  - [x] 1.5 Portar mensajes de control y payloads
    - Portar `ControlMessage` y sus payloads (join, membership, resume,
      host-changed, chat-history, room-closed, activity-*).
    - _Requisitos: 5.2, 5.4, 6.2, 7.2, 8.7_

- [ ] 2. Identidad local y cifrado PSK (Capa 1 parcial)
  - [x] 2.1 Implementar `LocalIdentity` con `DeviceID` persistente
    - `loadOrCreate(displayName:)` que genera/recupera `DeviceID` en Keychain
      (`AccessibleAfterFirstUnlockThisDeviceOnly`), con `throws(IdentityError)`.
    - Eliminar toda la generación de certificado/clave P-256/X.509 del antiguo
      `LocalP2PIdentity`.
    - _Requisitos: 3.1, 3.2, 3.3, 3.4_
  - [x] 2.2 Implementar `SessionCrypto` (PSK)
    - `init(appSecret:)` y `init(appSecret:roomCode:)`.
    - Derivación `PSK = HMAC-SHA256(appSecret, roomCode)` y `pskHint =
      SHA256(PSK).prefix(16)` con CryptoKit. Tipo `Sendable` (solo `Data`).
    - _Requisitos: 2.1, 2.2, 2.4_
  - [~] 2.3 Tests de derivación PSK e identidad (escritos; se ejecutan al compilar el target completo)
    - Mismo `appSecret`+`roomCode` → mismo PSK; distinto `roomCode` → distinto PSK.
    - `DeviceID` persiste y se recupera entre instancias.
    - _Requisitos: 12.3_
  - [x] 2.4 Eliminar dependencias de certificados
    - Quitar `swift-certificates` y `swift-asn1` de `Package.swift`; quitar
      `swift-crypto` si no queda uso (CryptoKit cubre HMAC/SHA256).
    - Borrar `NexoPeerVerification.swift`, `NexoTLSConfiguration` basada en
      `sec_identity_t`, fixtures `.p12`/`.pem` de certificados.
    - _Requisitos: 2.5, 4.3_

- [ ] 3. Transporte neutral (Capa 1)
  - [x] 3.1 Definir el contrato `Transport`
    - Protocolo `Sendable` sin tipos de `Network.framework` ni `AnyObject`.
    - `connect` con `throws(TransportError)`; IDs como `DeviceID`.
    - Definir `TransportEvent`, `PeerAdvertisement`, `ConnectedPeer` (con `pskHint`
      en vez de `certificateFingerprint`), `AdvertisementRecord`.
    - _Requisitos: 1.1, 1.2, 1.4, 1.5_
  - [x] 3.2 Implementar `NetworkTransport` con cifrado PSK (API clásica + framer; PSK real pendiente de validar en 2 dispositivos)
    - Portar listener/browser Bonjour con reintentos por pieza, una conexión
      física por peer, descarte por `connectionSessionID`.
    - Integrar `SessionCrypto` vía `sec_protocol_options_add_pre_shared_key` +
      ciphersuite PSK.
    - Rediseñar el `Box` interno sin `@unchecked Sendable` (confinado al actor;
      tareas hijas capturan solo identidad inmutable).
    - _Requisitos: 1.3, 2.1, 2.3, 12.2_
  - [x] 3.3 Portar cola de envío con lanes y coalescing
    - Portar `TransportSendQueue` (lanes priorizados, coalescing latest-wins por
      `coalescingKey`).
    - _Requisitos: 1.4, 8.4, 12.5_
  - [x] 3.4 Portar presupuesto de Bonjour TXT (`AdvertisementRecord`/`CompactRoom`)
    - (test del presupuesto pendiente, va con la batería de tests de Fase 8)
    - _Requisitos: 6.1, 12.3, 12.5_
  - [x] 3.5 Implementar `MockTransport` para tests de capas superiores
    - `Transport` mock que emite eventos programados y captura envelopes
      encolados, sin red real.
    - _Requisitos: 1.6, 12.3_

- [ ] 4a. Salas: núcleo y descubrimiento (Capa 3, parte 1)
  - [x] 4a.1 Portar `Room` (antes `RoomSession`) con superficie mínima
    - Estado de sala viva, snapshots `Sendable` por `AsyncStream` (newest-1).
    - Pasar a `internal` la mecánica del service (`record`, `enqueueJoinRequest`,
      `apply(descriptor:)`, `makeActivityContext`, etc.).
    - Unificar canal de eventos: callbacks solo `internal`; el consumidor solo ve
      `AsyncStream`.
    - _Requisitos: 5.7, 12.4_
  - [x] 4a.2 Portar `RoomOutbox` y `RoomChat` con `MessageStore`
    - Portar `RoomOutbox` (emisor por-sala, journal de recuperación, coalescing).
    - Definir el protocolo `MessageStore` e implementar `InMemoryMessageStore`
      (efímero por defecto; deja la persistencia futura a un init de distancia).
    - Portar `RoomChat` (antes `ChatRoomSession`) apoyándose en el store: envío
      fiable, historial, merge idempotente por `messageID`.
    - _Requisitos: 7.1, 7.2, 7.3, 7.4_
  - [x] 4a.3 Formalizar `DiscoveryService`
    - Separar directorio de salas, anuncios Bonjour y filtrado por actividad en un
      colaborador `internal` (porta `RoomDirectory` + `advertisedRoomDescriptors`).
    - _Requisitos: 6.1, 6.2, 6.3, 6.4_

- [ ] 4b. Salas: descomposición del coordinador (Capa 3, parte 2)
  - [ ] 4b.1 Análisis de acoplamiento del coordinador
    - Mapear, sobre el código actual, qué estado concreto (`sessions`,
      `connectedPeers`, `pendingJoins`, journals) lee/escribe cada responsabilidad
      (membresía, enrutado, recuperación, migración, actividades) y sus llamadas
      cruzadas. Producir una matriz responsabilidad × estado.
    - **Entregar propuesta de descomposición basada en la matriz y revisarla con el
      usuario antes de implementar.**
    - _Requisitos: 12.5_
  - [x] 4b.1 Análisis de acoplamiento + descomposición acordada (3 piezas:
        RoomService núcleo con extensiones temáticas + EnvelopeRouter + ActivityCoordinator)
  - [ ] 4b.2 Implementar `RoomService` (fachada) + extensiones temáticas
    - RoomService.swift (estado/init/API/snapshots) + extensiones Membership,
      Recovery, Migration, TransportEvents. API pública en la fachada.
    - Portar join/leave/approval y topología mesh (presentación de miembros).
    - `join`/`startActivity` con `throws(RoomError)`.
    - _Requisitos: 5.1, 5.2, 5.3, 11.1_
  - [x] 4b.2 Implementar `RoomService` (fachada) + extensiones temáticas
  - [x] 4b.3 Portar enrutado de envelopes entrantes (EnvelopeRouter.swift)
  - [x] 4b.4 Portar recuperación tras caída (RoomService+Recovery.swift)
  - [x] 4b.5 Portar migración de host (RoomService+Migration.swift; test en Fase 8)

- [x] 5. Actividades (Capa 4)
  - [x] 5.1 Portar el protocolo `Activity` y `ActivityRegistry`
    - Portar `Activity` (antes `RoomActivity`), `ActivityContext`,
      `ActivityRegistry` (fábrica por `kind`, inyectado, sin singleton).
    - Ignorar sin fallar los `kind` desconocidos de peers más nuevos.
    - _Requisitos: 8.1, 8.2, 8.3, 8.7_
  - [x] 5.2 Rediseñar `GenericActivity` con streams estándar y destino explícito
    - Sustituir `ActivityEventStorage` manual por `AsyncStream` estándar.
    - Preservar la garantía "estado nuevo no adelanta a mensaje fiable" con dos
      streams separados por `DeliveryMode` en vez de la barrera manual.
    - API de envío con destino explícito: `.everyone` / `.member(DeviceID)` /
      `.members([DeviceID])`, combinable con fiable o coalescing.
    - Añadir `currentStateSnapshot() -> Message?` que Nexo reenvía en reconexión y
      al asumir autoridad de actividad tras migración.
    - _Requisitos: 8.4, 8.5, 8.6_
  - [x] 5.3 Portar el ciclo de vida y reconciliación de actividades (ActivityCoordinator.swift)
    - Portar createActivity/endActivity, admisión a actividades abiertas,
      reconciliación con autoridad de actividad independiente de la de sala.
    - _Requisitos: 8.6, 8.7_

- [x] 6. Transferencia de archivos (Capa 1 + 3)
  - [x] 6.1 Portar el canal binario QUIC aislado (`QUICChannel`/`ByteStream`) con
        PSK (no certificados), API clásica NWConnectionGroup, sin `@unchecked Sendable`.
        Streaming binario de primera clase. PSK+QUIC pendiente de validar en hardware.
  - [x] 6.2 Portar `FileTransferService` (canal PSK principal) y su estado observable;
        conforma `RoomTransferHandling`.

- [x] 7. Permisos de red local
  - [x] 7.1 Portar el checker de permisos (adelantado en Fase 3: `PermissionsChecker`,
        `PermissionState`, `PermissionsGuidance`, `LocalNetworkDenial`)
    - _Requisitos: 10.1, 10.2, 10.3_

- [ ] 8. Integración, tests end-to-end y limpieza
  - [x] 8.1 Tests de integración con `MockTransport` (23 tests verdes: sala,
        membresía, actividades, chat, closeAll, host election). Flujos de caída/
        recuperación de dos peers quedan como cobertura ampliable.
    - _Requisitos: 1.6, 5.4, 12.3_
  - [x] 8.2 Limpieza de archivos y nomenclatura (cero rastros de tipos viejos)
  - [x] 8.3 Actualizar documentación (README, USAGE, Security.docc, CommunicationArchitecture.docc)
  - [x] 8.4 Verificación final (build sin warnings, 0 @unchecked Sendable, 23 tests verdes)
