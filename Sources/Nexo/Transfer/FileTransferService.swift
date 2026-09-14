//
//  FileTransferService.swift
//  Nexo
//

import CryptoKit
import Foundation

// MARK: - FileTransferService

/// Reliable, room-scoped file transfer by chunks.
///
/// The file is never loaded whole into memory: read and written in pieces
/// via a `FileHandle`, and the receiver only publishes the final URL once the
/// SHA-256 matches the one in the offer.
@MainActor
@Observable
public final class FileTransferService {

    // MARK: - Transfers

    /// An upload in progress.
    @MainActor
    fileprivate final class Upload {
        let offer: FileOffer
        let sourceURL: URL
        let recipients: [String]
        /// Temporary source created to prepare the send, if any. The stable
        /// copy of the attachment lives as long as the message may need it.
        let temporarySourceURL: URL?
        var handle: FileHandle?
        var nextChunkIndex = 0
        var pumpTask: Task<Void, Never>?

        /// Last chunk acknowledged by each recipient. The window is computed
        /// on the slowest one: using the fastest would starve the rest.
        var acknowledgedIndexes: [String: Int] = [:]
        /// Recipients that have already validated the full file.
        var completedRecipients: Set<String> = []

        init(
            offer: FileOffer,
            sourceURL: URL,
            recipients: [String],
            temporarySourceURL: URL?
        ) {
            self.offer = offer
            self.sourceURL = sourceURL
            self.recipients = recipients
            self.temporarySourceURL = temporarySourceURL
        }

        /// Progress acknowledged by the slowest recipient.
        var slowestAcknowledgedIndex: Int {
            guard !recipients.isEmpty else { return offer.chunkCount - 1 }
            return recipients.map { acknowledgedIndexes[$0] ?? -1 }.min() ?? -1
        }

        var hasFinishedForEveryone: Bool {
            completedRecipients.isSuperset(of: recipients)
        }
    }

    /// A download in progress.
    @MainActor
    fileprivate final class Download {
        let offer: FileOffer
        let senderApplicationID: String
        let destinationURL: URL
        var handle: FileHandle?
        var nextExpectedIndex = 0
        var hasher = SHA256()

        init(offer: FileOffer, senderApplicationID: String, destinationURL: URL) {
            self.offer = offer
            self.senderApplicationID = senderApplicationID
            self.destinationURL = destinationURL
        }
    }

    // MARK: - Observable state

    /// State keyed by `transferID`, for both uploads and downloads.
    public private(set) var states: [UUID: FileTransferState] = [:]
    /// Files successfully received and available on disk.
    public private(set) var receivedFiles: [UUID: URL] = [:]
    /// Stable local copy for each chat attachment, whether sent or received.
    private var localFiles: [UUID: URL] = [:]

    // MARK: - Internal state

    private var uploads: [UUID: Upload] = [:]
    private var downloads: [UUID: Download] = [:]

    private let identity: LocalP2PIdentity
    private unowned let coordinator: RoomCoordinator

    /// Staging temporaries and incomplete files for an in-progress download.
    private let inboxDirectory: URL
    /// Stable cache so the chat bubble and viewer don't depend on the source temporary.
    private let attachmentDirectory: URL

    // MARK: - Init

