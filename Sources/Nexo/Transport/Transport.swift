import Foundation

// MARK: - TransportEvent

/// Eventos del transporte físico.
///
/// Cada evento lleva la `epoch` vigente al generarse. Un `stop()` incrementa la
/// epoch, así que los eventos encolados antes se descartan sin ambigüedad.
public enum TransportEvent: Sendable {
    case advertisementFound(PeerAdvertisement, epoch: UInt64)
    case advertisementUpdated(PeerAdvertisement, epoch: UInt64)
    case advertisementLost(TransportPeerID, epoch: UInt64)
    case peerConnected(ConnectedPeer, epoch: UInt64)
    case peerDisconnected(deviceID: DeviceID, reason: DisconnectReason?, epoch: UInt64)
    case received(Envelope, from: ConnectedPeer, epoch: UInt64)
    case lifecycleChanged(ConnectivityLifecycle, epoch: UInt64)
    case localNetworkPermissionChanged(LocalNetworkPermission, epoch: UInt64)

    public var epoch: UInt64 {
        switch self {
        case .advertisementFound(_, let epoch), .advertisementUpdated(_, let epoch),
             .advertisementLost(_, let epoch), .peerConnected(_, let epoch),
             .peerDisconnected(_, _, let epoch), .received(_, _, let epoch),
             .lifecycleChanged(_, let epoch), .localNetworkPermissionChanged(_, let epoch):
            epoch
        }
    }
}

// MARK: - Transport

/// Contrato del transporte físico, independiente de Network framework.
///
/// El transporte no sabe qué es una sala: solo descubre dispositivos, mantiene
/// una conexión por peer y entrega envelopes opacos. Todo el enrutado lógico vive
/// en la capa de salas.
///
/// Nada aquí está atado al hilo principal. La rotación de Bonjour, la
/// decodificación de TXT, la contabilidad de conexiones y el tráfico de frames
/// pertenecen al ejecutor propio del transporte. Consecuencias para quien llama:
///
/// - `start`, `stop`, `updateAdvertisement`, `refreshDiscovery`, `disconnect` y
///   `enqueue` son síncronos y nonisolated *por contrato*: entregan el trabajo y
///   retornan. Siguen siendo síncronos porque el estado de juego se envía a
///   cadencia de render, y un salto por mensaje costaría más y dejaría de
///   preservar el orden elegido por el emisor.
/// - `epoch` y `connectedPeers` se leen de forma síncrona por el mismo motivo.
/// - `events` se entrega en el ejecutor que elija el consumidor.
public protocol Transport: Sendable {

    /// Flujo único de eventos. Tiene un consumidor: `RoomService`, que lo lee
    /// desde su init. Nunca descarta eventos: perder un `peerConnected` o un
    /// `peerDisconnected` dejaría la lista de peers desincronizada.
    var events: AsyncStream<TransportEvent> { get }

    /// Generación asignada de forma síncrona al iniciar o detener una sesión.
    var epoch: UInt64 { get }

    /// Peers con el handshake completado, indexados por `DeviceID`.
    var connectedPeers: [ConnectedPeer] { get }

    // MARK: Ciclo de vida

    func start(advertising: Bool, browsing: Bool)
    func stop()

    /// Actualiza el TXT publicado sin reiniciar el listener, para que cambiar de
    /// sala nunca tire conexiones abiertas.
    func updateAdvertisement(_ record: AdvertisementRecord)

    /// Re-ejecuta el descubrimiento: reconstruye cualquier listener muerto y
    /// reinicia los browsers. Las conexiones establecidas sobreviven.
    func refreshDiscovery()

    // MARK: Conexiones

    /// Abre una conexión al anuncio dado, o reutiliza una conexión viva existente
    /// a ese `DeviceID`.
    @discardableResult
    func connect(to advertisement: PeerAdvertisement) async throws(TransportError) -> ConnectedPeer

    /// Cierra la conexión física a un peer. Solo el coordinador debería llamarlo:
    /// salir de una sala nunca cierra la conexión.
    func disconnect(deviceID: DeviceID, reason: DisconnectReason?)

    // MARK: Envío

    /// Encola un envelope para un peer concreto. El envío es asíncrono y respeta
    /// los carriles y el coalescing configurados en el envelope.
    func enqueue(_ envelope: Envelope, to deviceID: DeviceID)
}

