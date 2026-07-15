import Darwin
import Foundation
import LidSwitchXPCBridge
import XCTest
@testable import LidSwitchCore
@testable import LidSwitchHelper

/// Deterministic executable recovery fixtures. They are intentionally unrun
/// while the live-runtime safety gate is closed. Every test uses an owned
/// `/private/tmp` capability, fake power, and production-used store/coordinator
/// operations; no fixture calls the helper, launchd, pmset, or a live process.
final class RecoveryCoordinatorFixtureTests: XCTestCase {
    fileprivate static let boot = "00000000-0000-4000-8000-000000000001"

    func testLegacyWriterProbeAcceptsExactDarwinMissingAndDisabledDiagnostics() {
        let system = ContainedProcessResult(
            stdout: "",
            stderr: "Bad request.\nCould not find service \"com.johnsilva.lidswitch.helper\" in domain for system\n",
            exitCode: 113,
            outcome: .completed
        )
        XCTAssertTrue(LegacyWriterQuiescenceProbe.exactMissingService(
            system,
            target: "system/com.johnsilva.lidswitch.helper"
        ))

        let legacy = ContainedProcessResult(
            stdout: "",
            stderr: "Could not find service \"com.johnsilva.LidSwitch.login\" in domain for user gui: 501\n",
            exitCode: 113,
            outcome: .completed
        )
        XCTAssertTrue(LegacyWriterQuiescenceProbe.exactMissingService(
            legacy,
            target: "gui/501/com.johnsilva.LidSwitch.login"
        ))

        let currentDarwin = ContainedProcessResult(
            stdout: "disabled services = {\n\t\"com.johnsilva.LidSwitch.login\" => disabled\n}\n",
            stderr: "",
            exitCode: 0,
            outcome: .completed
        )
        XCTAssertTrue(LegacyWriterQuiescenceProbe.exactLegacyDisabled(
            currentDarwin,
            label: "com.johnsilva.LidSwitch.login"
        ))

        let legacyDarwin = ContainedProcessResult(
            stdout: "disabled services = {\n\t\"com.johnsilva.LidSwitch.login\" => true\n}\n",
            stderr: "",
            exitCode: 0,
            outcome: .completed
        )
        XCTAssertTrue(LegacyWriterQuiescenceProbe.exactLegacyDisabled(
            legacyDarwin,
            label: "com.johnsilva.LidSwitch.login"
        ))
    }

    func testLegacyWriterProbeRejectsWrongOrAmbiguousLaunchctlDiagnostics() {
        let label = "com.johnsilva.lidswitch.helper"
        let expected = "Bad request.\nCould not find service \"\(label)\" in domain for system\n"
        let malformed: [ContainedProcessResult] = [
            .init(stdout: "unexpected", stderr: expected, exitCode: 113, outcome: .completed),
            .init(stdout: "", stderr: expected + "extra\n", exitCode: 113, outcome: .completed),
            .init(stdout: "", stderr: expected.replacingOccurrences(of: label, with: "com.johnsilva.other"), exitCode: 113, outcome: .completed),
            .init(stdout: "", stderr: expected.replacingOccurrences(of: "system", with: "user gui: 501"), exitCode: 113, outcome: .completed),
            .init(stdout: "", stderr: expected, exitCode: 0, outcome: .completed),
            .init(stdout: "", stderr: expected, exitCode: 113, outcome: .timedOut),
        ]
        for result in malformed {
            XCTAssertFalse(LegacyWriterQuiescenceProbe.exactMissingService(
                result,
                target: "system/\(label)"
            ))
        }
        XCTAssertFalse(LegacyWriterQuiescenceProbe.exactMissingService(
            .init(stdout: "", stderr: expected, exitCode: 113, outcome: .completed),
            target: "gui/0501/\(label)"
        ))

        let disabled = "disabled services = {\n\t\"com.johnsilva.LidSwitch.login\" => disabled\n}\n"
        let malformedDisabled: [ContainedProcessResult] = [
            .init(stdout: disabled.replacingOccurrences(of: "=> disabled", with: "=> enabled"), stderr: "", exitCode: 0, outcome: .completed),
            .init(stdout: disabled.replacingOccurrences(of: "=> disabled", with: "=> false"), stderr: "", exitCode: 0, outcome: .completed),
            .init(stdout: disabled.replacingOccurrences(of: "LidSwitch.login", with: "LidSwitch.other"), stderr: "", exitCode: 0, outcome: .completed),
            .init(stdout: disabled + "\t\"com.johnsilva.LidSwitch.login\" => disabled\n", stderr: "", exitCode: 0, outcome: .completed),
            .init(stdout: disabled, stderr: "unexpected", exitCode: 0, outcome: .completed),
            .init(stdout: disabled, stderr: "", exitCode: 1, outcome: .completed),
            .init(stdout: disabled, stderr: "", exitCode: 0, outcome: .timedOut),
        ]
        for result in malformedDisabled {
            XCTAssertFalse(LegacyWriterQuiescenceProbe.exactLegacyDisabled(
                result,
                label: "com.johnsilva.LidSwitch.login"
            ))
        }
    }

    func testAdministratorRecoveryRequiresHelperOwnedQuiescenceEvidence() throws {
        let fixture = try Fixture(
            provision: false,
            quiescenceProbe: LegacyWriterQuiescenceProbe {
                .indeterminate("fixture-current-writer-present")
            }
        )
        defer { fixture.dispose() }

        XCTAssertEqual(fixture.coordinator.provision(), .ready)
        XCTAssertEqual(
            fixture.coordinator.recover(intent: .install, allowReconnect: false),
            .recoveryRequired("fixture-current-writer-present")
        )
        XCTAssertEqual(fixture.power.setCalls, [])
        XCTAssertEqual(fixture.store.appliedRecord(), .missing)
    }

    func testRecoveryBudgetBytesAreCanonicalAndPhaseBoundToOneSession() throws {
        let session = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let reserved = RecoveryBudgetState(sessionID: session, phase: .reserved)
        XCTAssertEqual(RecoveryBudgetState.parse(reserved.payload), reserved)
        XCTAssertNil(RecoveryBudgetState.parse(reserved.payload.replacingOccurrences(of: "phase=reserved", with: "phase=unknown")))
        let spent = RecoveryBudgetState(sessionID: session, phase: .spent)
        XCTAssertEqual(RecoveryBudgetState.parse(spent.payload), spent)
        XCTAssertNotEqual(reserved.payload, spent.payload)
    }

    func testStatusProjectionTaskIsBoundedCanonicalAndRetryIsStatusOnly() throws {
        let session = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let task = try XCTUnwrap(StatusProjectionTask(
            token: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!, generation: 7,
            state: "terminal", reason: "fixture-terminal", sessionID: session, issuedEpoch: 10,
            issuedMonotonicMillis: 20, bootID: "fixture-boot", deadlineNanoseconds: 100
        ))
        XCTAssertEqual(StatusProjectionTask.parse(task.payload), task)
        XCTAssertNil(StatusProjectionTask.parse(task.payload.replacingOccurrences(of: "generation=7", with: "generation=0")))
        let retry = try XCTUnwrap(task.retrying(now: 30))
        XCTAssertEqual(retry.token, task.token)
        XCTAssertEqual(retry.generation, task.generation)
        XCTAssertEqual(retry.state, task.state)
        XCTAssertEqual(retry.sessionID, task.sessionID)
        XCTAssertEqual(retry.attempt, 1)
        let exhausted = try XCTUnwrap(task.retrying(now: 100))
        XCTAssertTrue(exhausted.isExhausted)
        let rebooted = try XCTUnwrap(task.rebasedForCurrentBoot(now: 30, bootID: "fixture-next-boot"))
        XCTAssertEqual(rebooted.bootID, "fixture-next-boot")
        XCTAssertEqual(rebooted.nextAttemptNanoseconds, 30)
        XCTAssertEqual(rebooted.generation, task.generation)
    }

