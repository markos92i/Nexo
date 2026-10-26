# Requisitos — Rewrite de Nexo

## Introducción

Nexo es una librería Swift P2P para iOS/macOS que permite a dispositivos cercanos
descubrirse, conectarse y comunicarse **sin conexión a Internet**, usando el
framework Network (Bonjour + TCP/QUIC). Sobre ese transporte neutral, Nexo ofrece
un modelo de **salas** (rooms) donde varios participantes chatean, transfieren
archivos y ejecutan **actividades** (p. ej. juegos multijugador).

Este rewrite reconstruye la librería capa por capa preservando los algoritmos de
red ya probados (recuperación tras caída, migración de host, topología mesh,
coalescing latest-wins, presupuesto de bytes de Bonjour) mientras moderniza la
arquitectura, la concurrencia y la seguridad.

### Objetivos del rewrite

- **Arquitectura simple y escalable**: Nexo es una librería P2P genérica. "Salas +
  chat + juegos" es *un* uso construido encima, no el núcleo. El transporte y las
  sesiones P2P no conocen conceptos de dominio (chat, juego, sudoku).
- **100% async/await**: sin callbacks/closures como canal primario de eventos; sin
  mezcla de paradigmas. Entrega de eventos mediante `AsyncStream`/`AsyncSequence`.
- **Concurrencia Swift 6**: `actor`/`@globalActor`, `Sendable` real. **Cero
  `@unchecked Sendable`** en código propio; los tipos de C (`Sec*`, `sec_*`) se
  encapsulan en tipos `Sendable` seguros.
- **Typed throws** en toda la API pública.
- **API pública mínima**: solo se expone lo que un consumidor necesita; la mecánica
  interna es `internal`.
- **Sin dependencias de certificados**: se elimina `swift-certificates` y
  `swift-asn1`. El cifrado pasa a **PSK (pre-shared key)** derivada de un secreto de
  app + código de sala.
- **Nomenclatura con criterio**: el nombre de la librería sigue siendo `Nexo`. Los
  prefijos de tipos se unifican con criterio por capa, evitando la mezcla actual de
  `Nexo*`/`P2P*`/`Room*`.

### Decisiones de diseño ya acordadas

1. **Rewrite por capas preservando algoritmos**, no reescritura desde cero de la
   lógica de red distribuida.
2. **Cifrado PSK**: `PSK = HMAC-SHA256(key: appSecret, message: roomCode)`. El
   consumidor puede usar solo `appSecret` (canal común) o `appSecret + roomCode`
   (salas aisladas). Se elimina el modelo de certificado autofirmado, que además
   está bloqueado por iOS 26 en red local.
3. **Identidad de dispositivo**: la librería genera y persiste un `DeviceID` único
   (UUID en Keychain). El consumidor ya no inventa el `applicationID`.
4. **iOS 26 mínimo por defecto**; subir a iOS 27 solo si aporta algo concreto
   (p. ej. mejor soporte de PSK sobre TLS 1.3), a decidir en la fase de diseño.
5. **Sin TOFU ni huella visual por dispositivo**: con PSK, la seguridad vive en el
   secreto compartido. Si un peer no conoce `appSecret + roomCode`, el handshake PSK
   falla y no se conecta; si los conoce, está legítimamente en la sala. La huella
   derivada de la PSK sería idéntica para todos los miembros, así que no identifica a
   un dispositivo concreto y no aporta. Se eliminan el trust store, los estados de
   verificación, los formatters de huella (emoji/palabras) y el QR. **Comparar el
   código de sala en persona ES la verificación.**

---

## Requisitos

### Requisito 1 — Transporte P2P neutral

**Historia:** Como desarrollador que integra Nexo, quiero un contrato de transporte
que descubra dispositivos y entregue mensajes opacos, independiente del framework
Network, para poder sustituirlo por un mock en tests.

#### Criterios de aceptación

1. CUANDO se define el transporte ENTONCES debe existir un protocolo `Sendable` que
   no exponga ningún tipo de `Network.framework` en su superficie pública.
