//
//  ChatRoomSession.swift
//  Nexo
//

import Foundation

// MARK: - ChatMessageKind

public enum ChatMessageKind: String, Codable, Sendable {
    case text
    /// App-only display notice; never accepted into room chat history.
    case systemInfo
    /// Message with an attachment. Content arrives over the transfer channel.
    case attachment
}

// MARK: - ChatActivityInvitation

/// Reference to an already-created activity, presented as a chat invitation.
/// The control announcement remains the activity's authority; this payload
/// only keeps a reference to render it as a bubble.
public struct ChatActivityInvitation: Codable, Sendable, Hashable {
    public let activityID: ActivityID
    public let roomID: RoomID
    public let kind: ActivityKind

    public init(activityID: ActivityID, roomID: RoomID, kind: ActivityKind) {
        self.activityID = activityID
        self.roomID = roomID
        self.kind = kind
    }
}

// MARK: - ChatAttachment

/// Attachment metadata carried in a chat message.
///
/// Content does **not** travel here: only the description and the
/// `transferID` used to match chunks on the `.fileTransfer` channel.
public struct ChatAttachment: Codable, Sendable, Hashable {
    public let transferID: UUID
    public let fileName: String
    public let mimeType: String
    public let fileSize: Int64
    public let checksum: String

    public init(transferID: UUID, fileName: String, mimeType: String, fileSize: Int64, checksum: String) {
        self.transferID = transferID
        self.fileName = fileName
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.checksum = checksum
    }

    public var isImage: Bool { mimeType.hasPrefix("image/") }
}

// MARK: - ChatMessage

public struct ChatMessage: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let roomID: RoomID
    public let senderApplicationID: String
    public var senderDisplayName: String
    public var body: String
    public let kind: ChatMessageKind
    public var attachment: ChatAttachment?
    /// Optional, so messages from older peers still decode as plain text.
    public var invitation: ChatActivityInvitation?
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        roomID: RoomID,
        senderApplicationID: String,
        senderDisplayName: String,
        body: String,
        kind: ChatMessageKind = .text,
        attachment: ChatAttachment? = nil,
        invitation: ChatActivityInvitation? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.roomID = roomID
        self.senderApplicationID = senderApplicationID
        self.senderDisplayName = senderDisplayName
        self.body = body
        self.kind = kind
        self.attachment = attachment
        self.invitation = invitation
        self.timestamp = timestamp
    }

    public var isSystem: Bool { kind == .systemInfo }

    public static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool { lhs.id == rhs.id }
}

// MARK: - ChatRoomSession

/// Chat for one specific room.
///
/// Only exists if the room declares `RoomFeatures.chat`, so a game-only room
/// carries no chat history or UI.
@NexoActor
public final class ChatRoomSession {

    public let roomID: RoomID

    // MARK: - State

    public private(set) var messages: [ChatMessage] = []
    /// Live transfers associated with this chat's messages.
    public private(set) var transfers: [UUID: FileTransferState] = [:]

    private let membership: RoomMembership
    private let outbox: RoomOutbox
    private let identity: LocalP2PIdentity
    /// Called after any visible change so the owning room can republish its
    /// snapshot. The chat has no stream of its own: messages travel over the
    /// transfer and chat channels and the room already aggregates both.
    var onChange: (@NexoActor () -> Void)?
    /// IDs already seen: the same message can arrive again via replay. Kept
    /// independently of the visible window so an old replay never reinserts a
    /// message already dropped from `messages`. IDs no longer visible are kept
    /// only for the recovery window and up to the journal limit.
    private var seenMessageIDs: Set<UUID> = []
    private var seenMessageDates: [UUID: Date] = [:]

    // MARK: - Init

    public convenience init(
        roomID: RoomID,
        outbox: RoomOutbox,
        identity: LocalP2PIdentity,
        members: [RoomMember] = []
    ) {
        self.init(roomID: roomID, outbox: outbox, identity: identity, membership: RoomMembership(members: members))
    }

    init(roomID: RoomID, outbox: RoomOutbox, identity: LocalP2PIdentity, membership: RoomMembership) {
        self.roomID = roomID
        self.membership = membership
        self.outbox = outbox
        self.identity = identity
    }

    // MARK: - Sending

    public func send(text: String) {
        send(text: text, invitation: nil)
    }

    /// Publishes text or an activity invitation. The activity must already
    /// have been created by the coordinator, which remains the authority for
    /// its participants and state.
    public func send(text: String, invitation: ChatActivityInvitation?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || invitation != nil else { return }
        if let invitation, invitation.roomID != roomID { return }

        let message = ChatMessage(
            roomID: roomID,
            senderApplicationID: identity.applicationID,
            senderDisplayName: identity.displayName,
            body: String(trimmed.prefix(4_000)),
            invitation: invitation
        )

        append(message)
        let recipients = membership.members
            .filter { $0.applicationID != identity.applicationID }
            .map(\.applicationID)
        outbox.send(message, channel: .chat, to: recipients)
        onChange?()
    }