    func testContainmentClaimCarriesItsLeaseDeadlineIntoActualStoreTransition() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let identity = ContainedProcessIdentity(pid: 41, startSeconds: 10, startMicroseconds: 1)
        let receipt = ContainedProcessReceipt(token: UUID(), executable: "/usr/bin/pmset", commandFingerprint: "0123456789abcdef",
                                               leader: identity, members: [.init(identity: identity, executable: "/usr/bin/pmset", commandFingerprint: "0123456789abcdef")],
                                               processGroupID: 41, sessionID: 9, rootDeadlineNanoseconds: 10, cleanupDeadlineNanoseconds: 100)
        let owner = UUID()
        XCTAssertTrue(try XCTUnwrap(fixture.store.withTransaction { fixture.store.publishInitialContainmentReceipt(receipt, $0) }))
        let claimed = try XCTUnwrap(try XCTUnwrap(fixture.store.withTransaction { transaction in
            fixture.store.claimContainmentReceipt(token: receipt.token, owner: owner, now: 20, until: 30, transaction)
        }))
        let issued = try XCTUnwrap(claimed.markingTermSignalIssued(owner: owner, deadline: claimed.ownerDeadlineNanoseconds))
        XCTAssertTrue(try XCTUnwrap(fixture.store.withTransaction { fixture.store.advanceContainmentReceipt(expected: claimed, next: issued, $0) }))
        let reclaimed = try XCTUnwrap(try XCTUnwrap(fixture.store.withTransaction { transaction in
            fixture.store.claimContainmentReceipt(token: issued.token, owner: owner, now: 31, until: 40, transaction)
        }))
        XCTAssertEqual(reclaimed.ownerDeadlineNanoseconds, 40)
    }

    /// Exercises the production connected timer entrypoint.  It deliberately
    /// enters through BEGIN, privateAuthorityMatches and tickLocked rather
    /// than calling the recovery-budget helper directly.
    func testConnectedTickSpendsOwnedRecoveryBudgetOnceAndRestartFencesRearm() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let clock = IntegerBox()
        clock.set(100)
        var peer = ls_peer_identity_t()
        XCTAssertTrue(ls_peer_identity_for_current_process(&peer))
        let authority = HelperSessionAuthority(
            configuration: fixture.configuration,
            power: fixture.power,
            recoveryStoreFactory: { _ in fixture.store },
            monotonicNow: { TimeInterval(clock.value) },
            peerIsLive: { _ in true },
            bootIdentity: { Self.boot },
            timerStarter: { _ in NSObject() },
            recoveryCoordinatorFactory: { fixture.coordinator }
        )
        let session = UUID()
        XCTAssertEqual(authority.handle(connection: 1, peer: peer,
                                        operation: UInt32(LS_OPERATION_BEGIN.rawValue), sessionID: session).result, 0)
        fixture.power.setCalls.removeAll()

        // Connected, exact owned drift: `BEGIN` left AC sleep at zero and the
        // test changes only SleepDisabled. The first tick must reserve before
        // its one setter, verify native state, and spend the same budget.
        fixture.power.disabled = false
        fixture.power.ac = 0
        authority.reconcileForTesting()
        XCTAssertEqual(fixture.power.setCalls, ["sleep=1"])
        XCTAssertEqual(fixture.power.disabled, true)
        XCTAssertEqual(fixture.power.ac, 0)
        XCTAssertEqual(fixture.store.recoveryBudgetRecord(), .valid(.init(sessionID: session, phase: .spent)))
        XCTAssertTrue(try XCTUnwrap(fixture.store.privateLedger(RecoveryAuthorityStore.reservationBasename)).contains(session))
        switch fixture.store.statusProjectionTaskRecord() {
        case let .valid(task):
            XCTAssertEqual(task.state, "active")
            XCTAssertEqual(task.reason, "override-recovered")
        case .absent:
            // The dispatcher may have completed its asynchronous projection
            // before this assertion; either representation is truthful.
            let projected = try String(contentsOfFile: fixture.configuration.statusPath, encoding: .utf8)
            XCTAssertTrue(projected.contains("state=active\n"))
            XCTAssertTrue(projected.contains("reason=override-recovered\n"))
        case .invalid:
            XCTFail("connected recovery projection must remain durable or converge exactly")
        }
        XCTAssertEqual(authority.handle(connection: 1, peer: peer,
                                        operation: UInt32(LS_OPERATION_SNAPSHOT.rawValue), sessionID: session).state, 1)
        // A real helper restart ends the old process and therefore its
        // asynchronous projection worker. Drain that worker before creating
        // the in-process restart stand-in so the fixture preserves the same
        // process-lifetime boundary instead of manufacturing root-lock
        // contention between two helper generations.
        XCTAssertTrue(fixture.waitForStatusProjectionDrain())

        // Hydration accepts only the already-spent fence. It binds the same
        // durable authority while native state is intact, then a second drift
        // reaches the normal terminal path. It must not re-arm SleepDisabled;
        // it must restore the still-owned AC baseline and retire the spent
        // recovery budget with the generation.
        let restarted = HelperSessionAuthority(
            configuration: fixture.configuration,
            power: fixture.power,
            recoveryStoreFactory: { _ in fixture.store },
            monotonicNow: { TimeInterval(clock.value) },
            peerIsLive: { _ in true },
            bootIdentity: { Self.boot },
            timerStarter: { _ in NSObject() },
            recoveryCoordinatorFactory: { fixture.coordinator }
        )
        let preparation = restarted.prepareBeforeListening()
        XCTAssertEqual(
            preparation,
            .ready,
            "assessment=\(String(describing: restarted.lastPreparationAssessmentForTesting)) stage=\(restarted.lastPreparationStageForTesting)"
        )
        XCTAssertTrue(fixture.waitForStatusProjectionDrain())
        XCTAssertEqual(restarted.handle(connection: 2, peer: peer,
                                        operation: UInt32(LS_OPERATION_RECONNECT.rawValue), sessionID: session).result, 0)
        XCTAssertTrue(fixture.waitForStatusProjectionDrain())
        fixture.power.setCalls.removeAll()
        fixture.power.disabled = false
        for _ in 0..<3 {
            restarted.reconcileForTesting()
            if !fixture.power.setCalls.isEmpty { break }
            guard let retryAt = restarted.rollbackNextAttemptForTesting else { break }
            clock.set(Int(retryAt.rounded(.up)))
        }
        let terminal = restarted.handle(connection: 2, peer: peer,
                                        operation: UInt32(LS_OPERATION_SNAPSHOT.rawValue), sessionID: session)
        let diagnostic = "reason=\(terminal.reason) state=\(terminal.state) attempts=\(restarted.rollbackAttemptCountForTesting) next=\(String(describing: restarted.rollbackNextAttemptForTesting)) assessment=\(String(describing: restarted.lastRollbackAssessmentForTesting)) terminal=\(String(describing: fixture.store.privateLedger(RecoveryAuthorityStore.terminalBasename))) containment=\(fixture.store.containmentReceiptRecord()) proof=\(fixture.store.proofRecord()) applied=\(fixture.store.appliedRecord())"
        XCTAssertEqual(fixture.power.setCalls, ["ac=10"], diagnostic)
        XCTAssertEqual(terminal.state, 2, diagnostic)
        XCTAssertEqual(fixture.store.recoveryBudgetRecord(), .absent)
    }

    func testTransientPreTransactionLockContentionRevalidatesWithoutSpendingMutationRetry() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let clock = IntegerBox()
        clock.set(100)
        var peer = ls_peer_identity_t()
        XCTAssertTrue(ls_peer_identity_for_current_process(&peer))
        let authority = HelperSessionAuthority(
            configuration: fixture.configuration,
            power: fixture.power,
            recoveryStoreFactory: { _ in fixture.store },
            monotonicNow: { TimeInterval(clock.value) },
            peerIsLive: { _ in true },
            bootIdentity: { Self.boot },
            timerStarter: { _ in NSObject() },
            recoveryCoordinatorFactory: { fixture.coordinator }
        )
        let session = UUID()
        XCTAssertEqual(authority.handle(connection: 1, peer: peer,
                                        operation: UInt32(LS_OPERATION_BEGIN.rawValue), sessionID: session).result, 0)
        XCTAssertTrue(fixture.waitForStatusProjectionDrain())
        fixture.power.setCalls.removeAll()
        try fixture.activateStore(lockTimeout: 0)

        let lockPath = fixture.sandbox.url.appendingPathComponent(RootStateLock.authorizationBasename).path
        var heldLock = open(lockPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(heldLock, 0)
        defer {
            if heldLock >= 0 {
                _ = flock(heldLock, LOCK_UN)
                close(heldLock)
            }
        }
        XCTAssertEqual(flock(heldLock, LOCK_EX | LOCK_NB), 0)

        authority.reconcileForTesting()
        XCTAssertEqual(authority.rollbackAttemptCountForTesting, 1)
        XCTAssertEqual(authority.tickStoreAttemptCountForTesting, 1)
        XCTAssertEqual(authority.rollbackNextAttemptForTesting, 102)
        XCTAssertEqual(fixture.power.setCalls, [])

        XCTAssertEqual(flock(heldLock, LOCK_UN), 0)
        close(heldLock)
        heldLock = -1
        clock.set(102)
        authority.reconcileForTesting()

        XCTAssertEqual(authority.rollbackAttemptCountForTesting, 0)
        XCTAssertEqual(authority.tickStoreAttemptCountForTesting, 2)
        XCTAssertEqual(fixture.power.setCalls, [])
        XCTAssertEqual(fixture.store.recoveryBudgetRecord(), .absent)
        let snapshot = authority.handle(connection: 1, peer: peer,
                                        operation: UInt32(LS_OPERATION_SNAPSHOT.rawValue), sessionID: session)
        XCTAssertEqual(snapshot.result, 0)
        XCTAssertEqual(snapshot.state, 1)
        XCTAssertTrue(snapshot.sleepDisabled)
        XCTAssertEqual(snapshot.acSleepMinutes, 0)
    }

    func testMutationUncertaintyAbsorbsAnEarlierPreTransactionRetry() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let clock = IntegerBox()
        clock.set(100)
        var peer = ls_peer_identity_t()
        XCTAssertTrue(ls_peer_identity_for_current_process(&peer))
        let authority = HelperSessionAuthority(
            configuration: fixture.configuration,
            power: fixture.power,
            recoveryStoreFactory: { _ in fixture.store },
            monotonicNow: { TimeInterval(clock.value) },
            peerIsLive: { _ in true },
            bootIdentity: { Self.boot },
            timerStarter: { _ in NSObject() },
            recoveryCoordinatorFactory: { fixture.coordinator }
        )
        let session = UUID()
        XCTAssertEqual(authority.handle(connection: 1, peer: peer,
                                        operation: UInt32(LS_OPERATION_BEGIN.rawValue), sessionID: session).result, 0)
        XCTAssertTrue(fixture.waitForStatusProjectionDrain())
        fixture.power.setCalls.removeAll()
        try fixture.activateStore(lockTimeout: 0)

        let lockPath = fixture.sandbox.url.appendingPathComponent(RootStateLock.authorizationBasename).path
        let heldLock = open(lockPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(heldLock, 0)
        defer { close(heldLock) }
        XCTAssertEqual(flock(heldLock, LOCK_EX | LOCK_NB), 0)
        authority.reconcileForTesting()
        XCTAssertEqual(authority.rollbackAttemptCountForTesting, 1)
        XCTAssertEqual(flock(heldLock, LOCK_UN), 0)

        // A due snapshot may re-enter while only a no-mutation retry is latched.
        // It discovers unsafe native state; its first restore
        // setter then fails before a postcondition can prove whether mutation
        // happened. That stronger classification must permanently absorb the
        // earlier pre-transaction lock miss.
        clock.set(102)
        fixture.power.source = .battery
        fixture.power.throwBeforeSleepMutation = true
        XCTAssertEqual(authority.handle(connection: 1, peer: peer,
                                        operation: UInt32(LS_OPERATION_SNAPSHOT.rawValue), sessionID: session).result, 75)
        XCTAssertEqual(authority.rollbackAttemptCountForTesting, 2)
        XCTAssertEqual(authority.rollbackNextAttemptForTesting, 106)
        XCTAssertEqual(fixture.power.setCalls, ["sleep=0"])

        clock.set(106)
        XCTAssertEqual(authority.handle(connection: 1, peer: peer,
                                        operation: UInt32(LS_OPERATION_SNAPSHOT.rawValue), sessionID: session).result, 75)
        XCTAssertEqual(authority.rollbackAttemptCountForTesting, 3)
        XCTAssertEqual(fixture.power.setCalls, ["sleep=0"],
                       "a snapshot must never re-enter an unproved setter")
        authority.reconcileForTesting()
        XCTAssertEqual(fixture.power.setCalls, ["sleep=0"],
                       "a tick must preserve the same no-second-setter fence")
    }

    func testProjectionGenerationWatermarkSurvivesTaskRemoval() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let first = try XCTUnwrap(try XCTUnwrap(fixture.store.withTransaction { fixture.store.enqueueStatusProjection(state: "active", reason: "fixture-first", sessionID: nil, $0) }))
        XCTAssertTrue(try XCTUnwrap(fixture.store.withTransaction { fixture.store.removeStatusProjectionTask(expected: first, $0) }))
        let second = try XCTUnwrap(try XCTUnwrap(fixture.store.withTransaction { fixture.store.enqueueStatusProjection(state: "terminal", reason: "fixture-second", sessionID: nil, $0) }))
        XCTAssertGreaterThan(second.generation, first.generation)
    }

    /// Uses the production atomic writer against the owned fixture status file;
    /// it is intentionally source-only until the isolated XCTest gate reopens.
    func testStatusProjectionWriterSerializesNewGenerationBeforeOldRetry() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let old = try XCTUnwrap(StatusProjectionTask(generation: 3, state: "active", reason: "fixture-old",
                                                     sessionID: nil, issuedEpoch: 10, issuedMonotonicMillis: 10,
                                                     bootID: "fixture-boot", deadlineNanoseconds: 100))
        let new = try XCTUnwrap(StatusProjectionTask(generation: 4, state: "terminal", reason: "fixture-new",
                                                     sessionID: nil, issuedEpoch: 11, issuedMonotonicMillis: 11,
                                                     bootID: "fixture-boot", deadlineNanoseconds: 100))
        XCTAssertTrue(fixture.writeStatus(task: new))
        XCTAssertEqual(fixture.statusWriteOutcome(task: old), .staleNewer(new.generation))
        XCTAssertEqual(try String(contentsOfFile: fixture.configuration.statusPath, encoding: .utf8), new.statusPayload)
        XCTAssertEqual(fixture.power.setCalls, [])
    }

    func testStatusProjectionWriterRetainsMalformedPublicLeafAsUnsafe() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        try fixture.createLegacyFile("helper-status", bytes: "state=active\n")
        let task = try XCTUnwrap(StatusProjectionTask(generation: 1, state: "active", reason: "fixture-malformed",
                                                      sessionID: nil, issuedEpoch: 10, issuedMonotonicMillis: 10,
                                                      bootID: "fixture-boot", deadlineNanoseconds: 100))
        XCTAssertEqual(fixture.statusWriteOutcome(task: task), .unsafeExisting)
        XCTAssertEqual(fixture.power.setCalls, [])
        XCTAssertEqual(fixture.store.appliedRecord(), .missing)
    }

    func testTerminalMigrationTaskReplacesOnlyMatchingShippedV4InactiveStatus() throws {
        let session = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let fixture = try Fixture()
        defer { fixture.dispose() }
        try fixture.createLegacyFile(
            "helper-status",
            bytes: [
                "state=inactive",
                "reason=no-valid-lease",
                "session=\(session.uuidString.lowercased())",
                "updated=10",
                "",
            ].joined(separator: "\n")
        )
        let task = try XCTUnwrap(StatusProjectionTask(
            generation: 1,
            state: "terminal",
            reason: "legacy-migration",
            sessionID: session,
            issuedEpoch: 11,
            issuedMonotonicMillis: 12,
            bootID: "fixture-boot",
            deadlineNanoseconds: 100
        ))
        XCTAssertEqual(fixture.statusWriteOutcome(task: task), .written)
        XCTAssertEqual(
            try String(contentsOfFile: fixture.configuration.statusPath, encoding: .utf8),
            task.statusPayload
        )
        XCTAssertEqual(fixture.power.setCalls, [])

        let mismatch = try Fixture()
        defer { mismatch.dispose() }
        try mismatch.createLegacyFile(
            "helper-status",
            bytes: [
                "state=inactive",
                "reason=no-valid-lease",
                "session=\(UUID().uuidString.lowercased())",
                "updated=10",
                "",
            ].joined(separator: "\n")
        )
        XCTAssertEqual(mismatch.statusWriteOutcome(task: task), .unsafeExisting)
        XCTAssertEqual(mismatch.power.setCalls, [])
    }

    /// Zero and partial bytes at the one fixed temp name are not public
    /// status and never authority. They are the descriptor-bound residue of
    /// an interrupted writer transaction and are retired while holding the
    /// production projection lock before the dirty task republish.
    func testProjectionTempCrashResidueRetiresThenRepublishesCurrentTask() throws {
        for bytes in ["", "projection_generation=partial\n"] {
            let fixture = try Fixture()
            defer { fixture.dispose() }
            try fixture.createLegacyFile("helper-status.projection-temp", bytes: bytes)
            let task = try XCTUnwrap(StatusProjectionTask(generation: 9, state: "active", reason: "fixture-crash-recovery",
                                                          sessionID: nil, issuedEpoch: 10, issuedMonotonicMillis: 10,
                                                          bootID: "fixture-boot", deadlineNanoseconds: 100))
            XCTAssertEqual(fixture.statusWriteOutcome(task: task), .written)
            XCTAssertEqual(try String(contentsOfFile: fixture.configuration.statusPath, encoding: .utf8), task.statusPayload)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sandbox.url.appendingPathComponent("helper-status.projection-temp").path))
            XCTAssertEqual(fixture.power.setCalls, [])
            XCTAssertEqual(fixture.store.appliedRecord(), .missing)
        }
    }

    func testProjectionTempRecoveryRejectsSwapLinksAndWrongMetadata() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let temp = fixture.sandbox.url.appendingPathComponent("helper-status.projection-temp").path
        try fixture.createLegacyFile("helper-status.projection-temp", bytes: "partial\n")
        let task = try XCTUnwrap(StatusProjectionTask(generation: 10, state: "active", reason: "fixture-temp-safety",
                                                      sessionID: nil, issuedEpoch: 10, issuedMonotonicMillis: 10,
                                                      bootID: "fixture-boot", deadlineNanoseconds: 100))
        let swapped = fixture.statusWriteOutcome(task: task, recoveryGate: { stage in
            guard stage == .beforeRetire else { return true }
            _ = Darwin.rename(temp, temp + ".held")
            _ = FileManager.default.createFile(atPath: temp, contents: Data("replacement\n".utf8))
            _ = chmod(temp, 0o644)
            return true
        })
        XCTAssertEqual(swapped, .indeterminate)

        try? FileManager.default.removeItem(atPath: temp)
        try fixture.createLegacyFile("helper-status.projection-temp", bytes: "partial\n")
        // The held XCTest sandbox denies hard-link creation.  When the host
        // permits the operation, retain the behavioral nlink rejection; when
        // it denies it before creation, the wrong-mode case below still
        // exercises the production descriptor recovery path.
        if link(temp, temp + ".link") == 0 {
            XCTAssertEqual(fixture.statusWriteOutcome(task: task), .unsafeExisting)
            try? FileManager.default.removeItem(atPath: temp + ".link")
        }
        try? FileManager.default.removeItem(atPath: temp)
        try fixture.createLegacyFile("helper-status.projection-temp", bytes: "partial\n", mode: 0o600)
        XCTAssertEqual(fixture.statusWriteOutcome(task: task), .unsafeExisting)
        XCTAssertEqual(fixture.power.setCalls, [])
    }

    func testProjectionTempWrongOwnerIsFailClosedWhenFixturePrivilegesPermitIt() throws {
        guard geteuid() == 0 else { throw XCTSkip("wrong-owner fixture needs a disposable root-owned test sandbox") }
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let temp = fixture.sandbox.url.appendingPathComponent("helper-status.projection-temp").path
        try fixture.createLegacyFile("helper-status.projection-temp", bytes: "partial\n")
        XCTAssertEqual(chown(temp, 1, getgid()), 0)
        let task = try XCTUnwrap(StatusProjectionTask(generation: 10, state: "active", reason: "fixture-temp-owner",
                                                      sessionID: nil, issuedEpoch: 10, issuedMonotonicMillis: 10,
                                                      bootID: "fixture-boot", deadlineNanoseconds: 100))
        XCTAssertEqual(fixture.statusWriteOutcome(task: task), .unsafeExisting)
        XCTAssertEqual(fixture.power.setCalls, [])
    }

    func testProjectionTempRetirementDurabilityFaultRetriesAndPreservesNewerPriority() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        try fixture.createLegacyFile("helper-status.projection-temp", bytes: "partial\n")
        let newer = try XCTUnwrap(StatusProjectionTask(generation: 12, state: "terminal", reason: "fixture-newer",
                                                       sessionID: nil, issuedEpoch: 12, issuedMonotonicMillis: 12,
                                                       bootID: "fixture-boot", deadlineNanoseconds: 100))
        XCTAssertEqual(fixture.statusWriteOutcome(task: newer,
                                                   recoveryGate: { $0 != .beforeRetire }), .indeterminate)
        XCTAssertEqual(fixture.statusWriteOutcome(task: newer), .written)
        try? FileManager.default.removeItem(atPath: fixture.configuration.statusPath)
        try fixture.createLegacyFile("helper-status.projection-temp", bytes: "partial\n")
        XCTAssertEqual(fixture.statusWriteOutcome(task: newer,
                                                   recoveryGate: { $0 != .afterRetire }), .indeterminate)
        XCTAssertEqual(fixture.statusWriteOutcome(task: newer), .written)
        let older = try XCTUnwrap(StatusProjectionTask(generation: 11, state: "active", reason: "fixture-older",
                                                       sessionID: nil, issuedEpoch: 11, issuedMonotonicMillis: 11,
                                                       bootID: "fixture-boot", deadlineNanoseconds: 100))
        XCTAssertEqual(fixture.statusWriteOutcome(task: older), .staleNewer(newer.generation))
        XCTAssertEqual(try String(contentsOfFile: fixture.configuration.statusPath, encoding: .utf8), newer.statusPayload)
        XCTAssertEqual(fixture.power.setCalls, [])
    }

    func testStatusProjectionWriterVerifiedSwapPublishesOnlyNewerGeneration() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let first = try XCTUnwrap(StatusProjectionTask(generation: 1, state: "active", reason: "fixture-first",
                                                       sessionID: nil, issuedEpoch: 10, issuedMonotonicMillis: 10,
                                                       bootID: "fixture-boot", deadlineNanoseconds: 100))
        let second = try XCTUnwrap(StatusProjectionTask(generation: 2, state: "terminal", reason: "fixture-second",
                                                        sessionID: nil, issuedEpoch: 11, issuedMonotonicMillis: 11,
                                                        bootID: "fixture-boot", deadlineNanoseconds: 100))
        XCTAssertEqual(fixture.statusWriteOutcome(task: first), .written)
        XCTAssertEqual(fixture.statusWriteOutcome(task: second), .written)
        XCTAssertEqual(try String(contentsOfFile: fixture.configuration.statusPath, encoding: .utf8), second.statusPayload)
        XCTAssertEqual(fixture.power.setCalls, [])
    }

    func testStalePublicGenerationMintsNewInitialAcknowledgementTask() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let old = try XCTUnwrap(try XCTUnwrap(fixture.store.withTransaction {
            fixture.store.enqueueStatusProjection(state: "active", reason: "fixture-ack", sessionID: nil, $0)
        }))
        let publicNewer = try XCTUnwrap(StatusProjectionTask(generation: old.generation + 1, state: "active", reason: "fixture-ack",
                                                              sessionID: nil, issuedEpoch: 11, issuedMonotonicMillis: 11,
                                                              bootID: "fixture-boot", deadlineNanoseconds: 100))
        XCTAssertEqual(fixture.statusWriteOutcome(task: publicNewer), .written)
        let replacement = try XCTUnwrap(try XCTUnwrap(fixture.store.withTransaction { transaction in
            fixture.store.enqueueStatusProjection(state: old.state, reason: old.reason, sessionID: old.sessionID,
                                                   transaction, generationFloor: publicNewer.generation)
        }))
        XCTAssertGreaterThan(replacement.generation, publicNewer.generation)
        XCTAssertNotEqual(replacement.authoritySnapshot, old.authoritySnapshot)
        XCTAssertEqual(fixture.power.setCalls, [])
    }

    func testStatusProjectionProductionWriterFaultGateLeavesNoPowerOrLeaseSideEffect() throws {
        for stage in HelperStatusStore.WriteStage.allCases {
            let fixture = try Fixture()
            defer { fixture.dispose() }
            let task = try XCTUnwrap(StatusProjectionTask(generation: 1, state: "terminal", reason: "fixture-fault",
                                                          sessionID: nil, issuedEpoch: 10, issuedMonotonicMillis: 10,
                                                          bootID: "fixture-boot", deadlineNanoseconds: 100))
            XCTAssertFalse(fixture.writeStatus(task: task,
                                                stageGate: { $0 != stage }), "stage=\(stage)")
            XCTAssertEqual(fixture.power.setCalls, [], "stage=\(stage)")
            XCTAssertEqual(fixture.store.appliedRecord(), .missing, "stage=\(stage)")
        }
    }

    func testProvablyFreshRootAloneBootstrapsPrivateEmptyLedgersAndPristineProof() throws {
        let fixture = try Fixture(provision: false)
        defer { fixture.dispose() }

        XCTAssertEqual(fixture.store.provision(), .ready)
        XCTAssertEqual(fixture.store.privateLedger(RecoveryAuthorityStore.terminalBasename), [])
        XCTAssertEqual(fixture.store.privateLedger(RecoveryAuthorityStore.reservationBasename), [])
        XCTAssertEqual(
            fixture.store.proof(),
            RecoveryProof(kind: .pristine, sessionID: nil, reason: "bootstrap")
        )
        XCTAssertEqual(fixture.store.appliedRecord(), .missing)
        XCTAssertEqual(fixture.coordinator.recover(intent: .startup, allowReconnect: true), .pristineIdle)
        XCTAssertEqual(fixture.power.setCalls, [])
    }

    func testAdministratorInstallPublishesPristineSafeIdleButDaemonStartupDoesNotManufactureIt() throws {
        let administrator = try Fixture(provision: false)
        defer { administrator.dispose() }
        XCTAssertEqual(administrator.store.provision(), .ready)
        XCTAssertEqual(
            administrator.coordinator.recover(intent: .install, allowReconnect: false),
            .pristineIdle
        )
        XCTAssertTrue(StatusProjectionDispatcher.waitForIdleForTesting())
        let payload = try String(contentsOfFile: administrator.configuration.statusPath, encoding: .utf8)
        XCTAssertTrue(payload.contains("state=inactive\n"))
        XCTAssertTrue(payload.contains("reason=pristine\n"))
        XCTAssertTrue(payload.contains("session=none\n"))
        XCTAssertTrue(payload.contains("projection_authority="))
        XCTAssertTrue(payload.contains("projection_generation="))
        XCTAssertTrue(payload.contains("projection_token="))
        XCTAssertEqual(administrator.store.statusProjectionTaskRecord(), .absent)
        XCTAssertEqual(administrator.store.appliedRecord(), .missing)
        XCTAssertEqual(administrator.power.setCalls, [])

        let daemon = try Fixture(provision: false)
        defer { daemon.dispose() }
        XCTAssertEqual(daemon.store.provision(), .ready)
        XCTAssertEqual(daemon.coordinator.recover(intent: .startup, allowReconnect: true), .pristineIdle)
        XCTAssertTrue(StatusProjectionDispatcher.waitForIdleForTesting())
        XCTAssertEqual(daemon.store.evidenceState(for: "helper-status"), .absent)
        XCTAssertEqual(daemon.store.statusProjectionTaskRecord(), .absent)
        XCTAssertEqual(daemon.store.appliedRecord(), .missing)
        XCTAssertEqual(daemon.power.setCalls, [])
    }

    func testDaemonStartupAndRecoverOnceNeverProvisionMissingAuthority() throws {
        let fixture = try Fixture(provision: false)
        defer { fixture.dispose() }
        let recoverOperations = HelperControlServiceOperations(
            provision: { _ in XCTFail("normal paths must not provision"); return .recoveryRequired("unexpected-provision") },
            recover: { _, intent in fixture.coordinator.recover(intent: intent, allowReconnect: false) },
            daemon: { _ in
                let outcome = fixture.coordinator.recover(intent: .startup, allowReconnect: true)
                if case .recoveryRequired("root-state-lock-unavailable") = outcome { return 78 }
                return 0
            }
        )

        let recoverConfiguration = Fixture.makeConfiguration(directory: fixture.sandbox.url, mode: .recoverOnce(.uninstall))
        XCTAssertEqual(HelperControlService.run(configuration: recoverConfiguration, operations: recoverOperations), 75)
        let daemonConfiguration = Fixture.makeConfiguration(directory: fixture.sandbox.url, mode: .daemon)
        XCTAssertEqual(HelperControlService.run(configuration: daemonConfiguration, operations: recoverOperations), 78)

        for basename in [
            RootStateLock.authorizationBasename,
            RecoveryAuthorityStore.terminalBasename,
            RecoveryAuthorityStore.reservationBasename,
            RecoveryAuthorityStore.appliedBasename,
            RecoveryAuthorityStore.proofBasename,
            "helper-status",
        ] {
            XCTAssertEqual(fixture.store.evidenceState(for: basename), .absent, "\(basename) was provisioned")
        }
        XCTAssertEqual(fixture.power.setCalls, [])

        let unsafe = try Fixture(provision: false)
        defer { unsafe.dispose() }
        try unsafe.createLegacyFile(RootStateLock.authorizationBasename, bytes: "")
        XCTAssertEqual(
            unsafe.coordinator.recover(intent: .startup, allowReconnect: true),
            .recoveryRequired("root-state-lock-unavailable")
        )
        XCTAssertEqual(try unsafe.mode(RootStateLock.authorizationBasename), 0o644)
        XCTAssertEqual(unsafe.store.evidenceState(for: RecoveryAuthorityStore.terminalBasename), .absent)
        XCTAssertEqual(unsafe.store.evidenceState(for: RecoveryAuthorityStore.proofBasename), .absent)
        XCTAssertEqual(unsafe.power.setCalls, [])
    }

    func testIdleProofNeverClaimsSafeWhileNativeSleepOverrideIsActiveOrUnknown() throws {
        let active = try Fixture()
        defer { active.dispose() }
        active.power.disabled = true
        guard case .recoveryRequired("idle-sleep-override-active") = active.coordinator.recover(
            intent: .userRestore,
            allowReconnect: false
        ) else {
            return XCTFail("idle authority must not claim safe while SleepDisabled is active")
        }
        XCTAssertEqual(active.power.setCalls, [], "missing ownership must never authorize a clear")

        let unknown = try Fixture()
        defer { unknown.dispose() }
        unknown.power.disabled = nil
        guard case .recoveryRequired("idle-power-state-unknown") = unknown.coordinator.recover(
            intent: .userRestore,
            allowReconnect: false
        ) else {
            return XCTFail("idle authority must require a native power observation")
        }
        XCTAssertEqual(unknown.power.setCalls, [])
    }

    func testTimedOutExistingLockRunsNoRecoveryBodyAndMutatesNoAuthority() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let lockPath = fixture.sandbox.url.appendingPathComponent(RootStateLock.authorizationBasename).path
        let held = open(lockPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(held, 0)
        defer { Darwin.close(held) }
        XCTAssertEqual(flock(held, LOCK_EX | LOCK_NB), 0)
        try fixture.activateStore(lockTimeout: 0)
        let proofBefore = fixture.store.proof()
        let terminalBefore = fixture.store.privateLedger(RecoveryAuthorityStore.terminalBasename)

        XCTAssertEqual(
            fixture.coordinator.recover(intent: .startup, allowReconnect: true),
            .recoveryRequired("root-state-lock-unavailable")
        )
        XCTAssertEqual(fixture.store.proof(), proofBefore)
        XCTAssertEqual(fixture.store.privateLedger(RecoveryAuthorityStore.terminalBasename), terminalBefore)
        XCTAssertEqual(fixture.power.setCalls, [])
    }

    func testValidLegacyLedgersMigrateExactBytesToPrivateAuthorityWithoutOverwritingHistory() throws {
        let fixture = try Fixture(provision: false)
        defer { fixture.dispose() }
        let terminal = UUID()
        let reservation = UUID()
        let terminalBytes = terminal.uuidString.lowercased() + "\n"
        let reservationBytes = reservation.uuidString.lowercased() + "\n"
        try fixture.createLegacyFile(RecoveryAuthorityStore.terminalBasename, bytes: terminalBytes)
        try fixture.createLegacyFile(RecoveryAuthorityStore.reservationBasename, bytes: reservationBytes)

        XCTAssertEqual(fixture.store.provision(), .recoveryRequired("legacy-reservation-unresolved"))
        XCTAssertEqual(fixture.store.privateLedger(RecoveryAuthorityStore.terminalBasename), [terminal])
        XCTAssertEqual(fixture.store.privateLedger(RecoveryAuthorityStore.reservationBasename), [reservation])
        XCTAssertEqual(try fixture.readBytes(RecoveryAuthorityStore.terminalBasename), terminalBytes)
        XCTAssertEqual(try fixture.readBytes(RecoveryAuthorityStore.reservationBasename), reservationBytes)
        XCTAssertEqual(try fixture.mode(RecoveryAuthorityStore.terminalBasename), 0o600)
        XCTAssertEqual(try fixture.mode(RecoveryAuthorityStore.reservationBasename), 0o600)
        // Historical ledgers never receive a forged bootstrap proof.
        XCTAssertEqual(
            fixture.store.proof(),
            RecoveryProof(kind: .recoveryRequired, sessionID: nil, reason: "legacy-reservation-unresolved")
        )
    }

    func testLegacyFourKeyAppliedAndExactACBatteryEvidenceMigrateAndRestoreNatively() throws {
        let fixture = try Fixture(provision: false)
        defer { fixture.dispose() }
        let session = UUID()
        let legacy = AppliedState(
            sessionID: session,
            changedSleepDisabled: true,
            changedACSleep: false,
            originalACSleep: nil
        )
        try fixture.createLegacyFile(RecoveryAuthorityStore.appliedBasename, bytes: legacy.storagePayload)
        try fixture.createLegacyFile(
            RecoveryAuthorityStore.legacyACBasename,
            bytes: "9\n",
            mode: 0o640
        )
        try fixture.createLegacyFile(RecoveryAuthorityStore.legacyBatteryBasename, bytes: "11\n")
        fixture.power.disabled = true
        fixture.power.ac = 0
        fixture.power.battery = 0

        XCTAssertEqual(fixture.store.provision(), .ready)
        guard case let .legacyRestoreOnly(migrated) = fixture.store.appliedRecord() else {
            return XCTFail("legacy applied state was not migrated to private authority")
        }
        XCTAssertTrue(migrated.changedACSleep)
        XCTAssertEqual(migrated.originalACSleep, 9)
        XCTAssertTrue(migrated.changedBatterySleep)
        XCTAssertEqual(migrated.originalBatterySleep, 11)

        XCTAssertEqual(
            fixture.coordinator.recover(
                intent: .userRestore,
            allowReconnect: false
            ),
            .terminalIdle(session, "legacy-restore")
        )
        XCTAssertEqual(fixture.power.disabled, false)
        XCTAssertEqual(fixture.power.ac, 9)
        XCTAssertEqual(fixture.power.battery, 11)
        XCTAssertEqual(
            fixture.store.evidenceState(for: RecoveryAuthorityStore.legacyACBasename),
            .absent
        )
        XCTAssertEqual(
            fixture.store.evidenceState(for: RecoveryAuthorityStore.legacyBatteryBasename),
            .absent
        )
    }

    func testMalformedLegacyPowerEvidenceFailsClosedWithoutRearm() throws {
        let fixture = try Fixture(provision: false)
        defer { fixture.dispose() }
        let legacy = AppliedState(
            sessionID: UUID(),
            changedSleepDisabled: true,
            changedACSleep: false,
            originalACSleep: nil
        )
        try fixture.createLegacyFile(RecoveryAuthorityStore.appliedBasename, bytes: legacy.storagePayload)
        try fixture.createLegacyFile(RecoveryAuthorityStore.legacyACBasename, bytes: "1441\n")

        guard case .recoveryRequired = fixture.store.provision() else {
            return XCTFail("malformed legacy evidence must fail closed")
        }
        XCTAssertEqual(fixture.power.setCalls, [])
        XCTAssertEqual(
            fixture.store.evidenceState(for: RecoveryAuthorityStore.legacyACBasename),
            .present
        )
    }

    func testAppliedOriginalTimersAreBoundedToOneDay() {
        let session = UUID().uuidString.lowercased()
        XCTAssertNotNil(AppliedState.parse(
            "session=\(session)\nchanged_sleep_disabled=1\nchanged_ac_sleep=1\noriginal_ac_sleep=1440\n"
        ))
        XCTAssertNil(AppliedState.parse(
            "session=\(session)\nchanged_sleep_disabled=1\nchanged_ac_sleep=1\noriginal_ac_sleep=1441\n"
        ))
        XCTAssertNil(AppliedState.parse(
            "session=\(session)\nchanged_sleep_disabled=1\nchanged_ac_sleep=0\noriginal_ac_sleep=unknown\nchanged_battery_sleep=1\noriginal_battery_sleep=1441\n"
        ))
    }

    func testLeafClassificationOpensOnceAndRejectsPublicBindingSwap() throws {
        let fixture = try Fixture(provision: false)
        defer { fixture.dispose() }
        let original = UUID().uuidString.lowercased() + "\n"
        let replacement = UUID().uuidString.lowercased() + "\n"
        try fixture.createLegacyFile(RecoveryAuthorityStore.terminalBasename, bytes: original)
        let opens = IntegerBox()
        let operations = RecoveryAuthorityFileOperations(
            openLeaf: { directory, basename in
                opens.increment()
                return Darwin.openat(directory, basename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            },
            afterOpen: { directory, basename in
                guard basename == RecoveryAuthorityStore.terminalBasename else { return }
                _ = Darwin.renameat(directory, basename, directory, "terminal-held-original")
                let replacementFD = Darwin.openat(
                    directory,
                    basename,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    0o644
                )
                guard replacementFD >= 0 else { return }
                defer { Darwin.close(replacementFD) }
                _ = Data(replacement.utf8).withUnsafeBytes {
                    Darwin.write(replacementFD, $0.baseAddress, $0.count)
                }
                _ = Darwin.fchmod(replacementFD, 0o644)
            }
        )
        try fixture.activateFileOperations(operations)

        XCTAssertEqual(fixture.store.ledger(RecoveryAuthorityStore.terminalBasename), .invalid)
        XCTAssertEqual(opens.value, 1, "private/legacy classification reopened the basename")
        XCTAssertEqual(try fixture.readBytes(RecoveryAuthorityStore.terminalBasename), replacement)
    }

    func testInvalidLegacyLedgerIsNeverOverwrittenOrCompletedWithAnEmptyPeerLedger() throws {
        let fixture = try Fixture(provision: false)
        defer { fixture.dispose() }
        try fixture.createLegacyFile(RecoveryAuthorityStore.terminalBasename, bytes: "not-a-uuid\n")

        guard case .recoveryRequired = fixture.store.provision() else {
            return XCTFail("invalid migration must fail closed")
        }
        XCTAssertEqual(try fixture.readBytes(RecoveryAuthorityStore.terminalBasename), "not-a-uuid\n")
        XCTAssertEqual(try fixture.mode(RecoveryAuthorityStore.terminalBasename), 0o644)
        XCTAssertEqual(fixture.store.evidenceState(for: RecoveryAuthorityStore.reservationBasename), .absent)
        XCTAssertEqual(fixture.store.proof()?.kind, .recoveryRequired)
    }

    func testQuarantinedHistoricalEvidenceCanNeverBeReclassifiedAsFreshBootstrap() throws {
        let fixture = try Fixture(provision: false)
        defer { fixture.dispose() }
        let quarantine = try XCTUnwrap(
            VerifiedRootStateDirectory.quarantineBasename(for: RecoveryAuthorityStore.appliedBasename)
        )
        try fixture.createPrivateFile(quarantine, bytes: "interrupted-recovery")

        guard case .recoveryRequired = fixture.store.provision() else {
            return XCTFail("quarantine evidence must block bootstrap")
        }
        XCTAssertEqual(fixture.store.evidenceState(for: RecoveryAuthorityStore.appliedBasename), .present)
        XCTAssertEqual(fixture.store.evidenceState(for: RecoveryAuthorityStore.terminalBasename), .absent)
        XCTAssertEqual(fixture.store.evidenceState(for: RecoveryAuthorityStore.reservationBasename), .absent)
        XCTAssertNotEqual(fixture.store.proof()?.kind, .pristine)
    }

    func testLegacyStatusAndHistoryEvidenceBlockPristineBootstrap() throws {
        for basename in RecoveryAuthorityStore.legacyHistoryBasenames {
            let fixture = try Fixture(provision: false)
            defer { fixture.dispose() }
            try fixture.createLegacyFile(basename, bytes: "prior-evidence\n")

            guard case .recoveryRequired = fixture.store.provision() else {
                return XCTFail("\(basename) must block pristine bootstrap")
            }
            XCTAssertNotEqual(fixture.store.proof()?.kind, .pristine)
            XCTAssertEqual(try fixture.readBytes(basename), "prior-evidence\n")
        }
    }

    func testPristineAndTerminalIdleRequireExactLedgerProofRelationships() throws {
        let pristineConflict = try Fixture()
        defer { pristineConflict.dispose() }
        let historical = UUID()
        XCTAssertTrue(pristineConflict.record(historical, in: RecoveryAuthorityStore.terminalBasename))
        guard case .recoveryRequired("pristine-history-conflict") = pristineConflict.coordinator.recover(intent: .startup, allowReconnect: false) else {
            return XCTFail("pristine proof cannot coexist with history")
        }

        let terminalMismatch = try Fixture()
        defer { terminalMismatch.dispose() }
        let missing = UUID()
        XCTAssertTrue(terminalMismatch.publishProof(.init(kind: .terminal, sessionID: missing, reason: "test-terminal")))
        guard case .recoveryRequired("terminal-proof-ledger-mismatch") = terminalMismatch.coordinator.recover(intent: .startup, allowReconnect: false) else {
            return XCTFail("terminal proof needs exact terminal membership")
        }

        let staleLatest = try Fixture()
        defer { staleLatest.dispose() }
        let older = UUID()
        let newer = UUID()
        XCTAssertTrue(staleLatest.record(older, in: RecoveryAuthorityStore.terminalBasename))
        XCTAssertTrue(staleLatest.publishProof(.init(kind: .terminal, sessionID: older, reason: "older-terminal")))
        XCTAssertTrue(staleLatest.record(newer, in: RecoveryAuthorityStore.terminalBasename))
        guard case .recoveryRequired("terminal-proof-ledger-mismatch") = staleLatest.coordinator.recover(intent: .startup, allowReconnect: false) else {
            return XCTFail("a terminal proof must bind the ordered latest ledger entry")
        }
    }

    func testMalformedProofBytesArePreservedAndNeverReplacedByProvisionOrRecovery() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let applied = Mutation.both.state(session: UUID(), boot: Self.boot)
        try fixture.installPrivateApplied(applied)
        fixture.power.prepareForOwnedMutation(.both)
        let malformed = "schema=1\nkind=terminal\nsession=not-a-uuid\nreason=malformed\n"
        try fixture.replacePrivateFile(RecoveryAuthorityStore.proofBasename, payload: malformed)

        XCTAssertEqual(fixture.store.proofRecord(), .invalid)
        guard case .recoveryRequired("invalid-recovery-proof") = fixture.coordinator.recover(intent: .startup, allowReconnect: false) else {
            return XCTFail("malformed proof must fail closed")
        }
        XCTAssertEqual(try fixture.readBytes(RecoveryAuthorityStore.proofBasename), malformed)
        XCTAssertEqual(fixture.store.appliedRecord(), .privateAuthority(applied))
        XCTAssertEqual(fixture.power.setCalls, [])
        guard case .recoveryRequired = fixture.store.provision() else {
            return XCTFail("provision must not overwrite malformed proof")
        }
        XCTAssertEqual(try fixture.readBytes(RecoveryAuthorityStore.proofBasename), malformed)
    }

    func testReconnectCandidateRequiresExactRecoveryBudgetPhase() throws {
        let eligible = try Fixture()
        defer { eligible.dispose() }
        let session = UUID()
        try eligible.installPrivateApplied(Mutation.both.state(session: session, boot: Self.boot))
        eligible.power.disabled = true
        eligible.power.ac = 0
        guard case let .reconnectCandidate(state) = eligible.coordinator.recover(intent: .startup, allowReconnect: true) else {
            return XCTFail("expected a source-only reconnect candidate")
        }
        XCTAssertEqual(state.sessionID, session)
        XCTAssertEqual(eligible.power.setCalls, [])

        let denied = try Fixture()
        defer { denied.dispose() }
        try denied.installPrivateApplied(Mutation.both.state(session: session, boot: Self.boot))
        XCTAssertTrue(denied.record(session, in: RecoveryAuthorityStore.reservationBasename))
        denied.power.disabled = true
        denied.power.ac = 0
        guard case .recoveryRequired("recovery-budget-reservation-without-phase") = denied.coordinator.recover(intent: .startup, allowReconnect: true) else {
            return XCTFail("reservation without a durable phase must retain evidence for administrator recovery")
        }
        XCTAssertEqual(denied.power.setCalls, [])
        XCTAssertEqual(denied.store.appliedRecord(), .privateAuthority(Mutation.both.state(session: session, boot: Self.boot)))

        let reserved = try Fixture()
        defer { reserved.dispose() }
        let reservedState = Mutation.both.state(session: session, boot: Self.boot)
        try reserved.installPrivateApplied(reservedState)
        XCTAssertTrue(reserved.record(session, in: RecoveryAuthorityStore.reservationBasename))
        XCTAssertTrue(reserved.store.withTransaction {
            reserved.store.publishRecoveryBudget(
                RecoveryBudgetState(sessionID: session, phase: .reserved),
                $0
            ).isVerified
        } == true)
        reserved.power.disabled = true
        reserved.power.ac = 0
        XCTAssertEqual(
            reserved.coordinator.recover(intent: .startup, allowReconnect: true),
            .recoveryRequired("recovery-budget-reserved")
        )
        XCTAssertEqual(reserved.power.setCalls, [])
        XCTAssertEqual(reserved.store.appliedRecord(), .privateAuthority(reservedState))

        let spent = try Fixture()
        defer { spent.dispose() }
        let spentState = Mutation.both.state(session: session, boot: Self.boot)
        try spent.installPrivateApplied(spentState)
        XCTAssertTrue(spent.record(session, in: RecoveryAuthorityStore.reservationBasename))
        XCTAssertTrue(spent.store.withTransaction {
            spent.store.publishRecoveryBudget(
                RecoveryBudgetState(sessionID: session, phase: .spent),
                $0
            ).isVerified
        } == true)
        spent.power.disabled = true
        spent.power.ac = 0
        XCTAssertEqual(spent.coordinator.recover(intent: .startup, allowReconnect: true), .reconnectCandidate(spentState))
        XCTAssertEqual(spent.power.setCalls, [])
    }

    func testExplicitRecoveryNeverReconnectsAndRestoresOnlyOwnedExactFields() throws {
        for mutation in Mutation.allCases {
            let fixture = try Fixture()
            defer { fixture.dispose() }
            let session = UUID()
            try fixture.installPrivateApplied(mutation.state(session: session, boot: Self.boot))
            fixture.power.prepareForOwnedMutation(mutation)

            guard case let .terminalIdle(actual, reason) = fixture.coordinator.recover(
                intent: .userRestore,
                allowReconnect: false
            ) else { return XCTFail("explicit recovery must terminate") }
            XCTAssertEqual(actual, session)
            XCTAssertEqual(reason, "user-restore-recovery")
            XCTAssertEqual(fixture.power.disabled, false)
            XCTAssertEqual(fixture.power.ac, mutation.expectedAC)
            XCTAssertFalse(fixture.power.setCalls.contains("sleep=1"))
            XCTAssertFalse(fixture.power.setCalls.contains("ac=0"))
            XCTAssertEqual(fixture.store.appliedRecord(), .missing)
            XCTAssertTrue(fixture.store.privateLedger(RecoveryAuthorityStore.terminalBasename)?.contains(session) == true)
            XCTAssertEqual(
                fixture.store.proof(),
                RecoveryProof(kind: .terminal, sessionID: session, reason: reason)
            )
        }
    }

    func testIndeterminateRestoreSetterAcceptsOnlyExactNativePostconditionWithoutRetry() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let session = UUID()
        try fixture.installPrivateApplied(Mutation.sleep.state(session: session, boot: Self.boot))
        fixture.power.prepareForOwnedMutation(.sleep)
        fixture.power.throwAfterSleepMutation = true

        XCTAssertEqual(
            fixture.coordinator.recover(intent: .userRestore, allowReconnect: false),
            .terminalIdle(session, "user-restore-recovery")
        )
        XCTAssertEqual(fixture.power.setCalls, ["sleep=0"], "an indeterminate runner result must never retry pmset")
        XCTAssertEqual(fixture.power.sleepDisabled(), false)
        XCTAssertEqual(fixture.store.appliedRecord(), .missing)
    }

    func testStaleHistoricalTerminalCannotAuthorizeProofAbsentAppliedRecovery() throws {
        let fixture = try Fixture(provision: false)
        defer { fixture.dispose() }
        XCTAssertEqual(fixture.store.provisionLock(), .ready)
        let session = UUID()
        let foreign = UUID()
        let terminalBytes = [session, foreign].map { $0.uuidString.lowercased() }.joined(separator: "\n") + "\n"
        try fixture.createPrivateFile(RecoveryAuthorityStore.terminalBasename, bytes: terminalBytes)
        try fixture.createPrivateFile(RecoveryAuthorityStore.reservationBasename, bytes: "")
        try fixture.installPrivateApplied(Mutation.both.state(session: session, boot: Self.boot))
        fixture.power.prepareForOwnedMutation(.both)

        guard case .recoveryRequired = fixture.coordinator.recover(
            intent: .userRestore,
            allowReconnect: false
        ) else {
            return XCTFail("a stale terminal receipt must fail closed before any restore")
        }
        XCTAssertEqual(fixture.power.setCalls, [])
        XCTAssertNotEqual(fixture.store.appliedRecord(), .missing)
        XCTAssertNotEqual(fixture.store.proof()?.kind, .terminal)
        XCTAssertNotEqual(fixture.store.proof()?.sessionID, session)
        XCTAssertEqual(try fixture.readBytes(RecoveryAuthorityStore.terminalBasename), terminalBytes)
        XCTAssertEqual(fixture.store.privateLedger(RecoveryAuthorityStore.terminalBasename), [session, foreign])
    }

    func testLegacyAppliedStateIsRestoreOnlyAndNeverReconnectAuthority() throws {
        let fixture = try Fixture(provision: false)
        defer { fixture.dispose() }
        XCTAssertEqual(fixture.store.provisionLock(), .ready)
        let session = UUID()
        try fixture.installLegacyApplied(Mutation.both.state(session: session, boot: Self.boot))
        fixture.power.prepareForOwnedMutation(.both)

        guard case .recoveryRequired("legacy-writers-not-quiesced") = fixture.coordinator.recover(
            intent: .startup,
            allowReconnect: true
        ) else {
            return XCTFail("daemon startup cannot assume the old writer is stopped")
        }
        XCTAssertEqual(fixture.power.setCalls, [])
        guard case let .terminalIdle(actual, reason) = fixture.coordinator.recover(
            intent: .userRestore,
            allowReconnect: false
        ) else {
            return XCTFail("quiesced administrator recovery must restore legacy bytes")
        }
        XCTAssertEqual(actual, session)
        XCTAssertEqual(reason, "legacy-restore")
        XCTAssertEqual(fixture.power.disabled, false)
        XCTAssertEqual(fixture.power.ac, 10)
    }

    func testMigratedProofAndPublicSchema2ConflictNeverPublishesOrReconnects() throws {
        let fixture = try Fixture(provision: false)
        defer { fixture.dispose() }
        XCTAssertEqual(fixture.store.provisionLock(), .ready)
        let session = UUID()
        let publicState = Mutation.both.state(session: session, boot: Self.boot)
        let proof = RecoveryProof(kind: .migrated, sessionID: nil, reason: "legacy-migration")
        try fixture.createPrivateFile(RecoveryAuthorityStore.terminalBasename, bytes: "")
        try fixture.createPrivateFile(RecoveryAuthorityStore.reservationBasename, bytes: "")
        try fixture.createPrivateFile(RecoveryAuthorityStore.proofBasename, bytes: proof.payload)
        try fixture.installLegacyApplied(publicState)
        fixture.power.prepareForOwnedMutation(.both)
        let originalBytes = try fixture.readBytes(RecoveryAuthorityStore.appliedBasename)

        XCTAssertEqual(
            fixture.coordinator.recover(
                intent: .userRestore,
            allowReconnect: false
            ),
            .recoveryRequired("legacy-applied-proof-conflict")
        )
        XCTAssertEqual(fixture.power.setCalls, [])
        XCTAssertEqual(try fixture.readBytes(RecoveryAuthorityStore.appliedBasename), originalBytes)
        XCTAssertEqual(try fixture.mode(RecoveryAuthorityStore.appliedBasename), 0o644)
        XCTAssertEqual(fixture.store.appliedRecord(), .legacyRestoreOnly(publicState))
        XCTAssertEqual(fixture.store.proof(), proof)

        let startup = fixture.coordinator.recover(intent: .startup, allowReconnect: true)
        XCTAssertEqual(startup, .recoveryRequired("legacy-writers-not-quiesced"))
        if case .reconnectCandidate = startup { XCTFail("public legacy identity became reconnect authority") }
        XCTAssertEqual(fixture.power.setCalls, [])
        XCTAssertEqual(fixture.store.proof(), proof)
        XCTAssertEqual(try fixture.mode(RecoveryAuthorityStore.appliedBasename), 0o644)

        let peerChecks = IntegerBox()
        let timerStarts = IntegerBox()
        let authority = HelperSessionAuthority(
            configuration: fixture.configuration,
            power: fixture.power,
            recoveryStoreFactory: { _ in fixture.store },
            peerIsLive: { _ in peerChecks.increment(); return true },
            timerStarter: { _ in timerStarts.increment(); return NSObject() },
            recoveryCoordinatorFactory: { fixture.coordinator }
        )
        XCTAssertNotEqual(authority.prepareBeforeListening(), .ready)
        XCTAssertEqual(peerChecks.value, 0)
        XCTAssertEqual(timerStarts.value, 0)
    }

    func testPristineAndTerminalProofsAlsoConflictBeforePublicAppliedMutation() throws {
        for kind in [RecoveryProof.Kind.pristine, .terminal] {
            let fixture = try Fixture(provision: false)
            defer { fixture.dispose() }
            XCTAssertEqual(fixture.store.provisionLock(), .ready)
            let session = UUID()
            let publicState = Mutation.both.state(session: session, boot: Self.boot)
            let proof = kind == .pristine
                ? RecoveryProof(kind: .pristine, sessionID: nil, reason: "bootstrap")
                : RecoveryProof(kind: .terminal, sessionID: session, reason: "legacy-restore")
            if kind == .terminal {
                try fixture.createPrivateFile(
                    RecoveryAuthorityStore.terminalBasename,
                    bytes: session.uuidString.lowercased() + "\n"
                )
                try fixture.createPrivateFile(RecoveryAuthorityStore.reservationBasename, bytes: "")
            }
            try fixture.createPrivateFile(RecoveryAuthorityStore.proofBasename, bytes: proof.payload)
            try fixture.installLegacyApplied(publicState)
            let originalBytes = try fixture.readBytes(RecoveryAuthorityStore.appliedBasename)

            XCTAssertEqual(
                fixture.coordinator.recover(
                    intent: .userRestore,
            allowReconnect: false
                ),
                .recoveryRequired("legacy-applied-proof-conflict")
            )
            XCTAssertEqual(fixture.power.setCalls, [])
            XCTAssertEqual(try fixture.readBytes(RecoveryAuthorityStore.appliedBasename), originalBytes)
            XCTAssertEqual(try fixture.mode(RecoveryAuthorityStore.appliedBasename), 0o644)
            XCTAssertEqual(fixture.store.proof(), proof)
            if kind == .pristine {
                XCTAssertEqual(
                    fixture.store.evidenceState(for: RecoveryAuthorityStore.terminalBasename),
                    .absent
                )
                XCTAssertEqual(
                    fixture.store.evidenceState(for: RecoveryAuthorityStore.reservationBasename),
                    .absent
                )
            }
        }
    }

    func testProofAbsentPublicSchema2PublishesOnlySanitizedRestoreAuthorityAndReplays() throws {
        let fixture = try Fixture(provision: false)
        defer { fixture.dispose() }
        XCTAssertEqual(fixture.store.provisionLock(), .ready)
        let session = UUID()
        let processState = Mutation.both.state(session: session, boot: Self.boot)
        let publicState = AppliedState(
            sessionID: session,
            changedSleepDisabled: true,
            changedACSleep: true,
            originalACSleep: 10,
            changedBatterySleep: true,
            originalBatterySleep: 12,
            owner: processState.owner,
            leaseExpiryMonotonic: processState.leaseExpiryMonotonic
        )
        try fixture.installLegacyApplied(publicState)
        fixture.power.prepareForOwnedMutation(.both)
        fixture.power.battery = 0

        XCTAssertEqual(fixture.store.prepareAuthorityAfterWriterQuiescence(), .ready)
        guard case let .legacyRestoreOnly(sanitized) = fixture.store.appliedRecord() else {
            return XCTFail("sanitized private state was not restore-only")
        }
        XCTAssertEqual(sanitized.sessionID, session)
        XCTAssertTrue(sanitized.changedSleepDisabled)
        XCTAssertTrue(sanitized.changedACSleep)
        XCTAssertEqual(sanitized.originalACSleep, 10)
        XCTAssertTrue(sanitized.changedBatterySleep)
        XCTAssertEqual(sanitized.originalBatterySleep, 12)
        XCTAssertNil(sanitized.owner)
        XCTAssertNil(sanitized.leaseExpiryMonotonic)
        XCTAssertFalse(sanitized.isProcessBound)
        XCTAssertEqual(try fixture.mode(RecoveryAuthorityStore.appliedBasename), 0o600)
        XCTAssertEqual(fixture.power.setCalls, [])

        let startup = fixture.coordinator.recover(intent: .startup, allowReconnect: true)
        XCTAssertEqual(startup, .recoveryRequired("legacy-writers-not-quiesced"))
        if case .reconnectCandidate = startup { XCTFail("sanitized state became reconnect authority") }
        XCTAssertEqual(fixture.power.setCalls, [])

        XCTAssertEqual(
            fixture.coordinator.recover(
                intent: .userRestore,
            allowReconnect: false
            ),
            .terminalIdle(session, "legacy-restore")
        )
        XCTAssertEqual(fixture.store.appliedRecord(), .missing)
        XCTAssertEqual(fixture.power.battery, 12)
    }

    func testSanitizationRetainsExplicitNoOpBatteryDimensionForSixAndFourteenKeyInputs() throws {
        for shape in [AppliedState.PayloadShape.legacySix, .schemaFourteen] {
            let fixture = try Fixture(provision: false)
            defer { fixture.dispose() }
            XCTAssertEqual(fixture.store.provisionLock(), .ready)
            let session = UUID()
            let owner = Mutation.both.state(session: session, boot: Self.boot).owner
            let state = AppliedState(
                sessionID: session,
                changedSleepDisabled: false,
                changedACSleep: false,
                originalACSleep: nil,
                changedBatterySleep: false,
                originalBatterySleep: nil,
                owner: shape == .schemaFourteen ? owner : nil,
                leaseExpiryMonotonic: shape == .schemaFourteen ? 999 : nil,
                payloadShape: shape
            )
            try fixture.installLegacyApplied(state)

            XCTAssertEqual(fixture.store.prepareAuthorityAfterWriterQuiescence(), .ready)
            guard case let .legacyRestoreOnly(sanitized) = fixture.store.appliedRecord() else {
                return XCTFail("\(shape) must remain restore-only after sanitization")
            }
            let bytes = try fixture.readBytes(RecoveryAuthorityStore.appliedBasename)
            XCTAssertEqual(sanitized.payloadShape, .legacySix)
            XCTAssertNil(sanitized.owner)
            XCTAssertNil(sanitized.leaseExpiryMonotonic)
            XCTAssertTrue(bytes.contains("changed_battery_sleep=0\n"))
            XCTAssertTrue(bytes.contains("original_battery_sleep=unknown\n"))
            XCTAssertEqual(AppliedState.parse(bytes)?.storagePayload, bytes)
        }
    }

    func testRecoveryRequiredRetrySanitizesBeforeCrashAndDaemonCannotReconnectIt() throws {
        let fixture = try Fixture(provision: false)
        defer { fixture.dispose() }
        XCTAssertEqual(fixture.store.provisionLock(), .ready)
        let session = UUID()
        let publicState = Mutation.both.state(session: session, boot: Self.boot)
        let requiredProof = RecoveryProof(
            kind: .recoveryRequired,
            sessionID: nil,
            reason: "owned-restore-failed"
        )
        try fixture.createPrivateFile(RecoveryAuthorityStore.terminalBasename, bytes: "")
        try fixture.createPrivateFile(RecoveryAuthorityStore.reservationBasename, bytes: "")
        try fixture.createPrivateFile(RecoveryAuthorityStore.proofBasename, bytes: requiredProof.payload)
        try fixture.installLegacyApplied(publicState)
        fixture.power.prepareForOwnedMutation(.both)

        let prepared = try XCTUnwrap(fixture.store.withTransaction {
            fixture.store.prepareAuthorityLocked(
                $0,
                allowRecoveryRequiredLegacyRetry: true
            )
        })
        XCTAssertEqual(prepared, .ready)
        guard case let .legacyRestoreOnly(sanitized) = fixture.store.appliedRecord() else {
            return XCTFail("retry publication retained process identity")
        }
        XCTAssertNil(sanitized.owner)
        XCTAssertNil(sanitized.leaseExpiryMonotonic)
        XCTAssertEqual(try fixture.mode(RecoveryAuthorityStore.appliedBasename), 0o600)
        XCTAssertEqual(fixture.store.proof(), requiredProof)
        XCTAssertEqual(fixture.power.setCalls, [])

        let startup = fixture.coordinator.recover(intent: .startup, allowReconnect: true)
        XCTAssertEqual(startup, .recoveryRequired("legacy-writers-not-quiesced"))
        if case .reconnectCandidate = startup { XCTFail("retry crash boundary reconnected") }
        XCTAssertEqual(fixture.power.setCalls, [])

        XCTAssertEqual(
            fixture.coordinator.recover(
                intent: .userRestore,
            allowReconnect: false
            ),
            .terminalIdle(session, "legacy-restore")
        )
        XCTAssertEqual(fixture.store.appliedRecord(), .missing)
    }

    func testCompletedMigrationStillAllowsLegitimateNewPrivateProcessAuthority() throws {
        let fixture = try Fixture(provision: false)
        defer { fixture.dispose() }
        XCTAssertEqual(fixture.store.provisionLock(), .ready)
        let session = UUID()
        let current = Mutation.both.state(session: session, boot: Self.boot)
        try fixture.createPrivateFile(RecoveryAuthorityStore.terminalBasename, bytes: "")
        try fixture.createPrivateFile(RecoveryAuthorityStore.reservationBasename, bytes: "")
        try fixture.createPrivateFile(
            RecoveryAuthorityStore.proofBasename,
            bytes: RecoveryProof(kind: .migrated, sessionID: nil, reason: "legacy-migration").payload
        )
        try fixture.installPrivateApplied(current)
        fixture.power.prepareForOwnedMutation(.both)

        XCTAssertEqual(
            fixture.coordinator.recover(intent: .startup, allowReconnect: true),
            .reconnectCandidate(current)
        )
        XCTAssertEqual(fixture.store.appliedRecord(), .privateAuthority(current))
        XCTAssertEqual(fixture.power.setCalls, [])

        XCTAssertEqual(
            fixture.coordinator.recover(intent: .userRestore, allowReconnect: false),
            .terminalIdle(session, "user-restore-recovery")
        )
        XCTAssertEqual(fixture.store.proof()?.kind, .terminal)
        XCTAssertEqual(fixture.store.appliedRecord(), .missing)
    }

    func testMigratedCurrentTerminalSuccessIgnoresHistoricalReservationReceipt() throws {
        let fixture = try Fixture(provision: false)
        defer { fixture.dispose() }
        XCTAssertEqual(fixture.store.provisionLock(), .ready)
        let session = UUID()
        let current = Mutation.both.state(session: session, boot: Self.boot)
        try fixture.createPrivateFile(RecoveryAuthorityStore.terminalBasename, bytes: "")
        try fixture.createPrivateFile(RecoveryAuthorityStore.reservationBasename, bytes: "")
        try fixture.createPrivateFile(
            RecoveryAuthorityStore.proofBasename,
            bytes: RecoveryProof(kind: .migrated, sessionID: nil, reason: "legacy-migration").payload
        )
        try fixture.installPrivateApplied(current)
        XCTAssertTrue(fixture.record(session, in: RecoveryAuthorityStore.reservationBasename))
        fixture.power.prepareForOwnedMutation(.both)

        XCTAssertEqual(
            fixture.coordinator.recover(intent: .userRestore, allowReconnect: false),
            .terminalIdle(session, "user-restore-recovery")
        )
        XCTAssertEqual(fixture.store.proof()?.kind, .terminal)
        XCTAssertEqual(fixture.store.appliedRecord(), .missing)
    }

    func testTerminalProofReplayRemovesExactAppliedAuthorityWithoutReconnect() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let session = UUID()
        let state = Mutation.both.state(session: session, boot: Self.boot)
        try fixture.installPrivateApplied(state)
        XCTAssertTrue(fixture.record(session, in: RecoveryAuthorityStore.reservationBasename))
        fixture.power.prepareForOwnedMutation(.both)
        XCTAssertTrue(fixture.record(session, in: RecoveryAuthorityStore.terminalBasename))
        XCTAssertTrue(fixture.publishProof(.init(kind: .terminal, sessionID: session, reason: "crash-replay")))
        fixture.power.disabled = false
        fixture.power.ac = 10
        let calls = fixture.power.setCalls

        XCTAssertEqual(
            fixture.coordinator.recover(intent: .startup, allowReconnect: true),
            .terminalIdle(session, "crash-replay")
        )
        XCTAssertEqual(fixture.power.setCalls, calls, "terminal replay must never reconnect or mutate power")
        XCTAssertEqual(fixture.store.appliedRecord(), .missing)
    }

    func testReservedTerminalQuarantineReplayResumesExactRemovalWithoutReconnect() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let session = UUID()
        let state = Mutation.both.state(session: session, boot: Self.boot)
        try fixture.installPrivateApplied(state)
        XCTAssertTrue(fixture.record(session, in: RecoveryAuthorityStore.reservationBasename))
        XCTAssertTrue(fixture.record(session, in: RecoveryAuthorityStore.terminalBasename))
        XCTAssertTrue(fixture.publishProof(.init(kind: .terminal, sessionID: session, reason: "crash-replay")))
        fixture.power.disabled = false
        fixture.power.ac = 10
        try fixture.activateFault(.removalPreUnlink)
        guard case .recoveryRequired = fixture.coordinator.recover(intent: .startup, allowReconnect: true) else {
            return XCTFail("first cleanup must retain the quarantined exact authority")
        }
        try fixture.activateStore(lockTimeout: 1)
        let calls = fixture.power.setCalls
        XCTAssertEqual(
            fixture.coordinator.recover(intent: .startup, allowReconnect: true),
            .terminalIdle(session, "crash-replay")
        )
        XCTAssertEqual(fixture.power.setCalls, calls)
        XCTAssertEqual(fixture.store.appliedRecord(), .missing)
    }

    func testReservedTerminalReplayRejectsMismatchedLatestTerminalOrProofSession() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let session = UUID()
        let foreign = UUID()
        let state = Mutation.both.state(session: session, boot: Self.boot)
        try fixture.installPrivateApplied(state)
        XCTAssertTrue(fixture.record(session, in: RecoveryAuthorityStore.reservationBasename))
        XCTAssertTrue(fixture.record(foreign, in: RecoveryAuthorityStore.terminalBasename))
        XCTAssertTrue(fixture.publishProof(.init(kind: .terminal, sessionID: session, reason: "crash-replay")))
        fixture.power.disabled = false
        fixture.power.ac = 10

        guard case .recoveryRequired = fixture.coordinator.recover(intent: .startup, allowReconnect: true) else {
            return XCTFail("foreign latest terminal must never authorize reserved cleanup")
        }
        XCTAssertEqual(fixture.power.setCalls, [])
        XCTAssertNotEqual(fixture.store.appliedRecord(), .missing)
    }

    func testKnownBatteryPermitsOwnedRollbackWhileUnknownNilAndConflictingPowerFailClosed() throws {
        // Restoring our own changes is safe on a known battery source; starting
        // remains AC-only in the authority. Unknown or contradictory facts
        // still veto any mutation.
        for powerCase in PowerCase.allCases {
            let fixture = try Fixture()
            defer { fixture.dispose() }
            try fixture.installPrivateApplied(Mutation.both.state(session: UUID(), boot: Self.boot))
            fixture.power.apply(powerCase)
            fixture.power.setCalls.removeAll()

            let outcome = fixture.coordinator.recover(intent: .userRestore, allowReconnect: false)
            if powerCase == .battery {
                guard case .terminalIdle = outcome else { return XCTFail("known battery must permit owned rollback") }
                XCTAssertEqual(fixture.power.disabled, false)
                XCTAssertEqual(fixture.power.ac, 10)
            } else {
                guard case .recoveryRequired = outcome else { return XCTFail("\(powerCase) must fail closed") }
                XCTAssertEqual(fixture.power.setCalls, [])
                XCTAssertNotEqual(fixture.store.evidenceState(for: RecoveryAuthorityStore.appliedBasename), .absent)
                XCTAssertEqual(fixture.store.proof()?.kind, .recoveryRequired)
            }
        }
    }

    func testTimerSetterBoundariesPreserveExternalPositiveValues() throws {
        for lane in ["ac", "battery"] {
            let fixture = try Fixture()
            defer { fixture.dispose() }
            let session = UUID()
            let base = Mutation.both.state(session: session, boot: Self.boot)
            let state = AppliedState(
                sessionID: session,
                changedSleepDisabled: base.changedSleepDisabled,
                changedACSleep: base.changedACSleep,
                originalACSleep: base.originalACSleep,
                changedBatterySleep: true,
                originalBatterySleep: 12,
                owner: base.owner,
                leaseExpiryMonotonic: base.leaseExpiryMonotonic,
                provenance: base.provenance,
                payloadShape: .schemaFourteen
            )
            try fixture.installPrivateApplied(state)
            fixture.power.prepareForOwnedMutation(.both)
            fixture.power.battery = 0
            if lane == "ac" {
                fixture.power.skipNextACRead = true
                fixture.power.onNextACRead = { fixture.power.ac = 23 }
            } else {
                fixture.power.skipNextBatteryRead = true
                fixture.power.onNextBatteryRead = { fixture.power.battery = 24 }
            }

            guard case .recoveryRequired = fixture.coordinator.recover(intent: .userRestore, allowReconnect: false) else {
                return XCTFail("\(lane) setter race must fail closed")
            }
            XCTAssertEqual(lane == "ac" ? fixture.power.ac : fixture.power.battery, lane == "ac" ? 23 : 24)
            XCTAssertFalse(fixture.power.setCalls.contains(lane == "ac" ? "ac=10" : "battery=12"))
        }
    }

    func testMalformedDuplicateAndOversizedPrivateLedgersFailClosedWithoutPowerMutation() throws {
        let duplicate = UUID().uuidString.lowercased()
        for payload in [
            "not-a-uuid\n",
            "\(duplicate)\n\(duplicate)\n",
            String(repeating: "x", count: TerminalGenerationLedger.maximumBytes + 1),
        ] {
            let fixture = try Fixture()
            defer { fixture.dispose() }
            try fixture.replacePrivateLedger(RecoveryAuthorityStore.terminalBasename, payload: payload)
            guard case .recoveryRequired = fixture.coordinator.recover(intent: .startup, allowReconnect: false) else {
                return XCTFail("malformed ledger must fail closed")
            }
            XCTAssertEqual(fixture.power.setCalls, [])
        }
    }

    func testPublicationRemovalAndCrashFaultsUseProductionOperationsAndRetainEvidence() throws {
        for phase in RecoveryFaultPhase.allCases {
            let fixture = try Fixture()
            defer { fixture.dispose() }
            let session = UUID()
            try fixture.installPrivateApplied(Mutation.both.state(session: session, boot: Self.boot))
            fixture.power.prepareForOwnedMutation(.both)
            try fixture.activateFault(phase)

            guard case .recoveryRequired = fixture.coordinator.recover(intent: .userRestore, allowReconnect: false) else {
                return XCTFail("\(phase) must surface typed uncertainty")
            }
            XCTAssertFalse(fixture.power.setCalls.contains("sleep=1"), "\(phase) rearmed sleep")
            XCTAssertFalse(fixture.power.setCalls.contains("ac=0"), "\(phase) rearmed AC sleep")

            let appliedEvidence = fixture.store.evidenceState(for: RecoveryAuthorityStore.appliedBasename)
            let terminalEvidence = fixture.store.privateLedger(RecoveryAuthorityStore.terminalBasename)?.contains(session) == true
            let proofEvidence = fixture.store.proof() != nil
            XCTAssertTrue(appliedEvidence != .absent || (terminalEvidence && proofEvidence), "\(phase) lost all recovery evidence")

            switch phase {
            case .terminalPreRename, .terminalPostRename:
                XCTAssertEqual(fixture.power.setCalls, [], "terminal must precede power restoration")
            case .proofPreRename, .proofPostRename, .removalPreUnlink, .removalPostUnlink:
                XCTAssertEqual(fixture.power.disabled, false)
                XCTAssertEqual(fixture.power.ac, 10)
            }

            if phase == .removalPreUnlink {
                // The first attempt has crossed public->quarantine. A fresh
                // coordinator can only resume exact terminal cleanup; it must
                // not treat the quarantined parsed state as reconnectable.
                try fixture.activateStore(lockTimeout: 1)
                let calls = fixture.power.setCalls
                XCTAssertEqual(
                    fixture.coordinator.recover(intent: .startup, allowReconnect: true),
                    .terminalIdle(session, "user-restore-recovery")
                )
                XCTAssertEqual(fixture.power.setCalls, calls)
                XCTAssertEqual(fixture.store.appliedRecord(), .missing)
            }
        }
    }

    func testRepeatedCompletedRecoveryIsIdempotentThroughTerminalProof() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let session = UUID()
        try fixture.installPrivateApplied(Mutation.both.state(session: session, boot: Self.boot))
        fixture.power.prepareForOwnedMutation(.both)
        guard case .terminalIdle = fixture.coordinator.recover(intent: .userRestore, allowReconnect: false) else {
            return XCTFail("first recovery failed")
        }
        let calls = fixture.power.setCalls
        XCTAssertEqual(
            fixture.coordinator.recover(intent: .userRestore, allowReconnect: false),
            .terminalIdle(session, "user-restore-recovery")
        )
        XCTAssertEqual(fixture.power.setCalls, calls)
    }

    func testExplicitOperatorRetryCanFinishExactPersistedRecoveryRequiredStateButStartupCannotReconnectIt() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let session = UUID()
        try fixture.installPrivateApplied(Mutation.both.state(session: session, boot: Self.boot))
        fixture.power.prepareForOwnedMutation(.both)
        XCTAssertTrue(fixture.store.withTransaction {
            fixture.store.markRecoveryRequired("owned-restore-failed", $0).isVerified
        } == true)

        XCTAssertEqual(
            fixture.coordinator.recover(intent: .startup, allowReconnect: true),
            .recoveryRequired("owned-restore-failed")
        )
        XCTAssertEqual(fixture.power.setCalls, [])
        let listenerCalls = IntegerBox()
        let stoppedDaemon = HelperSessionAuthority(
            configuration: fixture.configuration,
            power: fixture.power,
            recoveryStoreFactory: { _ in fixture.store },
            timerStarter: { _ in XCTFail("persisted recovery-required must not start timer"); return NSObject() },
            recoveryCoordinatorFactory: { fixture.coordinator }
        )
        XCTAssertEqual(HelperControlService.runPreparedDaemon(authority: stoppedDaemon) {
            listenerCalls.increment()
            return 0
        }, 0)
        XCTAssertEqual(listenerCalls.value, 0)
        guard case let .terminalIdle(actual, reason) = fixture.coordinator.recover(intent: .userRestore, allowReconnect: false) else {
            return XCTFail("operator one-shot must receive one restore-only retry")
        }
        XCTAssertEqual(actual, session)
        XCTAssertEqual(reason, "user-restore-recovery")
        XCTAssertEqual(fixture.store.appliedRecord(), .missing)

        let forbidden = try Fixture()
        defer { forbidden.dispose() }
        XCTAssertEqual(
            try XCTUnwrap(forbidden.store.withTransaction {
                forbidden.coordinator.recoverWithinTransaction(
                    store: forbidden.store,
                    transaction: $0,
                    intent: .startup,
                    allowReconnect: true,
                    permitRecoveryRequiredRetry: true
                )
            }),
            .recoveryRequired("invalid-recovery-retry-mode")
        )
    }

    func testOneShotDispatchNeverConstructsDaemonPathAndDaemonDispatchesExactlyOnce() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let counts = OperationCounts()
        let operations = HelperControlServiceOperations(
            provision: { _ in counts.incrementProvision(); return .ready },
            recover: { _, _ in counts.incrementRecover(); return .terminalIdle(UUID(), "test-terminal") },
            daemon: { configuration in
                counts.incrementDaemon()
                let authority = HelperSessionAuthority(
                    configuration: configuration,
                    power: fixture.power,
                    recoveryStoreFactory: { _ in fixture.store },
                    bootIdentity: { RecoveryCoordinatorFixtureTests.boot },
                    timerStarter: { _ in counts.incrementTimer(); return NSObject() },
                    recoveryCoordinatorFactory: { fixture.coordinator }
                )
                return HelperControlService.runPreparedDaemon(authority: authority) {
                    counts.incrementListener()
                    return 0
                }
            }
        )

        let provision = Fixture.makeConfiguration(directory: fixture.sandbox.url, mode: .provisionRootStateLock)
        XCTAssertEqual(HelperControlService.run(configuration: provision, operations: operations), 0)
        XCTAssertEqual(counts.snapshot, .init(provision: 1, recover: 0, daemon: 0, timer: 0, listener: 0))

        let recover = Fixture.makeConfiguration(directory: fixture.sandbox.url, mode: .recoverOnce(.uninstall))
        XCTAssertEqual(HelperControlService.run(configuration: recover, operations: operations), 0)
        XCTAssertEqual(counts.snapshot, .init(provision: 1, recover: 1, daemon: 0, timer: 0, listener: 0))

        let daemon = Fixture.makeConfiguration(directory: fixture.sandbox.url, mode: .daemon)
        XCTAssertEqual(HelperControlService.run(configuration: daemon, operations: operations), 0)
        XCTAssertEqual(counts.snapshot, .init(provision: 1, recover: 1, daemon: 1, timer: 1, listener: 1))

        let handled = try Fixture()
        defer { handled.dispose() }
        XCTAssertTrue(handled.store.withTransaction {
            handled.store.markRecoveryRequired("owned-restore-failed", $0).isVerified
        } == true)
        let handledTimer = IntegerBox()
        let handledListener = IntegerBox()
        let handledAuthority = HelperSessionAuthority(
            configuration: handled.configuration,
            power: handled.power,
            recoveryStoreFactory: { _ in handled.store },
            timerStarter: { _ in handledTimer.increment(); return NSObject() },
            recoveryCoordinatorFactory: { handled.coordinator }
        )
        XCTAssertEqual(HelperControlService.runPreparedDaemon(authority: handledAuthority) {
            handledListener.increment()
            return 0
        }, 0)
        XCTAssertEqual(handledTimer.value, 0)
        XCTAssertEqual(handledListener.value, 0)

        let transientAuthority = HelperSessionAuthority(
            configuration: handled.configuration,
            power: handled.power,
            recoveryStoreFactory: { _ in nil },
            timerStarter: { _ in XCTFail("transient recovery must not start timer"); return NSObject() }
        )
        XCTAssertEqual(HelperControlService.runPreparedDaemon(authority: transientAuthority) {
            XCTFail("transient recovery must not start listener")
            return 0
        }, 78)

        let timerFailure = try Fixture()
        defer { timerFailure.dispose() }
        let timerFailureAuthority = HelperSessionAuthority(
            configuration: timerFailure.configuration,
            power: timerFailure.power,
            recoveryStoreFactory: { _ in timerFailure.store },
            timerStarter: { _ in nil },
            recoveryCoordinatorFactory: { timerFailure.coordinator }
        )
        XCTAssertEqual(HelperControlService.runPreparedDaemon(authority: timerFailureAuthority) {
            XCTFail("timer failure must not expose listener")
            return 0
        }, 78)

        let listenerFailure = try Fixture()
        defer { listenerFailure.dispose() }
        let listenerFailureAuthority = HelperSessionAuthority(
            configuration: listenerFailure.configuration,
            power: listenerFailure.power,
            recoveryStoreFactory: { _ in listenerFailure.store },
            timerStarter: { _ in NSObject() },
            recoveryCoordinatorFactory: { listenerFailure.coordinator }
        )
        XCTAssertEqual(HelperControlService.runPreparedDaemon(authority: listenerFailureAuthority) { 71 }, 78)
    }
}

