import Darwin
import Foundation
import LidSwitchCore

enum TerminalGenerationStore {
    enum DurabilityStage: Equatable { case fileBarrier, rename, directoryBarrier, finalFileBarrier, finalVerification }

    struct DurabilityOperations: Sendable {
        let fileBarrier: @Sendable (Int32) -> Bool
        let rename: @Sendable (String, String) -> Bool
        let directoryBarrier: @Sendable (String) -> Bool
        let finalFileBarrier: @Sendable (String) -> Bool
        let verify: @Sendable (String, [UUID]) -> Bool

        static let system = DurabilityOperations(
            fileBarrier: { descriptor in fsync(descriptor) == 0 && fcntl(descriptor, F_FULLFSYNC) == 0 },
            rename: { source, destination in Darwin.rename(source, destination) == 0 },
            directoryBarrier: { directory in
                let descriptor = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard descriptor >= 0 else { return false }
                defer { close(descriptor) }
                return fsync(descriptor) == 0 && fcntl(descriptor, F_FULLFSYNC) == 0
            },
            finalFileBarrier: { path in
                let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
                guard descriptor >= 0 else { return false }
                defer { close(descriptor) }
                return fsync(descriptor) == 0 && fcntl(descriptor, F_FULLFSYNC) == 0
            },
            verify: { path, expected in
                guard case let .valid(actual) = load(path: path) else { return false }
                return actual == expected
            }
        )
    }

    private enum LoadResult {
        case missing
        case valid([UUID])
        case invalid
    }

    static func allowsActivation(sessionID: UUID, path: String) -> Bool {
        switch load(path: path) {
        case .missing:
            // The installer must create and durably verify the empty ledger.
            // Missing is unsafe: allowing it would resurrect terminal sessions
            // after a crash between rename and directory persistence.
            return false
        case let .valid(entries):
            return !entries.contains(sessionID)
        case .invalid:
            return false
        }
    }

    static func allowsNewSessions(path: String) -> Bool {
        if case .valid = load(path: path) { return true }
        return false
    }

    @discardableResult
    static func record(
        sessionID: UUID,
        path: String,
        operations: DurabilityOperations = .system
    ) -> Bool {
        var entries: [UUID]
        switch load(path: path) {
        case .missing:
            return false
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
        BenchmarkProbe.record("file_open")
        guard descriptor >= 0 else { return false }
        var removeTemp = true
        defer {
            close(descriptor)
            if removeTemp { unlink(temp) }
        }
        guard fchmod(descriptor, readableMode) == 0 else { return false }
        let bytes = Array(payload.utf8)
        BenchmarkProbe.record("decoded_bytes", count: bytes.count)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 { BenchmarkProbe.record("file_write") }
            guard written > 0 else { return false }
            offset += written
        }
        BenchmarkProbe.record("file_fsync")
        BenchmarkProbe.record("file_rename")
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard operations.fileBarrier(descriptor) else { return false }
        guard operations.rename(temp, path) else { return false }
        removeTemp = false
        guard operations.directoryBarrier(directory) else { return false }
        guard operations.finalFileBarrier(path) else { return false }
        return operations.verify(path, entries)
    }

    private static func load(path: String) -> LoadResult {
        let policy = BoundedFileReadPolicy(
            maximumBytes: Int(TerminalGenerationLedger.maximumBytes), expectedOwnerUID: geteuid(),
            requireSingleLink: true, rejectGroupOrWorldWritable: true,
            requireNonEmpty: false, safeParentDepth: 1
        )
        let result = BoundedFileReader.readUTF8(path: path, policy: policy)
        guard case let .success(raw) = result else {
            if case .failure(.missing) = result { return .missing }
            return .invalid
        }
        BenchmarkProbe.record("file_read")
        BenchmarkProbe.record("decoded_bytes", count: raw.utf8.count)
        guard let entries = TerminalGenerationLedger.parse(raw) else { return .invalid }
        return .valid(entries)
    }
}
