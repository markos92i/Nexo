//
//  RoomChatHistory.swift
//  Nexo
//

import Foundation

enum RoomChatHistory {

    /// Authority comes from the envelope; display names come from known members.
    static func validatedMessages(
        _ messages: [ChatMessage],
        roomID: RoomID,
        members: [RoomMember],
        senderApplicationID: String,
        hostApplicationID: String
    ) -> [ChatMessage] {
        guard messages.count <= P2PLimits.recoveryChatMessageLimit else { return [] }

        let memberIDs = Set(members.map(\.applicationID))
        let isRoomHost = senderApplicationID == hostApplicationID
        var messageIDs = Set<UUID>()
        var validatedMessages: [ChatMessage] = []
        validatedMessages.reserveCapacity(messages.count)

        for original in messages {
            guard messageIDs.insert(original.id).inserted,
                  original.roomID == roomID,
                  !original.senderApplicationID.isEmpty,
                  original.body.count <= 4_000,
                  original.kind != .systemInfo,
                  memberIDs.contains(original.senderApplicationID),
                  isRoomHost || original.senderApplicationID == senderApplicationID
            else { continue }

            switch original.kind {
            case .text:
                guard original.attachment == nil else { continue }

            case .attachment:
                guard let attachment = original.attachment,
                      original.invitation == nil,
                      attachment.fileSize > 0,
                      attachment.fileSize <= P2PLimits.maximumTransferBytes,
                      !attachment.fileName.isEmpty,
                      attachment.fileName.utf8.count <= 512,
                      !attachment.mimeType.isEmpty,
                      attachment.mimeType.utf8.count <= 256,
                      !attachment.checksum.isEmpty,
                      attachment.checksum.utf8.count <= 256
                else { continue }

            case .systemInfo:
                continue
            }

            if let invitation = original.invitation,
               invitation.roomID != roomID {
                continue
            }

            guard let member = members.first(where: {
                $0.applicationID == original.senderApplicationID
            }) else { continue }

            var message = original
            message.senderDisplayName = member.displayName
            validatedMessages.append(message)
        }

        return validatedMessages
    }

    static func chunks(
        _ messages: [ChatMessage],
        roomID: RoomID,
        senderApplicationID: String,
        hostApplicationID: String
    ) -> [ChatHistoryPayload] {
        let isRoomHost = senderApplicationID == hostApplicationID
        var payloads: [ChatHistoryPayload] = []
        var chunk: [ChatMessage] = []

        // System notices are device-local; guests only contribute their own messages.
        for message in messages
        where message.kind != .systemInfo
            && (isRoomHost || message.senderApplicationID == senderApplicationID) {
            let candidate = chunk + [message]
            if candidate.count <= P2PLimits.recoveryChatMessageLimit,
               fits(candidate, roomID: roomID) {
                chunk = candidate
                continue
            }

            if !chunk.isEmpty {
                payloads.append(ChatHistoryPayload(roomID: roomID, messages: chunk))
                chunk.removeAll(keepingCapacity: true)
            }

            guard fits([message], roomID: roomID) else { continue }
            chunk = [message]
        }

        if !chunk.isEmpty {
            payloads.append(ChatHistoryPayload(roomID: roomID, messages: chunk))
        }
        return payloads
    }

    private static func fits(_ messages: [ChatMessage], roomID: RoomID) -> Bool {
        let payload = ChatHistoryPayload(roomID: roomID, messages: messages)
        guard let encoded = try? P2PCoder.encode(RoomControlMessage.chatHistory(payload)) else {
            return false
        }
        return encoded.count <= P2PLimits.maximumEnvelopeBytes
    }
}