2. CUANDO el transporte descubre un dispositivo vía Bonjour ENTONCES debe emitir un
   evento de anuncio que incluya la información del TXT sin abrir conexión.
3. CUANDO se solicita conectar a un peer ENTONCES el transporte debe mantener **una
   sola conexión física por peer**, reutilizándola para todas las salas compartidas.
4. CUANDO el transporte entrega eventos ENTONCES debe hacerlo mediante un único
   `AsyncStream`, y cada evento debe portar la `epoch` (generación) vigente al
   generarse, de modo que los eventos de una sesión detenida se descarten sin
   ambigüedad.
5. CUANDO el framework Network produce un error ENTONCES debe traducirse a un error
   tipado de Nexo antes de cruzar la frontera de la API pública.
6. CUANDO existe un mock de transporte en tests ENTONCES debe poder conducir el
   resto de la pila (salas, chat, actividades) sin ningún dispositivo real.

### Requisito 2 — Cifrado mediante PSK

**Historia:** Como usuario, quiero que mis conversaciones y partidas estén cifradas
sin depender de certificados ni de un servidor, para que solo quien tiene el código
de la sala pueda participar.

#### Criterios de aceptación

1. CUANDO se configura el transporte con un secreto de app ENTONCES el canal debe
   cifrarse mediante PSK sobre TLS/QUIC usando `sec_protocol_options_add_pre_shared_key`.
2. CUANDO se indica además un código de sala ENTONCES la PSK debe derivarse como
   `HMAC-SHA256(key: appSecret, message: roomCode)`, de modo que peers de la misma
   app pero distinta sala no puedan descifrarse entre sí.
3. CUANDO dos dispositivos con la misma app y código de sala se conectan por Wi-Fi
   local en iOS 26+ ENTONCES el handshake debe completarse (sin el bloqueo de
   certificados autofirmados).
4. CUANDO se establece una conexión ENTONCES debe derivarse un fingerprint
   determinista del material del handshake, estable entre reconexiones del mismo par
   app+sala.
5. CUANDO el rewrite finaliza ENTONCES `Package.swift` no debe depender de
   `swift-certificates` ni de `swift-asn1`.

### Requisito 3 — Identidad de dispositivo

**Historia:** Como desarrollador, quiero que Nexo gestione un identificador único y
persistente por dispositivo, para no tener que generarlo ni almacenarlo yo.

#### Criterios de aceptación

1. CUANDO una app usa Nexo por primera vez ENTONCES la librería debe generar un
   `DeviceID` único y persistirlo en Keychain.
2. CUANDO la app se reinicia ENTONCES Nexo debe recuperar el mismo `DeviceID`.
3. CUANDO se expone la identidad local ENTONCES debe incluir el `DeviceID`, un nombre
   visible editable por el usuario y un token de avatar opaco opcional.
4. CUANDO la creación o lectura de la identidad falla ENTONCES debe lanzarse un error
   tipado que describa la causa (estado de Keychain, etc.).

### Requisito 4 — Seguridad por secreto compartido (sin TOFU)

**Historia:** Como usuario, quiero que solo quien conoce el código de la sala pueda
participar y descifrar, sin tener que gestionar huellas ni confianzas por dispositivo.

#### Criterios de aceptación

1. CUANDO un peer intenta conectarse sin conocer `appSecret + roomCode` ENTONCES el
   handshake PSK debe fallar y la conexión no debe establecerse.
2. CUANDO un peer conoce `appSecret + roomCode` ENTONCES debe poder conectarse y
   descifrar, y se considera legítimamente parte de la sala.
3. CUANDO el rewrite finaliza ENTONCES no debe existir trust store, estados de
   verificación, formatters de huella (emoji/palabras) ni QR de verificación.
4. CUANDO el usuario quiere confirmar que está en la sala correcta ENTONCES debe poder
   leer el código de sala en forma legible (`shortCode`) y compararlo de viva voz;
   esa comparación constituye la verificación del modelo.
