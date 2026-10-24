//
//  FileTransferService.swift
//  Nexo
//

import CryptoKit
import Foundation

// MARK: - FileTransferService

/// Room-scoped TCP transfers. Only protocol state lives on the shared actor;
/// each transfer has a separate disk actor owning its handles and checksum.
@NexoActor
public final class FileTransferService {
    @NexoActor
    private final class Upload {
        let id: UUID
        let roomID: RoomID
        let file: TransferFile
        let originalRecipients: Set<String>
        var recipients: Set<String>
        var acceptedRecipients: Set<String> = []
        var completedRecipients: Set<String> = []
        var rejectedRecipients: [String: NexoReason] = [:]
        var acknowledgedIndexes: [String: Int] = [:]
        var offer: FileOffer?
        var nextChunkIndex = 0
        var preparation: Task<PreparedTransferFile, Error>?
        var pumpTask: Task<Void, Never>?
        weak var session: RoomSession?

        init(id: UUID, session: RoomSession, file: TransferFile, recipients: Set<String>) {
            self.id = id
            self.roomID = session.roomID
            self.session = session
            self.file = file
            self.originalRecipients = recipients
            self.recipients = recipients
        }

        var slowestAcknowledgedIndex: Int {
            recipients.map { acknowledgedIndexes[$0] ?? -1 }.min() ?? -1
        }
    }

    @NexoActor
    private final class Download {
        let offer: FileOffer
        let sender: String
        let file: TransferFile
        var isPrepared = false
        var nextReceivedIndex = 0
        var nextWrittenIndex = 0
        var pendingChunks: [FileChunk] = []
        var task: Task<Void, Never>?
        weak var session: RoomSession?

        init(offer: FileOffer, sender: String, file: TransferFile, session: RoomSession) {
            self.offer = offer
            self.sender = sender
            self.file = file
            self.session = session
        }
    }

    private struct LocalFile: Sendable {
        let url: URL
        let file: TransferFile
        let size: Int64
    }

    private struct Deadline {
        let token: UUID
        let task: Task<Void, Never>
    }

    public private(set) var states: [UUID: FileTransferState] = [:]
    public private(set) var receivedFiles: [UUID: URL] = [:]
    public private(set) var recipientOutcomes: [UUID: [String: FileTransferRecipientOutcome]] = [:]

    private let storageID = UUID()
    private var uploads: [UUID: Upload] = [:]
    private var downloads: [UUID: Download] = [:]
    private var localFiles: [UUID: LocalFile] = [:]
    private var deadlines: [UUID: Deadline] = [:]
    private var retainedIDs: Set<UUID> = []
    private var terminalDates: [UUID: ContinuousClock.Instant] = [:]
    private var lastProgress: [UUID: ContinuousClock.Instant] = [:]
    private var pendingProgress: [UUID: Double] = [:]
    private var progressTasks: [UUID: Task<Void, Never>] = [:]
    private var maintenanceTask: Task<Void, Never>?
    private var maintenanceToken = UUID()
    private var cleanupTasks: [UUID: Task<Void, Never>] = [:]
    private var lastFileValidation: ContinuousClock.Instant?
    private var isValidatingFiles = false

    public init() {}

    isolated deinit {
        cancelEverythingAndReleaseStorage()
    }

    /// Deinit body kept out of the destructor: instrumenting the destructor
    /// itself crashes the Swift 6.4 frontend.
    private func cancelEverythingAndReleaseStorage() {
        maintenanceTask?.cancel()
        for deadline in deadlines.values { deadline.task.cancel() }
        for task in progressTasks.values { task.cancel() }
        var files: [UUID: TransferFile] = [:]
        for upload in uploads.values {
            upload.preparation?.cancel()
            upload.pumpTask?.cancel()
            upload.session?.outbox.send(
                FileTransferMessage.cancel(FileTransferRejection(transferID: upload.id, roomID: upload.roomID, reason: .senderCancelled)),
                channel: .fileTransfer, to: Array(upload.recipients.subtracting(upload.completedRecipients))
            )
            files[upload.file.token] = upload.file
        }
        for download in downloads.values {
            download.task?.cancel()
            download.session?.outbox.send(
                FileTransferMessage.cancel(FileTransferRejection(transferID: download.offer.transferID, roomID: download.offer.roomID, reason: .receiverCancelled)),
                channel: .fileTransfer, to: [download.sender]
            )
            files[download.file.token] = download.file
        }
        for local in localFiles.values { files[local.file.token] = local.file }
        var pinnedTokens = Set<UUID>()
        for (id, local) in localFiles where retainedIDs.contains(id) {
            pinnedTokens.insert(local.file.token)
        }
        let pendingCleanup = Array(cleanupTasks.values)
        let storageID = storageID
        // A viewer may still hold a pinned URL. Keep those files until the next
        // process, including their disk budget, rather than unlinking live media.
        Task { @NexoActor in
            for task in pendingCleanup { await task.value }
            for (token, file) in files {
                if pinnedTokens.contains(token) {
                    await file.close()
                    TransferBudget.finish(token)
                } else {
                    await file.dispose()
                    TransferBudget.release(token)
                }
            }
            await TransferStorage.shared.release(storageID, preservingFiles: !pinnedTokens.isEmpty)
        }
    }

