//
//  P2PProtocolInfo.swift
//  Project Dark
//
//  Created by Marcos del Castillo Camacho on 11/09/2026.
//

import Foundation

// MARK: - P2PProtocolInfo

/// Versión y capacidades del protocolo de aplicación que viaja sobre Network
/// Framework. El handshake negocia estos valores antes de admitir envelopes.
public enum P2PProtocolInfo {

    /// Versión actual del protocolo. El resume de rooms forma parte del wire
    /// de esta versión, así que no se anuncia como compatible a peers v2.
    public static let currentVersion: UInt8 = 3

    /// Esta build necesita la versión que conoce `roomResume`.
    public static let minimumVersion: UInt8 = 3

    /// Capacidades anunciadas en el `hello`. Permiten activar funciones nuevas
    /// sin romper a un peer más antiguo: si la capacidad no está en la lista del
    /// remoto, no se usa con ese peer.
    public static let capabilities: Set<P2PCapability> = [
        .rooms,
        .chat,
        .activities,
        .fileTransfer,
        .coalescedSnapshots
    ]

    /// Nombre del servicio Bonjour. Debe coincidir con `NSBonjourServices` en
    /// `Project-Dark-Info.plist`.
    public static let serviceType = "_zafir-nearby._tcp"

    public static func isCompatible(remoteVersion: UInt8) -> Bool {
        remoteVersion >= minimumVersion
    }
}

// MARK: - P2PCapability

public enum P2PCapability: String, Codable, Sendable, CaseIterable {
    /// Soporta rooms lógicas multiplexadas sobre una conexión física.
    case rooms
    /// Soporta el canal de chat.
    case chat
    /// Soporta actividades (juegos) dentro de una room.
    case activities
    /// Soporta transferencia de ficheros por chunks.
    case fileTransfer
    /// Soporta snapshots con política latest-wins en la cola de envío.
    case coalescedSnapshots
}

// MARK: - P2PLimits

/// Límites técnicos. El producto no impone un máximo de participantes, pero el
/// host sí debe protegerse de memoria, ancho de banda y mensajes abusivos.
public enum P2PLimits {

    /// Tamaño máximo de un envelope decodificado.
    public static let maximumEnvelopeBytes = 512 * 1024

    /// Tamaño máximo de un fichero ofertado.
    public static let maximumTransferBytes: Int64 = 25 * 1024 * 1024

    /// Tamaño de cada chunk de transferencia.
    public static let transferChunkBytes = 32 * 1024

    /// Chunks en vuelo antes de esperar confirmación del receptor (backpressure).
    public static let transferWindowChunks = 8

    /// Mensajes de chat retenidos en memoria por room.
    public static let chatHistoryLimit = 500

    /// Tiempo durante el que una pérdida física se considera recuperable.
    /// La fecha límite se comprueba también al volver de background, porque iOS
    /// puede suspender la ejecución y no garantiza que un timer avance.
    public static let temporaryDisconnectGracePeriod: TimeInterval = 60

    /// Retención del journal de chat/actividad usado para reentregar mensajes
    /// después de una reconexión física.
    public static let recoveryJournalRetention: TimeInterval = 60
    public static let recoveryJournalLimit = 2_000
    public static let recoveryJournalBytesLimit = 4 * 1024 * 1024
    public static let recoveryChatMessageLimit = 100
    public static let recoveryMemberLimit = 256
    public static let recoveryActivityLimit = 64

    /// Rooms anunciadas en el registro TXT de Bonjour. El resto se conoce al
    /// conectar mediante `roomDirectory`.
    public static let advertisedRoomLimit = 3

    /// Tiempo máximo de espera del handshake físico.
    public static let handshakeTimeout: Duration = .seconds(12)

    /// Tiempo máximo de espera de una respuesta de entrada a room.
    public static let joinTimeout: Duration = .seconds(30)
}
