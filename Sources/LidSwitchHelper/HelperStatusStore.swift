import Darwin
import Foundation
import LidSwitchCore

/// The public helper-status leaf is deliberately less restrictive than the
/// root-private authority files (0644 so diagnostics can read it), but it is
/// still reached only through this held root-state directory capability.
/// There is no pathname reopen after the capability is constructed.
enum HelperStatusStore {
    enum WriteStage: CaseIterable, Equatable { case open, write, fsync, fullSync, rename, reopen, close }
    /// Fault seam for the only fixed crash-transaction leaf. It is threaded
    /// through the production writer so fixtures exercise the held lock and
    /// descriptor-relative recovery rather than a parallel parser.
    enum RecoveryStage: CaseIterable, Equatable { case beforeRetire, afterRetire }
    /// A stale result carries the generation observed while holding the same
    /// descriptor-bound lock as the comparison.  Callers must not reopen the
    /// public leaf to rediscover it: another writer could otherwise race that
    /// second observation.
    enum WriteOutcome: Equatable { case written, alreadyCurrent, staleNewer(UInt64), conflict, unsafeExisting, ioFailure, indeterminate }

    @discardableResult
    static func write(task: StatusProjectionTask, path: String,
                      stageGate: (WriteStage) -> Bool = { _ in true },
                      recoveryGate: (RecoveryStage) -> Bool = { _ in true }) -> Bool {
        switch writeOutcome(task: task, path: path, stageGate: stageGate, recoveryGate: recoveryGate) {
        case .written, .alreadyCurrent, .staleNewer(_:): return true
        case .conflict, .unsafeExisting, .ioFailure, .indeterminate: return false
        }
    }

    /// The only production public-status write seam.  The private task remains
    /// dirty unless this returns `.written` or `.alreadyCurrent`; a newer
    /// public generation is intentionally not an acknowledgement for this
    /// task because its root-private successor must make that decision.
    static func writeOutcome(task: StatusProjectionTask, path: String,
                             stageGate: (WriteStage) -> Bool = { _ in true },
                             recoveryGate: (RecoveryStage) -> Bool = { _ in true }) -> WriteOutcome {
        guard let capability = StatusDirectoryCapability(path: path) else { return .unsafeExisting }
        return writeOutcome(task: task, capability: capability, stageGate: stageGate, recoveryGate: recoveryGate)
    }

    /// Test-only intake for an already identity-checked fixture directory.
    /// Production continues to accept only its canonical pathname capability;
    /// fixture callers must obtain this descriptor from `TestSandbox` and may
    /// never replace it with a pathname reopen below `/private/tmp`.
    static func writeOutcome(
        task: StatusProjectionTask,
        heldDirectoryDescriptor: Int32,
        expectations: VerifiedRootStateDirectory.Expectations,
        stageGate: (WriteStage) -> Bool = { _ in true },
        recoveryGate: (RecoveryStage) -> Bool = { _ in true }
    ) -> WriteOutcome {
        guard let capability = StatusDirectoryCapability(
            heldDirectoryDescriptor: heldDirectoryDescriptor,
            expectations: expectations
        ) else { return .unsafeExisting }
        return writeOutcome(task: task, capability: capability, stageGate: stageGate, recoveryGate: recoveryGate)
    }

    @discardableResult
    static func write(
        task: StatusProjectionTask,
        heldDirectoryDescriptor: Int32,
        expectations: VerifiedRootStateDirectory.Expectations,
        stageGate: (WriteStage) -> Bool = { _ in true },
        recoveryGate: (RecoveryStage) -> Bool = { _ in true }
    ) -> Bool {
        switch writeOutcome(
            task: task,
            heldDirectoryDescriptor: heldDirectoryDescriptor,
            expectations: expectations,
            stageGate: stageGate,
            recoveryGate: recoveryGate
        ) {
        case .written, .alreadyCurrent, .staleNewer(_:): return true
        case .conflict, .unsafeExisting, .ioFailure, .indeterminate: return false
        }
    }

    /// Test-only descriptor-held read companion to the injected legacy-runtime
    /// projection writer. It never reconstructs authority from a fixture path.
    static func read(
        heldDirectoryDescriptor: Int32,
        expectations: VerifiedRootStateDirectory.Expectations
    ) -> HelperStatusTombstone? {
        guard let capability = StatusDirectoryCapability(
            heldDirectoryDescriptor: heldDirectoryDescriptor,
            expectations: expectations
        ), case let .existing(_, _, _, payload) = capability.readProjection()
        else { return nil }
        return tombstone(payload)
    }

