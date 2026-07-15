import Darwin
import CryptoKit
import Foundation
import XCTest
@testable import LidSwitch
@testable import LidSwitchCore

/// Production-capability fixtures. Every mutable path is rooted in
/// TestSandbox, while operation hooks model the exact interruption boundary.
final class UserStateDurabilityFixtureTests: XCTestCase {
    /// The operation callbacks are @Sendable in production. These fixtures are
    /// invoked synchronously by one test and use this tiny state holder only
    /// to force the first syscall down its EINTR branch.
    private final class OneShot: @unchecked Sendable {
        var pending = true
        func consume() -> Bool {
            guard pending else { return false }
            pending = false
            return true
        }
    }

    func testWriteDecisionAndInputBoundsFailClosed() {
        XCTAssertEqual(UserStateFileCapability.writeDecision(result: -1, errorCode: EINTR), .retry)
        XCTAssertEqual(UserStateFileCapability.writeDecision(result: 0, errorCode: 0), .fail(EIO))
        XCTAssertEqual(UserStateFileCapability.writeDecision(result: -1, errorCode: EPIPE), .fail(EPIPE))
        XCTAssertEqual(UserStateFileCapability.writeDecision(result: 3, errorCode: 0), .accept(3))
        XCTAssertEqual(UserStateFileCapability.maximumPayloadBytes, 4_096)
        XCTAssertEqual(UserStateFileCapability.privateDirectoryMode, 0o700)
        XCTAssertEqual(UserStateFileCapability.privateFileMode, 0o600)
        XCTAssertNotEqual(
            UserStateFileCapability.AncestryPolicy.production,
            .testSandbox(rootPath: TestSandbox.literalRoot, rootIdentity: .init(device: 1, inode: 2))
        )
    }

    func testSessionStartUserStateDecisionAdmitsOnlyValidDesiredAndMissingLease() {
        XCTAssertTrue(PowerSnapshot.userStateAllowsSessionStart(
            desiredStateTruth: .valid, activationLeaseTruth: .missing, activationLeasePresent: false
        ))
        for desired in [UserStatePersistenceTruth.missing, .invalid, .retainedResidue, .unsafe, .io, .indeterminate] {
            XCTAssertFalse(PowerSnapshot.userStateAllowsSessionStart(
                desiredStateTruth: desired, activationLeaseTruth: .missing, activationLeasePresent: false
            ))
        }
        for lease in [UserStatePersistenceTruth.valid, .invalid, .unsafe, .io, .indeterminate] {
            XCTAssertFalse(PowerSnapshot.userStateAllowsSessionStart(
                desiredStateTruth: .valid, activationLeaseTruth: lease, activationLeasePresent: false
            ))
        }
        XCTAssertFalse(PowerSnapshot.userStateAllowsSessionStart(
            desiredStateTruth: .valid, activationLeaseTruth: .retainedResidue, activationLeasePresent: false
        ))
        XCTAssertFalse(PowerSnapshot.userStateAllowsSessionStart(
            desiredStateTruth: .valid, activationLeaseTruth: .missing, activationLeasePresent: true
        ))
    }

    func testGenericLeaseResidueCannotRecoverOrMakeStartEligible() throws {
        let root = try TestSandbox.makeDirectory(label: "legacy-lease-generic-residue").url
        let file = root.appendingPathComponent("activation-lease")
        try writeFixture(fixtureLease().storagePayload, to: file, mode: 0o600)
        var status = stat()
        XCTAssertEqual(lstat(file.path, &status), 0)
        let residue = root.appendingPathComponent(
            ".lidswitch-revoke-activation-lease--\(status.st_dev)-\(status.st_ino)"
        )
        XCTAssertEqual(rename(file.path, residue.path), 0)
        let policy = try fixturePolicy(root)
        XCTAssertEqual(ActivationLeaseStore.read(from: file, capabilityPolicy: policy), .retainedResidue(root.path))
        XCTAssertThrowsError(try ActivationLeaseStore.reconcileRecognizedLegacyLease(file: file, ancestryPolicy: policy)) { error in
            guard case ActivationLeaseStore.StoreError.retainedResidue = error else {
                return XCTFail("generic residue must not reconcile: \(error)")
            }
        }
        XCTAssertFalse(PowerSnapshot.userStateAllowsSessionStart(
            desiredStateTruth: .valid, activationLeaseTruth: .retainedResidue, activationLeasePresent: false
        ))
    }

