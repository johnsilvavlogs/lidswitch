import Darwin
import Foundation
import XCTest
@testable import LidSwitchCore

/// These fixtures exercise the production collector, reducer and receipt
/// transitions without spawning, signaling or observing a live process.
final class ContainedProcessRecoveryRegressionTests: XCTestCase {
    private let owner = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
    private let leader = ContainedProcessIdentity(pid: 41, startSeconds: 100, startMicroseconds: 7)
    private let fingerprint = "0123456789abcdef"

    private func receipt(
        root: UInt64 = 10,
        cleanup: UInt64 = 100,
        schema: Int = 5,
        members: [ContainedProcessMember]? = nil
    ) -> ContainedProcessReceipt {
        .init(token: UUID(), executable: "/usr/bin/pmset", commandFingerprint: fingerprint,
              leader: leader,
              members: members ?? [.init(identity: leader, executable: "/usr/bin/pmset", commandFingerprint: fingerprint)],
              processGroupID: leader.pid, sessionID: 9,
              rootDeadlineNanoseconds: root, cleanupDeadlineNanoseconds: cleanup, schema: schema)
    }

    private func evidence(_ identity: ContainedProcessIdentity? = nil) -> ContainedProcessRunner.CleanupProcessEvidence {
        .present(identity ?? leader, processGroup: leader.pid, session: 9)
    }

    private func action(
        _ receipt: ContainedProcessReceipt,
        now: UInt64,
        observation: ContainedProcessCleanupMachine.Observation
    ) -> ContainedProcessCleanupMachine.Action {
        ContainedProcessCleanupMachine.next(receipt: receipt, owner: owner, now: now, observation: observation)
    }

    func testNewCommandDeadlinesUseContinuousClockAfterAccumulatedSleep() throws {
        let uptimeSeconds = 100.0
        let accumulatedSleepSeconds = 36_000.0
        let continuousSeconds = uptimeSeconds + accumulatedSleepSeconds
        let now = ContainedProcessRunner.containmentNowNanoseconds(continuousSeconds: continuousSeconds)
        let deadlines = ContainedProcessRunner.containmentDeadlines(timeout: 2, continuousSeconds: continuousSeconds)
        XCTAssertEqual(deadlines.root, now + 2_000_000_000)
        XCTAssertEqual(deadlines.cleanup, now + 7_000_000_000)
        XCTAssertGreaterThan(now, UInt64((uptimeSeconds + 7) * 1_000_000_000), "the historical uptime deadline would already have expired")

        // Early output/I/O failure can transfer before command timeout. Its
        // shorter owner lease remains independently valid and serializable.
        let claimed = try XCTUnwrap(receipt(root: deadlines.root, cleanup: deadlines.cleanup)
            .claimed(by: owner, until: now + 500_000_000))
        XCTAssertEqual(claimed.schema, 5)
        XCTAssertEqual(ContainedProcessReceipt.parse(claimed.storagePayload), claimed)
        XCTAssertEqual(action(claimed, now: now, observation: .liveExact), .signalTERM)
    }

    func testSchemaFiveRequiresItsClockAndFixedEscalationRecord() throws {
        let pending = receipt()
        XCTAssertEqual(ContainedProcessReceipt.parse(pending.storagePayload), pending)
        XCTAssertTrue(pending.storagePayload.hasPrefix("schema=5\n"))
        XCTAssertNil(ContainedProcessReceipt.parse(pending.storagePayload.replacingOccurrences(of: "term_escalation_deadline=0\n", with: "")))
        XCTAssertNil(ContainedProcessReceipt.parse(pending.storagePayload.replacingOccurrences(of: "term_escalation_deadline=0", with: "term_escalation_deadline=1")))
        XCTAssertNil(ContainedProcessReceipt.parse(pending.storagePayload.replacingOccurrences(of: "schema=5", with: "schema=4")))
        XCTAssertNil(ContainedProcessReceipt.parse(pending.storagePayload.replacingOccurrences(of: "schema=5", with: "schema=05")))
        XCTAssertNil(ContainedProcessReceipt.parse(pending.storagePayload.replacingOccurrences(of: "deadline_clock=continuous", with: "deadline_clock=uptime")))
        XCTAssertNil(ContainedProcessReceipt.parse(pending.storagePayload.replacingOccurrences(of: "exited_reap_attempted=0", with: "exited_reap_attempted=1")))
        let claimed = try XCTUnwrap(pending.claimed(by: owner, until: 50))
        XCTAssertNil(ContainedProcessReceipt.parse(claimed.storagePayload.replacingOccurrences(of: "term_escalation_deadline=50", with: "term_escalation_deadline=101")))
        XCTAssertNil(ContainedProcessReceipt.parse(claimed.storagePayload + "unknown=1\n"))
    }