    private static func writeOutcome(
        task: StatusProjectionTask,
        capability: StatusDirectoryCapability,
        stageGate: (WriteStage) -> Bool,
        recoveryGate: (RecoveryStage) -> Bool
    ) -> WriteOutcome {
        return capability.withProjectionLock(recoveryGate: recoveryGate) {
            switch capability.readProjection() {
            case let .existing(generation, authority, metadata, payload):
                if generation > task.generation { return .staleNewer(generation) }
                if generation == task.generation {
                    guard authority == task.authoritySnapshot, payload == task.statusPayload else { return .conflict }
                    return capability.durablyRevalidates(payload, expected: metadata) ? .alreadyCurrent : .indeterminate
                }
                return capability.publish(
                    task.statusPayload,
                    replacing: (metadata: metadata, payload: payload),
                    stageGate: stageGate
                )
            case .absent:
                return capability.publish(task.statusPayload, replacing: nil, stageGate: stageGate)
            case .unsafe:
                return .unsafeExisting
            case .io:
                return .ioFailure
            case .indeterminate:
                return .indeterminate
            }
        }
    }

    private static func tombstone(_ payload: String) -> HelperStatusTombstone? {
        var values: [String: String] = [:]
        for line in payload.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let key = String(parts[0])
            guard values[key] == nil else { return nil }
            values[key] = String(parts[1])
        }
        guard let state = values["state"], let reason = values["reason"], let sessionRaw = values["session"] else { return nil }
        let sessionID: UUID?
        if sessionRaw == "none" { sessionID = nil }
        else if let parsed = UUID(uuidString: sessionRaw) { sessionID = parsed }
        else { return nil }
        let recoveryBudget = values["recovery_budget"]
        guard recoveryBudget == nil || recoveryBudget == "reserved" || recoveryBudget == "spent" else { return nil }
        return HelperStatusTombstone(state: state, reason: reason, sessionID: sessionID, recoveryBudget: recoveryBudget)
    }

    /// Compatibility seam for compiler-excluded historical fixtures. It is a
    /// hard no-op so no caller can recreate the pre-projection public bypass.
    @discardableResult
    static func legacyDiagnosticWrite(
        state: String, reason: String, sessionID: UUID?, path: String,
        evidence: [String: String] = [:]
    ) -> Bool {
        _ = (state, reason, sessionID, path, evidence)
        return false
    }
}