private final class RecoveryFixturePower: HelperPowerSystem {
    var source: HelperPowerSource = .ac
    var disabled: Bool? = false
    var ac: Int? = 10
    var battery: Int? = 10
    var setCalls: [String] = []
    var onNextACRead: (() -> Void)?
    var onNextBatteryRead: (() -> Void)?
    var skipNextACRead = false
    var skipNextBatteryRead = false
    var throwBeforeSleepMutation = false
    var throwAfterSleepMutation = false

    func powerSource() -> HelperPowerSource { source }
    func sleepDisabled() -> Bool? { disabled }
    func acSleepMinutes() -> Int? {
        if skipNextACRead {
            skipNextACRead = false
            return ac
        }
        let hook = onNextACRead
        onNextACRead = nil
        hook?()
        return ac
    }
    func batterySleepMinutes() -> Int? {
        if skipNextBatteryRead {
            skipNextBatteryRead = false
            return battery
        }
        let hook = onNextBatteryRead
        onNextBatteryRead = nil
        hook?()
        return battery
    }
    func setSleepDisabled(_ enabled: Bool) throws {
        setCalls.append("sleep=\(enabled ? 1 : 0)")
        if throwBeforeSleepMutation {
            throwBeforeSleepMutation = false
            throw NSError(domain: "RecoveryFixturePower", code: 2)
        }
        disabled = enabled
        if throwAfterSleepMutation {
            throwAfterSleepMutation = false
            throw NSError(domain: "RecoveryFixturePower", code: 1)
        }
    }
    func setACSleepMinutes(_ minutes: Int) throws {
        setCalls.append("ac=\(minutes)")
        ac = minutes
    }
    func setBatterySleepMinutes(_ minutes: Int) throws {
        setCalls.append("battery=\(minutes)")
        battery = minutes
    }