// MARK: - BinaryStreamOpening

/// Capacidad opcional de un transporte: abrir streams binarios de alta velocidad
/// hacia un peer, por una conexión dedicada, para datos densos.
///
/// Es un protocolo aparte porque no todo transporte la ofrece (p. ej. un mock de
/// tests no). `RoomService` la usa solo si su transporte la implementa.
public protocol BinaryStreamOpening: Sendable {
    /// Abre un stream binario de escritura hacia un peer conectado. El par abre su
    /// lado consumiendo `incomingByteStreams`.
    func openByteStream(
        to deviceID: DeviceID,
        descriptor: ByteStreamDescriptor
    ) async throws(TransportError) -> ByteStreamWriter

    /// Streams binarios entrantes de todos los peers. Un único consumidor.
    var incomingByteStreams: AsyncStream<IncomingByteStream> { get }
}

// MARK: - TransportPeerID

/// Identidad efímera de endpoint dentro del transporte. Cambia entre sesiones y
/// nunca debe usarse como identidad de dominio (para eso está `DeviceID`).
public struct TransportPeerID: Hashable, Codable, Sendable, Identifiable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var id: String { rawValue }
    public var description: String { rawValue }
}

// MARK: - PeerAdvertisement

/// Un anuncio de Bonjour de un dispositivo cercano, leído del TXT antes de abrir
/// ninguna conexión. Permite listar salas sin conectar a cada peer.
public struct PeerAdvertisement: Identifiable, Sendable, Equatable {
    public let endpointID: TransportPeerID
    public let deviceID: DeviceID?
    public let displayName: String
    public let protocolVersion: UInt8
    /// Salas anunciadas en el TXT. Puede ser un subconjunto de las alojadas.
    public let rooms: [RoomDescriptor]
    /// Total real de salas alojadas, aunque no todas quepan en el TXT.
    public let totalRoomCount: Int

    public var id: TransportPeerID { endpointID }

    public var isCompatible: Bool { ProtocolInfo.isCompatible(remoteVersion: protocolVersion) }

    public var hasUndisclosedRooms: Bool { totalRoomCount > rooms.count }

    public init(
        endpointID: TransportPeerID,
        deviceID: DeviceID?,
        displayName: String,
        protocolVersion: UInt8,
        rooms: [RoomDescriptor],
        totalRoomCount: Int
    ) {
        self.endpointID = endpointID
        self.deviceID = deviceID
        self.displayName = displayName
        self.protocolVersion = protocolVersion
        self.rooms = rooms
        self.totalRoomCount = totalRoomCount
    }
}

// MARK: - ConnectedPeer

/// Un peer con el handshake completado. A partir de aquí el sistema lo identifica
/// por `deviceID`, nunca por el identificador de conexión.
public struct ConnectedPeer: Identifiable, Sendable, Hashable {
    public let deviceID: DeviceID
    public let displayName: String
    /// Derivado público de la PSK negociada (`SHA256(PSK).prefix(16)` en hex).
    /// Confirma que el peer comparte el mismo secreto de app+sala; no identifica
    /// al dispositivo. Igual para todos los miembros de una misma sala.
    public let pskHint: String?
    public let protocolVersion: UInt8
    public let capabilities: Set<Capability>
    /// Instancia concreta de conexión. Cambia en cada reconexión; se usa para
    /// descartar eventos de una conexión ya reemplazada.
    public let connectionSessionID: UUID

    public var id: DeviceID { deviceID }

    public init(
        deviceID: DeviceID,
        displayName: String,
        pskHint: String?,
        protocolVersion: UInt8,
        capabilities: Set<Capability>,
        connectionSessionID: UUID
    ) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.pskHint = pskHint
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.connectionSessionID = connectionSessionID
    }

    public func supports(_ capability: Capability) -> Bool {
        capabilities.contains(capability)
    }
}

// MARK: - ConnectivityLifecycle

/// Estado global del transporte.
public enum ConnectivityLifecycle: String, Sendable, Equatable {
    case idle
    case active
    /// La app pasó a segundo plano: las salas se conservan, las conexiones no.
    case suspended
    case reconnecting
    case disconnected
}

// MARK: - LocalNetworkPermission

public enum LocalNetworkPermission: Sendable, Equatable {
    case unknown
    case available
    case denied
}