    // MARK: - Sending

    /// Copies first, then hashes the owned copy. The original is never removed,
    /// including when the compatibility `isTemporarySource` flag is set.
    @discardableResult
    public func offer(
        fileURL: URL,
        fileName: String? = nil,
        mimeType: String,
        in session: RoomSession,
        isTemporarySource: Bool = false
    ) async throws -> ChatAttachment {
        try await prepareOffer(
            source: .file(fileURL),
            fileName: fileName ?? fileURL.lastPathComponent,
            mimeType: mimeType,
            reservedBytes: P2PLimits.maximumTransferBytes,
            in: session
        )
    }

    @discardableResult
    public func offer(
        data: Data,
        fileName: String,
        mimeType: String,
        in session: RoomSession
    ) async throws -> ChatAttachment {
        guard !data.isEmpty, data.count <= P2PLimits.maximumTransferBytes else {
            throw FileTransferError.tooLarge(Int64(data.count))
        }
        return try await prepareOffer(
            source: .data(data), fileName: fileName, mimeType: mimeType,
            reservedBytes: Int64(data.count), in: session
        )
    }

    private func prepareOffer(
        source: TransferSource,
        fileName: String,
        mimeType: String,
        reservedBytes: Int64,
        in session: RoomSession
    ) async throws -> ChatAttachment {
        try Task.checkCancellation()
        guard session.features.hasFileTransfer else { throw RoomError.featureUnavailable(.fileTransfer) }
        guard session.accessState == .joined else { throw FileTransferError.cancelled }
        guard !fileName.isEmpty, fileName.utf8.count <= 255, mimeType.utf8.count <= 255 else {
            throw FileTransferError.unsupportedType(mimeType)
        }
        prune()
        let id = UUID()
        let recipients = Set(session.remoteMembers.map(\.applicationID))
        let file = TransferFile(storageID: storageID)
        try TransferBudget.reserve(file.token, bytes: reservedBytes, peers: recipients)
        let upload = Upload(id: id, session: session, file: file, recipients: recipients)
        uploads[id] = upload
        recipientOutcomes[id] = recipients.reduce(into: [:]) { $0[$1] = .pending }
        armDeadline(id, in: session)
        let preparation = Task { try await file.prepareUpload(source: source, fileName: fileName) }
        upload.preparation = preparation
        do {
            let prepared = try await withTaskCancellationHandler {
                try await preparation.value
            } onCancel: {
                preparation.cancel()
            }
            try Task.checkCancellation()
            guard uploads[id] === upload, session.accessState == .joined else {
                throw FileTransferError.cancelled
            }
            upload.preparation = nil
            // Membership can change during the copy; never resurrect a removed peer.
            let departed = upload.recipients.filter { !session.contains($0) }
            removeRecipients(Set(departed), from: upload, reason: .peerDisconnected, in: session)
            guard uploads[id] === upload else { throw FileTransferError.cancelled }
            TransferBudget.resize(file.token, bytes: prepared.size)
            let chunkSize = P2PLimits.transferChunkBytes
            let offer = FileOffer(
                transferID: id, messageID: nil, roomID: session.roomID,
                fileName: fileName, mimeType: mimeType, fileSize: prepared.size,
                checksum: prepared.checksum,
                chunkCount: Int((prepared.size + Int64(chunkSize) - 1) / Int64(chunkSize)),
                chunkSize: chunkSize
            )
            upload.offer = offer
            localFiles[id] = LocalFile(url: prepared.url, file: file, size: prepared.size)
            update(id, state: .offered, in: session)
            if upload.originalRecipients.isEmpty {
                finishUpload(upload, in: session)
            } else {
                session.outbox.send(FileTransferMessage.offer(offer), channel: .fileTransfer, to: Array(upload.recipients))
                armDeadline(id, in: session)
            }
            return ChatAttachment(
                transferID: id, fileName: fileName, mimeType: mimeType,
                fileSize: prepared.size, checksum: prepared.checksum
            )
        } catch {
            if uploads[id] === upload {
                if Task.isCancelled || error is CancellationError || (error as? FileTransferError) == .cancelled {
                    terminate(id, state: .cancelled, reason: .senderCancelled, in: session)
                } else {
                    abort(id, reason: Self.reason(for: error), in: session)
                }
            }
            throw error
        }
    }

    public func cancel(_ transferID: UUID, in session: RoomSession) {
        let reason: NexoReason = uploads[transferID] == nil ? .receiverCancelled : .senderCancelled
        terminate(transferID, state: .cancelled, reason: reason, in: session)
    }

    func cancelAll(in session: RoomSession) {
        let ids = uploads.values.filter { $0.roomID == session.roomID }.map(\.id)
            + downloads.values.filter { $0.offer.roomID == session.roomID }.map { $0.offer.transferID }
        for id in ids { cancel(id, in: session) }
    }

    func reconcileMembers(in session: RoomSession) {
        for upload in Array(uploads.values) where upload.roomID == session.roomID {
            removeRecipients(
                Set(upload.recipients.filter { !session.contains($0) }),
                from: upload, reason: .peerDisconnected, in: session
            )
        }
        for download in Array(downloads.values)
        where download.offer.roomID == session.roomID && !session.contains(download.sender) {
            abort(download.offer.transferID, reason: .peerDisconnected, in: session)
        }
    }