    func prepareForOwnedMutation(_ mutation: Mutation) {
        source = .ac
        disabled = mutation == .ac ? false : true
        ac = mutation == .sleep ? 10 : 0
        setCalls.removeAll()
    }

    func apply(_ value: PowerCase) {
        source = .ac
        disabled = true
        ac = 0
        switch value {
        case .unknown: source = .unknown
        case .battery: source = .battery
        case .nilSleep: disabled = nil
        case .nilAC: ac = nil
        case .conflictingAC: ac = 7
        }
    }
}

private enum Mutation: CaseIterable {
    case sleep, ac, both

    var expectedAC: Int { 10 }

    func state(session: UUID, boot: String) -> AppliedState {
        let owner = AppliedState.Owner(
            pid: 1,
            startSeconds: 1,
            startMicroseconds: 0,
            asid: 1,
            euid: 0,
            bootID: boot
        )
        switch self {
        case .sleep:
            return .init(
                sessionID: session,
                changedSleepDisabled: true,
                changedACSleep: false,
                originalACSleep: nil,
                owner: owner,
                leaseExpiryMonotonic: 100,
                provenance: .current
            )
        case .ac:
            return .init(
                sessionID: session,
                changedSleepDisabled: false,
                changedACSleep: true,
                originalACSleep: 10,
                owner: owner,
                leaseExpiryMonotonic: 100,
                provenance: .current
            )
        case .both:
            return .init(
                sessionID: session,
                changedSleepDisabled: true,
                changedACSleep: true,
                originalACSleep: 10,
                owner: owner,
                leaseExpiryMonotonic: 100,
                provenance: .current
            )
        }
    }
}

