import Darwin
import Foundation
import LidSwitchCore

enum TerminalGenerationStore {
    private enum LoadResult {
        case missing
        case valid([UUID])
        case invalid
    }

    static func allowsActivation(sessionID: UUID, path: String) -> Bool {
        switch load(path: path) {
        case .missing:
            return true
        case let .valid(entries):
            return !entries.contains(sessionID)
        case .invalid:
            return false
        }
    }

    @discardableResult
    static func record(sessionID: UUID, path: String) -> Bool {
        var entries: [UUID]
        switch load(path: path) {
        case .missing:
            entries = []
        case let .valid(existing):
            entries = existing
        case .invalid:
            return false
        }
        entries.removeAll { $0 == sessionID }
        entries.append(sessionID)
        entries = Array(entries.suffix(TerminalGenerationLedger.maximumEntries))
        let payload = entries.map { $0.uuidString.lowercased() }.joined(separator: "\n") + "\n"
        let temp = path + ".tmp.\(UUID().uuidString)"
        let readableMode = mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        let descriptor = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, readableMode)
        guard descriptor >= 0 else { return false }
        var removeTemp = true
        defer {
            close(descriptor)
            if removeTemp { unlink(temp) }
        }
        guard fchmod(descriptor, readableMode) == 0 else { return false }
        let bytes = Array(payload.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            guard written > 0 else { return false }
            offset += written
        }
        guard fsync(descriptor) == 0, rename(temp, path) == 0 else { return false }
        removeTemp = false
        return true
    }

    private static func load(path: String) -> LoadResult {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return errno == ENOENT ? .missing : .invalid }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_uid == geteuid(),
              metadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
              metadata.st_size >= 0,
              metadata.st_size <= TerminalGenerationLedger.maximumBytes
        else { return .invalid }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while data.count <= TerminalGenerationLedger.maximumBytes {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 { data.append(buffer, count: count); continue }
            if count == 0 { break }
            if errno == EINTR { continue }
            return .invalid
        }
        guard data.count <= TerminalGenerationLedger.maximumBytes,
              let raw = String(data: data, encoding: .utf8)
        else { return .invalid }
        guard let entries = TerminalGenerationLedger.parse(raw) else { return .invalid }
        return .valid(entries)
    }
}
