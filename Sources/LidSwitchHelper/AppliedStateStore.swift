import Darwin
import Foundation

struct AppliedState: Equatable {
    let sessionID: UUID
    let changedSleepDisabled: Bool
    let changedACSleep: Bool
    let originalACSleep: Int?

    var storagePayload: String {
        [
            "session=\(sessionID.uuidString.lowercased())",
            "changed_sleep_disabled=\(changedSleepDisabled ? 1 : 0)",
            "changed_ac_sleep=\(changedACSleep ? 1 : 0)",
            "original_ac_sleep=\(originalACSleep.map(String.init) ?? "unknown")",
            "",
        ].joined(separator: "\n")
    }

    static func parse(_ raw: String) -> AppliedState? {
        var values: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let key = String(parts[0])
            guard values[key] == nil else { return nil }
            values[key] = String(parts[1])
        }
        guard values.count == 4,
              let sessionRaw = values["session"],
              let sessionID = UUID(uuidString: sessionRaw),
              let changedSleepRaw = values["changed_sleep_disabled"],
              let changedSleep = parseFlag(changedSleepRaw),
              let changedACRaw = values["changed_ac_sleep"],
              let changedAC = parseFlag(changedACRaw),
              let originalRaw = values["original_ac_sleep"]
        else {
            return nil
        }
        let original = originalRaw == "unknown" ? nil : Int(originalRaw)
        if originalRaw != "unknown", original == nil {
            return nil
        }
        if changedAC {
            guard let original, original > 0 else { return nil }
        } else if original != nil {
            return nil
        }
        return AppliedState(
            sessionID: sessionID,
            changedSleepDisabled: changedSleep,
            changedACSleep: changedAC,
            originalACSleep: original
        )
    }

    private static func parseFlag(_ raw: String) -> Bool? {
        if raw == "1" { return true }
        if raw == "0" { return false }
        return nil
    }
}

enum AppliedStateLoadResult: Equatable {
    case missing
    case invalid
    case success(AppliedState)
}

enum AppliedStateStore {
    private static let maximumSize: off_t = 4_096

    static func load(path: String, expectedOwnerUID: uid_t = getuid()) -> AppliedStateLoadResult {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            return errno == ENOENT ? .missing : .invalid
        }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == expectedOwnerUID,
              metadata.st_nlink == 1,
              metadata.st_size > 0,
              metadata.st_size <= maximumSize,
              metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
        else {
            return .invalid
        }

        var bytes = [UInt8](repeating: 0, count: Int(metadata.st_size))
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), remaining)
            }
            guard count > 0 else { return .invalid }
            offset += count
        }

        var trailingByte: UInt8 = 0
        guard Darwin.read(descriptor, &trailingByte, 1) == 0,
              let raw = String(bytes: bytes, encoding: .utf8),
              let state = AppliedState.parse(raw)
        else {
            return .invalid
        }
        return .success(state)
    }

    static func read(path: String) -> AppliedState? {
        guard case let .success(state) = load(path: path) else { return nil }
        return state
    }

    static func write(_ state: AppliedState, path: String) throws {
        let temp = path + ".tmp.\(UUID().uuidString)"
        let descriptor = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        var removeTemp = true
        defer {
            close(descriptor)
            if removeTemp { unlink(temp) }
        }
        let bytes = Array(state.storagePayload.utf8)
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), remaining)
            }
            guard count > 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            offset += count
        }
        guard fsync(descriptor) == 0, rename(temp, path) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        removeTemp = false
    }

    static func remove(path: String) -> Bool {
        unlink(path) == 0 || errno == ENOENT
    }
}