private enum PowerCase: CaseIterable, Equatable { case unknown, battery, nilSleep, nilAC, conflictingAC }

private enum RecoveryFaultPhase: CaseIterable {
    case terminalPreRename
    case terminalPostRename
    case proofPreRename
    case proofPostRename
    case removalPreUnlink
    case removalPostUnlink
}

private final class RecoveryStoreBox {
    var store: RecoveryAuthorityStore
    init(_ store: RecoveryAuthorityStore) { self.store = store }
}

private final class Fixture {
    let sandbox: TestSandbox.Directory
    let configuration: HelperServiceConfiguration
    let power = RecoveryFixturePower()
    let storeBox: RecoveryStoreBox
    let coordinator: RecoveryCoordinator

    var store: RecoveryAuthorityStore { storeBox.store }

    init(
        provision: Bool = true,
        quiescenceProbe: LegacyWriterQuiescenceProbe = .fixtureQuiesced
    ) throws {
        sandbox = try TestSandbox.makeDirectory(label: "recovery")
        XCTAssertEqual(chmod(sandbox.url.path, 0o755), 0)
        let directory = try XCTUnwrap(Self.directory(at: sandbox.url, operations: .system))
        let initialStore = RecoveryAuthorityStore(
            directory: directory,
            expectedOwnerUID: getuid(),
            expectedGroupID: getgid()
        )
        storeBox = RecoveryStoreBox(initialStore)
        configuration = Self.makeConfiguration(directory: sandbox.url, mode: .daemon)
        let box = storeBox
        let fixtureDirectory = sandbox.url
        let projectionWriter: StatusProjectionDispatcher.Writer = { task, _ in
            guard let descriptor = try? TestSandbox.openManagedDirectory(at: fixtureDirectory) else {
                return .unsafeExisting
            }
            defer { close(descriptor) }
            return HelperStatusStore.writeOutcome(
                task: task,
                heldDirectoryDescriptor: descriptor,
                expectations: .init(ownerUID: getuid(), groupID: getgid(), mode: 0o755)
            )
        }
        coordinator = RecoveryCoordinator(
            configuration: configuration,
            power: power,
            bootIdentity: { RecoveryCoordinatorFixtureTests.boot },
            storeFactory: { _ in box.store },
            quiescenceProbe: quiescenceProbe,
            statusProjectionWriter: projectionWriter
        )
        if provision {
            XCTAssertEqual(coordinator.provision(), .ready)
            XCTAssertEqual(
                coordinator.recover(
                    intent: .install,
                    allowReconnect: false
                ),
                .pristineIdle
            )
            XCTAssertEqual(coordinator.recover(intent: .startup, allowReconnect: true), .pristineIdle)
        }
    }

