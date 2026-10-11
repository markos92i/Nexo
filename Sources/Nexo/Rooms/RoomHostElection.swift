import Foundation

struct RoomHostElection {
    struct Result: Equatable {
        let applicationID: String
        let skippedApplicationIDs: [String]
    }

    static func successor(
        in members: [RoomMember],
        after failedHostApplicationID: String,
        availableApplicationIDs: Set<String>
    ) -> Result? {
        guard !members.isEmpty,
              let failedIndex = members.firstIndex(where: {
                  $0.applicationID == failedHostApplicationID
              })
        else { return nil }

        var skipped: [String] = []
        for offset in 1..<members.count {
            let applicationID = members[(failedIndex + offset) % members.count].applicationID
            guard applicationID != failedHostApplicationID else { continue }
            if availableApplicationIDs.contains(applicationID) {
                return Result(
                    applicationID: applicationID,
                    skippedApplicationIDs: skipped
                )
            }
            skipped.append(applicationID)
        }
        return nil
    }

    static func validates(
        _ result: Result,
        in members: [RoomMember],
        after failedHostApplicationID: String
    ) -> Bool {
        guard let expected = successor(
            in: members,
            after: failedHostApplicationID,
            availableApplicationIDs: [result.applicationID]
        ) else { return false }
        return expected == result
    }
}