    func testLegacyMixedClockReceiptNeverRegainsSignalAuthority() throws {
        let legacy = receipt(schema: 4)
        XCTAssertEqual(ContainedProcessReceipt.parse(legacy.storagePayload), legacy)
        XCTAssertFalse(legacy.storagePayload.contains("term_escalation_deadline="))
        let claimed = try XCTUnwrap(legacy.claimed(by: owner, until: 50))
        XCTAssertEqual(action(claimed, now: 20, observation: .liveExact), .retainFence)
        XCTAssertNil(claimed.markingTermSignalIssued(owner: owner, deadline: 50))
        let ambiguous = try XCTUnwrap(claimed.advancing(to: .ambiguous, owner: owner, deadline: 50))
        let reclaimed = try XCTUnwrap(ambiguous.reclaimedAmbiguousForExtinctionProof(by: owner, now: 120, until: 150))
        XCTAssertEqual(reclaimed.schema, 4)
        XCTAssertEqual(reclaimed.termEscalationDeadlineNanoseconds, 0)
        XCTAssertEqual(ContainedProcessReceipt.parse(reclaimed.storagePayload), reclaimed)
        XCTAssertEqual(action(reclaimed, now: 120, observation: .liveExact), .retainFence)
        XCTAssertEqual(action(reclaimed, now: 120, observation: .exitedDirectChildExact), .reapLeader)
        let attempted = try XCTUnwrap(reclaimed.recordingReapAttempt(owner: owner, deadline: 150))
        let reaped = try XCTUnwrap(attempted.markingLeaderReaped(owner: owner, deadline: 150))
        let extinct = try XCTUnwrap(reaped.advancing(to: .extinguished, owner: owner, deadline: 150))
        for copy in [claimed, ambiguous, reclaimed, attempted, reaped, extinct] {
            XCTAssertEqual(copy.schema, 4)
            XCTAssertEqual(ContainedProcessReceipt.parse(copy.storagePayload), copy)
        }
    }

    func testExactExitedDirectChildDoesNotRequireExecutableOrArgv() throws {
        let claimed = try XCTUnwrap(receipt().claimed(by: owner, until: 50))
        var fingerprintReads = 0
        var inventoryReads = 0
        let observed = ContainedProcessRunner.cleanupObservation(
            claimed, inspectProcess: { _ in self.evidence() },
            fingerprint: { _, _ in fingerprintReads += 1; return nil },
            exitedChild: { _ in .exitedExact },
            inventory: { inventoryReads += 1; return .exact([self.leader]) }
        )
        XCTAssertEqual(observed, .exitedDirectChildExact)
        XCTAssertEqual(fingerprintReads, 0, "the zombie exception relies on exact birth and parent-owned wait status")
        XCTAssertEqual(inventoryReads, 2)
        XCTAssertEqual(action(claimed, now: 20, observation: observed), .reapLeader)
    }

