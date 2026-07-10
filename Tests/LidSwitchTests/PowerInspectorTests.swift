import Darwin
import Foundation
import LidSwitchCore
import XCTest
@testable import LidSwitch
@testable import LidSwitchHelper

final class SessionSafetyTests: XCTestCase {
    func testHeartbeatRenewsFourTimesDuringFortySecondInspectionDelay() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let clock = LockedBox(startedAt)
        let monotonic = LockedBox<TimeInterval>(0)
        let renewals = LockedBox([Date]())
        let acknowledgements = LockedBox(0)
        let diagnostics = SessionDiagnosticStore(file: root.appendingPathComponent("history.json"))
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 3_600,
            renewalInterval: 8,
            acknowledgementTimeout: 20,
            now: { clock.value },
            monotonicNow: { monotonic.value },
            observe: { _ in
                let current = clock.value
                return SessionHeartbeatObservation(
                    power: .ac,
                    leaseIsValid: true,
                    helperStatus: HelperStatusRecord(
                        state: "active", reason: "verified", sessionID: sessionID, updatedAt: current
                    )
                )
            },
            renew: { _, commitGuard in
                guard commitGuard() else { throw TestError.commitRejected }
                renewals.withValue { $0.append(clock.value) }
                return monotonic.value + 30
            },
            revoke: {},
            diagnostics: diagnostics,
            onAcknowledged: { _ in acknowledgements.withValue { $0 += 1 } },
            onEnded: { _, _ in }
        )
        coordinator.start(sessionID: sessionID, initialLeaseExpiresMonotonic: 30)
        defer { coordinator.stop(reason: "test-complete") }

        coordinator.evaluateForTesting()
        for second in [8, 16, 24, 32, 40] {
            clock.value = startedAt.addingTimeInterval(TimeInterval(second))
            monotonic.value = TimeInterval(second)
            coordinator.evaluateForTesting()
        }

        XCTAssertGreaterThanOrEqual(renewals.value.count, 4)
        XCTAssertEqual(renewals.value.map { Int($0.timeIntervalSince(startedAt)) }, [8, 16, 24, 32, 40])
        XCTAssertEqual(acknowledgements.value, 1)
        XCTAssertTrue(diagnostics.entries().contains { $0.event == "acknowledged" })
    }

    func testHeartbeatAcknowledgementJustOutsideTimeoutFailsClosed() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let startedAt = Date(timeIntervalSince1970: 2_000)
        let clock = LockedBox(startedAt)
        let monotonic = LockedBox<TimeInterval>(0)
        let revoked = LockedBox(0)
        let endedReason = LockedBox<String?>(nil)
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 3_600,
            renewalInterval: 8,
            acknowledgementTimeout: 20,
            now: { clock.value },
            monotonicNow: { monotonic.value },
            observe: { _ in SessionHeartbeatObservation(power: .ac, leaseIsValid: true, helperStatus: nil) },
            renew: { _, commitGuard in
                guard commitGuard() else { throw TestError.commitRejected }
                return monotonic.value + 30
            },
            revoke: { revoked.withValue { $0 += 1 } },
            diagnostics: SessionDiagnosticStore(file: root.appendingPathComponent("history.json")),
            onAcknowledged: { _ in },
            onEnded: { _, reason in endedReason.value = reason }
        )
        coordinator.start(sessionID: sessionID, initialLeaseExpiresMonotonic: 30)
        clock.value = startedAt.addingTimeInterval(20)
        monotonic.value = 20
        coordinator.evaluateForTesting()

        XCTAssertEqual(revoked.value, 1)
        XCTAssertEqual(endedReason.value, "acknowledgement-timeout")
    }

    func testHeartbeatAcknowledgementJustInsideTimeoutCanRenew() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let base = Date(timeIntervalSince1970: 2_500)
        let clock = LockedBox(base)
        let monotonic = LockedBox<TimeInterval>(0)
        let status = LockedBox<HelperStatusRecord?>(nil)
        let acknowledged = LockedBox(0)
        let renewed = LockedBox(0)
        let revoked = LockedBox(0)
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 3_600,
            renewalInterval: 8,
            acknowledgementTimeout: 20,
            now: { clock.value },
            monotonicNow: { monotonic.value },
            observe: { _ in SessionHeartbeatObservation(power: .ac, leaseIsValid: true, helperStatus: status.value) },
            renew: { _, commitGuard in
                guard commitGuard() else { throw TestError.commitRejected }
                renewed.withValue { $0 += 1 }
                return monotonic.value + 30
            },
            revoke: { revoked.withValue { $0 += 1 } },
            diagnostics: SessionDiagnosticStore(file: root.appendingPathComponent("history.json")),
            onAcknowledged: { _ in acknowledged.withValue { $0 += 1 } },
            onEnded: { _, _ in }
        )
        coordinator.start(sessionID: sessionID, initialLeaseExpiresMonotonic: 30)
        monotonic.value = 8
        clock.value = base.addingTimeInterval(8)
        coordinator.evaluateForTesting()
        XCTAssertEqual(renewed.value, 0)
        XCTAssertEqual(revoked.value, 0)

        monotonic.value = 19.9
        clock.value = base.addingTimeInterval(19.9)
        status.value = HelperStatusRecord(
            state: "active", reason: "verified", sessionID: sessionID, updatedAt: clock.value
        )
        coordinator.evaluateForTesting()
        defer { coordinator.stop(reason: "test-complete") }

        XCTAssertEqual(acknowledged.value, 1)
        XCTAssertEqual(renewed.value, 1)
    }

    func testCommitBoundaryTerminalTransitionCannotPublishFreshLease() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let base = Date(timeIntervalSince1970: 2_750)
        let clock = LockedBox(base)
        let monotonic = LockedBox<TimeInterval>(0)
        let status = LockedBox(HelperStatusRecord(
            state: "active", reason: "verified", sessionID: sessionID, updatedAt: base
        ))
        let committed = LockedBox(0)
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 3_600,
            renewalInterval: 8,
            acknowledgementTimeout: 20,
            now: { clock.value },
            monotonicNow: { monotonic.value },
            observe: { _ in SessionHeartbeatObservation(power: .ac, leaseIsValid: true, helperStatus: status.value) },
            renew: { _, commitGuard in
                status.value = HelperStatusRecord(
                    state: "inactive",
                    reason: "override-lost",
                    sessionID: sessionID,
                    updatedAt: clock.value
                )
                guard commitGuard() else { throw TestError.commitRejected }
                committed.withValue { $0 += 1 }
                return monotonic.value + 30
            },
            revoke: {},
            diagnostics: SessionDiagnosticStore(file: root.appendingPathComponent("history.json")),
            onAcknowledged: { _ in },
            onEnded: { _, _ in }
        )
        coordinator.start(sessionID: sessionID, initialLeaseExpiresMonotonic: 30)
        coordinator.evaluateForTesting()
        monotonic.value = 8
        clock.value = base.addingTimeInterval(8)
        coordinator.evaluateForTesting()

        XCTAssertEqual(committed.value, 0)
    }

    func testHeartbeatRunsOffMainThreadWithoutRunLoopTimer() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let renewedOffMain = LockedBox(false)
        let signal = DispatchSemaphore(value: 0)
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 0.005,
            renewalInterval: 0.01,
            acknowledgementTimeout: 1,
            observe: { _ in
                SessionHeartbeatObservation(
                    power: .ac,
                    leaseIsValid: true,
                    helperStatus: HelperStatusRecord(
                        state: "active",
                        reason: "verified",
                        sessionID: sessionID,
                        updatedAt: Date()
                    )
                )
            },
            renew: { _, commitGuard in
                guard commitGuard() else { throw TestError.commitRejected }
                renewedOffMain.value = !Thread.isMainThread
                signal.signal()
                return MonotonicClock.seconds() + 30
            },
            revoke: {},
            diagnostics: SessionDiagnosticStore(file: root.appendingPathComponent("history.json")),
            onAcknowledged: { _ in },
            onEnded: { _, _ in }
        )
        coordinator.start(
            sessionID: sessionID,
            initialLeaseExpiresMonotonic: MonotonicClock.seconds() + 30
        )
        XCTAssertEqual(signal.wait(timeout: .now() + 1), .success)
        coordinator.stop(reason: "test-complete")
        XCTAssertTrue(renewedOffMain.value)
    }

    func testObservedUnplugAndReconnectCannotRearmGeneration() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let clock = LockedBox(Date(timeIntervalSince1970: 3_000))
        let monotonic = LockedBox<TimeInterval>(0)
        let power = LockedBox(SessionHeartbeatObservation.Power.ac)
        let renewals = LockedBox(0)
        let revocations = LockedBox(0)
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 3_600,
            renewalInterval: 8,
            acknowledgementTimeout: 20,
            now: { clock.value },
            monotonicNow: { monotonic.value },
            observe: { _ in
                SessionHeartbeatObservation(
                    power: power.value,
                    leaseIsValid: true,
                    helperStatus: HelperStatusRecord(
                        state: "active", reason: "verified", sessionID: sessionID, updatedAt: clock.value
                    )
                )
            },
            renew: { _, commitGuard in
                guard commitGuard() else { throw TestError.commitRejected }
                renewals.withValue { $0 += 1 }
                return monotonic.value + 30
            },
            revoke: { revocations.withValue { $0 += 1 } },
            diagnostics: SessionDiagnosticStore(file: root.appendingPathComponent("history.json")),
            onAcknowledged: { _ in },
            onEnded: { _, _ in }
        )
        coordinator.start(sessionID: sessionID, initialLeaseExpiresMonotonic: 30)
        coordinator.evaluateForTesting()
        power.value = .disconnected
        coordinator.evaluateForTesting()
        power.value = .ac
        clock.withValue { $0 = $0.addingTimeInterval(40) }
        monotonic.value = 40
        coordinator.evaluateForTesting()

        XCTAssertEqual(revocations.value, 1)
        XCTAssertEqual(renewals.value, 0)
    }

    func testHelperOverrideLostAndStatusMismatchEndHeartbeatPermanently() throws {
        for drift in ["override-lost", "lease-expired-or-invalid"] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let sessionID = UUID()
            let clock = LockedBox(Date(timeIntervalSince1970: 4_000))
            let monotonic = LockedBox<TimeInterval>(0)
            let status = LockedBox(HelperStatusRecord(
                state: "active", reason: "verified", sessionID: sessionID, updatedAt: clock.value
            ))
            let renewals = LockedBox(0)
            let endedReason = LockedBox<String?>(nil)
            let coordinator = SessionHeartbeatCoordinator(
                observationInterval: 3_600,
                renewalInterval: 8,
                acknowledgementTimeout: 20,
                now: { clock.value },
                monotonicNow: { monotonic.value },
                observe: { _ in SessionHeartbeatObservation(power: .ac, leaseIsValid: true, helperStatus: status.value) },
                renew: { _, commitGuard in
                    guard commitGuard() else { throw TestError.commitRejected }
                    renewals.withValue { $0 += 1 }
                    return monotonic.value + 30
                },
                revoke: {},
                diagnostics: SessionDiagnosticStore(file: root.appendingPathComponent("history.json")),
                onAcknowledged: { _ in },
                onEnded: { _, reason in endedReason.value = reason }
            )
            coordinator.start(sessionID: sessionID, initialLeaseExpiresMonotonic: 30)
            coordinator.evaluateForTesting()
            status.value = HelperStatusRecord(state: "inactive", reason: drift, sessionID: sessionID, updatedAt: clock.value)
            clock.withValue { $0 = $0.addingTimeInterval(8) }
            monotonic.value = 8
            coordinator.evaluateForTesting()
            status.value = HelperStatusRecord(state: "active", reason: "verified", sessionID: sessionID, updatedAt: clock.value)
            coordinator.evaluateForTesting()

            XCTAssertEqual(renewals.value, 0)
            XCTAssertTrue(endedReason.value?.contains(drift) == true)
        }
    }

    func testSessionDiagnosticsAreBoundedStructuredOwnerOnlyAndSanitized() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.json")
        let store = SessionDiagnosticStore(file: file, maximumEntries: 3, maximumBytes: 2_048)
        for index in 0..<8 {
            store.record(event: "renew", reason: "reason-\(index)", sessionID: UUID())
        }
        store.record(event: "end", reason: "token=secret/value", sessionID: UUID())

        let entries = store.entries()
        XCTAssertLessThanOrEqual(entries.count, 3)
        XCTAssertTrue(entries.allSatisfy { $0.schema == 1 && !$0.sessionID.isEmpty })
        XCTAssertEqual(entries.last?.reason, "redacted")
        XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 2_048)
        var metadata = stat()
        XCTAssertEqual(lstat(file.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("secret/value"))
    }

    func testFreshManualSessionRequiresVerifiedCurrentAcknowledgement() {
        let now = Date()
        let lease = makeLease(sessionID: UUID(), lifetime: 30)
        let status = HelperStatusRecord(
            state: "active",
            reason: "verified",
            sessionID: lease.sessionID,
            updatedAt: now
        )
        let snapshot = makeSnapshot(
            source: .ac,
            sleepDisabled: true,
            sleepDisabledVerified: true,
            lease: lease,
            status: status,
            checkedAt: now
        )

        XCTAssertTrue(snapshot.sessionActive)
        XCTAssertEqual(snapshot.statusTitle, "Protection active — plugged in")
        XCTAssertFalse(snapshot.canStartSession)
    }

    func testStaleAcknowledgementCannotClaimActive() {
        let now = Date()
        let lease = makeLease(sessionID: UUID(), lifetime: 30)
        let status = HelperStatusRecord(
            state: "active",
            reason: "verified",
            sessionID: lease.sessionID,
            updatedAt: now.addingTimeInterval(-30)
        )
        let snapshot = makeSnapshot(
            source: .ac,
            sleepDisabled: true,
            sleepDisabledVerified: true,
            lease: lease,
            status: status,
            checkedAt: now
        )

        XCTAssertFalse(snapshot.sessionActive)
        XCTAssertEqual(snapshot.statusTitle, "Restore required")
    }

    func testRecoveryRequiredBlocksReadyAndNewSessionsEvenWhenSleepDisabledIsOff() {
        let snapshot = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true,
            status: HelperStatusRecord(
                state: "recovery-required",
                reason: "restore-unverified",
                sessionID: UUID(),
                updatedAt: Date()
            )
        )

        XCTAssertTrue(snapshot.restoreRequired)
        XCTAssertTrue(snapshot.helperRecoveryRequired)
        XCTAssertFalse(snapshot.canStartSession)
        XCTAssertEqual(snapshot.statusTitle, "Recovery required")
    }

    func testOrphanedLeaseCannotClaimProtectionAfterAppRelaunch() {
        let now = Date()
        let lease = makeLease(sessionID: UUID(), lifetime: 30)
        let snapshot = makeSnapshot(
            source: .ac,
            sleepDisabled: true,
            sleepDisabledVerified: true,
            lease: lease,
            status: HelperStatusRecord(
                state: "active",
                reason: "verified",
                sessionID: lease.sessionID,
                updatedAt: now
            ),
            checkedAt: now,
            ownsLease: false
        )

        XCTAssertFalse(snapshot.sessionActive)
        XCTAssertTrue(snapshot.orphanedLeasePresent)
        XCTAssertEqual(snapshot.statusTitle, "Restore required")
    }

    func testUnpluggedSnapshotNeverClaimsProtectionOrRearminess() {
        let now = Date()
        let lease = makeLease(sessionID: UUID(), lifetime: 30)
        let snapshot = makeSnapshot(
            source: .battery(percent: 80),
            sleepDisabled: true,
            sleepDisabledVerified: true,
            lease: lease,
            status: HelperStatusRecord(
                state: "active",
                reason: "verified",
                sessionID: lease.sessionID,
                updatedAt: now
            ),
            checkedAt: now
        )

        XCTAssertFalse(snapshot.sessionActive)
        XCTAssertFalse(snapshot.canStartSession)
        XCTAssertEqual(snapshot.statusTitle, "Restore required")
    }

    func testUnknownLivePowerStateFailsClosed() {
        let snapshot = makeSnapshot(
            source: .unknown("pmset failed"),
            sleepDisabled: false,
            sleepDisabledVerified: false
        )

        XCTAssertFalse(snapshot.canStartSession)
        XCTAssertEqual(snapshot.statusTitle, "Power status unavailable")
    }

    func testOldLoginItemLoadedIsDistinctLegacyResidue() {
        let snapshot = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true,
            legacyLoginItemLoaded: true
        )

        XCTAssertTrue(snapshot.legacyResiduePresent)
        XCTAssertFalse(snapshot.canStartSession)
        XCTAssertEqual(snapshot.statusTitle, "Old startup files found")
    }

    func testSleepDisabledParserRejectsMissingAndMalformedValues() {
        XCTAssertEqual(
            PowerInspector.parseSleepDisabled(from: "SleepDisabled 1\n"),
            true
        )
        XCTAssertEqual(
            PowerInspector.parseSleepDisabled(from: "SleepDisabled 0\n"),
            false
        )
        XCTAssertNil(PowerInspector.parseSleepDisabled(from: "SleepDisabled maybe\n"))
        XCTAssertNil(PowerInspector.parseSleepDisabled(from: "sleep 0\n"))
    }

    func testPowerAndACSleepParsing() {
        XCTAssertEqual(
            PowerInspector.parsePowerSource(from: "Now drawing from 'AC Power'\n"),
            .ac
        )
        XCTAssertEqual(
            PowerInspector.parsePowerSource(from: "Now drawing from 'Battery Power'\n -InternalBattery-0\t35%; discharging;\n"),
            .battery(percent: 35)
        )
        XCTAssertEqual(
            PowerInspector.parseACIdleSleep(from: "Battery Power:\n sleep 7\nAC Power:\n sleep 3\n"),
            3
        )
    }

    func testHelperStatusRequiresTimestampAndRejectsDuplicates() {
        XCTAssertNil(HelperStatusRecord.parse("state=active\nreason=verified\nsession=none\n"))
        XCTAssertNil(HelperStatusRecord.parse("state=active\nstate=active\nreason=verified\nsession=none\nupdated=1\n"))
        XCTAssertNotNil(HelperStatusRecord.parse("state=inactive\nreason=restored\nsession=none\nupdated=1\n"))
    }

    func testLeaseParserRejectsDuplicateAndUnknownFields() {
        let lease = makeLease(sessionID: UUID(), lifetime: 30)
        XCTAssertNotNil(ActivationLease.parse(lease.storagePayload))
        XCTAssertNil(ActivationLease.parse(lease.storagePayload + "session=\(UUID())\n"))
        XCTAssertNil(ActivationLease.parse(lease.storagePayload + "unexpected=value\n"))
    }

    func testTerminalGenerationLedgerParserMatchesBoundedHelperSemantics() {
        let first = UUID()
        let second = UUID()
        XCTAssertEqual(TerminalGenerationLedger.parse(""), [])
        XCTAssertEqual(
            TerminalGenerationLedger.parse("\(first.uuidString)\n\(second.uuidString)\n"),
            [first, second]
        )
        XCTAssertNil(TerminalGenerationLedger.parse("not-a-uuid\n"))
        XCTAssertNil(TerminalGenerationLedger.parse("\(first.uuidString)\n\(first.uuidString)\n"))
        let tooMany = (0...TerminalGenerationLedger.maximumEntries)
            .map { _ in UUID().uuidString }
            .joined(separator: "\n") + "\n"
        XCTAssertNil(TerminalGenerationLedger.parse(tooMany))
    }

    func testAppLedgerReadinessRejectsMalformedDuplicateWritableAndSymlinkState() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = root.appendingPathComponent("terminal-generations")
        let first = UUID()
        let second = UUID()
        try "\(first.uuidString)\n\(second.uuidString)\n".write(to: ledger, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(ledger.path, 0o644), 0)
        XCTAssertTrue(PowerInspector.terminalGenerationsValid(path: ledger.path, expectedOwnerUID: getuid()))

        try "\(first.uuidString)\n\(first.uuidString.lowercased())\n".write(to: ledger, atomically: true, encoding: .utf8)
        XCTAssertFalse(PowerInspector.terminalGenerationsValid(path: ledger.path, expectedOwnerUID: getuid()))
        try "malformed\n".write(to: ledger, atomically: true, encoding: .utf8)
        XCTAssertFalse(PowerInspector.terminalGenerationsValid(path: ledger.path, expectedOwnerUID: getuid()))

        try "\(first.uuidString)\n".write(to: ledger, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(ledger.path, 0o622), 0)
        XCTAssertFalse(PowerInspector.terminalGenerationsValid(path: ledger.path, expectedOwnerUID: getuid()))
        XCTAssertEqual(unlink(ledger.path), 0)
        XCTAssertEqual(symlink("missing-target", ledger.path), 0)
        XCTAssertFalse(PowerInspector.terminalGenerationsValid(path: ledger.path, expectedOwnerUID: getuid()))
    }

    func testTerminalGenerationStorePublishesAppReadableNonWritableLedger() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = root.appendingPathComponent("terminal-generations")
        let sessionID = UUID()

        XCTAssertTrue(TerminalGenerationStore.record(sessionID: sessionID, path: ledger.path))
        var metadata = stat()
        XCTAssertEqual(lstat(ledger.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o644)
        XCTAssertEqual(TerminalGenerationLedger.parse(try String(contentsOf: ledger)), [sessionID])
        XCTAssertTrue(PowerInspector.terminalGenerationsValid(path: ledger.path, expectedOwnerUID: getuid()))
    }

    func testLeaseRejectsRebootExpiryAndExcessiveLifetime() {
        let now = Date()
        let mono = MonotonicClock.seconds()
        let lease = makeLease(sessionID: UUID(), lifetime: 30, now: now, monotonic: mono)

        XCTAssertEqual(
            lease.validationFailure(
                now: now,
                nowMonotonic: mono,
                currentBootID: "different-boot",
                expectedOwnerUID: getuid(),
                currentSystemBuild: lease.systemBuild
            ),
            .bootMismatch
        )

        let expired = ActivationLease(
            sessionID: lease.sessionID,
            bootID: lease.bootID,
            expiresAt: now.addingTimeInterval(-1),
            issuedMonotonic: mono - 20,
            expiresMonotonic: mono - 1,
            ownerUID: getuid(),
            systemBuild: lease.systemBuild
        )
        XCTAssertEqual(
            expired.validationFailure(
                now: now,
                nowMonotonic: mono,
                currentBootID: lease.bootID,
                expectedOwnerUID: getuid(),
                currentSystemBuild: lease.systemBuild
            ),
            .expired
        )

        let excessive = ActivationLease(
            sessionID: lease.sessionID,
            bootID: lease.bootID,
            expiresAt: now.addingTimeInterval(60),
            issuedMonotonic: mono,
            expiresMonotonic: mono + 60,
            ownerUID: getuid(),
            systemBuild: lease.systemBuild
        )
        XCTAssertEqual(
            excessive.validationFailure(
                now: now,
                nowMonotonic: mono,
                currentBootID: lease.bootID,
                expectedOwnerUID: getuid(),
                currentSystemBuild: lease.systemBuild
            ),
            .excessiveLifetime
        )
    }

    func testLeaseCommitGuardRejectsPublicationAndPreservesPriorLease() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("activation-lease")
        let prior = makeLease(sessionID: UUID(), lifetime: 30)
        let replacement = makeLease(sessionID: UUID(), lifetime: 30)
        try ActivationLeaseStore.write(prior, to: file)
        let priorBytes = try Data(contentsOf: file)

        XCTAssertThrowsError(try ActivationLeaseStore.write(replacement, to: file, commitGuard: { false })) { error in
            guard case ActivationLeaseStore.StoreError.commitRejected = error else {
                return XCTFail("Expected commitRejected, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: file), priorBytes)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".activation-lease.") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testSecureLeaseReaderRejectsSymlinkWritableAndMalformedFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        let real = support.appendingPathComponent("real-lease")
        let link = support.appendingPathComponent("activation-lease")
        let lease = makeLease(sessionID: UUID(), lifetime: 30)
        try lease.storagePayload.write(to: real, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(real.path, 0o600), 0)
        XCTAssertEqual(symlink(real.path, link.path), 0)

        assertLeaseFailure(
            SecureLeaseReader.load(path: link.path, expectedOwnerUID: getuid()),
            equals: .unsafeFile
        )

        XCTAssertEqual(unlink(link.path), 0)
        try lease.storagePayload.write(to: link, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(link.path, 0o666), 0)
        assertLeaseFailure(
            SecureLeaseReader.load(path: link.path, expectedOwnerUID: getuid()),
            equals: .unsafeFile
        )

        try "not-a-lease\n".write(to: link, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(link.path, 0o600), 0)
        assertLeaseFailure(
            SecureLeaseReader.load(path: link.path, expectedOwnerUID: getuid()),
            equals: .malformed
        )
    }

    func testAppliedStateRejectsStaleZeroBaselineAndUnsafeFile() throws {
        XCTAssertNil(AppliedState.parse("session=\(UUID())\nchanged_sleep_disabled=1\nchanged_ac_sleep=1\noriginal_ac_sleep=0\n"))

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let statePath = root.appendingPathComponent("applied-state").path
        let state = AppliedState(
            sessionID: UUID(),
            changedSleepDisabled: true,
            changedACSleep: true,
            originalACSleep: 5
        )
        try AppliedStateStore.write(state, path: statePath)
        XCTAssertEqual(AppliedStateStore.load(path: statePath), .success(state))
        XCTAssertEqual(chmod(statePath, 0o666), 0)
        XCTAssertEqual(AppliedStateStore.load(path: statePath), .invalid)
    }

    func testNativeHelperExpiresLeaseAndRestoresOwnedChanges() throws {
        let harness = try makeRuntimeHarness(lifetime: 1)
        let code = harness.runtime.run()

        XCTAssertEqual(code, 0)
        XCTAssertEqual(harness.power.currentSleepDisabled, false)
        XCTAssertEqual(harness.power.currentACSleep, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
        XCTAssertTrue(try String(contentsOfFile: harness.configuration.statusPath).contains("state=inactive"))
    }

    func testNativeHelperUnplugRestoresAndDoesNotRearmOnReconnect() throws {
        let harness = try makeRuntimeHarness(lifetime: 10)
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
            harness.power.setSource(.battery)
        }
        let code = harness.runtime.run()
        let activationCalls = harness.power.enableSleepOverrideCalls
        harness.power.setSource(.ac)

        XCTAssertEqual(code, 0)
        XCTAssertEqual(harness.power.currentSleepDisabled, false)
        XCTAssertEqual(harness.power.currentACSleep, 5)
        XCTAssertEqual(activationCalls, 1)
        XCTAssertEqual(harness.power.enableSleepOverrideCalls, 1)
    }

    func testNativeHelperOverrideLostCleansUpWithoutOverwritingExternalDrift() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5)
        let harness = try makeRuntimeHarness(lifetime: 5, power: power, reconciliationInterval: 0.02)
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in
            power.forceSleepDisabled(false)
            power.forceACSleep(7)
        }

        let code = harness.runtime.run()
        let status = try String(contentsOfFile: harness.configuration.statusPath, encoding: .utf8)

        XCTAssertEqual(code, 0)
        XCTAssertEqual(power.currentSleepDisabled, false)
        XCTAssertEqual(power.currentACSleep, 7)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
        XCTAssertTrue(status.contains("state=inactive"))
        XCTAssertTrue(status.contains("reason=override-lost"))
    }

    func testNativeHelperTerminalGenerationTombstoneBlocksSameSessionReplay() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5)
        let harness = try makeRuntimeHarness(
            lifetime: 5,
            power: power,
            reconciliationInterval: 0.02,
            terminalGenerationAllows: { _, _ in true },
            terminalGenerationRecord: { _, _ in false }
        )
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in
            power.setSource(.battery)
        }
        XCTAssertEqual(harness.runtime.run(), 0)
        XCTAssertEqual(power.enableSleepOverrideCalls, 1)
        let terminalStatus = try String(contentsOfFile: harness.configuration.statusPath, encoding: .utf8)
        XCTAssertTrue(terminalStatus.contains("state=inactive"))
        XCTAssertTrue(terminalStatus.contains("reason=power-source-changed"))
        XCTAssertTrue(terminalStatus.contains("session=\(harness.lease.sessionID.uuidString.lowercased())"))

        XCTAssertEqual(unlink(harness.configuration.leasePath), 0)
        let noLeaseRuntime = HelperRuntime(
            configuration: harness.configuration,
            power: power,
            currentBootID: { harness.lease.bootID },
            currentSystemBuild: { "25F84" },
            reconciliationInterval: 0.02,
            terminalGenerationAllows: { _, _ in true },
            terminalGenerationRecord: { _, _ in false }
        )
        XCTAssertEqual(noLeaseRuntime.run(), 0)
        let afterNoLease = try String(contentsOfFile: harness.configuration.statusPath, encoding: .utf8)
        XCTAssertTrue(afterNoLease.contains("session=\(harness.lease.sessionID.uuidString.lowercased())"))

        power.setSource(.ac)
        let replay = makeLease(sessionID: harness.lease.sessionID, lifetime: 5)
        try replay.storagePayload.write(toFile: harness.configuration.leasePath, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(harness.configuration.leasePath, 0o600), 0)
        let replayRuntime = HelperRuntime(
            configuration: harness.configuration,
            power: power,
            currentBootID: { replay.bootID },
            currentSystemBuild: { "25F84" },
            reconciliationInterval: 0.02,
            terminalGenerationAllows: { _, _ in true },
            terminalGenerationRecord: { _, _ in false }
        )

        XCTAssertEqual(replayRuntime.run(), 0)
        XCTAssertEqual(power.enableSleepOverrideCalls, 1)
        XCTAssertEqual(power.currentSleepDisabled, false)
        XCTAssertEqual(power.currentACSleep, 5)
    }

    func testTerminalGenerationCannotSuppressOwnedStateRestoration() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: true, acSleep: 0)
        let recordedAfterRestore = LockedBox(false)
        let statusWasPendingBeforeRestore = LockedBox(false)
        let harness = try makeRuntimeHarness(
            lifetime: 5,
            power: power,
            preapplyState: true,
            terminalGenerationAllows: { _, _ in false },
            terminalGenerationRecord: { _, ledgerPath in
                let appliedStatePath = URL(fileURLWithPath: ledgerPath)
                    .deletingLastPathComponent()
                    .appendingPathComponent("applied-state")
                    .path
                recordedAfterRestore.value = power.currentSleepDisabled == false
                    && power.currentACSleep == 5
                    && !FileManager.default.fileExists(atPath: appliedStatePath)
                return true
            }
        )
        power.onSleepRestore = {
            statusWasPendingBeforeRestore.value = (
                try? String(contentsOfFile: harness.configuration.statusPath)
            )?.contains("reason=terminal-session-recovery-restore-pending") == true
        }

        XCTAssertEqual(harness.runtime.run(), 0)
        XCTAssertTrue(statusWasPendingBeforeRestore.value)
        XCTAssertTrue(recordedAfterRestore.value)
        XCTAssertEqual(power.currentSleepDisabled, false)
        XCTAssertEqual(power.currentACSleep, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
        XCTAssertTrue(
            try String(contentsOfFile: harness.configuration.statusPath)
                .contains("reason=terminal-session-recovery")
        )
    }

    func testTerminalGenerationRetriesRecoveryRequiredRestoreOnRestart() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: true, acSleep: 0)
        power.failSleepRestore = true
        let recordCalls = LockedBox(0)
        let harness = try makeRuntimeHarness(
            lifetime: 5,
            power: power,
            preapplyState: true,
            terminalGenerationAllows: { _, _ in false },
            terminalGenerationRecord: { _, _ in
                recordCalls.withValue { $0 += 1 }
                return true
            }
        )

        XCTAssertEqual(harness.runtime.run(), 0)
        XCTAssertEqual(recordCalls.value, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
        XCTAssertTrue(
            try String(contentsOfFile: harness.configuration.statusPath)
                .contains("state=recovery-required")
        )

        power.failSleepRestore = false
        let restartedRuntime = HelperRuntime(
            configuration: harness.configuration,
            power: power,
            currentBootID: { harness.lease.bootID },
            currentSystemBuild: { "25F84" },
            terminalGenerationAllows: { _, _ in false },
            terminalGenerationRecord: { _, _ in
                recordCalls.withValue { $0 += 1 }
                return true
            }
        )

        XCTAssertEqual(restartedRuntime.run(), 0)
        XCTAssertEqual(recordCalls.value, 1)
        XCTAssertEqual(power.currentSleepDisabled, false)
        XCTAssertEqual(power.currentACSleep, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
        XCTAssertTrue(
            try String(contentsOfFile: harness.configuration.statusPath)
                .contains("state=inactive")
        )
    }

    func testTerminalStatusCannotSuppressOwnedStateRestoration() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: true, acSleep: 0)
        let recordCalls = LockedBox(0)
        let harness = try makeRuntimeHarness(
            lifetime: 5,
            power: power,
            preapplyState: true,
            terminalGenerationAllows: { _, _ in true },
            terminalGenerationRecord: { _, _ in
                recordCalls.withValue { $0 += 1 }
                return true
            }
        )
        HelperStatusStore.write(
            state: "recovery-required",
            reason: "interrupted-restore",
            sessionID: harness.lease.sessionID,
            path: harness.configuration.statusPath
        )

        XCTAssertEqual(harness.runtime.run(), 0)
        XCTAssertEqual(recordCalls.value, 1)
        XCTAssertEqual(power.currentSleepDisabled, false)
        XCTAssertEqual(power.currentACSleep, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
        XCTAssertTrue(
            try String(contentsOfFile: harness.configuration.statusPath)
                .contains("reason=terminal-session-recovery")
        )
    }

    func testRestorePendingRestartDoesNotReactivateAfterPowerWasAlreadyRestored() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5)
        let harness = try makeRuntimeHarness(
            lifetime: 5,
            power: power,
            preapplyState: true,
            terminalGenerationAllows: { _, _ in true }
        )
        HelperStatusStore.write(
            state: "recovery-required",
            reason: "signal-restore-pending",
            sessionID: harness.lease.sessionID,
            path: harness.configuration.statusPath
        )

        XCTAssertEqual(harness.runtime.run(), 0)
        XCTAssertEqual(power.enableSleepOverrideCalls, 0)
        XCTAssertEqual(power.currentSleepDisabled, false)
        XCTAssertEqual(power.currentACSleep, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
        XCTAssertTrue(
            try String(contentsOfFile: harness.configuration.statusPath)
                .contains("state=inactive")
        )
    }

    func testNoValidLeaseRecordsTerminalOnlyAfterOwnedStateRestoration() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: true, acSleep: 0)
        let recordedAfterRestore = LockedBox(false)
        let harness = try makeRuntimeHarness(
            lifetime: 5,
            power: power,
            preapplyState: true,
            terminalGenerationRecord: { _, ledgerPath in
                let appliedStatePath = URL(fileURLWithPath: ledgerPath)
                    .deletingLastPathComponent()
                    .appendingPathComponent("applied-state")
                    .path
                recordedAfterRestore.value = power.currentSleepDisabled == false
                    && power.currentACSleep == 5
                    && !FileManager.default.fileExists(atPath: appliedStatePath)
                return true
            }
        )
        XCTAssertEqual(unlink(harness.configuration.leasePath), 0)
        HelperStatusStore.write(
            state: "active",
            reason: "verified",
            sessionID: harness.lease.sessionID,
            path: harness.configuration.statusPath
        )

        XCTAssertEqual(harness.runtime.run(), 0)
        XCTAssertTrue(recordedAfterRestore.value)
        XCTAssertEqual(power.currentSleepDisabled, false)
        XCTAssertEqual(power.currentACSleep, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
        XCTAssertTrue(
            try String(contentsOfFile: harness.configuration.statusPath)
                .contains("reason=no-valid-lease")
        )
    }

    func testNoValidLeaseTerminalizesActiveStatusWhenLedgerRecordFails() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5)
        let harness = try makeRuntimeHarness(
            lifetime: 5,
            power: power,
            reconciliationInterval: 0.02,
            terminalGenerationAllows: { _, _ in true },
            terminalGenerationRecord: { _, _ in false }
        )
        XCTAssertEqual(unlink(harness.configuration.leasePath), 0)
        HelperStatusStore.write(
            state: "active",
            reason: "verified",
            sessionID: harness.lease.sessionID,
            path: harness.configuration.statusPath
        )

        XCTAssertEqual(harness.runtime.run(), 0)
        let terminalized = try String(contentsOfFile: harness.configuration.statusPath, encoding: .utf8)
        XCTAssertTrue(terminalized.contains("state=inactive"))
        XCTAssertTrue(terminalized.contains("reason=no-valid-lease"))
        XCTAssertTrue(terminalized.contains("session=\(harness.lease.sessionID.uuidString.lowercased())"))

        let replay = makeLease(sessionID: harness.lease.sessionID, lifetime: 5)
        try replay.storagePayload.write(toFile: harness.configuration.leasePath, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(harness.configuration.leasePath, 0o600), 0)
        let replayRuntime = HelperRuntime(
            configuration: harness.configuration,
            power: power,
            currentBootID: { replay.bootID },
            currentSystemBuild: { "25F84" },
            reconciliationInterval: 0.02,
            terminalGenerationAllows: { _, _ in true },
            terminalGenerationRecord: { _, _ in false }
        )

        XCTAssertEqual(replayRuntime.run(), 0)
        XCTAssertEqual(power.enableSleepOverrideCalls, 0)
        XCTAssertEqual(power.currentSleepDisabled, false)
    }

    func testNativeHelperBlockedPreflightGenerationCannotReplayAfterReconnect() throws {
        let power = FakePowerSystem(source: .battery, sleepDisabled: false, acSleep: 5)
        let harness = try makeRuntimeHarness(
            lifetime: 5,
            power: power,
            reconciliationInterval: 0.02,
            terminalGenerationAllows: { _, _ in true },
            terminalGenerationRecord: { _, _ in false }
        )

        XCTAssertEqual(harness.runtime.run(), 0)
        XCTAssertEqual(power.enableSleepOverrideCalls, 0)
        let blockedStatus = try String(contentsOfFile: harness.configuration.statusPath, encoding: .utf8)
        XCTAssertTrue(blockedStatus.contains("session=\(harness.lease.sessionID.uuidString.lowercased())"))

        power.setSource(.ac)
        let replay = makeLease(sessionID: harness.lease.sessionID, lifetime: 5)
        try replay.storagePayload.write(toFile: harness.configuration.leasePath, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(harness.configuration.leasePath, 0o600), 0)
        let replayRuntime = HelperRuntime(
            configuration: harness.configuration,
            power: power,
            currentBootID: { replay.bootID },
            currentSystemBuild: { "25F84" },
            reconciliationInterval: 0.02,
            terminalGenerationAllows: { _, _ in true },
            terminalGenerationRecord: { _, _ in false }
        )

        XCTAssertEqual(replayRuntime.run(), 0)
        XCTAssertEqual(power.enableSleepOverrideCalls, 0)
        XCTAssertEqual(power.currentSleepDisabled, false)
    }

    func testNativeHelperRetainsAppliedStateAndExitsCleanlyWhenRestoreCannotBeVerified() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5)
        power.failSleepRestore = true
        let harness = try makeRuntimeHarness(lifetime: 1, power: power)
        let code = harness.runtime.run()

        XCTAssertEqual(code, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
        XCTAssertTrue(try String(contentsOfFile: harness.configuration.statusPath).contains("state=recovery-required"))
    }

    func testNativeHelperRollsBackWhenPowerChangesDuringActivation() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5)
        power.unplugWhenEnablingSleepOverride = true
        let harness = try makeRuntimeHarness(lifetime: 5, power: power)

        let code = harness.runtime.run()

        XCTAssertEqual(code, 0)
        XCTAssertEqual(power.currentSleepDisabled, false)
        XCTAssertEqual(power.currentACSleep, 5)
        XCTAssertEqual(power.enableSleepOverrideCalls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
        XCTAssertTrue(try String(contentsOfFile: harness.configuration.statusPath).contains("state=inactive"))
    }

    func testNativeHelperRecoversMatchingAppliedSessionAfterAbnormalExit() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: true, acSleep: 0)
        let harness = try makeRuntimeHarness(lifetime: 1, power: power, preapplyState: true)
        let code = harness.runtime.run()

        XCTAssertEqual(code, 0)
        XCTAssertEqual(power.enableSleepOverrideCalls, 0)
        XCTAssertEqual(power.currentSleepDisabled, false)
        XCTAssertEqual(power.currentACSleep, 5)
    }

    func testUnknownPowerSourceNeverActivatesHelper() throws {
        let power = FakePowerSystem(source: .unknown, sleepDisabled: false, acSleep: 5)
        let harness = try makeRuntimeHarness(lifetime: 5, power: power)
        let code = harness.runtime.run()

        XCTAssertEqual(code, 0)
        XCTAssertEqual(power.enableSleepOverrideCalls, 0)
        XCTAssertEqual(power.currentSleepDisabled, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
    }

    func testLaunchDaemonIsEventDrivenAndCrashOnly() throws {
        let plist = PrivilegedHelperManager.diagnosticLaunchDaemonPlist()
        let data = try XCTUnwrap(plist.data(using: .utf8))
        let decoded = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let keepAlive = try XCTUnwrap(decoded["KeepAlive"] as? [String: Any])

        XCTAssertFalse(plist.contains("StartInterval"))
        XCTAssertNotNil(decoded["WatchPaths"] as? [String])
        XCTAssertEqual(keepAlive["SuccessfulExit"] as? Bool, false)
        XCTAssertEqual(decoded["ThrottleInterval"] as? Int, 10)
    }

    func testNormalAdminPathsAreOwnershipAwareAndForceRestoreIsExplicit() {
        let install = PrivilegedHelperManager.diagnosticInstallScript()
        let uninstall = PrivilegedHelperManager.diagnosticUninstallScript()
        let restore = PrivilegedHelperManager.diagnosticRestoreScript()

        XCTAssertTrue(install.contains("force=0"))
        XCTAssertTrue(uninstall.contains("force=0"))
        XCTAssertTrue(restore.contains("force=1"))
        XCTAssertTrue(install.contains("lidswitch_parse_applied_state"))
        XCTAssertTrue(install.contains(AppPaths.rootTerminalGenerationsPath))
        XCTAssertTrue(install.contains("/bin/chmod 0644 \"$terminal_generations_path\""))
        XCTAssertTrue(install.contains("/bin/chmod 0644 \"$terminal_generations_temp\""))
        XCTAssertFalse(install.contains("/bin/chmod 0600 \"$terminal_generations_path\""))
        XCTAssertTrue(install.contains("[ ! -L \"$terminal_generations_path\" ]"))
        XCTAssertTrue(install.contains("/usr/bin/stat -f '%u %g %Lp %l %z'"))
        XCTAssertTrue(install.contains("/usr/bin/grep -Eqv"))
        XCTAssertTrue(install.contains("/usr/bin/awk 'END { print NR }'"))
        XCTAssertTrue(install.contains("/usr/bin/tr '[:upper:]' '[:lower:]'"))
        XCTAssertTrue(install.contains("/usr/bin/uniq -d"))
        XCTAssertTrue(install.contains("/bin/rm -rf \"$terminal_generations_path\""))
        XCTAssertTrue(install.contains("/bin/mv -f \"$terminal_generations_temp\" \"$terminal_generations_path\""))
        XCTAssertTrue(uninstall.contains("lidswitch_parse_applied_state"))
        XCTAssertTrue(restore.contains("|0) return 1"))
        XCTAssertTrue(restore.contains("alarm(shift @ARGV)"))
        XCTAssertTrue(restore.contains("if [ \"$changed_ac\" = \"0\" ]"))
        XCTAssertTrue(install.contains("[ \"$owner\" = \"$(/usr/bin/id -u)\" ] && [ \"$links\" = \"1\" ]"))
        XCTAssertFalse(install.contains("[ \"$group\" = \"$(/usr/bin/id -g)\" ]"))
        XCTAssertFalse(install.contains("StartInterval"))
        XCTAssertFalse(install.contains(AppPaths.legacyLoginLabel))
    }

    func testAdministratorCommandSkipsUserZshStartupFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let startupMarker = root.appendingPathComponent("startup-sourced")
        let commandMarker = root.appendingPathComponent("command-ran")
        try "/usr/bin/touch \(startupMarker.path)\n".write(
            to: root.appendingPathComponent(".zshenv"),
            atomically: true,
            encoding: .utf8
        )

        let command = PrivilegedHelperManager.diagnosticAdministratorCommand(
            "/usr/bin/touch \(commandMarker.path)\n"
        )
        XCTAssertTrue(command.hasSuffix("| /bin/zsh -f"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        var environment = ProcessInfo.processInfo.environment
        environment["ZDOTDIR"] = root.path
        process.environment = environment
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: commandMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: startupMarker.path))
    }

    func testAdminRestoreMigratesValidLegacyACBaseline() throws {
        let result = try runAdminRestoreScenario(legacyAC: "5", currentACSleep: 0)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.acSleep, 5)
        XCTAssertFalse(result.legacyFileExists)
    }

    func testAdminRestoreMigratesRootAdminLegacyACBaseline() throws {
        let result = try runAdminRestoreScenario(
            legacyAC: "5",
            currentACSleep: 0,
            legacyACGroup: 80
        )

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.acSleep, 5)
        XCTAssertFalse(result.legacyFileExists)
    }

    func testAdminRestoreRejectsGroupWritableLegacyBaseline() throws {
        let result = try runAdminRestoreScenario(
            legacyAC: "5",
            currentACSleep: 0,
            legacyACMode: 0o664
        )

        XCTAssertEqual(result.exitCode, 75, result.stderr)
        XCTAssertEqual(result.acSleep, 0)
        XCTAssertTrue(result.legacyFileExists)
        XCTAssertTrue(result.stderr.contains("reason=unsafe-legacy-state"))
    }

    func testAdminRestoreIgnoresStaleZeroLegacyBaseline() throws {
        let result = try runAdminRestoreScenario(legacyAC: "0", currentACSleep: 0)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.acSleep, 0)
        XCTAssertFalse(result.legacyFileExists)
    }

    func testAdminRestoreDoesNotOverwriteSupersedingACValue() throws {
        let result = try runAdminRestoreScenario(legacyAC: "5", currentACSleep: 7)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.acSleep, 7)
        XCTAssertFalse(result.legacyFileExists)
    }

    func testAdminRestoreMigratesLegacyBatteryBaselineAndClearsSleepDisabled() throws {
        let result = try runAdminRestoreScenario(
            legacyAC: nil,
            currentACSleep: 5,
            legacyBattery: "9",
            currentBatterySleep: 0,
            sleepDisabled: 1
        )

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.batterySleep, 9)
        XCTAssertEqual(result.sleepDisabled, 0)
        XCTAssertFalse(result.legacyBatteryFileExists)
    }

    func testHelperConfigurationRejectsMissingAndDuplicateArguments() {
        let valid = [
            "LidSwitchHelper", "--lease-path", "/tmp/lease", "--owner-uid", "501",
            "--qualified-build", "25F84", "--support-directory", "/tmp/support",
            "--applied-state", "/tmp/support/state", "--status-path", "/tmp/support/status",
        ]
        XCTAssertNotNil(HelperConfiguration.parse(arguments: valid))
        XCTAssertNil(HelperConfiguration.parse(arguments: Array(valid.dropLast())))
        XCTAssertNil(HelperConfiguration.parse(arguments: valid + ["--lease-path", "/tmp/other"]))
    }

    private func makeSnapshot(
        source: PowerSource,
        sleepDisabled: Bool,
        sleepDisabledVerified: Bool,
        legacyLoginItemLoaded: Bool = false,
        lease: ActivationLease? = nil,
        status: HelperStatusRecord? = nil,
        checkedAt: Date = Date(),
        ownsLease: Bool = true
    ) -> PowerSnapshot {
        PowerSnapshot(
            source: source,
            sleepDisabled: sleepDisabled,
            sleepDisabledVerified: sleepDisabledVerified,
            acIdleSleepMinutes: 5,
            preferences: .disabled,
            helperArtifactsPresent: true,
            helperLoaded: true,
            helperNeedsUpdate: false,
            legacyLoginItemPresent: false,
            legacyLoginItemLoaded: legacyLoginItemLoaded,
            activationLease: lease,
            ownedSessionID: ownsLease ? lease?.sessionID : nil,
            helperStatus: status,
            systemBuild: "25F84",
            systemBuildQualified: true,
            bundleIntegrityValid: true,
            bundleVersionValid: true,
            checkedAt: checkedAt
        )
    }

    private func makeLease(
        sessionID: UUID,
        lifetime: TimeInterval,
        now: Date = Date(),
        monotonic: TimeInterval = MonotonicClock.seconds()
    ) -> ActivationLease {
        ActivationLease(
            sessionID: sessionID,
            bootID: BootIdentity.current() ?? "test-boot",
            expiresAt: now.addingTimeInterval(lifetime),
            issuedMonotonic: monotonic,
            expiresMonotonic: monotonic + lifetime,
            ownerUID: getuid(),
            systemBuild: "25F84"
        )
    }

    private func assertLeaseFailure(
        _ result: Result<ActivationLease, LeaseValidationFailure>,
        equals expected: LeaseValidationFailure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success:
            XCTFail("Expected lease failure", file: file, line: line)
        case let .failure(actual):
            XCTAssertEqual(actual, expected, file: file, line: line)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LidSwitchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private struct AdminRestoreResult {
        let exitCode: Int32
        let acSleep: Int
        let batterySleep: Int
        let sleepDisabled: Int
        let legacyFileExists: Bool
        let legacyBatteryFileExists: Bool
        let stderr: String
    }

    private func runAdminRestoreScenario(
        legacyAC: String?,
        currentACSleep: Int,
        legacyACGroup: gid_t? = nil,
        legacyACMode: mode_t? = nil,
        legacyBattery: String? = nil,
        currentBatterySleep: Int = 5,
        sleepDisabled: Int = 0
    ) throws -> AdminRestoreResult {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("power", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        try "\(sleepDisabled)\n".write(to: state.appendingPathComponent("sleep-disabled"), atomically: true, encoding: .utf8)
        try "\(currentACSleep)\n".write(to: state.appendingPathComponent("ac-sleep"), atomically: true, encoding: .utf8)
        try "\(currentBatterySleep)\n".write(to: state.appendingPathComponent("battery-sleep"), atomically: true, encoding: .utf8)

        let mockPMSet = root.appendingPathComponent("pmset")
        let mockSource = """
        #!/bin/sh
        set -eu
        state="${MOCK_POWER_STATE:?}"
        printf 'state=%s args=%s\n' "$state" "$*" >> "$state/calls.log"
        if [ "$1" = "-g" ] && [ "$2" = "live" ]; then
          output="SleepDisabled $(/bin/cat "$state/sleep-disabled")"
          echo "$output"
        elif [ "$1" = "-g" ] && [ "$2" = "custom" ]; then
          echo "Battery Power:"
          echo " sleep $(/bin/cat "$state/battery-sleep")"
          echo "AC Power:"
          echo " sleep $(/bin/cat "$state/ac-sleep")"
        elif [ "$1" = "-a" ] && [ "$2" = "disablesleep" ]; then
          printf '%s\n' "$3" > "$state/sleep-disabled"
        elif [ "$1" = "-c" ] && [ "$2" = "sleep" ]; then
          printf '%s\n' "$3" > "$state/ac-sleep"
        elif [ "$1" = "-b" ] && [ "$2" = "sleep" ]; then
          printf '%s\n' "$3" > "$state/battery-sleep"
        else
          exit 64
        fi
        """
        try mockSource.write(to: mockPMSet, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(mockPMSet.path, 0o755), 0)

        let applied = support.appendingPathComponent("applied-state").path
        let status = support.appendingPathComponent("helper-status").path
        let legacyACPath = support.appendingPathComponent("original-ac-sleep").path
        let legacyBatteryPath = support.appendingPathComponent("original-battery-sleep").path
        if let legacyAC {
            try "\(legacyAC)\n".write(toFile: legacyACPath, atomically: true, encoding: .utf8)
            if let legacyACGroup {
                XCTAssertEqual(chown(legacyACPath, getuid(), legacyACGroup), 0)
            }
            if let legacyACMode {
                XCTAssertEqual(chmod(legacyACPath, legacyACMode), 0)
            }
        }
        if let legacyBattery {
            try "\(legacyBattery)\n".write(toFile: legacyBatteryPath, atomically: true, encoding: .utf8)
        }

        var script = PrivilegedHelperManager.diagnosticNormalRestoreScriptForTesting()
        for (original, replacement) in [
            (AppPaths.rootAppliedStatePath, applied),
            (AppPaths.rootHelperStatusPath, status),
            (AppPaths.rootOriginalACSleepPath, legacyACPath),
            (AppPaths.rootOriginalBatterySleepPath, legacyBatteryPath),
            ("5 /usr/bin/pmset", "5 \(mockPMSet.path)"),
        ] {
            script = script.replacingOccurrences(of: original, with: replacement)
        }
        let scriptFile = root.appendingPathComponent("restore.zsh")
        try script.write(to: scriptFile, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", scriptFile.path]
        var environment = ProcessInfo.processInfo.environment
        environment["MOCK_POWER_STATE"] = state.path
        process.environment = environment
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        var errorText = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        if let statusText = try? String(contentsOfFile: status, encoding: .utf8) {
            errorText += "\nstatus:\n\(statusText)"
        }
        if let callLog = try? String(contentsOf: state.appendingPathComponent("calls.log"), encoding: .utf8) {
            errorText += "\npmset calls:\n\(callLog)"
        }
        let finalAC = try XCTUnwrap(
            Int(String(contentsOf: state.appendingPathComponent("ac-sleep"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )
        let finalBattery = try XCTUnwrap(
            Int(String(contentsOf: state.appendingPathComponent("battery-sleep"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )
        let finalSleepDisabled = try XCTUnwrap(
            Int(String(contentsOf: state.appendingPathComponent("sleep-disabled"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )
        return AdminRestoreResult(
            exitCode: process.terminationStatus,
            acSleep: finalAC,
            batterySleep: finalBattery,
            sleepDisabled: finalSleepDisabled,
            legacyFileExists: FileManager.default.fileExists(atPath: legacyACPath),
            legacyBatteryFileExists: FileManager.default.fileExists(atPath: legacyBatteryPath),
            stderr: errorText
        )
    }

    private struct RuntimeHarness {
        let root: URL
        let configuration: HelperConfiguration
        let lease: ActivationLease
        let power: FakePowerSystem
        let runtime: HelperRuntime
    }

    private func makeRuntimeHarness(
        lifetime: TimeInterval,
        power: FakePowerSystem = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5),
        preapplyState: Bool = false,
        reconciliationInterval: TimeInterval = 2,
        terminalGenerationAllows: @escaping (UUID, String) -> Bool = { sessionID, path in
            TerminalGenerationStore.allowsActivation(sessionID: sessionID, path: path)
        },
        terminalGenerationRecord: @escaping (UUID, String) -> Bool = { sessionID, path in
            TerminalGenerationStore.record(sessionID: sessionID, path: path)
        }
    ) throws -> RuntimeHarness {
        let root = try temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let userSupport = root.appendingPathComponent("user", isDirectory: true)
        let rootSupport = root.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: userSupport, withIntermediateDirectories: false)
        let leasePath = userSupport.appendingPathComponent("activation-lease").path
        let statePath = rootSupport.appendingPathComponent("applied-state").path
        let statusPath = rootSupport.appendingPathComponent("helper-status").path
        let lease = makeLease(sessionID: UUID(), lifetime: lifetime)
        try lease.storagePayload.write(toFile: leasePath, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(leasePath, 0o600), 0)
        try FileManager.default.createDirectory(at: rootSupport, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(rootSupport.path, 0o755), 0)

        if preapplyState {
            try AppliedStateStore.write(
                AppliedState(
                    sessionID: lease.sessionID,
                    changedSleepDisabled: true,
                    changedACSleep: true,
                    originalACSleep: 5
                ),
                path: statePath
            )
        }

        let configuration = HelperConfiguration(
            leasePath: leasePath,
            expectedOwnerUID: getuid(),
            qualifiedBuild: "25F84",
            supportDirectory: rootSupport.path,
            appliedStatePath: statePath,
            statusPath: statusPath
        )
        return RuntimeHarness(
            root: root,
            configuration: configuration,
            lease: lease,
            power: power,
            runtime: HelperRuntime(
                configuration: configuration,
                power: power,
                currentBootID: { lease.bootID },
                currentSystemBuild: { "25F84" },
                reconciliationInterval: reconciliationInterval,
                terminalGenerationAllows: terminalGenerationAllows,
                terminalGenerationRecord: terminalGenerationRecord
            )
        )
    }
}

private final class FakePowerSystem: HelperPowerSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var source: HelperPowerSource
    private var sleepDisabledValue: Bool?
    private var acSleepValue: Int?
    private var enableCalls = 0
    private var failRestoreValue = false
    private var unplugOnEnableValue = false
    private var sleepRestoreObserver: (() -> Void)?

    init(source: HelperPowerSource, sleepDisabled: Bool?, acSleep: Int?) {
        self.source = source
        sleepDisabledValue = sleepDisabled
        acSleepValue = acSleep
    }

    var currentSleepDisabled: Bool? { withLock { sleepDisabledValue } }
    var currentACSleep: Int? { withLock { acSleepValue } }
    var enableSleepOverrideCalls: Int { withLock { enableCalls } }
    var failSleepRestore: Bool {
        get { withLock { failRestoreValue } }
        set { withLock { failRestoreValue = newValue } }
    }
    var unplugWhenEnablingSleepOverride: Bool {
        get { withLock { unplugOnEnableValue } }
        set { withLock { unplugOnEnableValue = newValue } }
    }
    var onSleepRestore: (() -> Void)? {
        get { withLock { sleepRestoreObserver } }
        set { withLock { sleepRestoreObserver = newValue } }
    }

    func setSource(_ source: HelperPowerSource) {
        withLock { self.source = source }
    }

    func forceSleepDisabled(_ enabled: Bool) {
        withLock { sleepDisabledValue = enabled }
    }

    func forceACSleep(_ minutes: Int) {
        withLock { acSleepValue = minutes }
    }

    func powerSource() -> HelperPowerSource { withLock { source } }
    func sleepDisabled() -> Bool? { withLock { sleepDisabledValue } }
    func acSleepMinutes() -> Int? { withLock { acSleepValue } }

    func setSleepDisabled(_ enabled: Bool) throws {
        try withLock {
            if !enabled, failRestoreValue {
                throw NSError(domain: "FakePowerSystem", code: 1)
            }
            if !enabled {
                sleepRestoreObserver?()
            }
            if enabled {
                enableCalls += 1
                if unplugOnEnableValue {
                    source = .battery
                }
            }
            sleepDisabledValue = enabled
        }
    }

    func setACSleepMinutes(_ minutes: Int) throws {
        withLock { acSleepValue = minutes }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get { withValue { $0 } }
        set { withValue { $0 = newValue } }
    }

    @discardableResult
    func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&storage)
    }
}

private enum TestError: Error {
    case commitRejected
}