    // MARK: - Receiving

    public func handle(envelope: RoomEnvelope, from member: RoomMember, in session: RoomSession) {
        guard envelope.roomID == session.roomID, envelope.channel == .fileTransfer,
              envelope.senderApplicationID == member.applicationID,
              session.accessState == .joined, session.features.hasFileTransfer,
              session.contains(member.applicationID),
              let message = try? envelope.decodePayload(as: FileTransferMessage.self) else { return }
        switch message {
        case .offer(let offer):
            accept(offer: offer, from: member, in: session)
        case .accept(let control):
            guard control.roomID == session.roomID, let upload = uploads[control.transferID],
                  upload.roomID == session.roomID, upload.offer != nil,
                  upload.recipients.contains(member.applicationID),
                  upload.acceptedRecipients.insert(member.applicationID).inserted else { return }
            armDeadline(control.transferID, in: session)
            startPumping(control.transferID, in: session)
        case .reject(let rejection), .cancel(let rejection):
            guard rejection.roomID == session.roomID else { return }
            if let upload = uploads[rejection.transferID], upload.roomID == session.roomID,
               upload.recipients.contains(member.applicationID) {
                removeRecipients([member.applicationID], from: upload, reason: rejection.reason, in: session)
            } else if let download = downloads[rejection.transferID],
                      download.offer.roomID == session.roomID, download.sender == member.applicationID {
                terminate(rejection.transferID, state: .failed(rejection.reason), reason: rejection.reason, in: session, notify: false)
            }
        case .acknowledge(let ack):
            guard ack.roomID == session.roomID, let upload = uploads[ack.transferID],
                  upload.roomID == session.roomID, upload.acceptedRecipients.contains(member.applicationID),
                  upload.recipients.contains(member.applicationID),
                  ack.receivedThroughIndex > (upload.acknowledgedIndexes[member.applicationID] ?? -1),
                  ack.receivedThroughIndex < upload.nextChunkIndex else { return }
            upload.acknowledgedIndexes[member.applicationID] = ack.receivedThroughIndex
            armDeadline(ack.transferID, in: session)
            reportUploadProgress(upload, in: session)
            startPumping(ack.transferID, in: session)
        case .chunk(let chunk):
            receive(chunk: chunk, from: member, in: session)
        case .completed(let control):
            guard control.roomID == session.roomID, let upload = uploads[control.transferID],
                  upload.roomID == session.roomID, let offer = upload.offer,
                  upload.nextChunkIndex == offer.chunkCount,
                  upload.acceptedRecipients.contains(member.applicationID),
                  upload.recipients.contains(member.applicationID),
                  upload.completedRecipients.insert(member.applicationID).inserted else { return }
            upload.acknowledgedIndexes[member.applicationID] = offer.chunkCount - 1
            recipientOutcomes[control.transferID]?[member.applicationID] = .completed
            armDeadline(control.transferID, in: session)
            if upload.completedRecipients.isSuperset(of: upload.recipients) {
                finishUpload(upload, in: session)
            } else {
                startPumping(control.transferID, in: session)
            }
        }
    }

    public func state(of transferID: UUID) -> FileTransferState? { states[transferID] }

    /// Prepared files only. No filesystem calls on the snapshot path.
    public func localFileURLs(for transferIDs: Set<UUID>) -> [UUID: URL] {
        transferIDs.reduce(into: [:]) { result, id in result[id] = localFiles[id]?.url }
    }

    public func localFileURL(for transferID: UUID) -> URL? { localFiles[transferID]?.url }

    public func receivedFileURL(for transferID: UUID) -> URL? { localFileURL(for: transferID) }

    /// Replace with the union of IDs visible in all chats, active transfers and
    /// open viewers. Pinned files are never evicted to make room for another offer.
    public func retainTransfers(_ ids: Set<UUID>) async {
        retainedIDs = ids
        prune()
        let now = ContinuousClock.now
        guard !isValidatingFiles, !localFiles.isEmpty,
              lastFileValidation.map({ now >= $0.advanced(by: .seconds(30)) }) ?? true else { return }
        isValidatingFiles = true
        lastFileValidation = now
        let missing = await Self.missingFiles(in: localFiles)
        isValidatingFiles = false
        for (id, token) in missing {
            guard let local = localFiles[id], local.file.token == token else { continue }
            localFiles.removeValue(forKey: id)
            receivedFiles.removeValue(forKey: id)
            if let upload = uploads[id] {
                if let session = upload.session { abort(id, reason: .fileReadFailed, in: session) }
                else { discardOrphanedTransfer(id) }
            } else {
                dispose(local.file)
            }
        }
        prune()
    }

    @concurrent
    private static func missingFiles(in files: [UUID: LocalFile]) async -> [UUID: UUID] {
        var missing: [UUID: UUID] = [:]
        for (id, local) in files {
            guard !Task.isCancelled else { break }
            var url = local.url
            url.removeAllCachedResourceValues()
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile != true || values?.fileSize.map(Int64.init) != local.size {
                missing[id] = local.file.token
            }
        }
        return missing
    }