5. CUANDO el consumidor necesita saber quién está presente en una sala ENTONCES debe
   obtenerlo de la membresía de la sala, no de un registro de confianza aparte.

### Requisito 5 — Salas (rooms)

**Historia:** Como usuario, quiero crear o unirme a salas cercanas para chatear y
jugar, y que la sala sobreviva a caídas temporales de conexión.

#### Criterios de aceptación

1. CUANDO se crea una sala ENTONCES debe tener un identificador lógico independiente
   del transporte, un conjunto de capacidades (chat, actividades, transferencia),
   una política de acceso (abierta / con aprobación) y una capacidad opcional.
2. CUANDO un peer solicita unirse a una sala abierta ENTONCES debe ser admitido
   directamente; CUANDO la política es "con aprobación" ENTONCES el host debe decidir.
3. CUANDO un miembro es admitido ENTONCES el host debe propagar la lista de miembros
   y cada miembro debe abrir conexión directa con los demás (topología **mesh**).
4. CUANDO la conexión física a un peer se cae temporalmente ENTONCES la membresía,
   el chat y las actividades deben conservarse durante un periodo de gracia, y
   recuperarse al reconectar (replay idempotente por ID de mensaje).
5. CUANDO el host de una sala se vuelve inalcanzable ENTONCES debe elegirse un nuevo
   host de forma determinista (migración de host con generaciones validables).
6. CUANDO la app pasa a segundo plano ENTONCES las conexiones pueden cerrarse pero la
   membresía lógica debe conservarse para recuperarse al volver a primer plano.
7. CUANDO el estado visible de una sala cambia ENTONCES debe publicarse un snapshot
   `Sendable` por `AsyncStream`, conservando solo el más reciente para consumidores
   lentos.

### Requisito 6 — Descubrimiento y directorio de salas

**Historia:** Como usuario, quiero ver las salas cercanas disponibles sin conectarme
a cada dispositivo.

#### Criterios de aceptación

1. CUANDO un dispositivo anuncia salas ENTONCES debe publicar un subconjunto en el
   TXT de Bonjour respetando el límite de 255 bytes por entrada (presupuesto en
   UTF-8, sin partir caracteres).
2. CUANDO se completa el handshake con un peer ENTONCES debe poder solicitarse su
   catálogo completo de salas sin abrir otra conexión física.
3. CUANDO una sala deja de anunciarse o el host la cierra ENTONCES debe retirarse del
   directorio y notificarse a los consumidores.
4. CUANDO se filtra el directorio por tipo de actividad ENTONCES deben devolverse solo
   las salas que la ofrecen.

### Requisito 7 — Chat de sala

**Historia:** Como usuario, quiero enviar mensajes de texto (con adjuntos) a la sala y
ver el historial reciente.

#### Criterios de aceptación

1. CUANDO una sala tiene la capacidad de chat ENTONCES debe poder enviarse texto a
   todos sus miembros por un canal de entrega fiable y en orden.
2. CUANDO un miembro se reincorpora tras una caída ENTONCES debe recibir el historial
   reciente de chat (hasta el límite definido).
3. CUANDO el host agrega historial de varios miembros ENTONCES la deduplicación por
   ID de mensaje debe hacer la fusión idempotente.
4. CUANDO una sala no tiene capacidad de chat ENTONCES no debe existir API de chat
   para ella.

### Requisito 8 — Actividades (extensibilidad P2P)

**Historia:** Como desarrollador de un juego, quiero definir una actividad con sus
propios mensajes y registrarla, sin tocar el transporte ni el coordinador.

#### Criterios de aceptación

1. CUANDO se define una actividad ENTONCES su payload debe ser `Data` opaco para
   todas las capas inferiores; solo la actividad conoce y decodifica sus mensajes.
2. CUANDO una actividad se registra mediante una fábrica por `tipo` ENTONCES la pila
   debe poder instanciarla al recibir su anuncio, sin conocer el juego concreto.
3. CUANDO un tipo de actividad llega de un peer con una versión que esta build no
   conoce ENTONCES debe ignorarse sin fallar.
