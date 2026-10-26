import Foundation

/// Elección determinista del sucesor del host cuando el actual se vuelve
/// inalcanzable. Todos los miembros calculan el mismo resultado a partir del
/// mismo orden de miembros, sin negociación.
enum RoomHostElection {
    struct Result: Equatable {
        let deviceID: DeviceID
        let skippedDeviceIDs: [DeviceID]
    }

    static func successor(
        in members: [RoomMember],
        after failedHostDeviceID: DeviceID,
        availableDeviceIDs: Set<DeviceID>
    ) -> Result? {
        guard !members.isEmpty,
              let failedIndex = members.firstIndex(where: { $0.deviceID == failedHostDeviceID })
        else { return nil }

        var skipped: [DeviceID] = []
        for offset in 1..<members.count {
            let deviceID = members[(failedIndex + offset) % members.count].deviceID
            guard deviceID != failedHostDeviceID else { continue }
            if availableDeviceIDs.contains(deviceID) {
                return Result(deviceID: deviceID, skippedDeviceIDs: skipped)
            }
            skipped.append(deviceID)
        }
        return nil
    }

    static func validates(
        _ result: Result,
        in members: [RoomMember],
        after failedHostDeviceID: DeviceID
    ) -> Bool {
        guard let expected = successor(
            in: members,
            after: failedHostDeviceID,
            availableDeviceIDs: [result.deviceID]
        ) else { return false }
        return expected == result
    }
}
