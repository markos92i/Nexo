//
//  RoomService+Photos.swift
//  Nexo
//
//  Fotos de perfil bajo demanda. La lista de miembros solo lleva la miniatura y
//  el digest; la foto completa se pide al dueño (o al host, si no hay conexión
//  directa con él) y llega por un stream binario, que no comparte socket con el
//  control ni con el chat.
//

import CryptoKit
import Foundation

// MARK: - Pedir y servir fotos

@NexoActor
extension RoomService {

    /// Archivo local con la foto de perfil completa de un miembro, descargándola
    /// si hace falta. `nil` si no tiene foto o no se pudo obtener; la miniatura de
    /// `avatar` sigue sirviendo.
    public func memberPhoto(_ member: RoomMember, in roomID: RoomID) async -> URL? {
        guard let digest = member.photoDigest else { return nil }
        if digest == identity.photoDigest, let url = identity.photoURL { return url }
        if let url = photos.cachedURL(for: digest) { return url }
        if let running = photos.downloads[digest] { return await running.value }

        let download = Task {
            let url = await downloadPhoto(digest, of: member.deviceID, in: roomID)
            photos.downloads[digest] = nil
            return url
        }
        photos.downloads[digest] = download
        return await download.value
    }

    private func downloadPhoto(_ digest: String, of owner: DeviceID, in roomID: RoomID) async -> URL? {
        guard binaryTransport != nil,
              let session = sessions[roomID], session.accessState == .joined,
              session.contains(owner) else { return nil }

        // El host está conectado con todos: para entrar en la sala hay que pasar por él.
        let host = session.descriptor.hostDeviceID
        let source: DeviceID
        if isPeerAdmitted(owner) {
            source = owner
        } else if host != identity.deviceID, isPeerAdmitted(host) {
            source = host
        } else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            photos.wait(for: digest, from: source, in: roomID, continuation: continuation)
            send(.photoRequest(digest), to: [source], roomID: roomID)
        }
    }

    /// Solo se sirven fotos de miembros actuales de la sala, para que nadie use a
    /// otro peer como almacén de fotos ajenas a ella.
    func servePhoto(_ digest: String, to peer: DeviceID, in session: Room) {
        guard session.accessState == .joined,
              let owner = session.members.first(where: { $0.photoDigest == digest }),
              photos.beginUpload(digest, to: peer) else { return }
        let roomID = session.roomID

        Task {
            defer { photos.endUpload(digest, to: peer) }
            let url: URL?
            if digest == identity.photoDigest {
                url = identity.photoURL
            } else if let cached = photos.cachedURL(for: digest) {
                url = cached
            } else if session.isLocalHost, owner.deviceID != peer {
                url = await memberPhoto(owner, in: roomID)
            } else {
                url = nil
            }

            guard let url, let data = await PhotoCache.read(url),
                  let writer = try? await openByteStream(
                      to: peer,
                      in: roomID,
                      mimeType: ByteStreamDescriptor.photoMimeType,
                      name: digest,
                      expectedLength: Int64(data.count)
                  ) else { return }
            do {
                try await writer.send(data)
                try await writer.finish()
            } catch {
                await writer.cancel()
            }
        }
    }

    /// Un stream de foto solo se acepta si responde a una petición nuestra a ese
    /// mismo peer. Los demás se descartan, lo que los cancela en el emisor.
    func receivePhoto(_ incoming: IncomingByteStream) {
        let descriptor = incoming.descriptor
        guard let digest = descriptor.name,
              photos.isAwaiting(digest, from: incoming.senderDeviceID, in: descriptor.roomID),
              let length = descriptor.expectedLength,
              (1...Int64(Limits.maximumPhotoBytes)).contains(length) else { return }
        let photos = photos
        Task {
            let url = await PhotoCache.store(incoming.stream, digest: digest, length: length, in: photos.directory)
            photos.finish(digest, with: url)
        }
    }
}

// MARK: - PhotoCache