    // MARK: - Sending by chunks

    private func startPumping(_ id: UUID, in session: RoomSession) {
        guard let upload = uploads[id], let offer = upload.offer,
              upload.roomID == session.roomID, upload.pumpTask == nil,
              !upload.recipients.isEmpty,
              upload.acceptedRecipients.isSuperset(of: upload.recipients) else { return }
        upload.pumpTask = Task { @NexoActor [weak self, weak session] in
            defer { upload.pumpTask = nil }
            while !Task.isCancelled, upload.nextChunkIndex < offer.chunkCount {
                guard upload.nextChunkIndex - upload.slowestAcknowledgedIndex - 1 < P2PLimits.transferWindowChunks else { return }
                let index = upload.nextChunkIndex
                let length = Int(min(Int64(offer.chunkSize), offer.fileSize - Int64(index) * Int64(offer.chunkSize)))
                do {
                    let data = try await upload.file.read(index: index, chunkSize: offer.chunkSize, length: length)
                    guard !Task.isCancelled, let self, self.uploads[id] === upload else { return }
                    guard let session = self.usableSession(session, for: id), !upload.recipients.isEmpty else { return }
                    // Publish the sent index before an ACK can refill this window.
                    upload.nextChunkIndex += 1
                    session.outbox.send(
                        FileTransferMessage.chunk(FileChunk(transferID: id, index: index, data: data)),
                        channel: .fileTransfer, to: Array(upload.recipients.subtracting(upload.completedRecipients))
                    )
                } catch {
                    guard let self, self.uploads[id] === upload, !Task.isCancelled,
                          let session = self.usableSession(session, for: id) else { return }
                    self.abort(id, reason: .fileReadFailed, in: session)
                    return
                }
            }
        }
    }

    private func reportUploadProgress(_ upload: Upload, in session: RoomSession) {
        guard let offer = upload.offer else { return }
        update(upload.id, state: .transferring(progress: Double(upload.slowestAcknowledgedIndex + 1) / Double(offer.chunkCount)), in: session)
    }

    private func removeRecipients(_ ids: Set<String>, from upload: Upload, reason: NexoReason, in session: RoomSession) {
        guard !ids.isEmpty, uploads[upload.id] === upload else { return }
        for id in ids where upload.recipients.contains(id) && !upload.completedRecipients.contains(id) {
            upload.recipients.remove(id)
            upload.acceptedRecipients.remove(id)
            upload.acknowledgedIndexes.removeValue(forKey: id)
            upload.rejectedRecipients[id] = reason
            recipientOutcomes[upload.id]?[id] = .rejected(reason)
        }
        if upload.recipients.isEmpty {
            abort(upload.id, reason: reason, in: session)
        } else if upload.offer != nil, upload.completedRecipients.isSuperset(of: upload.recipients) {
            finishUpload(upload, in: session)
        } else {
            startPumping(upload.id, in: session)
        }
    }

    private func finishUpload(_ upload: Upload, in session: RoomSession) {
        guard uploads[upload.id] === upload else { return }
        guard let local = localFiles[upload.id] else {
            abort(upload.id, reason: .fileReadFailed, in: session)
            return
        }
        uploads.removeValue(forKey: upload.id)
        upload.pumpTask?.cancel()
        upload.preparation = nil
        TransferBudget.finish(upload.file.token)
        Task { await upload.file.close() }
        // Preserve per-peer outcomes, but never report a mixed result as success.
        if let reason = upload.rejectedRecipients.sorted(by: { $0.key < $1.key }).first?.value {
            update(upload.id, state: .failed(reason), in: session)
        } else {
            update(upload.id, state: .completed(url: local.url), in: session)
        }
    }

    // MARK: - Receiving by chunks

