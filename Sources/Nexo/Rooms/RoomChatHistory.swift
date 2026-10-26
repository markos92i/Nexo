import Foundation

/// Validación y troceo del historial de chat para resume/replay. La autoridad del
/// contenido viene del envelope; los nombres visibles, de los miembros conocidos.
enum RoomChatHistory {

    static func validatedMessages(
        _ messages: [ChatMessage],
        roomID: RoomID,
        members: [RoomMember],
        senderDeviceID: DeviceID,
        hostDeviceID: DeviceID
    ) -> [ChatMessage] {
        guard messages.count <= Limits.recoveryChatMessageLimit else { return [] }

        let memberIDs = Set(members.map(\.deviceID))
        let isRoomHost = senderDeviceID == hostDeviceID
        var messageIDs = Set<UUID>()
        var validatedMessages: [ChatMessage] = []
        validatedMessages.reserveCapacity(messages.count)

        for original in messages {
            guard messageIDs.insert(original.id).inserted,
                  original.roomID == roomID,
                  original.body.count <= 4_000,
                  original.kind != .systemInfo,
                  memberIDs.contains(original.senderDeviceID),
                  isRoomHost || original.senderDeviceID == senderDeviceID
            else { continue }

            switch original.kind {
            case .text:
                guard original.attachment == nil else { continue }

            case .attachment:
                guard let attachment = original.attachment,
                      original.invitation == nil,
                      attachment.fileSize > 0,
                      attachment.fileSize <= Limits.maximumTransferBytes,
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

            if let invitation = original.invitation, invitation.roomID != roomID {
                continue
            }

            guard let member = members.first(where: { $0.deviceID == original.senderDeviceID }) else { continue }

            var message = original
            message.senderDisplayName = member.displayName
            validatedMessages.append(message)
        }

        return validatedMessages
    }

    static func chunks(
        _ messages: [ChatMessage],
        roomID: RoomID,
        senderDeviceID: DeviceID,
        hostDeviceID: DeviceID
    ) -> [ChatHistoryPayload] {
        let isRoomHost = senderDeviceID == hostDeviceID
        var payloads: [ChatHistoryPayload] = []
        var chunk: [ChatMessage] = []

        // Los avisos de sistema son locales; los invitados solo aportan sus mensajes.
        for message in messages
        where message.kind != .systemInfo
            && (isRoomHost || message.senderDeviceID == senderDeviceID) {
            let candidate = chunk + [message]
            if candidate.count <= Limits.recoveryChatMessageLimit,
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
        guard let encoded = try? WireCoder.encode(ControlMessage.chatHistory(payload)) else {
            return false
        }
        return encoded.count <= Limits.maximumEnvelopeBytes
    }
}