/// Caché en disco indexada por SHA-256, separada de las transferencias del chat:
/// no le afecta su poda. Si el sistema vacía Caches, solo cuesta volver a
/// descargar.
@NexoActor
final class PhotoCache {
    private struct Pending {
        let sender: DeviceID
        let roomID: RoomID
        let continuation: CheckedContinuation<URL?, Never>
        let timeout: Task<Void, Never>
    }

    nonisolated let directory: URL
    var downloads: [String: Task<URL?, Never>] = [:]
    private var pending: [String: Pending] = [:]
    private var uploads: Set<String> = []

    private static let requestTimeout: Duration = .seconds(15)
    private nonisolated static let budgetBytes = 20 * 1024 * 1024

    nonisolated init() {
        directory = URL.cachesDirectory.appending(path: "nexo-photos-v1", directoryHint: .isDirectory)
    }

    func cachedURL(for digest: String) -> URL? {
        let url = directory.appending(path: digest)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // The modification date doubles as last use for eviction.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    // MARK: Peticiones pendientes

    func wait(
        for digest: String,
        from sender: DeviceID,
        in roomID: RoomID,
        continuation: CheckedContinuation<URL?, Never>
    ) {
        guard pending[digest] == nil else {
            continuation.resume(returning: nil)
            return
        }
        let timeout = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.requestTimeout)) != nil else { return }
            self?.finish(digest, with: nil)
        }
        pending[digest] = Pending(sender: sender, roomID: roomID, continuation: continuation, timeout: timeout)
    }

    func isAwaiting(_ digest: String, from sender: DeviceID, in roomID: RoomID) -> Bool {
        guard let entry = pending[digest] else { return false }
        return entry.sender == sender && entry.roomID == roomID
    }

    func finish(_ digest: String, with url: URL?) {
        guard let entry = pending.removeValue(forKey: digest) else { return }
        entry.timeout.cancel()
        entry.continuation.resume(returning: url)
    }

    func cancelAll() {
        for digest in Array(pending.keys) { finish(digest, with: nil) }
    }

    // MARK: Envíos en curso

    /// `false` si ya se está mandando esa foto a ese peer.
    func beginUpload(_ digest: String, to peer: DeviceID) -> Bool {
        uploads.insert("\(peer)/\(digest)").inserted
    }

    func endUpload(_ digest: String, to peer: DeviceID) {
        uploads.remove("\(peer)/\(digest)")
    }

    // MARK: Archivos

    /// SHA-256 en hexadecimal de una foto, o `nil` si no se puede leer o pasa del
    /// límite.
    @concurrent
    static func digest(ofFileAt url: URL) async -> String? {
        guard let data = await read(url) else { return nil }
        return hex(SHA256.hash(data: data))
    }

    @concurrent
    static func read(_ url: URL) async -> Data? {
        guard let data = try? Data(contentsOf: url),
              !data.isEmpty, data.count <= Limits.maximumPhotoBytes else { return nil }
        return data
    }

    /// Lee el stream con el tope anunciado, comprueba el hash y guarda la foto.
    @concurrent
    static func store(_ stream: ByteStream, digest: String, length: Int64, in directory: URL) async -> URL? {
        var data = Data()
        data.reserveCapacity(Int(length))
        do {
            for try await chunk in stream {
                // Leaving the loop drops the stream, which cancels it at the sender.
                guard Int64(data.count + chunk.count) <= length else { return nil }
                data.append(chunk)
            }
        } catch {
            return nil
        }
        guard Int64(data.count) == length, hex(SHA256.hash(data: data)) == digest else { return nil }

        let url = directory.appending(path: digest)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        evictLeastRecentlyUsed(in: directory)
        return url
    }

    private nonisolated static func evictLeastRecentlyUsed(in directory: URL) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)
        ) else { return }

        var entries = files.compactMap { url -> (url: URL, date: Date, size: Int)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        entries.sort { $0.date < $1.date }
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries where total > budgetBytes {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    private nonisolated static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