fileprivate final class StatusDirectoryCapability {
    fileprivate enum ReadResult {
        case absent
        case existing(UInt64, String, stat, String)
        case unsafe
        case io
        case indeterminate
    }

    private let directory: VerifiedRootStateDirectory
    private let directoryFD: Int32
    private let owner: uid_t
    private let group: gid_t
    private let leaf = "helper-status"
    private let lockLeaf = "helper-status.projection.lock"
    /// One closed, descriptor-relative recovery name. A random prefix would
    /// turn a crash into an unclassifiable authority-root leaf.
    private let temporaryLeaf = "helper-status.projection-temp"
    private static let maximumBytes = 4_096

    init?(path: String) {
        guard let (parent, leaf) = Self.checkedParentAndLeaf(path), leaf == "helper-status" else { return nil }
        let expectations: VerifiedRootStateDirectory.Expectations
        let policy: RootStateDirectoryAncestorPolicy
        let directory: VerifiedRootStateDirectory
        if path == ReleaseIdentity.rootStatusPath, parent == ReleaseIdentity.rootSupportDirectory {
            guard geteuid() == 0, getegid() == 0 else { return nil }
            expectations = .production
            policy = .production
            guard let opened = VerifiedRootStateDirectory(directoryPath: parent,
                                                          expectations: expectations,
                                                          ancestorPolicy: policy)
            else { return nil }
            directory = opened
        } else {
            // The only non-production capability is the literal fixture tree.
            // VerifiedRootStateDirectory then holds /private/tmp through the
            // nonce-owned 0700 directory chain; arbitrary caller paths fail.
            guard parent.hasPrefix("/private/tmp/") else { return nil }
            // Fixtures use either an owned 0700 sandbox or an owned 0755
            // root-support directory. Both are exact, not a permissive mode
            // mask, and both are held through the test-only ancestor policy.
            let candidates: [VerifiedRootStateDirectory.Expectations] = [
                .init(ownerUID: geteuid(), groupID: getegid(), mode: 0o700),
                .init(ownerUID: geteuid(), groupID: getegid(), mode: 0o755),
            ]
            policy = .testTemporaryDirectory
            guard let opened = candidates.compactMap({ expectation in
                VerifiedRootStateDirectory(directoryPath: parent,
                                           expectations: expectation,
                                           ancestorPolicy: policy).map { ($0, expectation) }
            }).first
            else { return nil }
            directory = opened.0
            expectations = opened.1
        }
        guard let descriptor = directory.directoryDescriptor else { return nil }
        self.directory = directory
        directoryFD = descriptor
        owner = expectations.ownerUID
        group = expectations.groupID
    }

    /// The caller owns the fixture capability. This initializer duplicates it
    /// through the core held-directory boundary, so the status writer keeps
    /// exactly the same descriptor-relative lock/read/write protocol as
    /// production without reopening shared test ancestors by pathname.
    init?(
        heldDirectoryDescriptor: Int32,
        expectations: VerifiedRootStateDirectory.Expectations
    ) {
        guard let directory = VerifiedRootStateDirectory(
            heldDirectoryDescriptor: heldDirectoryDescriptor,
            expectations: expectations
        ), let descriptor = directory.directoryDescriptor else { return nil }
        self.directory = directory
        directoryFD = descriptor
        owner = expectations.ownerUID
        group = expectations.groupID
    }

    fileprivate func withProjectionLock(
        recoveryGate: (HelperStatusStore.RecoveryStage) -> Bool,
        _ body: () -> HelperStatusStore.WriteOutcome
    ) -> HelperStatusStore.WriteOutcome {
        let descriptor: Int32
        let created = openat(directoryFD, lockLeaf, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                             S_IRUSR | S_IWUSR)
        if created >= 0 {
            descriptor = created
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
                  validLock(descriptor), fsync(descriptor) == 0,
                  fcntl(descriptor, F_FULLFSYNC) == 0,
                  fsync(directoryFD) == 0,
                  lockNameStillBinds(descriptor)
            else { close(descriptor); return .indeterminate }
        } else {
            guard errno == EEXIST else { return .ioFailure }
            descriptor = openat(directoryFD, lockLeaf, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { return errno == ELOOP ? .unsafeExisting : .ioFailure }
            guard validLock(descriptor), lockNameStillBinds(descriptor) else { close(descriptor); return .unsafeExisting }
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return .ioFailure }
        defer { _ = flock(descriptor, LOCK_UN) }
        switch recoverTemporaryLeaf(recoveryGate: recoveryGate) {
        case .ready: break
        case .unsafe: return .unsafeExisting
        case .io: return .ioFailure
        case .indeterminate: return .indeterminate
        }
        return body()
    }

    fileprivate func readProjection() -> ReadResult {
        let descriptor = openat(directoryFD, leaf, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return .absent }
            return errno == ELOOP ? .unsafe : .io
        }
        defer { close(descriptor) }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0 else { return .io }
        guard validPublic(initial) else { return .unsafe }
        guard initial.st_size <= off_t(Self.maximumBytes) else { return .unsafe }
        guard let bytes = readExactly(descriptor, count: Int(initial.st_size)) else { return .indeterminate }
        var final = stat()
        guard fstat(descriptor, &final) == 0 else { return .io }
        guard sameMetadata(initial, final) else { return .indeterminate }
        guard let raw = String(bytes: bytes, encoding: .utf8),
              let projection = parseProjection(raw)
        else { return .unsafe }
        return .existing(projection.generation, projection.authority, initial, raw)
    }

    fileprivate func publish(_ payload: String, replacing expected: (metadata: stat, payload: String)?,
                 stageGate: (HelperStatusStore.WriteStage) -> Bool) -> HelperStatusStore.WriteOutcome {
        guard payload.utf8.count <= Self.maximumBytes, stageGate(.open) else { return .indeterminate }
        let temporary = temporaryLeaf
        let descriptor = openat(directoryFD, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                                S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        BenchmarkProbe.record("file_open")
        guard descriptor >= 0 else { return .ioFailure }
        var installed = false
        var descriptorClosed = false
        defer {
            if !descriptorClosed { close(descriptor) }
            if !installed { _ = unlinkat(directoryFD, temporary, 0) }
        }
        // The fixed temp leaf is intentionally empty before its first write;
        // validating it as a final public projection here would reject every
        // new write because final projections require a nonzero payload.
        guard fchmod(descriptor, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH) == 0,
              validTemporaryDescriptor(descriptor), stageGate(.write),
              writeExactly(Array(payload.utf8), to: descriptor)
        else { return .ioFailure }
        BenchmarkProbe.record("decoded_bytes", count: payload.utf8.count)
        BenchmarkProbe.record("file_write")
        BenchmarkProbe.record("file_fsync")
        guard stageGate(.fsync), fsync(descriptor) == 0,
              stageGate(.fullSync), fcntl(descriptor, F_FULLFSYNC) == 0,
              stageGate(.rename)
        else { return .indeterminate }
        var temporaryMetadata = stat()
        guard fstat(descriptor, &temporaryMetadata) == 0, validPublic(temporaryMetadata) else { return .indeterminate }
        BenchmarkProbe.record("file_rename")
        if let expected {
            // Swap rather than blindly overwrite. The old leaf is unlinked
            // only after its exact pre-swap identity and public metadata are
            // revalidated under the same descriptor-held lock.
            guard Darwin.renameatx_np(directoryFD, temporary, directoryFD, leaf, UInt32(RENAME_SWAP)) == 0 else { return .indeterminate }
            installed = true
            guard verifyDisplacedProjection(
                    expected.payload,
                    expectedMetadata: expected.metadata,
                    basename: temporary
                  ),
                  fsync(directoryFD) == 0,
                  verifyInstalled(payload, expectedTemporary: temporaryMetadata, stageGate: stageGate)
            else { return .indeterminate }
            guard unlinkat(directoryFD, temporary, 0) == 0, fsync(directoryFD) == 0 else { return .indeterminate }
        } else {
            // A missing leaf is installed only with the kernel's exclusive
            // rename primitive; a racing creator is never overwritten.
            guard Darwin.renameatx_np(directoryFD, temporary, directoryFD, leaf, UInt32(RENAME_EXCL)) == 0 else {
                return errno == EEXIST ? .indeterminate : .ioFailure
            }
            installed = true
            guard fsync(directoryFD) == 0,
                  verifyInstalled(payload, expectedTemporary: temporaryMetadata, stageGate: stageGate)
            else { return .indeterminate }
        }
        guard stageGate(.close), close(descriptor) == 0 else { return .indeterminate }
        descriptorClosed = true
        return .written
    }

    private func verifyInstalled(_ payload: String, expectedTemporary: stat,
                                 stageGate: (HelperStatusStore.WriteStage) -> Bool) -> Bool {
        guard stageGate(.reopen) else { return false }
        let descriptor = openat(directoryFD, leaf, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0,
              sameIdentity(initial, expectedTemporary), validPublic(initial),
              initial.st_size == off_t(payload.utf8.count),
              let bytes = readExactly(descriptor, count: Int(initial.st_size)),
              String(bytes: bytes, encoding: .utf8) == payload,
              fcntl(descriptor, F_FULLFSYNC) == 0
        else { return false }
        var final = stat()
        return fstat(descriptor, &final) == 0 && sameMetadata(initial, final)
    }

    /// `RENAME_SWAP` legitimately updates the displaced inode's ctime. Prove
    /// that the temporary name still holds the exact old projection by inode,
    /// immutable safety metadata, stable contents, and final name binding;
    /// ctime alone is deliberately excluded from the pre/post-rename match.
    private func verifyDisplacedProjection(
        _ payload: String,
        expectedMetadata: stat,
        basename: String
    ) -> Bool {
        let descriptor = openat(directoryFD, basename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0,
              sameRenameStableMetadata(expectedMetadata, initial),
              validPublic(initial),
              initial.st_size == off_t(payload.utf8.count),
              let bytes = readExactly(descriptor, count: Int(initial.st_size)),
              String(bytes: bytes, encoding: .utf8) == payload,
              fcntl(descriptor, F_FULLFSYNC) == 0
        else { return false }
        var final = stat()
        var bound = stat()
        return fstat(descriptor, &final) == 0
            && sameMetadata(initial, final)
            && fstatat(directoryFD, basename, &bound, AT_SYMLINK_NOFOLLOW) == 0
            && sameMetadata(final, bound)
    }

    /// A retry may observe bytes left by a prior ambiguous close/rename. It
    /// cannot acknowledge them merely because their generation matches: it
    /// performs fresh file and directory durability plus exact descriptor-held
    /// reopen proof before the dispatcher may clear the dirty task.
    fileprivate func durablyRevalidates(_ payload: String, expected: stat) -> Bool {
        let descriptor = openat(directoryFD, leaf, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0, sameMetadata(initial, expected), validPublic(initial),
              initial.st_size == off_t(payload.utf8.count),
              let bytes = readExactly(descriptor, count: Int(initial.st_size)),
              String(bytes: bytes, encoding: .utf8) == payload,
              fcntl(descriptor, F_FULLFSYNC) == 0, fsync(directoryFD) == 0
        else { return false }
        var final = stat()
        return fstat(descriptor, &final) == 0 && sameMetadata(initial, final)
    }

    private enum TemporaryRecovery { case ready, unsafe, io, indeterminate }

    /// A normal failed write removes its temp in `defer`; this covers only a
    /// process crash between exclusive create and final cleanup. The fixed
    /// leaf and exact descriptor metadata identify an interrupted transaction;
    /// its bytes are never authority. A zero or partial temp is retired under
    /// the held projection lock so the already-durable private task can
    /// republish current authority. Any metadata or binding ambiguity remains
    /// fail-closed and is never unlinked.
    private func recoverTemporaryLeaf(
        recoveryGate: (HelperStatusStore.RecoveryStage) -> Bool
    ) -> TemporaryRecovery {
        let descriptor = openat(directoryFD, temporaryLeaf, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return errno == ENOENT ? .ready : (errno == ELOOP ? .unsafe : .io) }
        defer { close(descriptor) }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0 else { return .io }
        guard validTemporary(initial), initial.st_size <= off_t(Self.maximumBytes),
              readExactly(descriptor, count: Int(initial.st_size)) != nil
        else { return .unsafe }
        var final = stat()
        var bound = stat()
        guard fstat(descriptor, &final) == 0, sameMetadata(initial, final),
              fstatat(directoryFD, temporaryLeaf, &bound, AT_SYMLINK_NOFOLLOW) == 0,
              sameMetadata(initial, bound)
        else { return .indeterminate }
        // The preceding descriptor/basename equality is repeated immediately
        // before unlink. A name replacement, link, or metadata change can
        // only yield indeterminate/unsafe recovery, never a broad cleanup.
        guard recoveryGate(.beforeRetire),
              fstat(descriptor, &final) == 0, sameMetadata(initial, final),
              fstatat(directoryFD, temporaryLeaf, &bound, AT_SYMLINK_NOFOLLOW) == 0,
              sameMetadata(initial, bound),
              unlinkat(directoryFD, temporaryLeaf, 0) == 0,
              fsync(directoryFD) == 0,
              recoveryGate(.afterRetire)
        else { return .indeterminate }
        var absent = stat()
        guard fstatat(directoryFD, temporaryLeaf, &absent, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
            return .indeterminate
        }
        return .ready
    }

    private func validLock(_ descriptor: Int32) -> Bool {
        var metadata = stat()
        return fstat(descriptor, &metadata) == 0
            && (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_uid == owner && metadata.st_gid == group
            && metadata.st_nlink == 1 && metadata.st_mode & 0o7777 == 0o600
            && metadata.st_size == 0
    }

    private func lockNameStillBinds(_ descriptor: Int32) -> Bool {
        var held = stat()
        var bound = stat()
        return fstat(descriptor, &held) == 0
            && fstatat(directoryFD, lockLeaf, &bound, AT_SYMLINK_NOFOLLOW) == 0
            && sameMetadata(held, bound) && validLock(descriptor)
    }

    private func validPublicDescriptor(_ descriptor: Int32) -> Bool {
        var metadata = stat()
        return fstat(descriptor, &metadata) == 0 && validPublic(metadata)
    }

    private func validTemporaryDescriptor(_ descriptor: Int32) -> Bool {
        var metadata = stat()
        return fstat(descriptor, &metadata) == 0 && validTemporary(metadata)
    }

    private func validPublic(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_uid == owner && metadata.st_gid == group
            && metadata.st_nlink == 1 && metadata.st_mode & 0o7777 == 0o644
            && metadata.st_size > 0 && metadata.st_size <= off_t(Self.maximumBytes)
    }

    /// The fixed crash leaf has public diagnostic ownership/mode but may be
    /// empty before its first write. This accepts no alternate name, type,
    /// owner, group, mode, hardlink, or oversized inode.
    private func validTemporary(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_uid == owner && metadata.st_gid == group
            && metadata.st_nlink == 1 && metadata.st_mode & 0o7777 == 0o644
            && metadata.st_size >= 0 && metadata.st_size <= off_t(Self.maximumBytes)
    }

    private static func checkedParentAndLeaf(_ path: String) -> (String, String)? {
        guard path.precomposedStringWithCanonicalMapping == path,
              !path.utf8.contains(0), path.hasPrefix("/"), path != "/",
              !path.hasSuffix("/"), !path.contains("//")
        else { return nil }
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 2, components.allSatisfy(VerifiedRootStateDirectory.isSafeBasename),
              let leaf = components.last
        else { return nil }
        return ("/" + components.dropLast().joined(separator: "/"), leaf)
    }

    private func parseProjection(_ raw: String) -> (generation: UInt64, authority: String)? {
        guard raw.utf8.count <= Self.maximumBytes, raw.hasSuffix("\n"), !raw.hasSuffix("\n\n") else { return nil }
        var fields: [String: String] = [:]
        for line in raw.dropLast().split(separator: "\n", omittingEmptySubsequences: false) {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, fields.updateValue(String(pair[1]), forKey: String(pair[0])) == nil else { return nil }
        }
        let expected: Set<String> = ["state", "reason", "session", "updated", "boot_id", "updated_monotonic",
                                     "projection_generation", "projection_token", "projection_authority"]
        guard Set(fields.keys) == expected,
              fields["state"]?.range(of: "^[a-z0-9-]{1,32}$", options: .regularExpression) != nil,
              fields["reason"]?.range(of: "^[a-z0-9-]{1,96}$", options: .regularExpression) != nil,
              let generationRaw = fields["projection_generation"], let generation = UInt64(generationRaw), generation > 0,
              generationRaw == String(generation), let authority = fields["projection_authority"],
              authority.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil,
              let token = fields["projection_token"], token == token.lowercased(), UUID(uuidString: token) != nil,
              let updated = fields["updated"], let epoch = UInt64(updated), updated == String(epoch),
              let boot = fields["boot_id"], boot.range(of: "^[a-zA-Z0-9._-]{1,128}$", options: .regularExpression) != nil,
              let monotonic = fields["updated_monotonic"], monotonic.range(of: "^[0-9]+\\.[0-9]{3}$", options: .regularExpression) != nil
        else { return nil }
        if fields["session"] != "none" {
            guard let session = fields["session"], session == session.lowercased(), UUID(uuidString: session) != nil else { return nil }
        }
        return (generation, authority)
    }

    private func writeExactly(_ bytes: [UInt8], to descriptor: Int32) -> Bool {
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    private func readExactly(_ descriptor: Int32, count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let result = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset)
            }
            if result > 0 { offset += result; continue }
            if result < 0, errno == EINTR { continue }
            return nil
        }
        var trailing: UInt8 = 0
        while true {
            let result = Darwin.read(descriptor, &trailing, 1)
            if result == 0 { return bytes }
            if result < 0, errno == EINTR { continue }
            return nil
        }
    }

    private func sameIdentity(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }

    private func sameMetadata(_ first: stat, _ second: stat) -> Bool {
        sameIdentity(first, second) && first.st_uid == second.st_uid && first.st_gid == second.st_gid
            && first.st_mode == second.st_mode && first.st_nlink == second.st_nlink && first.st_size == second.st_size
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }

    private func sameRenameStableMetadata(_ first: stat, _ second: stat) -> Bool {
        sameIdentity(first, second) && first.st_uid == second.st_uid && first.st_gid == second.st_gid
            && first.st_mode == second.st_mode && first.st_nlink == second.st_nlink && first.st_size == second.st_size
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
    }
}