    public init(identity: LocalP2PIdentity, coordinator: RoomCoordinator) {
        self.identity = identity
        self.coordinator = coordinator

        let cachesDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        self.inboxDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2p-inbox", isDirectory: true)
        self.attachmentDirectory = cachesDirectory
            .appendingPathComponent("p2p-attachments", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: inboxDirectory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: attachmentDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Sending

    /// Offers a file from disk to the room's members.
    @discardableResult
    public func offer(
        fileURL: URL,
        fileName: String? = nil,
        mimeType: String,
        in session: RoomSession,
        isTemporarySource: Bool = false
    ) throws -> ChatAttachment {
        guard session.features.hasFileTransfer else {
            throw RoomError.featureUnavailable("archivos")
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        guard fileSize > 0, fileSize <= P2PLimits.maximumTransferBytes else {
            throw FileTransferError.tooLarge(fileSize)
        }

        let checksum = try Self.checksum(of: fileURL)
        let chunkSize = P2PLimits.transferChunkBytes
        let chunkCount = Int((fileSize + Int64(chunkSize) - 1) / Int64(chunkSize))

        let offer = FileOffer(
            transferID: UUID(),
            messageID: nil,
            roomID: session.roomID,
            fileName: fileName ?? fileURL.lastPathComponent,
            mimeType: mimeType,
            fileSize: fileSize,
            checksum: checksum,
            chunkCount: chunkCount,
            chunkSize: chunkSize
        )

        let recipients = session.remoteMembers.map(\.applicationID)
        let stableURL = localURL(for: offer)
        do {
            try FileManager.default.copyItem(at: fileURL, to: stableURL)
        } catch {
            if isTemporarySource {
                try? FileManager.default.removeItem(at: fileURL)
            }
            throw FileTransferError.writeFailed(
                "No se pudo preparar la copia local: \(error.localizedDescription)"
            )
        }

        let upload = Upload(
            offer: offer,
            sourceURL: stableURL,
            recipients: recipients,
            temporarySourceURL: isTemporarySource ? fileURL : nil
        )
        uploads[offer.transferID] = upload
        localFiles[offer.transferID] = stableURL
        states[offer.transferID] = .offered

        session.chat?.updateTransfer(offer.transferID, state: .offered)
        outbox(for: session)?.send(
            FileTransferMessage.offer(offer),
            channel: .fileTransfer
        )

        // With no recipients there's nothing to transfer, but the local
        // attachment still needs to show up in chat.
        if recipients.isEmpty {
            uploads.removeValue(forKey: offer.transferID)
            states[offer.transferID] = .completed(url: stableURL)
            session.chat?.updateTransfer(offer.transferID, state: .completed(url: stableURL))
            cleanUpTemporarySource(of: upload)
        }

        return ChatAttachment(
            transferID: offer.transferID,
            fileName: offer.fileName,
            mimeType: offer.mimeType,
            fileSize: offer.fileSize,
            checksum: offer.checksum
        )
    }

    /// Offers in-memory data by first writing it to a temporary file.
    @discardableResult
    public func offer(
        data: Data,
        fileName: String,
        mimeType: String,
        in session: RoomSession
    ) throws -> ChatAttachment {
        guard data.count <= P2PLimits.maximumTransferBytes else {
            throw FileTransferError.tooLarge(Int64(data.count))
        }

        let temporaryURL = inboxDirectory.appendingPathComponent("\(UUID().uuidString)-\(fileName)")
        try data.write(to: temporaryURL, options: .atomic)

        return try offer(
            fileURL: temporaryURL,
            fileName: fileName,
            mimeType: mimeType,
            in: session,
            isTemporarySource: true
        )
    }

    public func cancel(_ transferID: UUID, in session: RoomSession) {
        if let upload = uploads.removeValue(forKey: transferID) {
            upload.pumpTask?.cancel()
            try? upload.handle?.close()
            cleanUpTemporarySource(of: upload)
            cleanUpLocalFile(for: transferID)

            outbox(for: session)?.send(
                FileTransferMessage.cancel(FileTransferRejection(
                    transferID: transferID,
                    roomID: session.roomID,
                    reason: "El emisor canceló la transferencia."
                )),
                channel: .fileTransfer
            )
        }

        if let download = downloads.removeValue(forKey: transferID) {
            try? download.handle?.close()
            try? FileManager.default.removeItem(at: download.destinationURL)

            outbox(for: session)?.send(
                FileTransferMessage.cancel(FileTransferRejection(
                    transferID: transferID,
                    roomID: session.roomID,
                    reason: "El receptor canceló la transferencia."
                )),
                channel: .fileTransfer,
                to: [download.senderApplicationID]
            )
        }

        update(transferID, state: .cancelled, in: session)
    }

    // MARK: - Receiving

    /// Entry point for the `.fileTransfer` channel.
    public func handle(envelope: RoomEnvelope, from member: RoomMember, in session: RoomSession) {
        guard let message = try? envelope.decodePayload(as: FileTransferMessage.self) else { return }

        switch message {
        case .offer(let offer):
            accept(offer: offer, from: member, in: session)

        case .accept(let control):
            // Only a recipient of this offer can accept it.
            guard uploads[control.transferID]?.recipients.contains(member.applicationID) == true
            else { return }
            startPumping(control.transferID, in: session)

        case .reject(let rejection), .cancel(let rejection):
            guard isCounterparty(member, of: rejection.transferID) else { return }
            abort(rejection.transferID, reason: rejection.reason, in: session)

        case .acknowledge(let ack):
            guard let upload = uploads[ack.transferID],
                  upload.recipients.contains(member.applicationID) else { return }
            let previous = upload.acknowledgedIndexes[member.applicationID] ?? -1
            upload.acknowledgedIndexes[member.applicationID] = max(previous, ack.receivedThroughIndex)
            startPumping(ack.transferID, in: session)

        case .chunk(let chunk):
            receive(chunk: chunk, from: member, in: session)

        case .completed(let control):
            guard let upload = uploads[control.transferID],
                  upload.recipients.contains(member.applicationID) else { return }
            upload.completedRecipients.insert(member.applicationID)
            // Don't close on the first recipient to finish: the others would
            // be left missing chunks.
            guard upload.hasFinishedForEveryone else { return }
            finishUpload(upload, in: session)
        }
    }

    /// `true` if the member is a counterparty of this transfer, either as a
    /// recipient of our upload or the sender of our download.
    private func isCounterparty(_ member: RoomMember, of transferID: UUID) -> Bool {
        if let upload = uploads[transferID] {
            return upload.recipients.contains(member.applicationID)
        }
        if let download = downloads[transferID] {
            return download.senderApplicationID == member.applicationID
        }
        return false
    }

    public func state(of transferID: UUID) -> FileTransferState? {
        states[transferID]
    }

    /// Stable local URL for the attachment, whether this device sent it or
    /// finished receiving it from the room.
    public func localFileURL(for transferID: UUID) -> URL? {
        guard let url = localFiles[transferID] ?? receivedFiles[transferID],
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    /// Compatibility API for consumers that only care about downloads.
    public func receivedFileURL(for transferID: UUID) -> URL? {
        localFileURL(for: transferID)
    }
}

// MARK: - Sending by chunks

@MainActor
private extension FileTransferService {

    func startPumping(_ transferID: UUID, in session: RoomSession) {
        guard let upload = uploads[transferID], upload.pumpTask == nil else { return }

        if upload.handle == nil {
            upload.handle = try? FileHandle(forReadingFrom: upload.sourceURL)
        }
        guard let handle = upload.handle else {
            abort(transferID, reason: "No se pudo leer el archivo.", in: session)
            return
        }

        // Progress isn't reset when refilling the window: it's recomputed
        // from the chunks already sent.
        update(
            transferID,
            state: .transferring(
                progress: Double(upload.nextChunkIndex) / Double(max(1, upload.offer.chunkCount))
            ),
            in: session
        )

        upload.pumpTask = Task { @MainActor [weak self] in
            defer { upload.pumpTask = nil }

            while !Task.isCancelled, upload.nextChunkIndex < upload.offer.chunkCount {
                // Backpressure: never get more than one window ahead of what
                // the slowest recipient has acknowledged.
                let inFlight = upload.nextChunkIndex - upload.slowestAcknowledgedIndex - 1
                guard inFlight < P2PLimits.transferWindowChunks else { return }

                guard let self else { return }

                let offset = UInt64(upload.nextChunkIndex) * UInt64(upload.offer.chunkSize)
                guard let data = try? Self.read(
                    handle: handle,
                    offset: offset,
                    length: upload.offer.chunkSize
                ) else {
                    self.abort(upload.offer.transferID, reason: "Error al leer el archivo.", in: session)
                    return
                }

                self.outbox(for: session)?.send(
                    FileTransferMessage.chunk(FileChunk(
                        transferID: upload.offer.transferID,
                        index: upload.nextChunkIndex,
                        data: data
                    )),
                    channel: .fileTransfer,
                    to: upload.recipients
                )

                upload.nextChunkIndex += 1

                let progress = Double(upload.nextChunkIndex) / Double(upload.offer.chunkCount)
                self.update(
                    upload.offer.transferID,
                    state: .transferring(progress: progress),
                    in: session
                )

                // Yields so the UI and other lanes get a turn.
                await Task.yield()
            }
        }
    }

    func finishUpload(_ upload: Upload, in session: RoomSession) {
        upload.pumpTask?.cancel()
        try? upload.handle?.close()
        upload.handle = nil
        uploads.removeValue(forKey: upload.offer.transferID)

        update(upload.offer.transferID, state: .completed(url: upload.sourceURL), in: session)
        cleanUpTemporarySource(of: upload)
    }

    func cleanUpTemporarySource(of upload: Upload) {
        guard let temporarySourceURL = upload.temporarySourceURL else { return }
        try? FileManager.default.removeItem(at: temporarySourceURL)
    }

    func cleanUpLocalFile(for transferID: UUID) {
        guard let localURL = localFiles.removeValue(forKey: transferID) else { return }
        receivedFiles.removeValue(forKey: transferID)
        try? FileManager.default.removeItem(at: localURL)
    }

    func localURL(for offer: FileOffer) -> URL {
        let safeFileName = Self.safeFileName(offer.fileName)
        return attachmentDirectory.appendingPathComponent(
            "\(offer.transferID.uuidString)-\(safeFileName)"
        )
    }

    static func safeFileName(_ fileName: String) -> String {
        let lastPathComponent = URL(fileURLWithPath: fileName).lastPathComponent
        return lastPathComponent.isEmpty || lastPathComponent == "."
            ? "archivo"
            : lastPathComponent
    }

    static func read(handle: FileHandle, offset: UInt64, length: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: length) ?? Data()
    }
}

// MARK: - Receiving by chunks

@MainActor
private extension FileTransferService {

    func accept(offer: FileOffer, from member: RoomMember, in session: RoomSession) {
        guard offer.roomID == session.roomID else { return }

        guard offer.fileSize > 0, offer.fileSize <= P2PLimits.maximumTransferBytes else {
            reject(offer, reason: FileTransferError.tooLarge(offer.fileSize).localizedDescription, in: session, to: member)
            return
        }

        guard offer.chunkCount > 0, offer.chunkSize > 0,
              offer.chunkSize <= P2PLimits.transferChunkBytes * 4 else {
            reject(offer, reason: "Oferta de archivo no válida.", in: session, to: member)
            return
        }

        let destinationURL = localURL(for: offer)

        try? FileManager.default.removeItem(at: destinationURL)
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: destinationURL) else {
            reject(offer, reason: "No se pudo preparar el archivo.", in: session, to: member)
            return
        }

        let download = Download(
            offer: offer,
            senderApplicationID: member.applicationID,
            destinationURL: destinationURL
        )
        download.handle = handle
        downloads[offer.transferID] = download

        update(offer.transferID, state: .accepted, in: session)

        outbox(for: session)?.send(
            FileTransferMessage.accept(FileTransferControl(
                transferID: offer.transferID,
                roomID: session.roomID
            )),
            channel: .fileTransfer,
            to: [member.applicationID]
        )
    }

    func reject(_ offer: FileOffer, reason: String, in session: RoomSession, to member: RoomMember) {
        update(offer.transferID, state: .failed(reason), in: session)
        outbox(for: session)?.send(
            FileTransferMessage.reject(FileTransferRejection(
                transferID: offer.transferID,
                roomID: session.roomID,
                reason: reason
            )),
            channel: .fileTransfer,
            to: [member.applicationID]
        )
    }

    func receive(chunk: FileChunk, from member: RoomMember, in session: RoomSession) {
        guard let download = downloads[chunk.transferID],
              download.senderApplicationID == member.applicationID,
              let handle = download.handle else { return }

        // Only the next chunk is accepted: TCP preserves order, so this
        // detects any gap without needing to reorder in memory.
        guard chunk.index == download.nextExpectedIndex else { return }

        do {
            try handle.write(contentsOf: chunk.data)
        } catch {
            abort(chunk.transferID, reason: error.localizedDescription, in: session)
            return
        }

        download.hasher.update(data: chunk.data)
        download.nextExpectedIndex += 1

        let progress = Double(download.nextExpectedIndex) / Double(download.offer.chunkCount)
        update(chunk.transferID, state: .transferring(progress: progress), in: session)

        let isComplete = download.nextExpectedIndex == download.offer.chunkCount
        let shouldAcknowledge = isComplete
            || download.nextExpectedIndex % max(1, P2PLimits.transferWindowChunks / 2) == 0

        if shouldAcknowledge {
            outbox(for: session)?.send(
                FileTransferMessage.acknowledge(FileTransferAcknowledgement(
                    transferID: chunk.transferID,
                    roomID: session.roomID,
                    receivedThroughIndex: download.nextExpectedIndex - 1
                )),
                channel: .fileTransfer,
                to: [member.applicationID]
            )
        }

        guard isComplete else { return }
        completeDownload(download, in: session, notifying: member)
    }

    func completeDownload(_ download: Download, in session: RoomSession, notifying member: RoomMember) {
        try? download.handle?.close()
        download.handle = nil
        downloads.removeValue(forKey: download.offer.transferID)

        let digest = download.hasher.finalize()
        let checksum = digest.map { String(format: "%02x", $0) }.joined()

        guard checksum == download.offer.checksum else {
            try? FileManager.default.removeItem(at: download.destinationURL)
            update(
                download.offer.transferID,
                state: .failed(FileTransferError.checksumMismatch.localizedDescription),
                in: session
            )
            return
        }

        receivedFiles[download.offer.transferID] = download.destinationURL
        localFiles[download.offer.transferID] = download.destinationURL
        update(
            download.offer.transferID,
            state: .completed(url: download.destinationURL),
            in: session
        )

        outbox(for: session)?.send(
            FileTransferMessage.completed(FileTransferControl(
                transferID: download.offer.transferID,
                roomID: session.roomID
            )),
            channel: .fileTransfer,
            to: [member.applicationID]
        )
    }

    func abort(_ transferID: UUID, reason: String, in session: RoomSession) {
        if let upload = uploads.removeValue(forKey: transferID) {
            upload.pumpTask?.cancel()
            try? upload.handle?.close()
            cleanUpTemporarySource(of: upload)
            cleanUpLocalFile(for: transferID)
        }

        if let download = downloads.removeValue(forKey: transferID) {
            try? download.handle?.close()
            try? FileManager.default.removeItem(at: download.destinationURL)
        }

        update(transferID, state: .failed(reason), in: session)
    }
}

// MARK: - Utilities

@MainActor
private extension FileTransferService {

    func update(_ transferID: UUID, state: FileTransferState, in session: RoomSession) {
        states[transferID] = state
        session.chat?.updateTransfer(transferID, state: state)
    }

    /// The room's sender, fetched from the coordinator to avoid duplicating state.
    func outbox(for session: RoomSession) -> RoomOutbox? {
        coordinator.outbox(for: session.roomID)
    }

    /// Streaming SHA-256: never loads the whole file into memory.
    static func checksum(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let block = try handle.read(upToCount: P2PLimits.transferChunkBytes), !block.isEmpty {
            hasher.update(data: block)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
