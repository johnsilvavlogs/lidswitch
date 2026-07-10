import Darwin
import Foundation

struct HelperStatusTombstone: Equatable {
    let state: String
    let reason: String
    let sessionID: UUID?
    let recoveryBudget: String?

    var isTerminal: Bool {
        state == "inactive" || state == "blocked" || state == "recovery-required"
    }

    var recoveryReserved: Bool { recoveryBudget == "reserved" || reason == "override-drift-observed" }
    var recoverySpent: Bool { recoveryBudget == "spent" || reason == "override-recovered" || reason == "verified-after-override-recovery" }

    static func read(path: String, expectedOwnerUID: uid_t = geteuid()) -> HelperStatusTombstone? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_uid == expectedOwnerUID,
              metadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
              metadata.st_size >= 0,
              metadata.st_size <= 4_096
        else { return nil }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while data.count <= 4_096 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            return nil
        }
        guard data.count <= 4_096,
              let raw = String(data: data, encoding: .utf8)
        else { return nil }

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