    func testZombieBSDInfoRetainsBirthAndParentWithoutArgvGroupOrSessionCalls() throws {
        var info = proc_bsdinfo()
        info.pbi_pid = UInt32(leader.pid)
        info.pbi_ppid = UInt32(getpid())
        info.pbi_pgid = 0 // Darwin may have detached the exited process group.
        info.pbi_status = UInt32(SZOMB)
        info.pbi_start_tvsec = UInt64(leader.startSeconds)
        info.pbi_start_tvusec = UInt64(leader.startMicroseconds)
        let zombie = ContainedProcessRunner.cleanupBSDInfoEvidence(
            leader.pid, info: info,
            group: { XCTFail("getpgid excludes zombie lookup"); return -1 },
            session: { XCTFail("getsid excludes zombie lookup"); return -1 }
        )
        XCTAssertEqual(zombie, .exited(leader, parent: getpid(), processGroup: 0))
        let claimed = try XCTUnwrap(receipt().claimed(by: owner, until: 50))
        let observed = ContainedProcessRunner.cleanupObservation(
            claimed, inspectProcess: { _ in zombie },
            fingerprint: { _, _ in XCTFail("an exact exited child does not require argv"); return nil },
            exitedChild: { receipt in
                ContainedProcessRunner.leaderExitObservation(
                    receipt, inspectProcess: { _ in zombie },
                    waitExitedNoHang: { pid in (0, 0, pid, CLD_EXITED) }
                )
            }, inventory: { .exact([]) }
        )
        XCTAssertEqual(observed, .exitedDirectChildExact)
        XCTAssertEqual(action(claimed, now: 20, observation: observed), .reapLeader)
        XCTAssertNotEqual(observed, .leaderReapedAndExtinct, "a zombie outside the PGID list is still present")
        info.pbi_start_tvusec = 1_000_000
        XCTAssertEqual(ContainedProcessRunner.cleanupBSDInfoEvidence(
            leader.pid, info: info, group: { 41 }, session: { 9 }
        ), .unknown)
    }

    func testExpiredAmbiguousExactChildCanReapWithoutSignalAndNeedsFreshExtinction() throws {
        let claimed = try XCTUnwrap(receipt().claimed(by: owner, until: 50))
        let ambiguous = try XCTUnwrap(claimed.advancing(to: .ambiguous, owner: owner, deadline: 50))
        let reclaimed = try XCTUnwrap(ambiguous.reclaimedAmbiguousForExtinctionProof(by: owner, now: 120, until: 150))
        XCTAssertEqual(action(reclaimed, now: 120, observation: .liveExact), .retainFence)
        XCTAssertEqual(action(reclaimed, now: 120, observation: .exitedDirectChildExact), .reapLeader)
        let attempted = try XCTUnwrap(reclaimed.recordingReapAttempt(owner: owner, deadline: 150))
        XCTAssertEqual(attempted.phase, .ambiguous)
        XCTAssertEqual(attempted.reapAttemptCount, 1)
        XCTAssertEqual(ContainedProcessReceipt.parse(attempted.storagePayload), attempted)
        var waits = 0
        let outcome = ContainedProcessRunner.reapLeaderOutcome(
            attempted, now: 120, observeExitedChild: { _ in .exitedExact },
            waitNoHang: { pid in waits += 1; return (pid, 0) }
        )
        XCTAssertEqual(outcome, .reaped)
        XCTAssertEqual(waits, 1)
        let reaped = try XCTUnwrap(attempted.markingLeaderReaped(owner: owner, deadline: 150))
        XCTAssertEqual(reaped.phase, .ambiguous, "waitpid alone must not retire the receipt")
        XCTAssertEqual(action(reaped, now: 121, observation: .incompleteInventory), .retainFence)

        var inventoryReads = 0
        let fresh = ContainedProcessRunner.cleanupObservation(
            reaped, inspectProcess: { _ in .absent }, fingerprint: { _, _ in nil },
            exitedChild: { _ in XCTFail("absent members must not be reaped again"); return .identityUnproven },
            inventory: { inventoryReads += 1; return .exact([]) }
        )
        XCTAssertEqual(inventoryReads, 2)
        XCTAssertEqual(fresh, .leaderReapedAndExtinct)
        XCTAssertEqual(action(reaped, now: 121, observation: fresh), .extinguished)
        XCTAssertNotNil(reaped.advancing(to: .extinguished, owner: owner, deadline: 150))
    }