    static func makeConfiguration(
        directory: URL,
        mode: HelperServiceConfiguration.Mode
    ) -> HelperServiceConfiguration {
        .init(
            expectedOwnerUID: getuid(),
            qualifiedBuild: "25F84",
            supportDirectory: directory.path,
            appliedStatePath: directory.appendingPathComponent(RecoveryAuthorityStore.appliedBasename).path,
            statusPath: directory.appendingPathComponent("helper-status").path,
            policyPath: directory.appendingPathComponent("policy").path,
            mode: mode
        )
    }

    /// Status projection tests receive the fixture directory through the same
    /// sealed execution-root boundary as the root-state store. The production
    /// writer's pathname intake is deliberately not used here: it would reopen
    /// sandbox-denied `/private/tmp` ancestors rather than exercise the held
    /// descriptor-relative projection protocol.
    func statusWriteOutcome(
        task: StatusProjectionTask,
        stageGate: (HelperStatusStore.WriteStage) -> Bool = { _ in true },
        recoveryGate: (HelperStatusStore.RecoveryStage) -> Bool = { _ in true }
    ) -> HelperStatusStore.WriteOutcome {
        guard let descriptor = try? TestSandbox.openManagedDirectory(at: sandbox.url) else {
            return .unsafeExisting
        }
        defer { close(descriptor) }
        return HelperStatusStore.writeOutcome(
            task: task,
            heldDirectoryDescriptor: descriptor,
            expectations: .init(ownerUID: getuid(), groupID: getgid(), mode: 0o755),
            stageGate: stageGate,
            recoveryGate: recoveryGate
        )
    }

