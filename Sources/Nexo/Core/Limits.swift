import Foundation

// MARK: - Limits

/// Límites técnicos. No hay tope duro de participantes, pero el host necesita
/// protegerse de presión de memoria, ancho de banda y mensajes abusivos.
public enum Limits {

    public static let maximumEnvelopeBytes = 512 * 1024
    public static let maximumTransferBytes: Int64 = 25 * 1024 * 1024
    public static let transferChunkBytes = 32 * 1024
    /// Chunks en vuelo antes de esperar backpressure del receptor.
    public static let transferWindowChunks = 8
    public static let chatHistoryLimit = 500

    /// Cuánto tiempo una desconexión física se sigue considerando recuperable.
    /// También se comprueba al volver a primer plano, ya que iOS puede suspender
    /// la ejecución sin garantizar que un temporizador avance.
    public static let temporaryDisconnectGracePeriod: TimeInterval = 60
    /// Falla antes que el periodo de gracia de reconexión para que un host muerto
    /// no congele una malla por lo demás conectada durante un minuto entero.
    public static let hostMigrationDelay: Duration = .seconds(5)

    /// Ventana de retención del journal de chat/actividad usado para reenviar
    /// mensajes tras una reconexión física.
    public static let recoveryJournalRetention: TimeInterval = 60
    public static let recoveryJournalLimit = 2_000
    public static let recoveryJournalBytesLimit = 4 * 1024 * 1024
    public static let recoveryChatMessageLimit = 100
    public static let recoveryMemberLimit = 256
    public static let recoveryActivityLimit = 64

    /// Salas anunciadas en el TXT de Bonjour. El resto se descubren al conectar
    /// vía `roomDirectory`.
    public static let advertisedRoomLimit = 3

    public static let handshakeTimeout: Duration = .seconds(12)
    public static let joinTimeout: Duration = .seconds(30)
}
