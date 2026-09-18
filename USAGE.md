# Guía de Uso de Nexo

Esta guía documenta cómo usar Nexo para comunicaciones P2P en iOS sin conexión a Internet.

## Índice

1. [Configuración Inicial](#configuración-inicial)
2. [Verificación de Permisos](#verificación-de-permisos)
3. [Creación de Identidad TLS](#creación-de-identidad-tls)
4. [Verificación de Peers (TOFU)](#verificación-de-peers-tofu)
5. [Conexión y Descubrimiento](#conexión-y-descubrimiento)
6. [Salas y Chat](#salas-y-chat)
7. [Transferencia de Archivos](#transferencia-de-archivos)
8. [Actividades (Juegos)](#actividades-juegos)
9. [Mejores Prácticas de Seguridad](#mejores-prácticas-de-seguridad)

---

## Configuración Inicial

### Info.plist

Añade las claves necesarias para Bonjour:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Nexo necesita acceso a la red local para descubrir y conectar con dispositivos cercanos.</string>

<key>NSBonjourServices</key>
<array>
    <string>_zafir-nearby._tcp</string>
    <string>_zafir-nearby._udp</string>
</array>
```

### Importación

```swift
import Nexo
```

---

## Verificación de Permisos

Antes de iniciar conexiones, verifica que el usuario ha concedido los permisos necesarios:

```swift
@MainActor
class PermissionsManager: ObservableObject {
    let checker = NexoPermissionsChecker()
    
    func checkOnLaunch() async {
        await checker.checkPermissions()
        
        if checker.status.hasCriticalDenial {
            showPermissionAlert()
        }
    }
    
    func showPermissionAlert() {
        let guidance = checker.settingsGuidance
        
        // Mostrar alerta con:
        // - Título: guidance.title
        // - Mensaje: guidance.message
        // - Pasos: guidance.steps
        // - Botón para abrir Ajustes: guidance.settingsURL
    }
    
    // Monitoreo continuo para detectar cambios
    func startMonitoring() {
        checker.onPermissionChange = { kind, state in
            print("Permiso \(kind) cambió a \(state)")
        }
        checker.startMonitoring(interval: 5.0)
    }
}
```

### SwiftUI View

```swift
struct PermissionCheckView: View {
    @StateObject private var manager = PermissionsManager()
    
    var body: some View {
        VStack {
            switch manager.checker.status.localNetwork {
            case .unknown:
                ProgressView("Verificando permisos...")
            case .granted:
                Text("✅ Red local habilitada")
            case .denied, .restricted:
                PermissionDeniedView(guidance: manager.checker.settingsGuidance)
            case .unsupported:
                Text("⚠️ Esta función no está disponible")
            }
        }
        .task {
            await manager.checkOnLaunch()
        }
    }
}
```

---

## Creación de Identidad TLS

Nexo genera automáticamente un certificado TLS autofirmado la primera vez que se usa:

```swift
@MainActor
class ConnectionManager {
    private var transport: NetworkPeerTransport?
    private var coordinator: RoomCoordinator?
    private var identity: LocalP2PIdentity?
    private var tlsIdentity: NexoLocalTLSIdentity?
    
    func initialize() throws {
        // Generar o cargar identidad persistente
        let applicationID = getOrCreateApplicationID()
        let displayName = UIDevice.current.name
        
        // Crear identidad TLS (se almacena en Keychain)
        tlsIdentity = try NexoLocalTLSIdentity.loadOrCreate(applicationID: applicationID)
        
        // Crear configuración TLS
        let tlsConfig = tlsIdentity?.makeTLSConfiguration()
        
        // Crear identidad local
        identity = LocalP2PIdentity(applicationID: applicationID, displayName: displayName)
        
        // Crear transporte con cifrado
        transport = NetworkPeerTransport(
            applicationID: applicationID,
            displayName: displayName,
            tlsConfiguration: tlsConfig,
            localCertificateFingerprint: tlsIdentity?.fingerprint
        )
        
        // Crear coordinador de salas
        coordinator = RoomCoordinator(
            transport: transport!,
            identity: identity!
        )
        
        print("Mi fingerprint: \(tlsIdentity?.fingerprint ?? "N/A")")
    }
    
    private func getOrCreateApplicationID() -> String {
        let key = "nexo.applicationID"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: key)
        return newID
    }
}
```

---

## Verificación de Peers (TOFU)

El sistema TOFU (Trust On First Use) permite verificar identidades sin servidor central:

### Configuración Básica

```swift
@MainActor
class PeerVerificationManager: ObservableObject {
    let verificationService: NexoPeerVerificationService
    
    @Published var pendingVerifications: [NexoPeerIdentityInfo] = []
    @Published var identityChangedAlerts: [NexoPeerIdentityInfo] = []
    
    init(applicationID: String) {
        verificationService = NexoPeerVerificationService(applicationID: applicationID)
        
        // Callback cuando se detecta cambio de identidad (posible MITM)
        verificationService.onIdentityChanged = { [weak self] peerInfo, oldFingerprint in
            self?.handleIdentityChanged(peerInfo, oldFingerprint: oldFingerprint)
        }
    }
    
    func verifyPeer(_ peer: ConnectedPeer) -> NexoPeerVerificationState {
        let state = verificationService.verify(peer)
        
        switch state {
        case .unknown:
            // Primera conexión - mostrar UI para aceptar
            let info = verificationService.identityInfo(for: peer)
            pendingVerifications.append(info)
            
        case .trustedOnFirstUse:
            // Peer conocido, conexión cifrada
            print("Peer verificado por TOFU")
            
        case .verified:
            // Peer verificado fuera de banda
            print("Peer totalmente verificado ✓")
            
        case .identityChanged:
            // ¡ALERTA! Posible ataque
            break // Manejado por onIdentityChanged
        }
        
        return state
    }
    
    func handleIdentityChanged(_ info: NexoPeerIdentityInfo, oldFingerprint: String) {
        identityChangedAlerts.append(info)
    }
}
```

### UI para Primera Conexión

```swift
struct FirstConnectionView: View {
    let peerInfo: NexoPeerIdentityInfo
    let onAccept: () -> Void
    let onReject: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Nuevo dispositivo detectado")
                .font(.headline)
            
            Text(peerInfo.displayName)
                .font(.title2)
            
            // Mostrar fingerprint como emojis para verificación visual
            Text("Huella de seguridad:")
                .font(.caption)
            
            Text(peerInfo.emojiFingerprint)
                .font(.largeTitle)
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(12)
            
            Text("Pregunta a la otra persona si ve los mismos emojis")
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack(spacing: 20) {
                Button("Rechazar", role: .destructive, action: onReject)
                Button("Confiar", action: onAccept)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}
```

### Verificación Avanzada con QR

```swift
struct QRVerificationView: View {
    let myInfo: NexoPeerIdentityInfo
    @State private var scannedData: NexoVerificationQRData?
    
    var body: some View {
        TabView {
            // Tab 1: Mostrar mi QR
            VStack {
                Text("Muestra este QR a tu contacto")
                
                if let qrData = generateMyQRData() {
                    QRCodeView(data: qrData)
                        .frame(width: 200, height: 200)
                }
                
                Text(myInfo.emojiFingerprint)
                    .font(.title2)
            }
            .tabItem { Label("Mi código", systemImage: "qrcode") }
            
            // Tab 2: Escanear QR del otro
            VStack {
                Text("Escanea el QR de tu contacto")
                
                QRScannerView { data in
                    scannedData = NexoVerificationQRData.decode(data)
                }
            }
            .tabItem { Label("Escanear", systemImage: "camera") }
        }
    }
    
    func generateMyQRData() -> Data? {
        NexoVerificationQRData(
            applicationID: myInfo.applicationID,
            displayName: myInfo.displayName,
            fingerprint: myInfo.fingerprint
        ).encode()
    }
}
```

### Verificar QR Escaneado

```swift
func verifyScannedQR(_ qrData: NexoVerificationQRData, against peer: ConnectedPeer) -> Bool {
    if qrData.matches(peer) {
        // El QR coincide - marcar como verificado
        verificationService.markAsVerified(peer)
        return true
    }
    // El QR no coincide - posible ataque o dispositivo incorrecto
    return false
}
```

---

## Conexión y Descubrimiento

### Iniciar Búsqueda de Peers

```swift
@MainActor
class NearbyPeersManager: ObservableObject {
    @Published var nearbyPeers: [PeerAdvertisement] = []
    @Published var isSearching = false
    
    private let transport: NetworkPeerTransport
    private var eventTask: Task<Void, Never>?
    
    init(transport: NetworkPeerTransport) {
        self.transport = transport
    }
    
    func startSearching() {
        isSearching = true
        transport.start(advertising: true, browsing: true)
        
        eventTask = Task { @MainActor in
            for await event in transport.events {
                handleEvent(event)
            }
        }
    }
    
    func stopSearching() {
        isSearching = false
        transport.stop()
        eventTask?.cancel()
    }
    
    private func handleEvent(_ event: PeerTransportEvent) {
        switch event {
        case .advertisementFound(let ad, _):
            nearbyPeers.append(ad)
            
        case .advertisementLost(let id, _):
            nearbyPeers.removeAll { $0.endpointID == id }
            
        case .peerConnected(let peer, _):
            print("Conectado a: \(peer.displayName)")
            
        case .peerDisconnected(let appID, let reason, _):
            print("Desconectado de \(appID): \(reason ?? "sin razón")")
            
        case .localNetworkPermissionChanged(let state, _):
            if state == .denied {
                showPermissionDeniedAlert()
            }
            
        default:
            break
        }
    }
}
```

---

## Salas y Chat

### Crear una Sala

```swift
@MainActor
class RoomManager: ObservableObject {
    @Published var currentRoom: RoomSession?
    @Published var availableRooms: [DiscoveredRoom] = []
    
    private let coordinator: RoomCoordinator
    
    init(coordinator: RoomCoordinator) {
        self.coordinator = coordinator
    }
    
    func createRoom(name: String) {
        let room = coordinator.createRoom(
            name: name,
            features: .full,  // Chat + Activities + FileTransfer
            accessPolicy: .open,
            capacity: 10
        )
        currentRoom = room
    }
    
    func joinRoom(_ room: DiscoveredRoom) async throws {
        currentRoom = try await coordinator.join(room)
    }
    
    func leaveCurrentRoom() {
        guard let room = currentRoom else { return }
        coordinator.leave(room.roomID)
        currentRoom = nil
    }
}
```

### Enviar Mensajes de Chat

```swift
extension RoomSession {
    func sendChatMessage(_ text: String) {
        chat?.send(text)
    }
    
    func sendChatWithImage(_ text: String, imageData: Data) throws {
        guard let fileService = fileTransferService else { return }
        
        let attachment = try fileService.offer(
            data: imageData,
            fileName: "image.jpg",
            mimeType: "image/jpeg",
            in: self
        )
        
        chat?.send(text, attachment: attachment)
    }
}
```

### Observar Mensajes

```swift
struct ChatView: View {
    @ObservedObject var chatSession: ChatRoomSession
    @State private var messageText = ""
    
    var body: some View {
        VStack {
            // Lista de mensajes
            ScrollView {
                LazyVStack {
                    ForEach(chatSession.messages) { message in
                        ChatBubble(message: message)
                    }
                }
            }
            
            // Input
            HStack {
                TextField("Mensaje", text: $messageText)
                Button("Enviar") {
                    chatSession.send(messageText)
                    messageText = ""
                }
            }
            .padding()
        }
    }
}
```

---

## Transferencia de Archivos

### Enviar un Archivo

```swift
@MainActor
func sendFile(url: URL, in session: RoomSession) async throws {
    guard let fileService = session.fileTransferService else {
        throw RoomError.featureUnavailable("archivos")
    }
    
    let mimeType = getMimeType(for: url)
    
    let attachment = try fileService.offer(
        fileURL: url,
        fileName: url.lastPathComponent,
        mimeType: mimeType,
        in: session
    )
    
    // Observar progreso
    observeTransferProgress(attachment.transferID, fileService: fileService)
}

func observeTransferProgress(_ transferID: UUID, fileService: FileTransferService) {
    Task { @MainActor in
        while true {
            guard let state = fileService.state(of: transferID) else { break }
            
            switch state {
            case .offered:
                print("Oferta enviada, esperando aceptación...")
            case .accepted:
                print("Aceptado, iniciando transferencia...")
            case .transferring(let progress):
                print("Progreso: \(Int(progress * 100))%")
            case .completed(let url):
                print("Completado: \(url)")
                return
            case .failed(let reason):
                print("Error: \(reason)")
                return
            case .cancelled:
                print("Cancelado")
                return
            }
            
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
```

### Recibir Archivos

Los archivos se aceptan automáticamente. Para acceder a ellos:

```swift
func getReceivedFile(transferID: UUID, from fileService: FileTransferService) -> URL? {
    return fileService.localFileURL(for: transferID)
}
```

---

## Actividades (Juegos)

### Definir una Actividad

```swift
// 1. Definir el identificador
extension ActivityKind {
    static let sudoku = ActivityKind("sudoku")
}

// 2. Definir los mensajes
enum SudokuMessage: Codable, Sendable {
    case boardState(SudokuBoard)
    case move(row: Int, col: Int, value: Int)
    case gameOver(winner: String?)
}

// 3. Crear la actividad
final class SudokuActivity: GenericActivity<SudokuMessage> {
    @Published var board: SudokuBoard?
    
    override func handleMessage(_ message: SudokuMessage, from member: RoomMember) {
        switch message {
        case .boardState(let newBoard):
            board = newBoard
        case .move(let row, let col, let value):
            board?.set(row: row, col: col, value: value)
        case .gameOver(let winner):
            handleGameOver(winner: winner)
        }
    }
    
    func makeMove(row: Int, col: Int, value: Int) {
        send(.move(row: row, col: col, value: value))
    }
}

// 4. Registrar la fábrica
RoomActivityRegistry.shared.register(.sudoku) { context in
    SudokuActivity(context: context)
}
```

### Iniciar una Actividad

```swift
func startGame(in session: RoomSession) throws {
    let activity = try coordinator.startActivity(
        kind: .sudoku,
        in: session.roomID,
        participants: nil,  // nil = todos los miembros
        isExclusive: true   // Solo un juego a la vez
    )
    
    // Enviar estado inicial
    if let sudoku = activity as? SudokuActivity {
        sudoku.send(.boardState(SudokuBoard.generate()))
    }
}
```

---

## Mejores Prácticas de Seguridad

### 1. Siempre Verificar Peers para Datos Sensibles

```swift
func sendSensitiveData(to peer: ConnectedPeer, data: Data) async throws {
    let state = verificationService.verify(peer)
    
    switch state {
    case .verified:
        // OK - peer verificado fuera de banda
        try await actualSend(data, to: peer)
        
    case .trustedOnFirstUse:
        // Advertir al usuario
        let proceed = await showWarning(
            "Este contacto no ha sido verificado manualmente. " +
            "¿Deseas enviar igualmente?"
        )
        if proceed {
            try await actualSend(data, to: peer)
        }
        
    case .unknown, .identityChanged:
        throw SecurityError.peerNotTrusted
    }
}
```

### 2. Manejar Cambios de Identidad

```swift
verificationService.onIdentityChanged = { peerInfo, oldFingerprint in
    // NUNCA continuar automáticamente
    showSecurityAlert(
        title: "⚠️ Alerta de Seguridad",
        message: """
        La identidad de \(peerInfo.displayName) ha cambiado.
        
        Esto puede significar:
        - El dispositivo fue reinstalado
        - Alguien está intentando interceptar la comunicación
        
        Huella anterior: \(NexoFingerprintFormatter.toEmoji(oldFingerprint))
        Huella actual: \(peerInfo.emojiFingerprint)
        
        Contacta con la persona directamente para verificar.
        """,
        actions: [
            ("Rechazar", { rejectPeer(peerInfo.applicationID) }),
            ("Aceptar cambio", { acceptIdentityChange(peerInfo) })
        ]
    )
}
```

### 3. Usar TLS Siempre

```swift
// ❌ MAL - Sin cifrado
let transport = NetworkPeerTransport(
    applicationID: appID,
    displayName: name
)

// ✅ BIEN - Con TLS
let tlsIdentity = try NexoLocalTLSIdentity.loadOrCreate(applicationID: appID)
let transport = NetworkPeerTransport(
    applicationID: appID,
    displayName: name,
    tlsConfiguration: tlsIdentity.makeTLSConfiguration(),
    localCertificateFingerprint: tlsIdentity.fingerprint
)
```

### 4. Verificar Fingerprints en Persona

Para máxima seguridad, compara fingerprints cuando los usuarios están juntos:

```swift
// Usuario A lee en voz alta:
print("Mis emojis: \(myIdentity.emojiFingerprint)")
// "🍎🐶🌸⭐🍇🦊🌻🌙"

// Usuario B verifica que coinciden con lo que ve en su pantalla
// Si coinciden, ambos marcan al otro como verificado

verificationService.markAsVerified(peerB)  // En dispositivo A
verificationService.markAsVerified(peerA)  // En dispositivo B
```

---

## Notas Adicionales

### Límites del Protocolo

| Parámetro | Límite |
|-----------|--------|
| Tamaño máximo de mensaje | 512 KB |
| Tamaño máximo de archivo | 25 MB |
| Chunk de transferencia | 32 KB |
| Historial de chat | 500 mensajes |
| Timeout de handshake | 12 segundos |
| Timeout de join | 30 segundos |
| Gracia de reconexión | 60 segundos |

### Requisitos del Sistema

- iOS 26+ / macOS 26+
- Swift 6.4+
- Network framework con soporte para peer-to-peer

### Dependencias

- `swift-certificates` 1.20.0 (para generación de certificados X.509)