    func testDesiredStateMigrationResidueDoesNotBlockExactLeaseRecovery() throws {
        let root = try TestSandbox.makeDirectory(label: "cross-record-migration-residue").url
        let desiredState = root.appendingPathComponent("desired-state")
        let activationLease = root.appendingPathComponent("activation-lease")
        let policy = try fixturePolicy(root)
        let preferences = PowerPreferences(keepAwakeEnabled: false, allowBatteryKeepAwake: false)

        try writeFixture(preferences.storagePayload, to: desiredState, mode: 0o644)
        try DesiredStateStore.write(
            preferences,
            supportDirectory: root,
            stateFile: desiredState,
            ancestryPolicy: policy
        )
        let priorNames = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".lidswitch-prior-desired-state--") }
        XCTAssertEqual(priorNames.count, 1)
        let priorName = try XCTUnwrap(priorNames.first)
        let prior = root.appendingPathComponent(priorName)
        var priorStatus = stat()
        XCTAssertEqual(lstat(prior.path, &priorStatus), 0)
        let currentIdentity = "\(priorStatus.st_dev)-\(priorStatus.st_ino)"
        let currentPrefix = ".lidswitch-prior-desired-state--\(currentIdentity)"
        XCTAssertTrue(priorName.hasPrefix(currentPrefix))
        let rebootedName = ".lidswitch-prior-desired-state--\(priorStatus.st_dev + 1)-\(priorStatus.st_ino)"
            + String(priorName.dropFirst(currentPrefix.count))
        XCTAssertEqual(rename(prior.path, root.appendingPathComponent(rebootedName).path), 0)
        XCTAssertEqual(
            DesiredStateStore.readPreferences(from: desiredState, capabilityPolicy: policy),
            .value(preferences)
        )
        guard case .missing = ActivationLeaseStore.read(
            from: activationLease,
            capabilityPolicy: policy
        ) else {
            return XCTFail("reboot-stale evidence for the other record must not become lease residue")
        }

        let lease = fixtureLease()
        try writeFixture(lease.storagePayload, to: activationLease, mode: 0o600)
        try ActivationLeaseStore.reconcileRecognizedLegacyLease(
            file: activationLease,
            ancestryPolicy: policy
        )
        guard case .missingWithRecognizedLegacyArchive = ActivationLeaseStore.read(
            from: activationLease,
            capabilityPolicy: policy
        ) else {
            return XCTFail("valid residue for another canonical record must not block exact lease recovery")
        }
        XCTAssertEqual(
            DesiredStateStore.readPreferences(from: desiredState, capabilityPolicy: policy),
            .value(preferences)
        )
    }

    func testSameRecordTemporaryResidueAndUnknownTargetRemainFailClosed() throws {
        let sameRecordRoot = try TestSandbox.makeDirectory(label: "same-record-temp-residue").url
        let sameRecordLease = sameRecordRoot.appendingPathComponent("activation-lease")
        let sameRecordPolicy = try fixturePolicy(sameRecordRoot)
        let lease = fixtureLease()
        try writeFixture(lease.storagePayload, to: sameRecordLease, mode: 0o600)
        let originalLease = try Data(contentsOf: sameRecordLease)

        let rejectedSeed = sameRecordRoot.appendingPathComponent("rejected-seed")
        try writeFixture("rejected", to: rejectedSeed, mode: 0o600)
        var rejectedStatus = stat()
        XCTAssertEqual(lstat(rejectedSeed.path, &rejectedStatus), 0)
        let rejectedName = ".lidswitch-rejected-.activation-lease.\(UUID().uuidString.lowercased())"
            + "--\(rejectedStatus.st_dev)-\(rejectedStatus.st_ino)-\(UUID().uuidString.lowercased())"
        XCTAssertEqual(rename(rejectedSeed.path, sameRecordRoot.appendingPathComponent(rejectedName).path), 0)
        XCTAssertEqual(
            ActivationLeaseStore.read(from: sameRecordLease, capabilityPolicy: sameRecordPolicy),
            .retainedResidue(sameRecordRoot.path)
        )
        XCTAssertThrowsError(try ActivationLeaseStore.reconcileRecognizedLegacyLease(
            file: sameRecordLease, ancestryPolicy: sameRecordPolicy
        ))
        XCTAssertEqual(try Data(contentsOf: sameRecordLease), originalLease)

        let unknownRoot = try TestSandbox.makeDirectory(label: "unknown-record-residue").url
        let desiredState = unknownRoot.appendingPathComponent("desired-state")
        let activationLease = unknownRoot.appendingPathComponent("activation-lease")
        let unknownPolicy = try fixturePolicy(unknownRoot)
        try DesiredStateStore.write(
            .disabled,
            supportDirectory: unknownRoot,
            stateFile: desiredState,
            ancestryPolicy: unknownPolicy
        )
        let unknownSeed = unknownRoot.appendingPathComponent("unknown-seed")
        try writeFixture("unknown", to: unknownSeed, mode: 0o600)
        var unknownStatus = stat()
        XCTAssertEqual(lstat(unknownSeed.path, &unknownStatus), 0)
        let unknownName = ".lidswitch-prior-unclassified--\(unknownStatus.st_dev)-\(unknownStatus.st_ino)"
            + "-\(UUID().uuidString.lowercased())"
        XCTAssertEqual(rename(unknownSeed.path, unknownRoot.appendingPathComponent(unknownName).path), 0)
        XCTAssertEqual(
            DesiredStateStore.readPreferences(from: desiredState, capabilityPolicy: unknownPolicy),
            .retainedResidue(unknownRoot.path)
        )
        XCTAssertEqual(
            ActivationLeaseStore.read(from: activationLease, capabilityPolicy: unknownPolicy),
            .retainedResidue(unknownRoot.path)
        )

        let malformedRoot = try TestSandbox.makeDirectory(label: "extra-marker-residue").url
        let malformedLease = malformedRoot.appendingPathComponent("activation-lease")
        let malformedPolicy = try fixturePolicy(malformedRoot)
        let malformedSeed = malformedRoot.appendingPathComponent("malformed-seed")
        try writeFixture(lease.storagePayload, to: malformedSeed, mode: 0o600)
        var malformedStatus = stat()
        XCTAssertEqual(lstat(malformedSeed.path, &malformedStatus), 0)
        let malformedName = legacyArchiveLeaf(identity: malformedStatus, payload: lease.storagePayload)
            .replacingOccurrences(
                of: ".lidswitch-legacy-lease-activation-lease--",
                with: ".lidswitch-legacy-lease-activation-lease--garbage--"
            )
        XCTAssertEqual(rename(malformedSeed.path, malformedRoot.appendingPathComponent(malformedName).path), 0)
        guard case .retainedResidue = ActivationLeaseStore.read(
            from: malformedLease, capabilityPolicy: malformedPolicy
        ) else { return XCTFail("extra identity markers must remain fail-closed") }
        XCTAssertThrowsError(try ActivationLeaseStore.reconcileRecognizedLegacyLease(
            file: malformedLease, ancestryPolicy: malformedPolicy
        ))

        let mismatchRoot = try TestSandbox.makeDirectory(label: "cross-record-inode-mismatch").url
        let mismatchLease = mismatchRoot.appendingPathComponent("activation-lease")
        let mismatchPolicy = try fixturePolicy(mismatchRoot)
        try writeFixture(lease.storagePayload, to: mismatchLease, mode: 0o600)
        let originalMismatchLease = try Data(contentsOf: mismatchLease)
        let mismatchSeed = mismatchRoot.appendingPathComponent("mismatch-seed")
        try writeFixture("mismatch", to: mismatchSeed, mode: 0o600)
        var mismatchStatus = stat()
        XCTAssertEqual(lstat(mismatchSeed.path, &mismatchStatus), 0)
        let mismatchName = ".lidswitch-prior-desired-state--\(mismatchStatus.st_dev + 1)"
            + "-\(mismatchStatus.st_ino + 1)-\(UUID().uuidString.lowercased())"
        XCTAssertEqual(rename(mismatchSeed.path, mismatchRoot.appendingPathComponent(mismatchName).path), 0)
        guard case .retainedResidue = ActivationLeaseStore.read(
            from: mismatchLease, capabilityPolicy: mismatchPolicy
        ) else { return XCTFail("cross-record residue must retain stable-inode binding") }
        XCTAssertThrowsError(try ActivationLeaseStore.reconcileRecognizedLegacyLease(
            file: mismatchLease, ancestryPolicy: mismatchPolicy
        ))
        XCTAssertEqual(try Data(contentsOf: mismatchLease), originalMismatchLease)

        let shapeRoot = try TestSandbox.makeDirectory(label: "cross-record-shape-mismatch").url
        let shapeLease = shapeRoot.appendingPathComponent("activation-lease")
        let shapePolicy = try fixturePolicy(shapeRoot)
        try writeFixture(lease.storagePayload, to: shapeLease, mode: 0o600)
        let shapeSeed = shapeRoot.appendingPathComponent("shape-seed")
        try writeFixture("shape", to: shapeSeed, mode: 0o600)
        var shapeStatus = stat()
        XCTAssertEqual(lstat(shapeSeed.path, &shapeStatus), 0)
        let shapeName = ".lidswitch-prior-desired-state--\(shapeStatus.st_dev)-\(shapeStatus.st_ino)"
        XCTAssertEqual(rename(shapeSeed.path, shapeRoot.appendingPathComponent(shapeName).path), 0)
        guard case .retainedResidue = ActivationLeaseStore.read(
            from: shapeLease, capabilityPolicy: shapePolicy
        ) else { return XCTFail("non-producer suffix shapes must remain unknown and fail-closed") }
        XCTAssertThrowsError(try ActivationLeaseStore.reconcileRecognizedLegacyLease(
            file: shapeLease, ancestryPolicy: shapePolicy
        ))
    }

    func testRecognizedLegacyLeaseArchivesExactBytesAndProjectsMissingActiveLease() throws {
        let root = try TestSandbox.makeDirectory(label: "legacy-lease-archive").url
        let file = root.appendingPathComponent("activation-lease")
        let lease = fixtureLease()
        try writeFixture(lease.storagePayload, to: file, mode: 0o600)
        let policy = try fixturePolicy(root)

        try ActivationLeaseStore.reconcileRecognizedLegacyLease(file: file, ancestryPolicy: policy)
        guard case let .missingWithRecognizedLegacyArchive(archive) = ActivationLeaseStore.read(
            from: file, capabilityPolicy: policy
        ) else { return XCTFail("exact archived legacy lease must project canonical absence") }
        XCTAssertTrue(archive.hasPrefix(".lidswitch-legacy-lease-activation-lease--"))
        let archiveURL = root.appendingPathComponent(archive)
        var archiveStatus = stat()
        XCTAssertEqual(lstat(archiveURL.path, &archiveStatus), 0)
        let archiveIdentity = "\(archiveStatus.st_dev)-\(archiveStatus.st_ino)-"
        let archivePrefix = ".lidswitch-legacy-lease-activation-lease--\(archiveIdentity)"
        XCTAssertTrue(archive.hasPrefix(archivePrefix))
        let rebootedArchive = ".lidswitch-legacy-lease-activation-lease--\(archiveStatus.st_dev + 1)-\(archiveStatus.st_ino)-"
            + String(archive.dropFirst(archivePrefix.count))
        XCTAssertEqual(rename(archiveURL.path, root.appendingPathComponent(rebootedArchive).path), 0)
        guard case .missingWithRecognizedLegacyArchive = ActivationLeaseStore.read(
            from: file, capabilityPolicy: policy
        ) else { return XCTFail("verified legacy archive must survive APFS device renumbering") }
        XCTAssertTrue(try UserStateFileCapability.canonicalFinalIsAbsent(
            finalFile: file, supportDirectory: root, ancestryPolicy: policy
        ))
        XCTAssertTrue(PowerSnapshot.userStateAllowsSessionStart(
            desiredStateTruth: .valid, activationLeaseTruth: .missing, activationLeasePresent: false
        ))
        // Repeating only this exact descriptor/digest-bound transaction is a
        // non-mutating success; no generic retained name is accepted here.
        try ActivationLeaseStore.reconcileRecognizedLegacyLease(file: file, ancestryPolicy: policy)
    }

    func testExactStaleCanonicalLegacyLeaseClassifiesForPrepareThenArchivesToMissing() throws {
        let root = try TestSandbox.makeDirectory(label: "stale-canonical-legacy-lease").url
        let file = root.appendingPathComponent("activation-lease")
        let now = Date(timeIntervalSince1970: 1_000)
        let stale = ActivationLease(
            sessionID: UUID(), bootID: "fixture-boot", expiresAt: now.addingTimeInterval(-1),
            issuedMonotonic: 10, expiresMonotonic: 20, ownerUID: getuid(), systemBuild: "fixture-build"
        )
        try writeFixture(stale.storagePayload, to: file, mode: 0o600)
        let policy = try fixturePolicy(root)
        guard case let .legacyPlaintext(observed) = ActivationLeaseStore.read(from: file, capabilityPolicy: policy) else {
            return XCTFail("exact legacy plaintext provenance was lost")
        }
        let classified = PowerInspector.classifyActivationLeaseObservation(
            .legacyPlaintext(observed), now: now, nowMonotonic: 21,
            bootID: "fixture-boot", systemBuild: "fixture-build", expectedOwnerUID: getuid()
        )
        guard case .staleLegacyCanonical = classified else {
            return XCTFail("expired exact canonical legacy lease must be recoverable stale residue")
        }
        XCTAssertFalse(PowerSnapshot.userStateAllowsSessionStart(
            desiredStateTruth: .valid, activationLeaseTruth: .invalid, activationLeasePresent: false
        ))

        try ActivationLeaseStore.reconcileRecognizedLegacyLease(file: file, ancestryPolicy: policy)
        guard case .missingWithRecognizedLegacyArchive = ActivationLeaseStore.read(
            from: file, capabilityPolicy: policy
        ) else { return XCTFail("reconciliation must yield verified canonical absence plus audit evidence") }
        XCTAssertTrue(try UserStateFileCapability.canonicalFinalIsAbsent(
            finalFile: file, supportDirectory: root, ancestryPolicy: policy
        ))
        XCTAssertTrue(PowerSnapshot.userStateAllowsSessionStart(
            desiredStateTruth: .valid, activationLeaseTruth: .missing, activationLeasePresent: false
        ))

        let active = ActivationLease(
            sessionID: UUID(), bootID: "fixture-boot", expiresAt: now.addingTimeInterval(10),
            issuedMonotonic: 10, expiresMonotonic: 30, ownerUID: getuid(), systemBuild: "fixture-build"
        )
        XCTAssertEqual(
            PowerInspector.classifyActivationLeaseObservation(
                .legacyPlaintext(active), now: now, nowMonotonic: 20,
                bootID: "fixture-boot", systemBuild: "fixture-build", expectedOwnerUID: getuid()
            ),
            .value(active)
        )
    }

    func testMalformedLegacyArchiveEvidenceFailsClosed() throws {
        let root = try TestSandbox.makeDirectory(label: "legacy-lease-malformed-archive").url
        let archive = root.appendingPathComponent(
            ".lidswitch-legacy-lease-activation-lease--1-2-" + String(repeating: "0", count: 64)
        )
        try writeFixture("not-a-lease", to: archive, mode: 0o600)
        let file = root.appendingPathComponent("activation-lease")
        let policy = try fixturePolicy(root)
        XCTAssertEqual(ActivationLeaseStore.read(from: file, capabilityPolicy: policy), .retainedResidue(file.path))
        XCTAssertThrowsError(try ActivationLeaseStore.reconcileRecognizedLegacyLease(file: file, ancestryPolicy: policy))
        XCTAssertFalse(PowerSnapshot.userStateAllowsSessionStart(
            desiredStateTruth: .valid, activationLeaseTruth: .retainedResidue, activationLeasePresent: false
        ))
    }

    func testAdditionalOrSwappedLegacyArchiveEvidenceFailsClosed() throws {
        let root = try TestSandbox.makeDirectory(label: "legacy-lease-extra-archive").url
        let file = root.appendingPathComponent("activation-lease")
        let lease = fixtureLease()
        try writeFixture(lease.storagePayload, to: file, mode: 0o600)
        let policy = try fixturePolicy(root)
        try ActivationLeaseStore.reconcileRecognizedLegacyLease(file: file, ancestryPolicy: policy)

        let seed = root.appendingPathComponent("extra-seed")
        try writeFixture(lease.storagePayload, to: seed, mode: 0o600)
        var status = stat()
        XCTAssertEqual(lstat(seed.path, &status), 0)
        let extra = root.appendingPathComponent(legacyArchiveLeaf(
            identity: status, payload: lease.storagePayload
        ))
        XCTAssertEqual(rename(seed.path, extra.path), 0)
        XCTAssertEqual(ActivationLeaseStore.read(from: file, capabilityPolicy: policy), .retainedResidue(root.path))
        XCTAssertThrowsError(try ActivationLeaseStore.reconcileRecognizedLegacyLease(file: file, ancestryPolicy: policy))

        let swappedRoot = try TestSandbox.makeDirectory(label: "legacy-lease-swapped-archive").url
        let swappedFile = swappedRoot.appendingPathComponent("activation-lease")
        try writeFixture(lease.storagePayload, to: swappedFile, mode: 0o600)
        let rootPath = swappedRoot.path
        let swap = UserStateFileCapability.Operations(
            fileFsync: UserStateFileCapability.Operations.system.fileFsync,
            directoryFsync: UserStateFileCapability.Operations.system.directoryFsync,
            close: UserStateFileCapability.Operations.system.close,
            renameExclusive: { oldFD, oldName, newFD, newName in
                let result = UserStateFileCapability.Operations.system.renameExclusive(oldFD, oldName, newFD, newName)
                if result.0 == 0 {
                    _ = unlink(rootPath + "/" + newName)
                    let replacement = open(rootPath + "/" + newName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                    if replacement >= 0 { _ = Darwin.close(replacement) }
                }
                return result
            }
        )
        XCTAssertThrowsError(try ActivationLeaseStore.reconcileRecognizedLegacyLease(
            file: swappedFile, operations: swap, ancestryPolicy: try fixturePolicy(swappedRoot)
        )) { error in
            guard case ActivationLeaseStore.StoreError.revokedIndeterminate = error else {
                return XCTFail("archive replacement after atomic detach is indeterminate: \(error)")
            }
        }
    }

    func testJournalCommitGuardRunsBeforeEqualOrChangingPwrite() throws {
        let root = try TestSandbox.makeDirectory(label: "user-state-journal-guard").url
        let state = root.appendingPathComponent("desired-state")
        let policy = try fixturePolicy(root)
        try DesiredStateStore.write(.disabled, supportDirectory: root, stateFile: state, ancestryPolicy: policy)
        let before = try Data(contentsOf: state)
        for payload in ["mode=disabled\nbattery=disabled\n", "mode=enabled\nbattery=disabled\n"] {
            XCTAssertThrowsError(try UserStateFileCapability.writePayload(
                payload, finalFile: state, supportDirectory: root, temporaryPrefix: ".fixture.",
                commitGuard: { false }, ancestryPolicy: policy
            )) { error in
                guard case UserStateFileCapability.Failure.commitRejected = error else {
                    return XCTFail("journal guard must reject before pwrite: \(error)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: state), before)
        }
    }

    func testJournalPwriteSeamRetriesEINTRAndMapsZeroAfterBytesToIndeterminate() throws {
        let root = try TestSandbox.makeDirectory(label: "user-state-journal-pwrite").url
        let state = root.appendingPathComponent("desired-state")
        let policy = try fixturePolicy(root)
        try DesiredStateStore.write(.disabled, supportDirectory: root, stateFile: state, ancestryPolicy: policy)
        let interrupted = OneShot()
        let partial = UserStateFileCapability.Operations(
            fileFsync: UserStateFileCapability.Operations.system.fileFsync,
            directoryFsync: UserStateFileCapability.Operations.system.directoryFsync,
            close: UserStateFileCapability.Operations.system.close,
            pwrite: { descriptor, bytes, offset in
                if interrupted.consume() { return (-1, EINTR) }
                return UserStateFileCapability.Operations.system.pwrite(
                    descriptor, Array(bytes.prefix(min(31, bytes.count))), offset
                )
            }
        )
        try UserStateFileCapability.writePayload(
            "mode=enabled\nbattery=disabled\n", finalFile: state, supportDirectory: root,
            temporaryPrefix: ".fixture.", operations: partial, ancestryPolicy: policy
        )
        XCTAssertEqual(DesiredStateStore.readPreferences(from: state, capabilityPolicy: policy), .value(.acOnlyEnabled))

        let zero = UserStateFileCapability.Operations(
            fileFsync: UserStateFileCapability.Operations.system.fileFsync,
            directoryFsync: UserStateFileCapability.Operations.system.directoryFsync,
            close: UserStateFileCapability.Operations.system.close,
            pwrite: { _, _, _ in (0, 0) }
        )
        XCTAssertThrowsError(try UserStateFileCapability.writePayload(
            "mode=disabled\nbattery=disabled\n", finalFile: state, supportDirectory: root,
            temporaryPrefix: ".fixture.", operations: zero, ancestryPolicy: policy
        )) { error in
            guard case UserStateFileCapability.Failure.committedIndeterminate = error else {
                return XCTFail("zero pwrite after a journal decision is indeterminate: \(error)")
            }
        }
    }

    func testProductionOperationSeamsHandleInterruptedPartialAndZeroWrites() throws {
        let root = try TestSandbox.makeDirectory(label: "user-state-io-seams").url
        let state = root.appendingPathComponent("desired-state")
        let writeInterrupted = OneShot()
        let readInterrupted = OneShot()
        let operations = UserStateFileCapability.Operations(
            fileFsync: UserStateFileCapability.Operations.system.fileFsync,
            directoryFsync: UserStateFileCapability.Operations.system.directoryFsync,
            close: UserStateFileCapability.Operations.system.close,
            write: { descriptor, bytes in
                if writeInterrupted.consume() { return (-1, EINTR) }
                return UserStateFileCapability.Operations.system.write(descriptor, Array(bytes.prefix(min(17, bytes.count))))
            },
            read: { descriptor, count in
                if readInterrupted.consume() { return ([], -1, EINTR) }
                return UserStateFileCapability.Operations.system.read(descriptor, min(19, count))
            }
        )
        let policy = try fixturePolicy(root)
        try UserStateFileCapability.writePayload(
            "mode=enabled\nbattery=disabled\n", finalFile: state, supportDirectory: root,
            temporaryPrefix: ".fixture.", operations: operations, ancestryPolicy: policy
        )
        XCTAssertEqual(
            try UserStateFileCapability.readPayload(
                finalFile: state, supportDirectory: root, operations: operations, ancestryPolicy: policy
            ),
            .value("mode=enabled\nbattery=disabled\n")
        )

        let zeroRoot = try TestSandbox.makeDirectory(label: "user-state-zero-write").url
        let zeroState = zeroRoot.appendingPathComponent("desired-state")
        let zeroWrite = UserStateFileCapability.Operations(
            fileFsync: UserStateFileCapability.Operations.system.fileFsync,
            directoryFsync: UserStateFileCapability.Operations.system.directoryFsync,
            close: UserStateFileCapability.Operations.system.close,
            write: { _, _ in (0, 0) }
        )
        XCTAssertThrowsError(try UserStateFileCapability.writePayload(
            "mode=disabled\nbattery=disabled\n", finalFile: zeroState, supportDirectory: zeroRoot,
            temporaryPrefix: ".fixture.", operations: zeroWrite, ancestryPolicy: try fixturePolicy(zeroRoot)
        ))
    }

    func testEmptyOversizedAndUnsafeLeafInputsAreRejectedBeforePublication() throws {
        let root = try TestSandbox.makeDirectory(label: "user-state-input").url
        let support = root.appendingPathComponent("support", isDirectory: true)
        let final = support.appendingPathComponent("desired-state")
        XCTAssertThrowsError(try UserStateFileCapability.writePayload(
            "", finalFile: final, supportDirectory: support, temporaryPrefix: ".fixture."
        ))
        XCTAssertThrowsError(try UserStateFileCapability.writePayload(
            String(repeating: "x", count: UserStateFileCapability.maximumPayloadBytes + 1),
            finalFile: final, supportDirectory: support, temporaryPrefix: ".fixture."
        ))
        for prefix in ["", ".", "..", "a/b", String(repeating: "x", count: UserStateFileCapability.maximumNameBytes)] {
            XCTAssertThrowsError(try UserStateFileCapability.writePayload(
                "mode=disabled\n", finalFile: final, supportDirectory: support, temporaryPrefix: prefix
            ), prefix)
        }
        XCTAssertFalse(UserStateFileCapability.safeLeafComponent("desired\u{0000}state"))
    }

    func testDirectoryChainRejectsUnsafeMetadataAndReplacementClassification() {
        XCTAssertTrue(UserStateFileCapability.directoryMetadataIsSafe(
            mode: mode_t(S_IFDIR) | 0o700, uid: getuid(), gid: getgid(), isDirectory: true
        ))
        XCTAssertFalse(UserStateFileCapability.directoryMetadataIsSafe(
            mode: mode_t(S_IFDIR) | 0o755, uid: getuid(), gid: getgid(), isDirectory: true
        ))
        XCTAssertFalse(UserStateFileCapability.privateRegularMetadataIsSafe(
            mode: mode_t(S_IFLNK) | 0o600, uid: getuid(), gid: getgid(), linkCount: 1, isRegular: false
        ))
        let expected = UserStateFileCapability.FileIdentity(device: 1, inode: 2)
        XCTAssertEqual(UserStateFileCapability.publicationVerification(
            expectedIdentity: expected,
            observedIdentity: .init(device: 1, inode: 3),
            metadataIsSafe: true,
            expectedBytes: [1], observedBytes: [1]
        ), .replacementOrMetadataChanged)
    }

    func testExactLegacyModesAndProductionStickyPolicyAreNarrow() {
        XCTAssertTrue(UserStateFileCapability.legacySupportMetadataIsSafe(
            mode: mode_t(S_IFDIR) | 0o755, uid: getuid(), gid: getgid(), isDirectory: true
        ))
        for mode in [mode_t(0o711), mode_t(0o750), mode_t(0o700)] {
            XCTAssertFalse(UserStateFileCapability.legacySupportMetadataIsSafe(
                mode: mode_t(S_IFDIR) | mode, uid: getuid(), gid: getgid(), isDirectory: true
            ))
        }
        XCTAssertTrue(UserStateFileCapability.replaceEligibleFinalMetadataIsSafe(
            mode: mode_t(S_IFREG) | 0o644, uid: getuid(), gid: getgid(), linkCount: 1, isRegular: true
        ))
        for mode in [mode_t(0o400), mode_t(0o640), mode_t(0o700), mode_t(0o755)] {
            XCTAssertFalse(UserStateFileCapability.replaceEligibleFinalMetadataIsSafe(
                mode: mode_t(S_IFREG) | mode, uid: getuid(), gid: getgid(), linkCount: 1, isRegular: true
            ))
        }
        XCTAssertEqual(UserStateFileCapability.AncestryPolicy.production, .production)
        XCTAssertNotEqual(
            UserStateFileCapability.AncestryPolicy.production,
            .testSandbox(rootPath: "/private/tmp/fixture", rootIdentity: .init(device: 1, inode: 2))
        )
    }

    func testPreferencesRejectCommentOnlyMissingModeAliasesAndBatteryActivation() {
        for raw in [
            "# legacy comment only\n",
            "battery=disabled\n",
            "mode=enabled\nkeep-awake=enabled\n",
            "mode=enabled\nunknown=true\n",
            "mode=enabled\nbattery=enabled\n",
            "mode=enabled\nbattery=maybe\n",
            "=enabled\n",
            "mode=\n",
        ] {
            let preferences = PowerPreferences.parse(raw)
            XCTAssertFalse(preferences.keepAwakeEnabled, raw)
            XCTAssertTrue(preferences.invalidPersistenceDetected, raw)
            XCTAssertFalse(preferences.allowBatteryKeepAwake, raw)
        }
        XCTAssertEqual(PowerPreferences.parse("enabled"), .acOnlyEnabled)
        XCTAssertEqual(PowerPreferences.parse("disabled"), .disabled)
        XCTAssertTrue(PowerPreferences.parse("\n\t").invalidPersistenceDetected)
    }

    func testSymlinkFinalAndParentAreRejectedFromSandbox() throws {
        let root = try TestSandbox.makeDirectory(label: "user-state-symlink").url
        let final = root.appendingPathComponent("desired-state")
        XCTAssertEqual(symlink("/dev/null", final.path), 0)
        XCTAssertThrowsError(try DesiredStateStore.write(.disabled, supportDirectory: root, stateFile: final))
        XCTAssertEqual(unlink(final.path), 0)
        let real = root.appendingPathComponent("real", isDirectory: true)
        XCTAssertEqual(mkdir(real.path, 0o700), 0)
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        XCTAssertEqual(symlink(real.path, linked.path), 0)
        XCTAssertThrowsError(try DesiredStateStore.write(.disabled, supportDirectory: linked, stateFile: linked.appendingPathComponent("desired-state")))
    }

    func testLegacy0755SupportAnd0644DesiredStateMigrateToPrivatePublication() throws {
        let root = try TestSandbox.makeDirectory(label: "user-state-legacy").url
        let file = root.appendingPathComponent("desired-state")
        try writeFixture("mode=disabled\nbattery=disabled\n", to: file, mode: 0o644)
        XCTAssertEqual(chmod(root.path, 0o755), 0)
        try DesiredStateStore.write(.acOnlyEnabled, supportDirectory: root, stateFile: file, ancestryPolicy: try fixturePolicy(root))
        var directory = stat(); var final = stat()
        XCTAssertEqual(lstat(root.path, &directory), 0)
        XCTAssertEqual(lstat(file.path, &final), 0)
        XCTAssertEqual(directory.st_mode & 0o777, 0o700)
        XCTAssertEqual(final.st_mode & 0o777, 0o600)
        XCTAssertEqual(
            DesiredStateStore.readPreferences(from: file, capabilityPolicy: try fixturePolicy(root)),
            .value(.acOnlyEnabled)
        )

        let unsafeRoot = try TestSandbox.makeDirectory(label: "user-state-legacy-bad").url
        let unsafeFile = unsafeRoot.appendingPathComponent("desired-state")
        try writeFixture("mode=disabled\n", to: unsafeFile, mode: 0o666)
        XCTAssertThrowsError(try DesiredStateStore.write(.disabled, supportDirectory: unsafeRoot, stateFile: unsafeFile))
        XCTAssertEqual(chmod(unsafeRoot.path, 0o775), 0)
        XCTAssertThrowsError(try DesiredStateStore.write(.disabled, supportDirectory: unsafeRoot, stateFile: unsafeFile))
        XCTAssertFalse(UserStateFileCapability.replaceEligibleFinalMetadataIsSafe(
            mode: mode_t(S_IFREG) | 0o666, uid: getuid(), gid: getgid(), linkCount: 1, isRegular: true
        ))
        XCTAssertFalse(UserStateFileCapability.replaceEligibleFinalMetadataIsSafe(
            mode: mode_t(S_IFREG) | 0o644, uid: getuid(), gid: getgid(), linkCount: 2, isRegular: true
        ))
        XCTAssertFalse(UserStateFileCapability.replaceEligibleFinalMetadataIsSafe(
            mode: mode_t(S_IFIFO) | 0o644, uid: getuid(), gid: getgid(), linkCount: 1, isRegular: false
        ))
        XCTAssertFalse(UserStateFileCapability.replaceEligibleFinalMetadataIsSafe(
            mode: mode_t(S_IFREG) | 0o644, uid: getuid() &+ 1, gid: getgid(), linkCount: 1, isRegular: true
        ))
        XCTAssertFalse(UserStateFileCapability.legacySupportMetadataIsSafe(
            mode: mode_t(S_IFDIR) | 0o775, uid: getuid(), gid: getgid(), isDirectory: true
        ))

    }

    func testCreationEEXISTRaceRebindsAndPersistsParentBeforePublish() throws {
        let root = try TestSandbox.makeDirectory(label: "user-state-eexist").url
        let support = root.appendingPathComponent("support", isDirectory: true)
        let rootPath = root.path
        let controls = UserStateFileCapability.Controls(beforeSupportCreate: { name in
            _ = mkdir(rootPath + "/" + name, 0o700)
        })
        try UserStateFileCapability.writePayload(
            "mode=disabled\nbattery=disabled\n",
            finalFile: support.appendingPathComponent("desired-state"),
            supportDirectory: support,
            temporaryPrefix: ".fixture.",
            controls: controls,
            ancestryPolicy: try fixturePolicy(root)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent("desired-state").path))
        XCTAssertTrue(UserStateFileCapability.requiresDirectoryFsync(after: .supportDirectoryCreation))
    }

    func testSupportDetachmentBeforeCommitFailsBeforeNamespacePublication() throws {
        let fixture = try makeLegacyDesiredFixture(label: "user-state-before-commit")
        let supportPath = fixture.support.path
        let movedPath = fixture.root.deletingLastPathComponent()
            .appendingPathComponent(fixture.root.lastPathComponent + "-moved", isDirectory: true).path
        let controls = UserStateFileCapability.Controls(beforeCommit: { _ in
            _ = rename(supportPath, movedPath)
            _ = mkdir(supportPath, 0o700)
        })
        XCTAssertThrowsError(try UserStateFileCapability.writePayload(
            "mode=enabled\nbattery=disabled\n", finalFile: fixture.file,
            supportDirectory: fixture.support, temporaryPrefix: ".desired-state.", controls: controls,
            ancestryPolicy: try fixturePolicy(fixture.root)
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    func testTemporaryReplacementAndPostRenameReplacementAreClassified() throws {
        let temporaryFixture = try makeLegacyDesiredFixture(label: "user-state-temp-race")
        let supportPath = temporaryFixture.support.path
        let tempControls = UserStateFileCapability.Controls(beforeCommit: { name in
            _ = unlink(supportPath + "/" + name)
            let replacement = open(supportPath + "/" + name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            if replacement >= 0 { _ = Darwin.close(replacement) }
        })
        XCTAssertThrowsError(try UserStateFileCapability.writePayload(
            "mode=enabled\nbattery=disabled\n", finalFile: temporaryFixture.file,
            supportDirectory: temporaryFixture.support, temporaryPrefix: ".desired-state.", controls: tempControls,
            ancestryPolicy: try fixturePolicy(temporaryFixture.root)
        ))

        let publishedFixture = try makeDesiredFixture(label: "user-state-post-rename")
        let finalPath = publishedFixture.file.path
        let replacementControls = UserStateFileCapability.Controls(afterRename: { _ in
            _ = unlink(finalPath)
            let replacement = open(finalPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            if replacement >= 0 { _ = Darwin.close(replacement) }
        })
        XCTAssertThrowsError(try UserStateFileCapability.writePayload(
            "mode=enabled\nbattery=disabled\n", finalFile: publishedFixture.file,
            supportDirectory: publishedFixture.support, temporaryPrefix: ".fixture.", controls: replacementControls,
            ancestryPolicy: try fixturePolicy(publishedFixture.root)
        )) { error in
            guard case UserStateFileCapability.Failure.committedIndeterminate = error else {
                return XCTFail("expected committed-indeterminate, got \(error)")
            }
        }
    }

    func testAtomicPriorQuarantineRaceNeverOverwritesReplacement() throws {
        let fixture = try makeLegacyDesiredFixture(label: "user-state-prior-quarantine-race")
        let finalPath = fixture.file.path
        let controls = UserStateFileCapability.Controls(beforeExistingFinalQuarantine: { _ in
            _ = unlink(finalPath)
            let replacement = open(finalPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            if replacement >= 0 { _ = Darwin.close(replacement) }
        })
        XCTAssertThrowsError(try {
            try UserStateFileCapability.writePayload(
                "mode=enabled\nbattery=disabled\n", finalFile: fixture.file,
                supportDirectory: fixture.support, temporaryPrefix: ".desired-state.", controls: controls,
                ancestryPolicy: try fixturePolicy(fixture.root)
            )
        }()) { error in
            guard case let UserStateFileCapability.Failure.unsafePath(reason, kind) = error,
                  reason == "replaced existing final desired-state",
                  kind == .finalFile else {
                return XCTFail("expected final replacement rejection, got \(error)")
            }
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.support.path)
                .filter { $0.hasPrefix(".lidswitch-prior-desired-state--") }.count,
            0
        )
        var replacement = stat()
        XCTAssertEqual(lstat(finalPath, &replacement), 0)
        XCTAssertEqual(replacement.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(replacement.st_size, 0)
    }

    func testTerminalFinalBindingAfterDescriptorVerificationAndDirectoryFsync() throws {
        let descriptorFixture = try makeLegacyDesiredFixture(label: "user-state-terminal-descriptor")
        let descriptorPath = descriptorFixture.file.path
        let descriptorControls = UserStateFileCapability.Controls(afterDescriptorVerification: { _ in
            _ = unlink(descriptorPath)
            let fd = open(descriptorPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            if fd >= 0 { _ = Darwin.close(fd) }
        })
        assertCommittedIndeterminate {
            try UserStateFileCapability.writePayload("mode=enabled\nbattery=disabled\n", finalFile: descriptorFixture.file, supportDirectory: descriptorFixture.support, temporaryPrefix: ".desired-state.", controls: descriptorControls, ancestryPolicy: try fixturePolicy(descriptorFixture.root))
        }

        let fsyncFixture = try makeLegacyDesiredFixture(label: "user-state-terminal-fsync")
        let fsyncPath = fsyncFixture.file.path
        let fsyncControls = UserStateFileCapability.Controls(afterDirectoryFsync: { _ in
            _ = unlink(fsyncPath)
            let fd = open(fsyncPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            if fd >= 0 { _ = Darwin.close(fd) }
        })
        assertCommittedIndeterminate {
            try UserStateFileCapability.writePayload("mode=enabled\nbattery=disabled\n", finalFile: fsyncFixture.file, supportDirectory: fsyncFixture.support, temporaryPrefix: ".desired-state.", controls: fsyncControls, ancestryPolicy: try fixturePolicy(fsyncFixture.root))
        }
    }

    func testPostRenameFsyncAndCloseFailuresAreCommittedIndeterminate() throws {
        let fsyncFixture = try makeLegacyDesiredFixture(label: "user-state-fsync")
        let fsyncFailure = UserStateFileCapability.Operations(
            fileFsync: UserStateFileCapability.Operations.system.fileFsync,
            directoryFsync: { _ in (-1, EIO) },
            close: UserStateFileCapability.Operations.system.close
        )
        assertCommittedIndeterminate {
            try UserStateFileCapability.writePayload(
                "mode=disabled\nbattery=disabled\n", finalFile: fsyncFixture.file,
                supportDirectory: fsyncFixture.support, temporaryPrefix: ".desired-state.", operations: fsyncFailure,
                ancestryPolicy: try fixturePolicy(fsyncFixture.root)
            )
        }

        let closeFixture = try makeLegacyDesiredFixture(label: "user-state-close")
        let terminalPhase = TerminalClosePhase()
        let closeFailure = UserStateFileCapability.Operations(
            fileFsync: UserStateFileCapability.Operations.system.fileFsync,
            directoryFsync: UserStateFileCapability.Operations.system.directoryFsync,
            close: { descriptor in
                terminalPhase.reached ? (-1, EIO) : UserStateFileCapability.Operations.system.close(descriptor)
            }
        )
        let terminalControls = UserStateFileCapability.Controls(beforeTerminalChainClose: { _ in terminalPhase.reached = true })
        assertCommittedIndeterminate {
            try UserStateFileCapability.writePayload(
                "mode=disabled\nbattery=disabled\n", finalFile: closeFixture.file,
                supportDirectory: closeFixture.support, temporaryPrefix: ".desired-state.", operations: closeFailure,
                controls: terminalControls,
                ancestryPolicy: try fixturePolicy(closeFixture.root)
            )
        }
        XCTAssertTrue(terminalPhase.reached)
    }

    func testCommitRejectionPreservesPriorLeaseAndRetainsOnlyBoundedPrivateEvidence() throws {
        let root = try TestSandbox.makeDirectory(label: "user-state-commit").url
        let file = root.appendingPathComponent("activation-lease")
        let prior = fixtureLease()
        try writeFixture(prior.storagePayload, to: file, mode: 0o600)
        let bytes = try Data(contentsOf: file)
        XCTAssertThrowsError(try ActivationLeaseStore.write(fixtureLease(), to: file, commitGuard: { false }, ancestryPolicy: try fixturePolicy(root))) { error in
            guard case ActivationLeaseStore.StoreError.commitRejected = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(names.filter { $0.hasPrefix(".activation-lease.") }.isEmpty)
        XCTAssertEqual(names.filter { $0.hasPrefix(".lidswitch-rejected-.activation-lease.") }.count, 1)
    }

    func testJournaledAlternatingWritesHaveZeroSteadyNamespaceGrowth() throws {
        let root = try TestSandbox.makeDirectory(label: "user-state-journal-steady").url
        let state = root.appendingPathComponent("desired-state")
        let policy = try fixturePolicy(root)
        for index in 0..<100 {
            try DesiredStateStore.write(
                index.isMultiple(of: 2) ? .disabled : .acOnlyEnabled,
                supportDirectory: root, stateFile: state, ancestryPolicy: policy
            )
        }
        XCTAssertEqual(
            DesiredStateStore.readPreferences(from: state, capabilityPolicy: policy),
            .value(.acOnlyEnabled)
        )
        let residue = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".lidswitch-") || $0.hasPrefix(".desired-state.") }
        XCTAssertTrue(residue.isEmpty)
    }

    func testRetainedResidueCapacityReservesTheNinthNameBeforeMutation() throws {
        let root = try TestSandbox.makeDirectory(label: "user-state-residue-capacity").url
        let state = root.appendingPathComponent("desired-state")
        let policy = try fixturePolicy(root)
        for index in 0..<7 {
            let staging = root.appendingPathComponent("staging-\(index)")
            try writeFixture("mode=disabled\nbattery=disabled\n", to: staging, mode: 0o600)
            var status = stat()
            XCTAssertEqual(lstat(staging.path, &status), 0)
            let retained = root.appendingPathComponent(
                ".lidswitch-rejected-desired-state--\(status.st_dev)-\(status.st_ino)-\(UUID().uuidString.lowercased())"
            )
            XCTAssertEqual(rename(staging.path, retained.path), 0)
        }
        XCTAssertThrowsError(try UserStateFileCapability.writePayload(
            "mode=disabled\nbattery=disabled\n", finalFile: state, supportDirectory: root,
            temporaryPrefix: ".fixture.", commitGuard: { false }, ancestryPolicy: policy
        )) { error in
            guard case UserStateFileCapability.Failure.commitRejected = error else {
                return XCTFail("seventh residue should reserve the eighth name: \(error)")
            }
        }
        let beforeNinth = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(beforeNinth.filter { $0.hasPrefix(".lidswitch-") }.count, 8)
        XCTAssertThrowsError(try UserStateFileCapability.writePayload(
            "mode=enabled\nbattery=disabled\n", finalFile: state, supportDirectory: root,
            temporaryPrefix: ".fixture.", ancestryPolicy: policy
        )) { error in
            guard case UserStateFileCapability.Failure.retainedResidue = error else {
                return XCTFail("ninth retained name must be rejected before mutation: \(error)")
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), beforeNinth)
    }

    func testRevokeDetachmentAndRecreationBecomeTypedIndeterminate() throws {
        let detached = try makeLeaseFixture(label: "user-state-revoke-before")
        let supportPath = detached.root.path
        let movedPath = detached.root.deletingLastPathComponent()
            .appendingPathComponent(detached.root.lastPathComponent + "-moved", isDirectory: true).path
        let beforeControls = UserStateFileCapability.Controls(beforeRevoke: { _ in
            _ = rename(supportPath, movedPath)
            _ = mkdir(supportPath, 0o700)
        })
        XCTAssertThrowsError(try UserStateFileCapability.revoke(finalFile: detached.file, supportDirectory: detached.root, controls: beforeControls, ancestryPolicy: try fixturePolicy(detached.root)))

        let recreated = try makeLeaseFixture(label: "user-state-revoke-after")
        let rootPath = recreated.root.path
        let afterControls = UserStateFileCapability.Controls(afterFirstRevokeAbsence: { name in
            let replacement = open(rootPath + "/" + name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            if replacement >= 0 { _ = Darwin.close(replacement) }
        })
        XCTAssertThrowsError(try UserStateFileCapability.revoke(finalFile: recreated.file, supportDirectory: recreated.root, controls: afterControls, ancestryPolicy: try fixturePolicy(recreated.root))) { error in
            guard case UserStateFileCapability.Failure.revokedIndeterminate = error else {
                return XCTFail("expected revoked-indeterminate, got \(error)")
            }
        }

        let detachedAfter = try makeLeaseFixture(label: "user-state-revoke-detached-after")
        let detachedAfterPath = detachedAfter.root.path
        let detachedAfterMoved = detachedAfter.root.deletingLastPathComponent()
            .appendingPathComponent(detachedAfter.root.lastPathComponent + "-moved-after", isDirectory: true).path
        let detachedAfterControls = UserStateFileCapability.Controls(afterFirstRevokeAbsence: { _ in
            _ = rename(detachedAfterPath, detachedAfterMoved)
            _ = mkdir(detachedAfterPath, 0o700)
        })
        XCTAssertThrowsError(try UserStateFileCapability.revoke(finalFile: detachedAfter.file, supportDirectory: detachedAfter.root, controls: detachedAfterControls, ancestryPolicy: try fixturePolicy(detachedAfter.root))) { error in
            guard case UserStateFileCapability.Failure.revokedIndeterminate = error else {
                return XCTFail("expected detached revoke to be indeterminate, got \(error)")
            }
        }

        let fsyncFixture = try makeLeaseFixture(label: "user-state-revoke-fsync")
        let fsyncFailure = UserStateFileCapability.Operations(
            fileFsync: UserStateFileCapability.Operations.system.fileFsync,
            directoryFsync: { _ in (-1, EIO) },
            close: UserStateFileCapability.Operations.system.close
        )
        XCTAssertThrowsError(try UserStateFileCapability.revoke(finalFile: fsyncFixture.file, supportDirectory: fsyncFixture.root, operations: fsyncFailure, ancestryPolicy: try fixturePolicy(fsyncFixture.root))) { error in
            guard case UserStateFileCapability.Failure.revokedIndeterminate = error else {
                return XCTFail("expected revoke fsync indeterminate, got \(error)")
            }
        }

        let afterFsync = try makeLeaseFixture(label: "user-state-revoke-after-fsync")
        let afterFsyncPath = afterFsync.root.path
        let afterFsyncControls = UserStateFileCapability.Controls(afterRevokeFsync: { name in
            let replacement = open(afterFsyncPath + "/" + name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            if replacement >= 0 { _ = Darwin.close(replacement) }
        })
        XCTAssertThrowsError(try UserStateFileCapability.revoke(finalFile: afterFsync.file, supportDirectory: afterFsync.root, controls: afterFsyncControls, ancestryPolicy: try fixturePolicy(afterFsync.root))) { error in
            guard case UserStateFileCapability.Failure.revokedIndeterminate = error else {
                return XCTFail("expected post-fsync revoke indeterminate, got \(error)")
            }
        }

        let tombstoneFixture = try makeLeaseFixture(label: "user-state-tombstone")
        let tombstonePath = tombstoneFixture.root.path
        let tombstoneControls = UserStateFileCapability.Controls(afterTombstoneMove: { name in
            _ = unlink(tombstonePath + "/" + name)
            let replacement = open(tombstonePath + "/" + name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            if replacement >= 0 { _ = Darwin.close(replacement) }
        })
        XCTAssertThrowsError(try UserStateFileCapability.revoke(finalFile: tombstoneFixture.file, supportDirectory: tombstoneFixture.root, controls: tombstoneControls, ancestryPolicy: try fixturePolicy(tombstoneFixture.root))) { error in
            guard case UserStateFileCapability.Failure.revokedIndeterminate = error else {
                return XCTFail("expected tombstone substitution indeterminate, got \(error)")
            }
        }

        let missingRoot = try TestSandbox.makeDirectory(label: "user-state-missing-support").url
        let missingSupport = missingRoot.appendingPathComponent("support", isDirectory: true)
        let missingControls = UserStateFileCapability.Controls(afterMissingSupport: { name in
            _ = mkdir(missingRoot.path + "/" + name, 0o700)
        })
        XCTAssertThrowsError(try UserStateFileCapability.revoke(
            finalFile: missingSupport.appendingPathComponent("activation-lease"),
            supportDirectory: missingSupport,
            controls: missingControls,
            ancestryPolicy: try fixturePolicy(missingRoot)
        ))
    }

    func testLeaseStoreRetainsDistinctRevocationUncertainty() {
        let file = URL(fileURLWithPath: "/private/tmp/lidswitch-fixture-lease")
        let mapped = ActivationLeaseStore.mapCapabilityFailure(.revokedIndeterminate("fixture", EIO), file: file)
        guard case let .revokedIndeterminate(path, code) = mapped else {
            return XCTFail("revocation uncertainty was collapsed: \(mapped)")
        }
        XCTAssertEqual(path, file.path)
        XCTAssertEqual(code, EIO)
    }

    func testStoreUnsafePathMappingPreservesSupportAndFinalKinds() {
        let support = URL(fileURLWithPath: "/unsafe/support")
        let final = support.appendingPathComponent("desired-state")
        let supportMapped = DesiredStateStore.mapCapabilityFailureForFixture(
            .unsafePath(support.path, .supportDirectory), supportDirectory: support, stateFile: final
        )
        guard case let .unsafePath(path, kind) = supportMapped else { return XCTFail("support kind lost") }
        XCTAssertEqual(path, support.path)
        XCTAssertEqual(kind, .supportDirectory)
        let finalMapped = DesiredStateStore.mapCapabilityFailureForFixture(
            .unsafePath(final.path, .finalFile), supportDirectory: support, stateFile: final
        )
        guard case let .unsafePath(finalPath, finalKind) = finalMapped else { return XCTFail("final kind lost") }
        XCTAssertEqual(finalPath, final.path)
        XCTAssertEqual(finalKind, .stateFile)
    }

    private func assertCommittedIndeterminate(_ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation()) { error in
            guard case UserStateFileCapability.Failure.committedIndeterminate = error else {
                return XCTFail("expected committed-indeterminate, got \(error)")
            }
        }
    }

    private func makeDesiredFixture(label: String) throws -> (root: URL, support: URL, file: URL) {
        let root = try TestSandbox.makeDirectory(label: label).url
        let support = root.appendingPathComponent("support", isDirectory: true)
        return (root, support, support.appendingPathComponent("desired-state"))
    }

    private func makeLegacyDesiredFixture(label: String) throws -> (root: URL, support: URL, file: URL) {
        let fixture = try makeDesiredFixture(label: label)
        try FileManager.default.createDirectory(at: fixture.support, withIntermediateDirectories: false)
        try writeFixture("mode=disabled\nbattery=disabled\n", to: fixture.file, mode: 0o644)
        return fixture
    }

    private func writeFixture(_ value: String, to file: URL, mode: mode_t) throws {
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { _ = Darwin.close(fd) }
        let bytes = Array(value.utf8)
        let result = bytes.withUnsafeBytes { raw in Darwin.write(fd, raw.baseAddress, raw.count) }
        guard result == bytes.count else { throw POSIXError(.EIO) }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
    }

    private func makeLeaseFixture(label: String) throws -> (root: URL, file: URL) {
        let root = try TestSandbox.makeDirectory(label: label).url
        let file = root.appendingPathComponent("activation-lease")
        try ActivationLeaseStore.write(fixtureLease(), to: file, ancestryPolicy: try fixturePolicy(root))
        return (root, file)
    }

    private func fixtureLease() -> ActivationLease {
        ActivationLease(
            sessionID: UUID(), bootID: "fixture-boot", expiresAt: Date().addingTimeInterval(10),
            issuedMonotonic: 10, expiresMonotonic: 20, ownerUID: getuid(), systemBuild: "fixture-build"
        )
    }

    private func legacyArchiveLeaf(identity: stat, payload: String) -> String {
        let digest = SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
        return ".lidswitch-legacy-lease-activation-lease--\(identity.st_dev)-\(identity.st_ino)-\(digest)"
    }

    private func fixturePolicy(_ root: URL) throws -> UserStateFileCapability.AncestryPolicy {
        try .testSandbox(root: root)
    }

    private final class TerminalClosePhase: @unchecked Sendable {
        var reached = false
    }
}