    func testExpiredTermAndKillPermitOnlyExactExitedReap() throws {
        let claimed = try XCTUnwrap(receipt().claimed(by: owner, until: 50))
        let term = try XCTUnwrap(claimed.markingTermSignalIssued(owner: owner, deadline: 50))
        let kill = try XCTUnwrap(term.advancing(to: .kill, owner: owner, deadline: 50))
        for original in [term, kill] {
            let reclaimed = try XCTUnwrap(original.reclaimed(by: owner, now: 120, until: 150))
            XCTAssertEqual(action(reclaimed, now: 120, observation: .liveExact), .retainFence)
            XCTAssertEqual(action(reclaimed, now: 120, observation: .exitedDirectChildExact), .reapLeader)
        }
        XCTAssertEqual(action(term, now: 50, observation: .exitedDirectChildExact), .retainFence, "an expired owner cannot consume wait status")
        XCTAssertEqual(ContainedProcessCleanupMachine.next(receipt: term, owner: UUID(), now: 20, observation: .exitedDirectChildExact), .retainFence)
    }

    func testReapRequiresPersistedAttemptAndFreshExitedChildProof() throws {
        let claimed = try XCTUnwrap(receipt().claimed(by: owner, until: 50))
        var waitCalls = 0
        XCTAssertEqual(ContainedProcessRunner.reapLeaderOutcome(
            claimed, now: 20, observeExitedChild: { _ in .exitedExact },
            waitNoHang: { pid in waitCalls += 1; return (pid, 0) }
        ), .identityUnproven)
        XCTAssertEqual(waitCalls, 0)
        let attempted = try XCTUnwrap(claimed.recordingReapAttempt(owner: owner, deadline: 50))
        let failures: [(ContainedProcessRunner.LeaderExitObservation, ContainedProcessRunner.LeaderReapOutcome)] = [
            (.notExited, .live), (.notChild, .echild), (.identityUnproven, .identityUnproven),
            (.interruptedLimit, .interruptedLimit), (.failed(EIO), .failed(EIO)),
        ]
        for (observation, expected) in failures {
            XCTAssertEqual(ContainedProcessRunner.reapLeaderOutcome(
                attempted, now: 20, observeExitedChild: { _ in observation },
                waitNoHang: { pid in waitCalls += 1; return (pid, 0) }
            ), expected)
        }
        XCTAssertEqual(waitCalls, 0, "unproven child identity never reaches consuming waitpid")
        XCTAssertEqual(ContainedProcessRunner.reapLeaderOutcome(
            attempted, now: 20, observeExitedChild: { _ in .exitedExact },
            waitNoHang: { _ in (-1, ECHILD) }
        ), .echild)
        XCTAssertFalse(attempted.leaderReaped, "ECHILD cannot set the leader closure latch")
        XCTAssertEqual(ContainedProcessRunner.reapLeaderOutcome(
            attempted, now: 50, observeExitedChild: { _ in .exitedExact },
            waitNoHang: { pid in waitCalls += 1; return (pid, 0) }
        ), .identityUnproven)
        XCTAssertEqual(waitCalls, 0)
    }

    func testWaitidProofIsNonconsumingBirthBoundAndInterruptBounded() {
        let base = receipt()
        let exact = evidence()
        var calls = 0
        XCTAssertEqual(ContainedProcessRunner.leaderExitObservation(
            base, inspectProcess: { _ in exact },
            waitExitedNoHang: { pid in
                calls += 1
                return calls == 1 ? (-1, EINTR, 0, 0) : (0, 0, pid, CLD_EXITED)
            }
        ), .exitedExact)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(ContainedProcessRunner.leaderExitObservation(
            base, inspectProcess: { _ in exact }, waitExitedNoHang: { _ in (-1, ECHILD, 0, 0) }
        ), .notChild)
        XCTAssertEqual(ContainedProcessRunner.leaderExitObservation(
            base, inspectProcess: { _ in exact }, waitExitedNoHang: { _ in (0, 0, 0, 0) }
        ), .notExited)
        XCTAssertEqual(ContainedProcessRunner.leaderExitObservation(
            base, inspectProcess: { _ in exact }, waitExitedNoHang: { pid in (0, 0, pid, CLD_STOPPED) }
        ), .identityUnproven)
        var identityReads = 0
        let reused = ContainedProcessIdentity(pid: leader.pid, startSeconds: 101, startMicroseconds: 7)
        XCTAssertEqual(ContainedProcessRunner.leaderExitObservation(
            base, inspectProcess: { _ in identityReads += 1; return identityReads == 1 ? exact : self.evidence(reused) },
            waitExitedNoHang: { pid in (0, 0, pid, CLD_EXITED) }
        ), .identityUnproven)
        calls = 0
        XCTAssertEqual(ContainedProcessRunner.leaderExitObservation(
            base, maximumInterrupts: 2, inspectProcess: { _ in exact },
            waitExitedNoHang: { _ in calls += 1; return (-1, EINTR, 0, 0) }
        ), .interruptedLimit)
        XCTAssertEqual(calls, 3)
    }