4. CUANDO una actividad envía estado reemplazable (p. ej. snapshot de tablero)
   ENTONCES debe poder usar una clave de coalescing latest-wins para que un estado
   nuevo no quede detrás de uno obsoleto, sin adelantar a un mensaje fiable.
5. CUANDO una actividad entrega eventos a su consumidor ENTONCES debe hacerlo por una
   `AsyncSequence`, cuya cancelación desconecte al lector sin afectar a la actividad.
6. CUANDO una actividad puede ser exclusiva (un juego a la vez) o no (chat) ENTONCES
   el modelo debe permitir ambas sin cambios en capas inferiores.
7. CUANDO una actividad es alojada por un invitado (no el host de la sala) ENTONCES su
   autoridad debe reconciliarse de forma independiente de la autoridad de la sala.

### Requisito 9 — Transferencia de archivos

**Historia:** Como usuario, quiero enviar un archivo o imagen a la sala y ver el
progreso.

#### Criterios de aceptación

1. CUANDO una sala tiene la capacidad de transferencia ENTONCES debe poder ofrecerse
   un archivo (o datos) con nombre y tipo MIME.
2. CUANDO una transferencia está en curso ENTONCES su estado (ofrecida, aceptada,
   transfiriendo con progreso, completada, fallida, cancelada) debe ser observable.
3. CUANDO una transferencia finaliza ENTONCES debe poder obtenerse la URL local del
   archivo recibido.
4. CUANDO se transfiere ENTONCES deben respetarse los límites de tamaño de archivo,
   tamaño de chunk y número de transferencias simultáneas, con verificación de
   integridad (checksum).

### Requisito 10 — Permisos de red local

**Historia:** Como desarrollador, quiero comprobar el permiso de red local antes de
iniciar, para guiar al usuario si está denegado.

#### Criterios de aceptación

1. CUANDO se consulta el estado de permisos ENTONCES debe informarse de forma
   asíncrona si la red local está concedida, denegada o es desconocida.
2. CUANDO un permiso crítico está denegado ENTONCES debe ofrecerse una guía con los
   pasos y un enlace a Ajustes.
3. CUANDO el permiso cambia en tiempo de ejecución ENTONCES debe notificarse por el
   canal de eventos async.

### Requisito 11 — Manejo de errores tipado

**Historia:** Como desarrollador, quiero errores tipados y específicos por operación,
para manejar cada fallo de forma exhaustiva.

#### Criterios de aceptación

1. CUANDO una función pública puede fallar ENTONCES debe usar `throws(ErrorEspecífico)`
   con un enum de error acotado a esa operación.
2. CUANDO un error de una capa inferior cruza a una superior ENTONCES debe traducirse
   a un error de la capa superior en lugar de propagar tipos internos.
3. CUANDO un error representa una causa de desconexión o rechazo ENTONCES debe ser
   `Sendable` y `Equatable` para poder compararse en tests y UI.

### Requisito 12 — Calidad, concurrencia y compatibilidad

**Historia:** Como mantenedor, quiero que la librería compile con concurrencia
estricta de Swift 6 y esté cubierta por tests.

#### Criterios de aceptación

1. CUANDO se compila el paquete ENTONCES debe hacerlo sin warnings bajo concurrencia
   estricta de Swift 6.4.
2. CUANDO se inspecciona el código ENTONCES no debe haber `@unchecked Sendable` en
   tipos propios; los envoltorios de tipos de C deben ser `Sendable` de forma segura.
3. CUANDO se ejecutan los tests ENTONCES deben cubrir, como mínimo, la derivación de
   PSK, la identidad de dispositivo, y el flujo de salas/chat/actividades conducido por
   un transporte mock.
4. CUANDO se publica la API ENTONCES la superficie `public` debe limitarse a lo que el
   consumidor necesita; todo lo demás debe ser `internal`.
5. CUANDO se migran los algoritmos de red (recuperación, migración de host, mesh,
   coalescing, presupuesto TXT) ENTONCES su comportamiento observable debe preservarse.
