import Darwin
import Foundation
import LidSwitchCore

struct HelperStatusTombstone: Equatable {
    let state: String
    let reason: String
    let sessionID: UUID?
    let recoveryBudget: String?

    var isTerminal: Bool {
        state == "inactive" || state == "terminal" || state == "blocked" || state == "recovery-required"
    }

    var recoveryReserved: Bool { recoveryBudget == "reserved" || reason == "override-drift-observed" }
    var recoverySpent: Bool { recoveryBudget == "spent" || reason == "override-recovered" || reason == "verified-after-override-recovery" }

    static func read(path: String, expectedOwnerUID: uid_t = geteuid()) -> HelperStatusTombstone? {
        let policy = BoundedFileReadPolicy(
            maximumBytes: 4_096, expectedOwnerUID: expectedOwnerUID, requireSingleLink: true,
            rejectGroupOrWorldWritable: true, requireNonEmpty: true, safeParentDepth: 1
        )
        guard case let .success(raw) = BoundedFileReader.readUTF8(path: path, policy: policy) else { return nil }

        var values: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let key = String(parts[0])
            guard values[key] == nil else { return nil }
            values[key] = String(parts[1])
        }
        guard let state = values["state"],
              let reason = values["reason"],
              let sessionRaw = values["session"]
        else { return nil }
        let sessionID: UUID?
        if sessionRaw == "none" {
            sessionID = nil
        } else if let parsed = UUID(uuidString: sessionRaw) {
            sessionID = parsed
        } else {
            return nil
        }
        let recoveryBudget = values["recovery_budget"]
        guard recoveryBudget == nil || recoveryBudget == "reserved" || recoveryBudget == "spent" else { return nil }
        return HelperStatusTombstone(
            state: state,
            reason: reason,
            sessionID: sessionID,
            recoveryBudget: recoveryBudget
        )
    }
}