    private func accept(offer: FileOffer, from member: RoomMember, in session: RoomSession) {
        guard offer.roomID == session.roomID, states[offer.transferID] == nil,
              terminalDates[offer.transferID] == nil, localFiles[offer.transferID] == nil,
              uploads[offer.transferID] == nil, downloads[offer.transferID] == nil else { return }
        guard offer.fileSize > 0, offer.fileSize <= P2PLimits.maximumTransferBytes else {
            reject(offer, reason: .fileTooLarge(offer.fileSize), in: session, to: member.applicationID)
            return
        }
        guard offer.chunkCount > 0, offer.chunkSize > 0,
              offer.chunkSize <= P2PLimits.transferChunkBytes * 4,
              Int64(offer.chunkCount) == (offer.fileSize + Int64(offer.chunkSize) - 1) / Int64(offer.chunkSize),
              !offer.fileName.isEmpty, offer.fileName.utf8.count <= 255, offer.mimeType.utf8.count <= 255,
              offer.checksum.utf8.count == 64,
              offer.checksum.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            reject(offer, reason: .invalidOffer, in: session, to: member.applicationID)
            return
        }
        prune()
        let file = TransferFile(storageID: storageID)
        do {
            try TransferBudget.reserve(file.token, bytes: offer.fileSize, peers: [member.applicationID])
        } catch {
            reject(offer, reason: Self.reason(for: error), in: session, to: member.applicationID)
            return
        }
        let id = offer.transferID
        let download = Download(offer: offer, sender: member.applicationID, file: file, session: session)
        downloads[id] = download
        armDeadline(id, in: session)
        download.task = Task { @NexoActor [weak self, weak session] in
            do {
                try await file.prepareDownload(fileName: offer.fileName)
                guard !Task.isCancelled, let self, self.downloads[id] === download,
                      let session = self.usableSession(session, for: id) else { return }
                guard session.contains(download.sender) else {
                    self.abort(id, reason: .peerDisconnected, in: session)
                    return
                }
                download.isPrepared = true
                download.task = nil
                self.update(id, state: .accepted, in: session)
                self.armDeadline(id, in: session)
                session.outbox.send(
                    FileTransferMessage.accept(FileTransferControl(transferID: id, roomID: session.roomID)),
                    channel: .fileTransfer, to: [download.sender]
                )
            } catch {
                guard let self, self.downloads[id] === download, !Task.isCancelled,
                      let session = self.usableSession(session, for: id) else { return }
                self.abort(id, reason: .filePrepareFailed, in: session)
            }
        }
    }

    private func reject(_ offer: FileOffer, reason: NexoReason, in session: RoomSession, to peer: String) {
        // Retain only a bounded terminal status, never a file or inbox reservation.
        update(offer.transferID, state: .failed(reason), in: session)
        session.outbox.send(
            FileTransferMessage.reject(FileTransferRejection(transferID: offer.transferID, roomID: session.roomID, reason: reason)),
            channel: .fileTransfer, to: [peer]
        )
    }

    private func receive(chunk: FileChunk, from member: RoomMember, in session: RoomSession) {
        guard let download = downloads[chunk.transferID], download.offer.roomID == session.roomID,
              download.sender == member.applicationID else { return }
        guard download.isPrepared, chunk.index == download.nextReceivedIndex,
              chunk.index < download.offer.chunkCount,
              download.nextReceivedIndex - download.nextWrittenIndex < P2PLimits.transferWindowChunks else {
            abort(chunk.transferID, reason: .invalidOffer, in: session)
            return
        }
        let remaining = download.offer.fileSize - Int64(chunk.index) * Int64(download.offer.chunkSize)
        guard chunk.data.count == Int(min(Int64(download.offer.chunkSize), remaining)) else {
            abort(chunk.transferID, reason: .invalidOffer, in: session)
            return
        }
        download.pendingChunks.append(chunk)
        download.nextReceivedIndex += 1
        drain(download, in: session)
    }

    private func drain(_ download: Download, in session: RoomSession) {
        guard download.task == nil else { return }
        let id = download.offer.transferID
        download.task = Task { @NexoActor [weak self, weak session] in
            defer { download.task = nil }
            while !Task.isCancelled, !download.pendingChunks.isEmpty {
                let chunk = download.pendingChunks.removeFirst()
                do {
                    let finalURL = try await download.file.write(chunk, offer: download.offer)
                    guard !Task.isCancelled, let self, self.downloads[id] === download,
                          let session = self.usableSession(session, for: id) else { return }
                    download.nextWrittenIndex += 1
                    self.armDeadline(id, in: session)
                    if let finalURL {
                        self.downloads.removeValue(forKey: id)
                        self.localFiles[id] = LocalFile(url: finalURL, file: download.file, size: download.offer.fileSize)
                        self.receivedFiles[id] = finalURL
                        TransferBudget.finish(download.file.token)
                        self.update(id, state: .completed(url: finalURL), in: session)
                        // No final ACK or completion can precede checksum and rename.
                        session.outbox.send(
                            FileTransferMessage.completed(FileTransferControl(transferID: id, roomID: session.roomID)),
                            channel: .fileTransfer, to: [download.sender]
                        )
                        return
                    }
                    self.update(id, state: .transferring(progress: Double(download.nextWrittenIndex) / Double(download.offer.chunkCount)), in: session)
                    if download.nextWrittenIndex % max(1, P2PLimits.transferWindowChunks / 2) == 0 {
                        session.outbox.send(
                            FileTransferMessage.acknowledge(FileTransferAcknowledgement(
                                transferID: id, roomID: session.roomID,
                                receivedThroughIndex: download.nextWrittenIndex - 1
                            )), channel: .fileTransfer, to: [download.sender]
                        )
                    }
                } catch {
                    guard let self, self.downloads[id] === download, !Task.isCancelled,
                          let session = self.usableSession(session, for: id) else { return }
                    self.abort(id, reason: Self.reason(for: error), in: session)
                    return
                }
            }
        }
    }

    // MARK: - Lifetime and progress

    private func usableSession(_ session: RoomSession?, for id: UUID) -> RoomSession? {
        guard let session else {
            discardOrphanedTransfer(id)
            return nil
        }
        guard session.accessState == .joined else {
            abort(id, reason: .sessionEnded, in: session)
            return nil
        }
        return session
    }

    private func abort(_ id: UUID, reason: NexoReason, in session: RoomSession) {
        terminate(id, state: .failed(reason), reason: reason, in: session)
    }

    private func terminate(_ id: UUID, state: FileTransferState, reason: NexoReason, in session: RoomSession, notify: Bool = true) {
        let file: TransferFile
        let peers: [String]
        if let upload = uploads[id], upload.roomID == session.roomID {
            uploads.removeValue(forKey: id)
            upload.preparation?.cancel()
            upload.pumpTask?.cancel()
            peers = Array(upload.recipients.subtracting(upload.completedRecipients))
            for peer in peers { recipientOutcomes[id]?[peer] = .rejected(reason) }
            file = upload.file
        } else if let download = downloads[id], download.offer.roomID == session.roomID {
            downloads.removeValue(forKey: id)
            download.task?.cancel()
            download.pendingChunks.removeAll()
            peers = [download.sender]
            file = download.file
        } else { return }
        if notify, !peers.isEmpty {
            session.outbox.send(
                FileTransferMessage.cancel(FileTransferRejection(transferID: id, roomID: session.roomID, reason: reason)),
                channel: .fileTransfer, to: peers
            )
        }
        if localFiles[id] != nil {
            TransferBudget.finish(file.token)
            Task { await file.close() }
        } else {
            dispose(file)
        }
        update(id, state: state, in: session)
    }

    private func armDeadline(_ id: UUID, in session: RoomSession) {
        deadlines.removeValue(forKey: id)?.task.cancel()
        let token = UUID()
        let task = Task { @NexoActor [weak self, weak session] in
            do { try await Task.sleep(for: FileTransferLimits.inactivityTimeout) }
            catch { return }
            guard !Task.isCancelled, let self, self.deadlines[id]?.token == token else { return }
            guard let session else {
                self.discardOrphanedTransfer(id)
                return
            }
            self.abort(id, reason: Self.reason(for: FileTransferError.timedOut), in: session)
        }
        deadlines[id] = Deadline(token: token, task: task)
    }

    private func discardOrphanedTransfer(_ id: UUID) {
        if let upload = uploads.removeValue(forKey: id) {
            upload.preparation?.cancel()
            upload.pumpTask?.cancel()
            if localFiles[id] == nil { dispose(upload.file) }
            else { TransferBudget.finish(upload.file.token); Task { await upload.file.close() } }
        }
        if let download = downloads.removeValue(forKey: id) {
            download.task?.cancel()
            dispose(download.file)
        }
        deadlines.removeValue(forKey: id)?.task.cancel()
        progressTasks.removeValue(forKey: id)?.cancel()
        pendingProgress.removeValue(forKey: id)
        lastProgress.removeValue(forKey: id)
        states[id] = .cancelled
        terminalDates[id] = .now
        prune()
    }

    private func update(_ id: UUID, state: FileTransferState, in session: RoomSession) {
        if case .transferring(let progress) = state {
            guard states[id]?.isTerminal != true else { return }
            let now = ContinuousClock.now
            if let last = lastProgress[id], now < last.advanced(by: .milliseconds(100)) {
                pendingProgress[id] = progress
                if progressTasks[id] == nil {
                    let deadline = last.advanced(by: .milliseconds(100))
                    progressTasks[id] = Task { @NexoActor [weak self, weak session] in
                        do { try await ContinuousClock().sleep(until: deadline) }
                        catch { return }
                        guard !Task.isCancelled, let self, let session else { return }
                        self.progressTasks.removeValue(forKey: id)
                        guard let value = self.pendingProgress.removeValue(forKey: id), self.states[id]?.isTerminal != true else { return }
                        self.update(id, state: .transferring(progress: value), in: session)
                    }
                }
                return
            }
            lastProgress[id] = now
        }
        progressTasks.removeValue(forKey: id)?.cancel()
        pendingProgress.removeValue(forKey: id)
        states[id] = state
        if state.isTerminal {
            deadlines.removeValue(forKey: id)?.task.cancel()
            lastProgress.removeValue(forKey: id)
            terminalDates[id] = .now
        }
        session.chat?.updateTransfer(id, state: state)
        if state.isTerminal { prune() }
    }

    private func prune() {
        maintenanceTask?.cancel()
        maintenanceTask = nil
        let token = UUID()
        maintenanceToken = token
        let now = ContinuousClock.now
        // The grace covers an offer finishing before its chat message is inserted.
        // Admission also counts cached files, so pinned/grace files cannot grow unbounded.
        let candidates = terminalDates.sorted { $0.value < $1.value }
        for (id, date) in candidates where !retainedIDs.contains(id) && uploads[id] == nil && downloads[id] == nil {
            guard now >= date.advanced(by: .seconds(60)) else { continue }
            if let local = localFiles.removeValue(forKey: id) {
                receivedFiles.removeValue(forKey: id)
                dispose(local.file)
            }
            terminalDates.removeValue(forKey: id)
            states.removeValue(forKey: id)
            recipientOutcomes.removeValue(forKey: id)
        }
        var terminalCount = states.values.filter(\.isTerminal).count
        for (id, _) in candidates where terminalCount > FileTransferLimits.maximumTerminalStates {
            guard states[id]?.isTerminal == true else { continue }
            states.removeValue(forKey: id)
            recipientOutcomes.removeValue(forKey: id)
            terminalCount -= 1
            // Evicting status must never unlink an attachment used by a visible message.
            if localFiles[id] == nil { terminalDates.removeValue(forKey: id) }
        }
        guard let next = terminalDates.filter({ !retainedIDs.contains($0.key) }).values.min() else { return }
        maintenanceTask = Task { @NexoActor [weak self] in
            do { try await ContinuousClock().sleep(until: next.advanced(by: .seconds(60))) }
            catch { return }
            guard !Task.isCancelled, let self, self.maintenanceToken == token else { return }
            self.prune()
        }
    }

    private func dispose(_ file: TransferFile) {
        let token = file.token
        guard cleanupTasks[token] == nil else { return }
        cleanupTasks[token] = Task { @NexoActor [weak self] in
            await file.dispose()
            TransferBudget.release(token)
            self?.cleanupTasks.removeValue(forKey: token)
        }
    }

    private static func reason(for error: any Error) -> NexoReason {
        switch error as? FileTransferError {
        case .checksumMismatch: .checksumMismatch
        case .tooLarge(let bytes): .fileTooLarge(bytes)
        case .cancelled: .senderCancelled
        case .writeFailed(let reason): reason
        case .resourceLimit: .system(domain: "Nexo.FileTransfer", code: 1)
        case .timedOut: .system(domain: "Nexo.FileTransfer", code: 2)
        case .incomplete, .bufferOverflow, .unsupportedType: .invalidOffer
        case nil: NexoReason(error: error)
        }
    }
}