    /// Publishes the message that accompanies an attachment. Content is
    /// moved by `FileTransferService` on its own channel.
    public func send(attachment: ChatAttachment, caption: String) {
        let message = ChatMessage(
            roomID: roomID,
            senderApplicationID: identity.applicationID,
            senderDisplayName: identity.displayName,
            body: String(caption.prefix(4_000)),
            kind: .attachment,
            attachment: attachment
        )

        if append(message), transfers[attachment.transferID] == nil {
            transfers[attachment.transferID] = .accepted
        }
        let recipients = membership.members
            .filter { $0.applicationID != identity.applicationID }
            .map(\.applicationID)
        outbox.send(message, channel: .chat, to: recipients)
        onChange?()
    }

    // MARK: - Receiving

    public func receive(payload: Data, from member: RoomMember) {
        guard var message = try? P2PCoder.decode(ChatMessage.self, from: payload) else { return }

        // The declared sender must match the peer known to the room, and the
        // message must belong to this room. System notices are local display only.
        guard message.senderApplicationID == member.applicationID,
              message.roomID == roomID,
              message.kind != .systemInfo else { return }

        // A plain message can't carry attachment metadata, and an attachment
        // message must declare its offer. An invitation and an attachment
        // aren't the same kind of message either.
        if message.kind == .attachment {
            guard message.attachment != nil, message.invitation == nil else { return }
        } else {
            guard message.attachment == nil else { return }
        }

        // The invitation is just a visual reference. If it points to another
        // room, keep the text but drop the action.
        if let invitation = message.invitation, invitation.roomID != roomID {
            message.invitation = nil
        }

        // The display name is the one the room knows, not whatever the peer
        // embedded in the payload.
        message.senderDisplayName = member.displayName
        message.body = String(message.body.prefix(4_000))
        guard append(message) else { return }

        if let attachment = message.attachment, transfers[attachment.transferID] == nil {
            transfers[attachment.transferID] = .offered
        }
        onChange?()
    }

    /// Merges history sent by the host during resume. UUID deduplication
    /// makes it safe to combine with replay.
    public func merge(messages: [ChatMessage]) -> Bool {
        var didChange = false

        for original in messages
        where original.roomID == roomID && original.kind != .systemInfo {
            var message = original
            message.body = String(message.body.prefix(4_000))
            if let invitation = message.invitation, invitation.roomID != roomID {
                message.invitation = nil
            }

            guard append(message) else { continue }
            didChange = true

            if let attachment = message.attachment, transfers[attachment.transferID] == nil {
                transfers[attachment.transferID] = .offered
            }
        }

        if didChange { onChange?() }
        return didChange
    }

    // MARK: - Transfers

    public func updateTransfer(_ transferID: UUID, state: FileTransferState) {
        transfers[transferID] = state
        onChange?()
    }

    public func transferState(for transferID: UUID) -> FileTransferState? {
        transfers[transferID]
    }

    public func clearHistory() {
        messages.removeAll()
        seenMessageIDs.removeAll()
        seenMessageDates.removeAll()
        transfers.removeAll()
        onChange?()
    }

    // MARK: - Private Helpers

    @discardableResult
    private func append(_ message: ChatMessage) -> Bool {
        pruneSeenMessageIDs()
        guard seenMessageIDs.insert(message.id).inserted else { return false }
        seenMessageDates[message.id] = Date()
        let index = messages.firstIndex {
            $0.timestamp > message.timestamp
                || ($0.timestamp == message.timestamp && $0.id.uuidString > message.id.uuidString)
        } ?? messages.endIndex
        messages.insert(message, at: index)

        if messages.count > P2PLimits.chatHistoryLimit {
            messages.removeFirst(messages.count - P2PLimits.chatHistoryLimit)
            let visibleTransfers = Set(messages.compactMap(\.attachment?.transferID))
            transfers = transfers.filter { visibleTransfers.contains($0.key) }
        }
        pruneSeenMessageIDs()
        return true
    }

    private func pruneSeenMessageIDs() {
        let visibleIDs = Set(messages.map(\.id))
        let cutoff = Date().addingTimeInterval(-P2PLimits.recoveryJournalRetention)
        let expiredIDs = seenMessageDates.compactMap { id, date in
            !visibleIDs.contains(id) && date < cutoff ? id : nil
        }

        for id in expiredIDs {
            seenMessageDates.removeValue(forKey: id)
            seenMessageIDs.remove(id)
        }

        let nonVisibleEntries = seenMessageDates.filter { id, _ in
            !visibleIDs.contains(id)
        }
        let excessCount = nonVisibleEntries.count - P2PLimits.recoveryJournalLimit
        guard excessCount > 0 else { return }

        let oldestIDs = nonVisibleEntries
            .sorted { lhs, rhs in
                if lhs.value != rhs.value {
                    return lhs.value < rhs.value
                }
                return lhs.key.uuidString < rhs.key.uuidString
            }
            .prefix(excessCount)
            .map(\.key)

        for id in oldestIDs {
            seenMessageDates.removeValue(forKey: id)
            seenMessageIDs.remove(id)
        }
    }
}