    func testReusedUnknownNonchildAndMismatchedLeaderRemainFenced() throws {
        let claimed = try XCTUnwrap(receipt().claimed(by: owner, until: 50))
        let reused = ContainedProcessIdentity(pid: leader.pid, startSeconds: 101, startMicroseconds: 7)
        let cases: [(ContainedProcessRunner.CleanupProcessEvidence, ContainedProcessRunner.LeaderExitObservation, ContainedProcessCleanupMachine.Observation)] = [
            (evidence(reused), .exitedExact, .memberReusedOrUnknown),
            (.unknown, .exitedExact, .memberReusedOrUnknown),
            (evidence(), .notChild, .memberReusedOrUnknown),
            (.exited(leader, parent: getpid() + 1, processGroup: leader.pid), .exitedExact, .memberReusedOrUnknown),
            (.exited(leader, parent: getpid(), processGroup: 42), .exitedExact, .groupOrSessionMismatch),
            (evidence(), .failed(EIO), .memberReusedOrUnknown),
            (.present(leader, processGroup: 42, session: 9), .exitedExact, .groupOrSessionMismatch),
            (.present(leader, processGroup: leader.pid, session: 10), .exitedExact, .groupOrSessionMismatch),
        ]
        for (process, exit, expected) in cases {
            let observed = ContainedProcessRunner.cleanupObservation(
                claimed, inspectProcess: { _ in process }, fingerprint: { _, _ in nil },
                exitedChild: { _ in exit }, inventory: { .exact([self.leader]) }
            )
            XCTAssertEqual(observed, expected)
            XCTAssertEqual(action(claimed, now: 20, observation: observed), .retainFence)
        }
    }

    func testUnexpectedMemberIncompleteOrChangingInventoryBlocksExitedChildReap() throws {
        let claimed = try XCTUnwrap(receipt().claimed(by: owner, until: 50))
        let unexpected = ContainedProcessIdentity(pid: 42, startSeconds: 101, startMicroseconds: 1)
        let inventories: [[ContainedProcessRunner.CleanupInventoryEvidence]] = [
            [.exact([leader, unexpected]), .exact([leader, unexpected])],
            [.indeterminate, .indeterminate],
            [.exact([leader]), .exact([])],
        ]
        for values in inventories {
            var index = 0
            let observed = ContainedProcessRunner.cleanupObservation(
                claimed, inspectProcess: { _ in self.evidence() }, fingerprint: { _, _ in nil },
                exitedChild: { _ in .exitedExact },
                inventory: { defer { index += 1 }; return values[index] }
            )
            XCTAssertEqual(observed, .incompleteInventory)
            XCTAssertEqual(action(claimed, now: 20, observation: observed), .retainFence)
        }
    }