    func writeStatus(
        task: StatusProjectionTask,
        stageGate: (HelperStatusStore.WriteStage) -> Bool = { _ in true },
        recoveryGate: (HelperStatusStore.RecoveryStage) -> Bool = { _ in true }
    ) -> Bool {
        guard let descriptor = try? TestSandbox.openManagedDirectory(at: sandbox.url) else {
            return false
        }
        defer { close(descriptor) }
        return HelperStatusStore.write(
            task: task,
            heldDirectoryDescriptor: descriptor,
            expectations: .init(ownerUID: getuid(), groupID: getgid(), mode: 0o755),
            stageGate: stageGate,
            recoveryGate: recoveryGate
        )
    }

    func waitForStatusProjectionDrain(timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let remaining = max(0, deadline.timeIntervalSinceNow)
            if StatusProjectionDispatcher.waitForIdleForTesting(timeout: remaining),
               store.statusProjectionTaskRecord() == .absent,
               store.withTransaction({ _ in true }) == true,
               StatusProjectionDispatcher.waitForIdleForTesting(timeout: max(0, deadline.timeIntervalSinceNow)),
               store.statusProjectionTaskRecord() == .absent {
                return true
            }
            usleep(1_000)
        } while Date() < deadline
        return false
    }

    func dispose() { try? FileManager.default.removeItem(at: sandbox.url) }

    func installPrivateApplied(_ state: AppliedState) throws {
        XCTAssertTrue(try XCTUnwrap(store.withTransaction { store.publishApplied(state, $0).isVerified }))
    }

    func installLegacyApplied(_ state: AppliedState) throws {
        try createLegacyFile(RecoveryAuthorityStore.appliedBasename, bytes: state.storagePayload)
    }

    func createLegacyFile(
        _ basename: String,
        bytes: String,
        mode: mode_t = 0o644
    ) throws {
        let path = sandbox.url.appendingPathComponent(basename).path
        guard FileManager.default.createFile(atPath: path, contents: Data(bytes.utf8)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard chmod(path, mode) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    func createPrivateFile(_ basename: String, bytes: String) throws {
        let path = sandbox.url.appendingPathComponent(basename).path
        guard FileManager.default.createFile(atPath: path, contents: Data(bytes.utf8)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard chmod(path, 0o600) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    func replacePrivateLedger(_ basename: String, payload: String) throws {
        try replacePrivateFile(basename, payload: payload)
    }

    func replacePrivateFile(_ basename: String, payload: String) throws {
        let published = try XCTUnwrap(store.withTransaction {
            $0.publish(Data(payload.utf8), to: basename, parser: { _ in true })
        })
        guard published == .published else { throw CocoaError(.fileWriteUnknown) }
    }

    func record(_ session: UUID, in basename: String) -> Bool {
        store.withTransaction {
            store.recordTerminal(session, into: basename, transaction: $0).isVerified
        } == true
    }

    func publishProof(_ proof: RecoveryProof) -> Bool {
        store.withTransaction { store.publishProof(proof, $0).isVerified } == true
    }

    func readBytes(_ basename: String) throws -> String {
        try String(contentsOf: sandbox.url.appendingPathComponent(basename), encoding: .utf8)
    }

    func mode(_ basename: String) throws -> mode_t {
        var status = stat()
        guard lstat(sandbox.url.appendingPathComponent(basename).path, &status) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return status.st_mode & 0o7777
    }

    func activateFault(_ phase: RecoveryFaultPhase) throws {
        let operations = FaultOperations(phase: phase).operations
        let directory = try XCTUnwrap(Self.directory(at: sandbox.url, operations: operations))
        storeBox.store = RecoveryAuthorityStore(
            directory: directory,
            expectedOwnerUID: getuid(),
            expectedGroupID: getgid()
        )
    }

    func activateStore(lockTimeout: TimeInterval) throws {
        let directory = try XCTUnwrap(Self.directory(at: sandbox.url, operations: .system))
        storeBox.store = RecoveryAuthorityStore(
            directory: directory,
            expectedOwnerUID: getuid(),
            expectedGroupID: getgid(),
            lockTimeout: lockTimeout,
            lockNow: { 1 }
        )
    }

    func activateFileOperations(_ fileOperations: RecoveryAuthorityFileOperations) throws {
        let directory = try XCTUnwrap(Self.directory(at: sandbox.url, operations: .system))
        storeBox.store = RecoveryAuthorityStore(
            directory: directory,
            expectedOwnerUID: getuid(),
            expectedGroupID: getgid(),
            fileOperations: fileOperations
        )
    }

    private static func directory(
        at url: URL,
        operations: VerifiedRootStateDirectory.Operations
    ) -> VerifiedRootStateDirectory? {
        guard let descriptor = try? TestSandbox.openManagedDirectory(at: url) else { return nil }
        defer { close(descriptor) }
        return VerifiedRootStateDirectory(
            heldDirectoryDescriptor: descriptor,
            expectations: .init(ownerUID: getuid(), groupID: getgid(), mode: 0o755),
            operations: operations
        )
    }
}

private final class FaultOperations {
    private enum Event { case none, terminalRename, proofRename, removalRename, removalUnlink }
    private let phase: RecoveryFaultPhase
    private var event: Event = .none

    init(phase: RecoveryFaultPhase) { self.phase = phase }

    var operations: VerifiedRootStateDirectory.Operations {
        .init(
            fileBarrier: { _ in true },
            directoryEntryBarrier: { [self] _ in
                defer { event = .none }
                switch (phase, event) {
                case (.terminalPostRename, .terminalRename),
                     (.proofPostRename, .proofRename),
                     (.removalPostUnlink, .removalUnlink):
                    return false
                default:
                    return true
                }
            },
            rename: { [self] oldFD, oldName, newFD, newName in
                if phase == .terminalPreRename, newName == RecoveryAuthorityStore.terminalBasename {
                    errno = EIO
                    return -1
                }
                if phase == .proofPreRename, newName == RecoveryAuthorityStore.proofBasename {
                    errno = EIO
                    return -1
                }
                let result = Darwin.renameat(oldFD, oldName, newFD, newName)
                if result == 0 {
                    if newName == RecoveryAuthorityStore.terminalBasename { event = .terminalRename }
                    if newName == RecoveryAuthorityStore.proofBasename { event = .proofRename }
                }
                return result
            },
            unlink: { [self] fd, name in
                let quarantine = VerifiedRootStateDirectory.quarantineBasename(
                    for: RecoveryAuthorityStore.appliedBasename
                )
                if name == quarantine, phase == .removalPreUnlink {
                    errno = EIO
                    return -1
                }
                let result = Darwin.unlinkat(fd, name, 0)
                if result == 0, name == quarantine { event = .removalUnlink }
                return result
            },
            renameExclusive: { [self] oldFD, oldName, newFD, newName in
                let result = Darwin.renameatx_np(oldFD, oldName, newFD, newName, UInt32(RENAME_EXCL))
                if result == 0,
                   oldName == RecoveryAuthorityStore.appliedBasename,
                   newName == VerifiedRootStateDirectory.quarantineBasename(for: RecoveryAuthorityStore.appliedBasename) {
                    event = .removalRename
                }
                return result
            }
        )
    }
}

private final class OperationCounts {
    struct Snapshot: Equatable {
        let provision: Int
        let recover: Int
        let daemon: Int
        let timer: Int
        let listener: Int
    }

    private let lock = NSLock()
    private var provision = 0
    private var recover = 0
    private var daemon = 0
    private var timer = 0
    private var listener = 0

    func incrementProvision() { lock.lock(); provision += 1; lock.unlock() }
    func incrementRecover() { lock.lock(); recover += 1; lock.unlock() }
    func incrementDaemon() { lock.lock(); daemon += 1; lock.unlock() }
    func incrementTimer() { lock.lock(); timer += 1; lock.unlock() }
    func incrementListener() { lock.lock(); listener += 1; lock.unlock() }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return .init(provision: provision, recover: recover, daemon: daemon, timer: timer, listener: listener)
    }
}

private final class IntegerBox {
    private let lock = NSLock()
    private var storage = 0

    func increment() { lock.lock(); storage += 1; lock.unlock() }
    func set(_ value: Int) { lock.lock(); storage = value; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
}