// MARK: - Process-wide admission

@NexoActor
private enum TransferBudget {
    private struct Reservation {
        var bytes: Int64
        let peers: Set<String>
        var isActive = true
    }
    private static var reservations: [UUID: Reservation] = [:]

    static func reserve(_ token: UUID, bytes: Int64, peers: Set<String>) throws(FileTransferError) {
        let active = reservations.values.filter(\.isActive)
        guard active.count < FileTransferLimits.maximumOpenTransfers,
              reservations.count < FileTransferLimits.maximumStoredTransfers,
              reservations.values.reduce(Int64(0), { $0 + $1.bytes }) + bytes <= FileTransferLimits.maximumReservedBytes else {
            throw .resourceLimit
        }
        for peer in peers {
            let matching = active.filter { $0.peers.contains(peer) }
            guard matching.count < FileTransferLimits.maximumOpenTransfersPerPeer,
                  matching.reduce(Int64(0), { $0 + $1.bytes }) + bytes <= FileTransferLimits.maximumReservedBytesPerPeer else {
                throw .resourceLimit
            }
        }
        reservations[token] = Reservation(bytes: bytes, peers: peers)
    }

    static func resize(_ token: UUID, bytes: Int64) { reservations[token]?.bytes = bytes }
    static func finish(_ token: UUID) { reservations[token]?.isActive = false }
    static func release(_ token: UUID) { reservations.removeValue(forKey: token) }
}