    func testReapedLeaderWithSurvivingRecordedMemberDoesNotProveExtinction() throws {
        let descendant = ContainedProcessIdentity(pid: 42, startSeconds: 101, startMicroseconds: 1)
        let members = [
            ContainedProcessMember(identity: leader, executable: "/usr/bin/pmset", commandFingerprint: fingerprint),
            ContainedProcessMember(identity: descendant, executable: "/bin/launchctl", commandFingerprint: "fedcba9876543210"),
        ]
        let claimed = try XCTUnwrap(receipt(members: members).claimed(by: owner, until: 50))
        let ambiguous = try XCTUnwrap(claimed.advancing(to: .ambiguous, owner: owner, deadline: 50))
        let attempted = try XCTUnwrap(ambiguous.recordingReapAttempt(owner: owner, deadline: 50))
        let reaped = try XCTUnwrap(attempted.markingLeaderReaped(owner: owner, deadline: 50))
        let observed = ContainedProcessRunner.cleanupObservation(
            reaped,
            inspectProcess: { $0 == self.leader.pid ? .absent : self.evidence(descendant) },
            fingerprint: { _, _ in "fedcba9876543210" },
            exitedChild: { _ in XCTFail("reaped leader must not receive another wait probe"); return .identityUnproven },
            inventory: { .exact([descendant]) }
        )
        XCTAssertEqual(observed, .liveExact)
        XCTAssertEqual(action(reaped, now: 20, observation: observed), .retainFence)
    }

    func testRenewedOwnerCannotPostponeFixedTermEscalationEvenBeforeRootDeadline() throws {
        let claimed = try XCTUnwrap(receipt(root: 1_000, cleanup: 2_000).claimed(by: owner, until: 50))
        let issued = try XCTUnwrap(claimed.markingTermSignalIssued(owner: owner, deadline: 50))
        XCTAssertEqual(issued.termEscalationDeadlineNanoseconds, 50)
        XCTAssertEqual(action(issued, now: 49, observation: .liveExact), .reapLeader)
        XCTAssertEqual(action(issued, now: 50, observation: .liveExact), .retainFence, "the expired owner has no signal authority")
        let renewed = try XCTUnwrap(issued.reclaimed(by: owner, now: 51, until: 100))
        XCTAssertEqual(renewed.ownerDeadlineNanoseconds, 100)
        XCTAssertEqual(renewed.termEscalationDeadlineNanoseconds, 50)
        XCTAssertEqual(ContainedProcessReceipt.parse(renewed.storagePayload), renewed)
        XCTAssertEqual(action(renewed, now: 51, observation: .liveExact), .signalKILL)
        let killing = try XCTUnwrap(renewed.advancing(to: .kill, owner: owner, deadline: 100))
        let killIssued = try XCTUnwrap(killing.markingKillSignalIssued(owner: owner, deadline: 100))
        let secondRenewal = try XCTUnwrap(killIssued.reclaimed(by: owner, now: 101, until: 150))
        XCTAssertEqual(secondRenewal.termEscalationDeadlineNanoseconds, 50)
        XCTAssertEqual(secondRenewal.phase, .kill)
        XCTAssertEqual(action(secondRenewal, now: 101, observation: .liveExact), .reapLeader, "committed KILL is never emitted again")
    }

    func testAmbiguousReapAttemptCapRemainsPersistedAndBounded() throws {
        let claimed = try XCTUnwrap(receipt().claimed(by: owner, until: 50))
        var current = try XCTUnwrap(claimed.advancing(to: .ambiguous, owner: owner, deadline: 50))
        for count in UInt8(1)...UInt8(8) {
            current = try XCTUnwrap(current.recordingReapAttempt(owner: owner, deadline: 50))
            XCTAssertEqual(current.reapAttemptCount, count)
            XCTAssertEqual(ContainedProcessReceipt.parse(current.storagePayload), current)
        }
        XCTAssertEqual(action(current, now: 20, observation: .exitedDirectChildExact), .reapLeader)
        let finalAttempt = try XCTUnwrap(current.recordingReapAttempt(owner: owner, deadline: 50))
        XCTAssertEqual(finalAttempt.reapAttemptCount, 8)
        XCTAssertTrue(finalAttempt.exitedLeaderReapAttempted)
        XCTAssertEqual(ContainedProcessReceipt.parse(finalAttempt.storagePayload), finalAttempt)
        XCTAssertNil(finalAttempt.recordingReapAttempt(owner: owner, deadline: 50))
        XCTAssertEqual(action(finalAttempt, now: 20, observation: .exitedDirectChildExact), .retainFence)
        XCTAssertEqual(action(finalAttempt, now: 20, observation: .leaderReapedAndExtinct), .extinguished, "exhausted reap attempts cannot block a separate full kernel absence proof")
    }

