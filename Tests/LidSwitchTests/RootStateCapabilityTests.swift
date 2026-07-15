import Darwin
import Foundation
import XCTest
@testable import LidSwitchCore

/// Source-only Revision-B tests. They operate exclusively under TestSandbox's
/// literal `/private/tmp` fixture policy and are intentionally unrun in this
/// implementation lane.
final class RootStateCapabilityTests: XCTestCase {
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value

        init(_ value: Value) { storage = value }

        var value: Value {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func set(_ value: Value) {
            lock.lock()
            storage = value
            lock.unlock()
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func takeFirst() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !value else { return false }
            value = true
            return true
        }

        var wasSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    func testProductionAncestorPolicyAcceptsOnlyCanonicalRootAdminBoundaryAndWheelFinal() {
        let canonical = ["Library", "Application Support", "LidSwitch"]
        let directory755 = mode_t(S_IFDIR) | mode_t(0o755)
        let directory775 = mode_t(S_IFDIR) | mode_t(0o775)
        let symlink755 = mode_t(S_IFLNK) | mode_t(0o755)

        let accepted: [(Int, gid_t)] = [(0, 0), (1, 0), (2, 80), (3, 0)]
        for (index, group) in accepted {
            XCTAssertTrue(VerifiedRootStateDirectory.productionAncestorIsValid(
                index: index,
                components: canonical,
                ownerUID: 0,
                groupID: group,
                mode: directory755,
                expectations: .production
            ))
            for special in [mode_t(0o4000), mode_t(0o2000), mode_t(0o1000)] {
                XCTAssertFalse(VerifiedRootStateDirectory.productionAncestorIsValid(
                    index: index,
                    components: canonical,
                    ownerUID: 0,
                    groupID: group,
                    mode: directory755 | special,
                    expectations: .production
                ), "index \(index) accepted special mode \(String(special, radix: 8))")
            }
        }

        let rejected: [(Int, [String], uid_t, gid_t, mode_t, VerifiedRootStateDirectory.Expectations)] = [
            (2, canonical, 501, 80, directory755, .production),
            (2, canonical, 0, 0, directory755, .production),
            (2, canonical, 0, 20, directory755, .production),
            (2, canonical, 0, 80, directory775, .production),
            (2, canonical, 0, 80, symlink755, .production),
            (2, ["Library", "Other", "LidSwitch"], 0, 80, directory755, .production),
            (3, canonical, 0, 80, directory755, .production),
            (3, canonical, 0, 0, mode_t(S_IFDIR) | mode_t(0o750), .production),
            (3, canonical, 0, 0, directory755, .init(ownerUID: 0, groupID: 80, mode: 0o755)),
        ]
        for fixture in rejected {
            XCTAssertFalse(VerifiedRootStateDirectory.productionAncestorIsValid(
                index: fixture.0,
                components: fixture.1,
                ownerUID: fixture.2,
                groupID: fixture.3,
                mode: fixture.4,
                expectations: fixture.5
            ))
        }
    }

    func testFullChainRejectsIntermediateSymlinkAndHoldsOriginalDirectoryAcrossSwap() throws {
        let fixture = try TestSandbox.makeDirectory(label: "root-chain").url
        let anchored = fixture.appendingPathComponent("anchored", isDirectory: true)
        let replacement = fixture.appendingPathComponent("replacement", isDirectory: true)
        let moved = fixture.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: anchored, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
        let file = anchored.appendingPathComponent("state")
        try Data("anchored".utf8).write(to: file)
        try Data("replacement".utf8).write(to: replacement.appendingPathComponent("state"))
        XCTAssertEqual(chmod(file.path, 0o600), 0)

        let policy = temporaryReadPolicy()
        let controls = BoundedFileReadControls(beforeLeafOpen: {
            _ = rename(anchored.path, moved.path)
            _ = symlink(replacement.path, anchored.path)
        })
        XCTAssertEqual(BoundedFileReader.readUTF8(path: file.path, policy: policy, controls: controls), .success("anchored"))
        XCTAssertEqual(BoundedFileReader.readUTF8(path: anchored.appendingPathComponent("state").path, policy: policy), .failure(.unsafeParent))
    }

    func testFullChainRejectsUnsafeAncestorsAndLeafTypeOwnerModeLinkViolations() throws {
        let fixture = try TestSandbox.makeDirectory(label: "root-reject").url
        let file = fixture.appendingPathComponent("state")
        try Data("valid".utf8).write(to: file)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        let policy = temporaryReadPolicy()
        XCTAssertEqual(BoundedFileReader.readUTF8(path: file.path, policy: policy), .success("valid"))

        XCTAssertEqual(chmod(fixture.path, 0o770), 0)
        XCTAssertEqual(BoundedFileReader.readUTF8(path: file.path, policy: policy), .failure(.unsafeParent))
        XCTAssertEqual(chmod(fixture.path, 0o700), 0)

        let link = fixture.appendingPathComponent("link")
        XCTAssertEqual(symlink(file.path, link.path), 0)
        XCTAssertEqual(BoundedFileReader.readUTF8(path: link.path, policy: policy), .failure(.unsafeFile))
        XCTAssertEqual(unlink(link.path), 0)
        XCTAssertEqual(chmod(file.path, 0o660), 0)
        XCTAssertEqual(BoundedFileReader.readUTF8(path: file.path, policy: policy), .failure(.unsafeFile))
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        let wrongOwner = BoundedFileReadPolicy(
            maximumBytes: 64, expectedOwnerUID: getuid() &+ 1, requireSingleLink: true,
            rejectGroupOrWorldWritable: true, requireNonEmpty: true, safeParentDepth: 0
        )
        XCTAssertEqual(BoundedFileReader.readUTF8(path: file.path, policy: wrongOwner), .failure(.unsafeFile))
        XCTAssertFalse(BoundedFileReader.fileMetadataIsSafe(
            mode: mode_t(S_IFREG) | 0o600,
            ownerUID: getuid(),
            linkCount: 2,
            size: 5,
            policy: policy
        ))

        XCTAssertEqual(unlink(file.path), 0)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        XCTAssertEqual(BoundedFileReader.readUTF8(path: file.path, policy: policy), .failure(.unsafeFile))
    }

    func testAuthorityLeavesAndGenerationDirectoriesRejectEverySpecialBit() throws {
        let policy = temporaryReadPolicy()
        // Darwin may strip set-ID bits from sandboxed fixture files even when
        // chmod succeeds, so exercise the production predicate directly.
        for special in [mode_t(0o4600), mode_t(0o2600), mode_t(0o1600)] {
            XCTAssertFalse(BoundedFileReader.fileMetadataIsSafe(
                mode: mode_t(S_IFREG) | special,
                ownerUID: getuid(),
                linkCount: 1,
                size: 9,
                policy: policy
            ), "accepted special file mode \(String(special, radix: 8))")
        }
        for special in [mode_t(0o2755), mode_t(0o1755)] {
            XCTAssertFalse(BoundedFileReader.directoryMetadataIsSafe(
                mode: mode_t(S_IFDIR) | special,
                ownerUID: getuid(),
                policy: policy
            ), "accepted special directory mode \(String(special, radix: 8))")
        }
    }

    func testFullChainRejectsNormalizationAndOnlyPermitsDocumentedVarAlias() throws {
        let policy = temporaryReadPolicy()
        XCTAssertEqual(
            BoundedFileReader.readUTF8(path: "/private/tmp/e\u{301}/state", policy: policy),
            .failure(.unsafeParent)
        )
        XCTAssertEqual(BoundedFileReader.readUTF8(path: "/tmp//state", policy: policy), .failure(.unsafeParent))
        XCTAssertEqual(BoundedFileReader.readUTF8(path: "/var/../tmp/state", policy: policy), .failure(.unsafeParent))
        // `/var` is only rewritten to `/private/var`; arbitrary aliases never
        // enter the descriptor chain as a resolved URL.
        XCTAssertEqual(BoundedFileReader.readUTF8(path: "/var/lidswitch-nope", policy: policy), .failure(.unsafeParent))
    }

    func testExactReadRequiresCompleteBodyEOFAndRetriesInjectedEINTR() throws {
        let fixture = try TestSandbox.makeDirectory(label: "root-read").url
        let file = fixture.appendingPathComponent("state")
        try Data("valid".utf8).write(to: file)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        let policy = temporaryReadPolicy()

        let interrupted = Flag()
        let eintr = BoundedFileReadControls(readDirective: { phase in
            phase == .body && interrupted.takeFirst() ? .interrupted : .system
        })
        XCTAssertEqual(BoundedFileReader.readUTF8(path: file.path, policy: policy, controls: eintr), .success("valid"))
        XCTAssertTrue(interrupted.wasSet)
        let earlyEOF = BoundedFileReadControls(readDirective: { phase in phase == .body ? .endOfFile : .system })
        XCTAssertEqual(BoundedFileReader.readUTF8(path: file.path, policy: policy, controls: earlyEOF), .failure(.changedDuringRead))
    }

    func testPublicationStageMatrixMarksEveryPostRenameFailureUnverified() throws {
        let fixture = try stateFixture(label: "publish-stages")
        let payload = Data("payload".utf8)
        let temporaryBarrierFailure = lockedDirectory(fixture, operations: .init(
            fileBarrier: { _ in false }, directoryEntryBarrier: { _ in true },
            rename: { oldFD, oldName, newFD, newName in Darwin.renameat(oldFD, oldName, newFD, newName) },
            unlink: { fd, name in Darwin.unlinkat(fd, name, 0) }, beforeQuarantineUnlink: { _, _ in }
        ))
        XCTAssertEqual(transact(temporaryBarrierFailure) { $0.publish(payload, to: "state") }, .notPublished(.temporaryBarrier))

        let directoryBarrierFailure = lockedDirectory(fixture, operations: .init(
            fileBarrier: { _ in true }, directoryEntryBarrier: { _ in false },
            rename: { oldFD, oldName, newFD, newName in Darwin.renameat(oldFD, oldName, newFD, newName) },
            unlink: { fd, name in Darwin.unlinkat(fd, name, 0) }, beforeQuarantineUnlink: { _, _ in }
        ))
        XCTAssertEqual(transact(directoryBarrierFailure) { $0.publish(payload, to: "state") }, .publishedButUnverified(.directoryBarrier))

        // The first file barrier is the temporary barrier; make a separate
        // fixture with a call counter so the final barrier is the only failure.
        var barrierCalls = 0
        let finalOnly = lockedDirectory(fixture, operations: .init(
            fileBarrier: { _ in barrierCalls += 1; return barrierCalls == 1 }, directoryEntryBarrier: { _ in true },
            rename: { oldFD, oldName, newFD, newName in Darwin.renameat(oldFD, oldName, newFD, newName) },
            unlink: { fd, name in Darwin.unlinkat(fd, name, 0) }, beforeQuarantineUnlink: { _, _ in }
        ))
        XCTAssertEqual(transact(finalOnly) { $0.publish(payload, to: "final") }, .publishedButUnverified(.finalBarrier))

        let mismatch = lockedDirectory(fixture, operations: .init(
            fileBarrier: { _ in true }, directoryEntryBarrier: { _ in true },
            rename: { oldFD, oldName, newFD, newName in
                let result = Darwin.renameat(oldFD, oldName, newFD, newName)
                guard result == 0 else { return result }
                let fd = openat(newFD, newName, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC)
                if fd >= 0 {
                    let replacement = Array("other".utf8)
                    _ = replacement.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, replacement.count) }
                    Darwin.close(fd)
                }
                return 0
            }, unlink: { fd, name in Darwin.unlinkat(fd, name, 0) }, beforeQuarantineUnlink: { _, _ in }
        ))
        XCTAssertEqual(transact(mismatch) { $0.publish(payload, to: "mismatch") }, .publishedButUnverified(.finalMetadata))
        XCTAssertEqual(transact(lockedDirectory(fixture)) { $0.publish(payload, to: "parser", parser: { _ in false }) }, .publishedButUnverified(.parser))
    }

    func testRemovalProvesAbsenceAndPreservesUncertainty() throws {
        let fixture = try stateFixture(label: "remove")
        let durable = lockedDirectory(fixture)
        XCTAssertEqual(transact(durable) { $0.publish(Data("state".utf8), to: "state") }, .published)
        XCTAssertEqual(transact(durable) { $0.remove("state") }, .removed)
        XCTAssertEqual(durable.entryState("state"), .absent)

        let uncertain = lockedDirectory(fixture, operations: .init(
            fileBarrier: { _ in true }, directoryEntryBarrier: { _ in false },
            rename: { oldFD, oldName, newFD, newName in Darwin.renameat(oldFD, oldName, newFD, newName) },
            unlink: { fd, name in Darwin.unlinkat(fd, name, 0) }, beforeQuarantineUnlink: { _, _ in }
        ))
        XCTAssertEqual(transact(uncertain) { $0.publish(Data("state".utf8), to: "uncertain") }, .publishedButUnverified(.directoryBarrier))
        XCTAssertEqual(transact(uncertain) { $0.remove("uncertain") }, .removalUnverified)
        XCTAssertEqual(transact(lockedDirectory(fixture)) { $0.remove("uncertain") }, .recoveryRequired)
    }

    func testLockProvisioningUsesExclusiveNoFollowValidationAndDistinctBarriers() throws {
        let fixture = try stateFixture(label: "lock-provision")
        let directory = makeDirectory(fixture)
        XCTAssertEqual(directory.provisionLockLeaf(RootStateLock.authorizationBasename), .provisioned)
        XCTAssertEqual(directory.provisionLockLeaf(RootStateLock.authorizationBasename), .alreadyPresent)

        var existingFileBarrierCalls = 0
        let existingFileBarrier = makeDirectory(fixture, operations: .init(
            fileBarrier: { _ in existingFileBarrierCalls += 1; return existingFileBarrierCalls > 1 },
            directoryEntryBarrier: { _ in true },
            rename: { oldFD, oldName, newFD, newName in Darwin.renameat(oldFD, oldName, newFD, newName) },
            unlink: { fd, name in Darwin.unlinkat(fd, name, 0) }, beforeQuarantineUnlink: { _, _ in }
        ))
        XCTAssertEqual(existingFileBarrier.provisionLockLeaf(RootStateLock.authorizationBasename), .provisionedButUnverified(.fileBarrier))
        XCTAssertEqual(existingFileBarrier.provisionLockLeaf(RootStateLock.authorizationBasename), .alreadyPresent)

        var existingDirectoryBarrierCalls = 0
        let existingDirectoryBarrier = makeDirectory(fixture, operations: .init(
            fileBarrier: { _ in true },
            directoryEntryBarrier: { _ in existingDirectoryBarrierCalls += 1; return existingDirectoryBarrierCalls > 1 },
            rename: { oldFD, oldName, newFD, newName in Darwin.renameat(oldFD, oldName, newFD, newName) },
            unlink: { fd, name in Darwin.unlinkat(fd, name, 0) }, beforeQuarantineUnlink: { _, _ in }
        ))
        XCTAssertEqual(existingDirectoryBarrier.provisionLockLeaf(RootStateLock.authorizationBasename), .provisionedButUnverified(.directoryBarrier))
        XCTAssertEqual(existingDirectoryBarrier.provisionLockLeaf(RootStateLock.authorizationBasename), .alreadyPresent)

        let fileBarrierFixture = try stateFixture(label: "lock-file-barrier")
        let fileBarrierFailure = makeDirectory(fileBarrierFixture, operations: .init(
            fileBarrier: { _ in false }, directoryEntryBarrier: { _ in true },
            rename: { oldFD, oldName, newFD, newName in Darwin.renameat(oldFD, oldName, newFD, newName) },
            unlink: { fd, name in Darwin.unlinkat(fd, name, 0) }, beforeQuarantineUnlink: { _, _ in }
        ))
        XCTAssertEqual(fileBarrierFailure.provisionLockLeaf(RootStateLock.authorizationBasename), .provisionedButUnverified(.fileBarrier))

        let directoryBarrierFixture = try stateFixture(label: "lock-dir-barrier")
        let directoryBarrierFailure = makeDirectory(directoryBarrierFixture, operations: .init(
            fileBarrier: { _ in true }, directoryEntryBarrier: { _ in false },
            rename: { oldFD, oldName, newFD, newName in Darwin.renameat(oldFD, oldName, newFD, newName) },
            unlink: { fd, name in Darwin.unlinkat(fd, name, 0) }, beforeQuarantineUnlink: { _, _ in }
        ))
        XCTAssertEqual(directoryBarrierFailure.provisionLockLeaf(RootStateLock.authorizationBasename), .provisionedButUnverified(.directoryBarrier))

        let symlinkFixture = try stateFixture(label: "lock-symlink")
        let symlinkDirectory = makeDirectory(symlinkFixture)
        XCTAssertEqual(symlink("target", symlinkFixture.appendingPathComponent(RootStateLock.authorizationBasename).path), 0)
        XCTAssertEqual(symlinkDirectory.provisionLockLeaf(RootStateLock.authorizationBasename), .failure(.existingInvalid))
    }

    func testTransactionPreservesReplacementInjectedBeforeUnlinkAndFinalIdentityBindsPublishedTemp() throws {
        let fixture = try stateFixture(label: "transaction-replace")
        let initial = lockedDirectory(fixture)
        XCTAssertEqual(transact(initial) { $0.publish(Data("initial".utf8), to: "state") }, .published)

        let replacement = lockedDirectory(fixture, operations: .init(
            fileBarrier: { _ in true }, directoryEntryBarrier: { _ in true },
            rename: { oldFD, oldName, newFD, newName in Darwin.renameat(oldFD, oldName, newFD, newName) },
            unlink: { fd, name in Darwin.unlinkat(fd, name, 0) },
            beforeQuarantineUnlink: { fd, name in
                _ = Darwin.renameat(fd, name, fd, "prior-state")
                let publicFD = openat(fd, "state", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                if publicFD >= 0 {
                    let bytes = Array("occupant".utf8)
                    _ = bytes.withUnsafeBytes { Darwin.write(publicFD, $0.baseAddress, bytes.count) }
                    _ = Darwin.fchmod(publicFD, 0o600)
                    Darwin.close(publicFD)
                }
                let replacementFD = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard replacementFD >= 0 else { return }
                let bytes = Array("replacement".utf8)
                _ = bytes.withUnsafeBytes { Darwin.write(replacementFD, $0.baseAddress, bytes.count) }
                _ = Darwin.fchmod(replacementFD, 0o600)
                Darwin.close(replacementFD)
            }
        ))
        XCTAssertEqual(transact(replacement) { $0.remove("state") }, .removalUnverified)
        let quarantine = try XCTUnwrap(VerifiedRootStateDirectory.quarantineBasename(for: "state"))
        XCTAssertEqual(try String(contentsOf: fixture.appendingPathComponent("state")), "occupant")
        XCTAssertEqual(replacement.entryState(quarantine), .present)
        XCTAssertEqual(transact(lockedDirectory(fixture)) { $0.remove("state") }, .recoveryRequired)

        let identity = lockedDirectory(fixture, operations: .init(
            fileBarrier: { _ in true }, directoryEntryBarrier: { _ in true },
            rename: { oldFD, oldName, newFD, newName in Darwin.renameat(oldFD, oldName, newFD, newName) },
            unlink: { fd, name in Darwin.unlinkat(fd, name, 0) },
            beforeFinalBinding: { fd, name in
                _ = Darwin.renameat(fd, name, fd, "published-temp")
                let replacement = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard replacement >= 0 else { return }
                let bytes = Array("identity".utf8)
                _ = bytes.withUnsafeBytes { Darwin.write(replacement, $0.baseAddress, bytes.count) }
                _ = Darwin.fchmod(replacement, 0o600)
                Darwin.close(replacement)
            }, beforeQuarantineUnlink: { _, _ in }
        ))
        XCTAssertEqual(transact(identity) { $0.publish(Data("identity".utf8), to: "identity") }, .publishedButUnverified(.finalIdentity))
    }

    func testQuarantineIdentityMismatchRemainsRecoveryEvidence() throws {
        let fixture = try stateFixture(label: "quarantine-mismatch")
        let initial = lockedDirectory(fixture)
        XCTAssertEqual(transact(initial) { $0.publish(Data("original".utf8), to: "state") }, .published)
        let mismatch = lockedDirectory(fixture, operations: .init(
            fileBarrier: { _ in true }, directoryEntryBarrier: { _ in true },
            rename: { oldFD, oldName, newFD, newName in Darwin.renameat(oldFD, oldName, newFD, newName) },
            unlink: { fd, name in Darwin.unlinkat(fd, name, 0) },
            beforeQuarantineVerify: { fd, name in
                _ = Darwin.renameat(fd, name, fd, "preverify-original")
                let replacement = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard replacement >= 0 else { return }
                let bytes = Array("replacement".utf8)
                _ = bytes.withUnsafeBytes { Darwin.write(replacement, $0.baseAddress, bytes.count) }
                _ = Darwin.fchmod(replacement, 0o600)
                Darwin.close(replacement)
            }, beforeQuarantineUnlink: { _, _ in }
        ))
        XCTAssertEqual(transact(mismatch) { $0.remove("state") }, .removalUnverified)
        let quarantine = try XCTUnwrap(VerifiedRootStateDirectory.quarantineBasename(for: "state"))
        XCTAssertEqual(mismatch.entryState("state"), .absent)
        XCTAssertEqual(mismatch.entryState(quarantine), .present)
        XCTAssertEqual(transact(lockedDirectory(fixture)) { $0.remove("state") }, .recoveryRequired)
    }

    func testAbsentAndPostUnlinkOutcomesNeedARealDirectoryBarrierBeforeSuccess() throws {
        let absentFixture = try stateFixture(label: "absence-barrier")
        var absentBarrierCalls = 0
        let absentDirectory = lockedDirectory(absentFixture, operations: .init(
            fileBarrier: { _ in true },
            directoryEntryBarrier: { _ in absentBarrierCalls += 1; return absentBarrierCalls > 1 },
            rename: { oldFD, oldName, newFD, newName in Darwin.renameat(oldFD, oldName, newFD, newName) },
            unlink: { fd, name in Darwin.unlinkat(fd, name, 0) }, beforeQuarantineUnlink: { _, _ in }
        ))
        XCTAssertEqual(transact(absentDirectory) { $0.remove("absent") }, .removalUnverified)
        XCTAssertEqual(transact(absentDirectory) { $0.remove("absent") }, .alreadyAbsent)

        let reportedFailureFixture = try stateFixture(label: "unlink-reported-failure")
        let initial = lockedDirectory(reportedFailureFixture)
        XCTAssertEqual(transact(initial) { $0.publish(Data("state".utf8), to: "state") }, .published)
        let reportedFailure = lockedDirectory(reportedFailureFixture, operations: .init(
            fileBarrier: { _ in true }, directoryEntryBarrier: { _ in true },
            rename: { oldFD, oldName, newFD, newName in Darwin.renameat(oldFD, oldName, newFD, newName) },
            unlink: { fd, name in
                _ = Darwin.unlinkat(fd, name, 0)
                return -1
            },
            beforeQuarantineUnlink: { _, _ in }
        ))
        XCTAssertEqual(transact(reportedFailure) { $0.remove("state") }, .removalUnverified)
        XCTAssertEqual(transact(lockedDirectory(reportedFailureFixture)) { $0.remove("state") }, .alreadyAbsent)

        let barrierFixture = try stateFixture(label: "post-unlink-barrier")
        let barrierInitial = lockedDirectory(barrierFixture)
        XCTAssertEqual(transact(barrierInitial) { $0.publish(Data("state".utf8), to: "state") }, .published)
        var removeBarrierCalls = 0
        let postUnlinkBarrier = lockedDirectory(barrierFixture, operations: .init(
            fileBarrier: { _ in true },
            directoryEntryBarrier: { _ in removeBarrierCalls += 1; return removeBarrierCalls != 2 },
            rename: { oldFD, oldName, newFD, newName in Darwin.renameat(oldFD, oldName, newFD, newName) },
            unlink: { fd, name in Darwin.unlinkat(fd, name, 0) }, beforeQuarantineUnlink: { _, _ in }
        ))
        XCTAssertEqual(transact(postUnlinkBarrier) { $0.remove("state") }, .removalUnverified)
        XCTAssertEqual(transact(lockedDirectory(barrierFixture)) { $0.remove("state") }, .alreadyAbsent)
    }

    func testLockTimeoutDoesNotRunMutationBody() throws {
        let fixture = try stateFixture(label: "lock")
        let directory = makeDirectory(fixture)
        let lock = openat(directory.directoryDescriptor!, RootStateLock.authorizationBasename, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(lock, 0)
        defer { Darwin.close(lock) }
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        var bodyRan = false
        let result: Bool? = RootStateLock.withExclusive(directory: directory, timeout: 0, now: { 1 }) { _ in
            bodyRan = true
            return true
        }
        XCTAssertNil(result)
        XCTAssertFalse(bodyRan)
    }

    func testRetainedTransactionRejectsMutationAfterLockScopeEnds() throws {
        let fixture = try stateFixture(label: "retained-transaction")
        let directory = lockedDirectory(fixture)
        var retained: VerifiedRootStateDirectory.Transaction?
        XCTAssertNotNil(RootStateLock.withExclusive(directory: directory) { transaction in
            retained = transaction
            return true
        })
        guard let retained else { return XCTFail("transaction was not retained") }
        XCTAssertEqual(retained.publish(Data("late".utf8), to: "late"), .notPublished(.transactionInactive))
        XCTAssertEqual(directory.entryState("late"), .absent)
    }

    func testParserReentryIsTypedAndDoesNotReenterTheActiveOperation() throws {
        let fixture = try stateFixture(label: "parser-reentry")
        let directory = lockedDirectory(fixture)
        var nested: VerifiedRootStateDirectory.PublicationResult?
        let outer = RootStateLock.withExclusive(directory: directory) { transaction in
            transaction.publish(Data("outer".utf8), to: "outer") { _ in
                let reentered = transaction.publish(Data("nested".utf8), to: "nested")
                nested = reentered
                return reentered == .notPublished(.reentrant)
            }
        }
        guard let outer else { return XCTFail("outer transaction did not return") }
        guard let nested else { return XCTFail("parser did not attempt reentry") }
        XCTAssertEqual(outer, .published)
        XCTAssertEqual(nested, .notPublished(.reentrant))
        XCTAssertEqual(directory.entryState("nested"), .absent)
    }

    func testSynchronousCrossThreadParserReentryIsTypedWithoutBlocking() throws {
        let fixture = try stateFixture(label: "parser-cross-thread")
        let directory = lockedDirectory(fixture)
        let transactionBox = Box<VerifiedRootStateDirectory.Transaction?>(nil)
        let nestedBox = Box<VerifiedRootStateDirectory.PublicationResult?>(nil)
        let outer = RootStateLock.withExclusive(directory: directory) { transaction in
            transactionBox.set(transaction)
            return transaction.publish(Data("outer".utf8), to: "outer") { _ in
                DispatchQueue.global().sync {
                    nestedBox.set(transactionBox.value?.publish(Data("nested".utf8), to: "nested"))
                }
                return nestedBox.value == .some(.notPublished(.reentrant))
            }
        }
        guard let outer, let nested = nestedBox.value else { return XCTFail("cross-thread reentry did not return") }
        XCTAssertEqual(outer, .published)
        XCTAssertEqual(nested, .notPublished(.reentrant))
    }

    func testDeterministicQuarantineSurfacesCrashOrphanBothPresentAndOverlongNames() throws {
        let orphanFixture = try stateFixture(label: "quarantine-orphan")
        let orphanDirectory = lockedDirectory(orphanFixture)
        let quarantine = try XCTUnwrap(VerifiedRootStateDirectory.quarantineBasename(for: "state"))
        try createPrivateFile(in: orphanDirectory, name: quarantine, bytes: Data("interrupted".utf8))
        XCTAssertEqual(transact(orphanDirectory) { $0.remove("state") }, .recoveryRequired)
        XCTAssertEqual(transact(orphanDirectory) { $0.publish(Data("replacement".utf8), to: "state") }, .notPublished(.recoveryRequired))

        let bothFixture = try stateFixture(label: "quarantine-both")
        let bothDirectory = lockedDirectory(bothFixture)
        XCTAssertEqual(transact(bothDirectory) { $0.publish(Data("state".utf8), to: "state") }, .published)
        try createPrivateFile(in: bothDirectory, name: quarantine, bytes: Data("orphan".utf8))
        XCTAssertEqual(transact(bothDirectory) { $0.remove("state") }, .recoveryRequired)

        let overlong = String(repeating: "x", count: Int(NAME_MAX))
        XCTAssertNil(VerifiedRootStateDirectory.quarantineBasename(for: overlong))
        XCTAssertEqual(transact(bothDirectory) { $0.publish(Data("x".utf8), to: overlong) }, .notPublished(.unsafeName))
    }

    func testOneLockAcquisitionSupportsMultipleRootStateOperations() throws {
        let fixture = try stateFixture(label: "multifile")
        let directory = lockedDirectory(fixture)
        let completed = RootStateLock.withExclusive(directory: directory) { transaction in
            let first = transaction.publish(Data("one".utf8), to: "one")
            let second = transaction.publish(Data("two".utf8), to: "two")
            let removed = transaction.remove("one")
            return first == .published && second == .published && removed == .removed
        }
        guard let completed else { return XCTFail("multi-file transaction did not acquire lock") }
        XCTAssertTrue(completed)
        XCTAssertEqual(directory.entryState("one"), .absent)
        XCTAssertEqual(directory.entryState("two"), .present)
    }

    func testInvalidationWaitsForInFlightOperationAndThenRejectsTheEscapedTransaction() throws {
        let fixture = try stateFixture(label: "inflight")
        let enteredBarrier = DispatchSemaphore(value: 0)
        let releaseBarrier = DispatchSemaphore(value: 0)
        let outerReturned = DispatchSemaphore(value: 0)
        let publishFinished = DispatchSemaphore(value: 0)
        let transactionBox = Box<VerifiedRootStateDirectory.Transaction?>(nil)
        let firstBarrier = Flag()
        let directory = lockedDirectory(fixture, operations: .init(
            fileBarrier: { _ in
                guard firstBarrier.takeFirst() else { return true }
                enteredBarrier.signal()
                enteredBarrier.signal()
                _ = releaseBarrier.wait(timeout: .now() + 2)
                return true
            }, directoryEntryBarrier: { _ in true },
            rename: { oldFD, oldName, newFD, newName in Darwin.renameat(oldFD, oldName, newFD, newName) },
            unlink: { fd, name in Darwin.unlinkat(fd, name, 0) }, beforeQuarantineUnlink: { _, _ in }
        ))
        let directoryBox = Box(directory)
        DispatchQueue.global().async {
            _ = RootStateLock.withExclusive(directory: directoryBox.value) { transaction in
                transactionBox.set(transaction)
                DispatchQueue.global().async {
                    _ = transactionBox.value?.publish(Data("active".utf8), to: "active")
                    publishFinished.signal()
                }
                _ = enteredBarrier.wait(timeout: .now() + 1)
                return true
            }
            outerReturned.signal()
        }
        XCTAssertEqual(enteredBarrier.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(outerReturned.wait(timeout: .now() + 0.05), .timedOut)
        releaseBarrier.signal()
        XCTAssertEqual(publishFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(outerReturned.wait(timeout: .now() + 2), .success)
        guard let escaped = transactionBox.value else { return XCTFail("transaction was not captured") }
        XCTAssertEqual(escaped.publish(Data("late".utf8), to: "late"), .notPublished(.transactionInactive))
    }

    private func temporaryReadPolicy() -> BoundedFileReadPolicy {
        BoundedFileReadPolicy(
            maximumBytes: 64, expectedOwnerUID: getuid(), requireSingleLink: true,
            rejectGroupOrWorldWritable: true, requireNonEmpty: true, safeParentDepth: 0,
            ancestorPolicy: .testTemporaryDirectory
        )
    }

    private func stateFixture(label: String) throws -> URL {
        let fixture = try TestSandbox.makeDirectory(label: label).url
        XCTAssertEqual(chmod(fixture.path, 0o755), 0)
        return fixture
    }

    private func makeDirectory(
        _ fixture: URL,
        operations: VerifiedRootStateDirectory.Operations = .system
    ) -> VerifiedRootStateDirectory {
        let descriptor = try! TestSandbox.openManagedDirectory(at: fixture)
        defer { close(descriptor) }
        return try! XCTUnwrap(VerifiedRootStateDirectory(
            heldDirectoryDescriptor: descriptor,
            expectations: .init(ownerUID: getuid(), groupID: getgid(), mode: 0o755),
            operations: operations
        ))
    }

    private func lockedDirectory(
        _ fixture: URL,
        operations: VerifiedRootStateDirectory.Operations = .system
    ) -> VerifiedRootStateDirectory {
        let provisioner = makeDirectory(fixture)
        let provision = provisioner.provisionLockLeaf(RootStateLock.authorizationBasename)
        guard provision == .provisioned || provision == .alreadyPresent else {
            XCTFail("lock provisioning failed: \(provision)")
            fatalError("unreachable")
        }
        return makeDirectory(fixture, operations: operations)
    }

    private func transact<T>(
        _ directory: VerifiedRootStateDirectory,
        body: (VerifiedRootStateDirectory.Transaction) -> T
    ) -> T {
        guard let result = RootStateLock.withExclusive(directory: directory, timeout: 0.1, body: body) else {
            XCTFail("could not acquire test lock")
            fatalError("unreachable")
        }
        return result
    }

    private func createPrivateFile(
        in directory: VerifiedRootStateDirectory,
        name: String,
        bytes: Data
    ) throws {
        guard let descriptor = directory.directoryDescriptor else { throw POSIXError(.EBADF) }
        let file = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(file) }
        _ = bytes.withUnsafeBytes { Darwin.write(file, $0.baseAddress, bytes.count) }
        guard Darwin.fchmod(file, 0o600) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
}