// MARK: - Disk ownership (never NexoActor or MainActor)

private enum TransferSource: Sendable {
    case file(URL)
    case data(Data)
}

private struct PreparedTransferFile: Sendable {
    let url: URL
    let size: Int64
    let checksum: String
}

private actor TransferFile {
    nonisolated let token = UUID()
    private let storageID: UUID
    private var localURL: URL?
    private var stagingURL: URL?
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var nextIndex = 0
    private var isDisposed = false
    private var preparationTask: Task<PreparedTransferFile, Error>?

    init(storageID: UUID) { self.storageID = storageID }

    isolated deinit {
        preparationTask?.cancel()
        try? handle?.close()
    }

    func prepareUpload(source: TransferSource, fileName: String) async throws -> PreparedTransferFile {
        try checkActive()
        let directory = try await TransferStorage.shared.directory(for: storageID)
        try checkActive()
        let url = directory.appendingPathComponent("\(token.uuidString)-\(Self.safeFileName(fileName))")
        localURL = url
        let task = Task { try await Self.copyAndHash(source: source, to: url) }
        preparationTask = task
        defer { preparationTask = nil }
        let prepared = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try checkActive()
        return prepared
    }

    @concurrent
    private static func copyAndHash(source: TransferSource, to url: URL) async throws -> PreparedTransferFile {
        try Task.checkCancellation()
        switch source {
        case .file(let sourceURL):
            // Stream the copy to bound memory and make cancellation/size enforcement incremental.
            let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw FileTransferError.incomplete }
            let size = Int64(values.fileSize ?? 0)
            guard size > 0, size <= P2PLimits.maximumTransferBytes else { throw FileTransferError.tooLarge(size) }
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw FileTransferError.writeFailed(.localCopyFailed) }
            let input = try FileHandle(forReadingFrom: sourceURL)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: url)
            defer { try? output.close() }
            var copied: Int64 = 0
            while true {
                try Task.checkCancellation()
                guard let block = try input.read(upToCount: P2PLimits.transferChunkBytes), !block.isEmpty else { break }
                copied += Int64(block.count)
                guard copied <= P2PLimits.maximumTransferBytes else { throw FileTransferError.tooLarge(copied) }
                try output.write(contentsOf: block)
            }
            try output.close()
        case .data(let data):
            try data.write(to: url, options: .atomic)
        }
        try Task.checkCancellation()
        // Hash the final owned bytes, not the mutable source that preceded the copy.
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var digest = SHA256()
        var size: Int64 = 0
        while true {
            try Task.checkCancellation()
            guard let block = try input.read(upToCount: P2PLimits.transferChunkBytes), !block.isEmpty else { break }
            size += Int64(block.count)
            digest.update(data: block)
        }
        guard size > 0, size <= P2PLimits.maximumTransferBytes else { throw FileTransferError.tooLarge(size) }
        return PreparedTransferFile(url: url, size: size, checksum: Self.hex(digest.finalize()))
    }

    func prepareDownload(fileName: String) async throws {
        try checkActive()
        let directory = try await TransferStorage.shared.directory(for: storageID)
        try checkActive()
        localURL = directory.appendingPathComponent("\(token.uuidString)-\(Self.safeFileName(fileName))")
        let staging = directory.appendingPathComponent("\(token.uuidString).partial")
        stagingURL = staging
        guard FileManager.default.createFile(atPath: staging.path, contents: nil) else { throw FileTransferError.writeFailed(.filePrepareFailed) }
        handle = try FileHandle(forWritingTo: staging)
    }

    func read(index: Int, chunkSize: Int, length: Int) throws -> Data {
        try checkActive()
        guard let localURL else { throw FileTransferError.incomplete }
        if handle == nil { handle = try FileHandle(forReadingFrom: localURL) }
        guard let handle else { throw FileTransferError.incomplete }
        try handle.seek(toOffset: UInt64(index) * UInt64(chunkSize))
        guard let data = try handle.read(upToCount: length), data.count == length else { throw FileTransferError.incomplete }
        return data
    }

    func write(_ chunk: FileChunk, offer: FileOffer) throws -> URL? {
        try checkActive()
        guard chunk.index == nextIndex, let handle else { throw FileTransferError.incomplete }
        try handle.write(contentsOf: chunk.data)
        hasher.update(data: chunk.data)
        nextIndex += 1
        guard nextIndex == offer.chunkCount else { return nil }
        try handle.synchronize()
        try handle.close()
        self.handle = nil
        guard Self.hex(hasher.finalize()) == offer.checksum else { throw FileTransferError.checksumMismatch }
        try checkActive()
        guard let stagingURL, let localURL else { throw FileTransferError.incomplete }
        try FileManager.default.moveItem(at: stagingURL, to: localURL)
        self.stagingURL = nil
        return localURL
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    func dispose() async {
        isDisposed = true
        if let preparationTask {
            preparationTask.cancel()
            _ = await preparationTask.result
        }
        close()
        if let stagingURL { try? FileManager.default.removeItem(at: stagingURL) }
        if let localURL { try? FileManager.default.removeItem(at: localURL) }
        stagingURL = nil
        localURL = nil
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        guard !isDisposed else { throw FileTransferError.cancelled }
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func safeFileName(_ fileName: String) -> String {
        var component = URL(fileURLWithPath: fileName).lastPathComponent
        while component.utf8.count > 180 { component.removeFirst() }
        return component.isEmpty || component == "." || component == ".." ? "file" : component
    }
}

/// Owns only the versioned Nexo cache. Legacy folders and user originals are not ours to delete.
private actor TransferStorage {
    static let shared = TransferStorage()
    private var directories: [UUID: URL] = [:]
    private var didSweep = false

    func directory(for id: UUID) throws -> URL {
        if let directory = directories[id] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let root = caches.appendingPathComponent("nexo-transfers-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if !didSweep {
            sweepOrphans(in: root)
            didSweep = true
        }
        let directory = root.appendingPathComponent("session-\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories[id] = directory
        return directory
    }

    func release(_ id: UUID, preservingFiles: Bool) {
        guard !preservingFiles, let directory = directories.removeValue(forKey: id) else { return }
        removeOwnedFiles(in: directory)
    }

    private func sweepOrphans(in root: URL) {
        guard let entries = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
        ) else { return }
        var visited = 0
        while visited < 128, let directory = entries.nextObject() as? URL {
            visited += 1
            let name = directory.lastPathComponent
            guard name.hasPrefix("session-"), UUID(uuidString: String(name.dropFirst(8))) != nil,
                  !directories.values.contains(directory),
                  let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            removeOwnedFiles(in: directory)
        }
    }

    private func removeOwnedFiles(in directory: URL) {
        guard let entries = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants]
        ) else { return }
        var visited = 0
        var containsUnknownFiles = false
        while visited < 512, let url = entries.nextObject() as? URL {
            visited += 1
            let name = url.lastPathComponent
            guard name.count > 36, UUID(uuidString: String(name.prefix(36))) != nil,
                  name.dropFirst(36).hasPrefix("-") || name.dropFirst(36) == ".partial",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true || values.isSymbolicLink == true else {
                containsUnknownFiles = true
                continue
            }
            do { try FileManager.default.removeItem(at: url) }
            catch { containsUnknownFiles = true }
        }
        if visited < 512, !containsUnknownFiles { try? FileManager.default.removeItem(at: directory) }
    }
}