    func testLegacyEightPollFenceHasOnePersistedExitedChildReapWithoutClockUpgradeAuthority() throws {
        let claimed = try XCTUnwrap(receipt(schema: 4).claimed(by: owner, until: 50))
        var historical = try XCTUnwrap(claimed.advancing(to: .ambiguous, owner: owner, deadline: 50))
        for _ in 0..<8 {
            historical = try XCTUnwrap(historical.recordingReapAttempt(owner: owner, deadline: 50))
        }
        XCTAssertEqual(historical.schema, 4)
        XCTAssertEqual(historical.reapAttemptCount, 8)
        XCTAssertEqual(ContainedProcessReceipt.parse(historical.storagePayload), historical)
        let reclaimed = try XCTUnwrap(historical.reclaimedAmbiguousForExtinctionProof(by: owner, now: 120, until: 150))
        XCTAssertEqual(action(reclaimed, now: 120, observation: .liveExact), .retainFence)
        XCTAssertEqual(action(reclaimed, now: 120, observation: .exitedDirectChildExact), .reapLeader)
        let attempted = try XCTUnwrap(reclaimed.recordingReapAttempt(owner: owner, deadline: 150))
        XCTAssertEqual(attempted.schema, 5)
        XCTAssertEqual(attempted.deadlineClock, .legacyMixed)
        XCTAssertEqual(attempted.reapAttemptCount, 8, "the historical poll budget must not be reset or raised")
        XCTAssertTrue(attempted.exitedLeaderReapAttempted)
        XCTAssertEqual(ContainedProcessReceipt.parse(attempted.storagePayload), attempted)
        XCTAssertEqual(action(attempted, now: 120, observation: .liveExact), .retainFence)
        XCTAssertNil(attempted.markingTermSignalIssued(owner: owner, deadline: 150))
        XCTAssertNil(attempted.markingKillSignalIssued(owner: owner, deadline: 150))
        var waits = 0
        XCTAssertEqual(ContainedProcessRunner.reapLeaderOutcome(
            attempted, now: 120, observeExitedChild: { _ in .exitedExact },
            waitNoHang: { pid in waits += 1; return (pid, 0) }
        ), .reaped)
        XCTAssertEqual(waits, 1)
        let reaped = try XCTUnwrap(attempted.markingLeaderReaped(owner: owner, deadline: 150))
        XCTAssertEqual(reaped.deadlineClock, .legacyMixed)
        XCTAssertEqual(ContainedProcessReceipt.parse(reaped.storagePayload), reaped)
        let extinction = ContainedProcessRunner.cleanupObservation(
            reaped, inspectProcess: { _ in .absent }, fingerprint: { _, _ in nil },
            exitedChild: { _ in .identityUnproven }, inventory: { .exact([]) }
        )
        XCTAssertEqual(action(reaped, now: 121, observation: extinction), .extinguished)

        // A crash/ECHILD after committing the one-shot allowance cannot create
        // another consuming attempt or regain signaling on a new owner lease.
        XCTAssertEqual(ContainedProcessRunner.reapLeaderOutcome(
            attempted, now: 120, observeExitedChild: { _ in .exitedExact }, waitNoHang: { _ in (-1, ECHILD) }
        ), .echild)
        let restarted = try XCTUnwrap(attempted.reclaimedAmbiguousForExtinctionProof(by: owner, now: 151, until: 180))
        XCTAssertEqual(restarted.deadlineClock, .legacyMixed)
        XCTAssertTrue(restarted.exitedLeaderReapAttempted)
        XCTAssertNil(restarted.recordingReapAttempt(owner: owner, deadline: 180))
        XCTAssertEqual(action(restarted, now: 151, observation: .exitedDirectChildExact), .retainFence)
        XCTAssertEqual(action(restarted, now: 151, observation: .liveExact), .retainFence)
        XCTAssertEqual(ContainedProcessReceipt.parse(restarted.storagePayload), restarted)
    }

}
