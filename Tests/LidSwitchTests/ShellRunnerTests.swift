import XCTest
@testable import LidSwitch
@testable import LidSwitchCore

final class ContainedProcessRunnerFixtureTests: XCTestCase {
    func testKernelProcargsAdapterRejectsMalformedAndEnvironmentSuffix() {
        var argc = Int32(2).littleEndian
        var valid = withUnsafeBytes(of: &argc) { Array($0) }
        valid += Array("/usr/bin/pmset\0\0/usr/bin/pmset\0-a\0PATH=/ignored\0".utf8)
        XCTAssertEqual(ContainedProcessRunner.parseKernelArgumentsFixture(valid), ["/usr/bin/pmset", "-a"])
        XCTAssertNil(ContainedProcessRunner.parseKernelArgumentsFixture(Array("\u{02}\0\0\0/usr/bin/pmset\0-a\0".utf8)))
        XCTAssertNil(ContainedProcessRunner.parseKernelArgumentsFixture(Array(repeating: 0, count: 5)))
        var tooMany = Int32(33).littleEndian
        XCTAssertNil(ContainedProcessRunner.parseKernelArgumentsFixture(withUnsafeBytes(of: &tooMany) { Array($0) } + Array("/x\0/x\0".utf8)))
        var emptyArg = Int32(1).littleEndian
        XCTAssertNil(ContainedProcessRunner.parseKernelArgumentsFixture(withUnsafeBytes(of: &emptyArg) { Array($0) } + Array("/x\0\0".utf8)))
        var padded = Int32(1).littleEndian
        XCTAssertEqual(ContainedProcessRunner.parseKernelArgumentsFixture(withUnsafeBytes(of: &padded) { Array($0) } + Array("/x\0\0\0/x\0ENV=ignored\0".utf8)), ["/x"])
        var invalidUTF8 = Int32(1).littleEndian
        XCTAssertNil(ContainedProcessRunner.parseKernelArgumentsFixture(withUnsafeBytes(of: &invalidUTF8) { Array($0) } + [0xff, 0, 0x2f, 0x78, 0]))
    }

    func testContainmentReceiptIsStrictBoundedAndNoSecondMutation() {
        let leader = ContainedProcessIdentity(pid: 41, startSeconds: 100, startMicroseconds: 7)
        let leaderMember = ContainedProcessMember(identity: leader, executable: "/usr/bin/pmset", commandFingerprint: "0123456789abcdef")
        let receipt = ContainedProcessReceipt(
            token: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
            executable: "/usr/bin/pmset", commandFingerprint: "0123456789abcdef",
            leader: leader, members: [leaderMember], processGroupID: 41, sessionID: 9,
            rootDeadlineNanoseconds: 10, cleanupDeadlineNanoseconds: 20
        )
        XCTAssertEqual(ContainedProcessReceipt.parse(receipt.storagePayload), receipt)
        XCTAssertNil(ContainedProcessReceipt.parse(receipt.storagePayload + "unknown=1\n"))
        XCTAssertNil(ContainedProcessReceipt.parse(receipt.storagePayload.replacingOccurrences(of: "no_second_mutation=1", with: "no_second_mutation=0")))
        XCTAssertNil(ContainedProcessReceipt.parse(receipt.storagePayload.replacingOccurrences(of: "pgid=41", with: "pgid=42")))
        XCTAssertNil(ContainedProcessReceipt.parse(receipt.storagePayload.replacingOccurrences(of: "reap_attempts=0", with: "reap_attempts=9")))
        let claimed = receipt.claimed(by: UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!, until: 20)
        XCTAssertNotNil(claimed)
        XCTAssertNil(ContainedProcessReceipt.parse(claimed!.storagePayload.replacingOccurrences(of: "owner=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", with: "owner=AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")))
    }

    func testContainmentCleanupReducerFencesReuseAndOnlyExtinguishesExactAbsence() throws {
        let owner = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let member = ContainedProcessIdentity(pid: 41, startSeconds: 100, startMicroseconds: 7)
        let boundMember = ContainedProcessMember(identity: member, executable: "/usr/bin/pmset", commandFingerprint: "0123456789abcdef")
        let base = ContainedProcessReceipt(token: UUID(), executable: "/usr/bin/pmset",
                                           commandFingerprint: "0123456789abcdef", leader: member, members: [boundMember],
                                           processGroupID: 41, sessionID: 9, rootDeadlineNanoseconds: 10,
                                           cleanupDeadlineNanoseconds: 100)
        let claimed = try XCTUnwrap(base.claimed(by: owner, until: 50))
        XCTAssertEqual(ContainedProcessCleanupMachine.next(receipt: claimed, owner: owner, now: 20, observation: .liveExact), .signalTERM)
        let termIssued = try XCTUnwrap(claimed.markingTermSignalIssued(owner: owner, deadline: 50))
        XCTAssertEqual(ContainedProcessCleanupMachine.next(receipt: termIssued, owner: owner, now: 20, observation: .liveExact), .reapLeader)
        XCTAssertEqual(ContainedProcessCleanupMachine.next(receipt: termIssued, owner: owner, now: 60, observation: .liveExact), .signalKILL)
        XCTAssertEqual(ContainedProcessCleanupMachine.next(receipt: claimed, owner: owner, now: 60, observation: .memberReusedOrUnknown), .retainFence)
        XCTAssertEqual(ContainedProcessCleanupMachine.next(receipt: claimed, owner: owner, now: 60, observation: .groupOrSessionMismatch), .retainFence)
        XCTAssertEqual(ContainedProcessCleanupMachine.next(receipt: claimed, owner: owner, now: 60, observation: .leaderReapedAndExtinct), .retainFence)
        XCTAssertNil(claimed.claimed(by: UUID(), until: 70), "second owner cannot claim a live receipt")
        let killing = try XCTUnwrap(termIssued.advancing(to: .kill, owner: owner, deadline: 60))
        XCTAssertEqual(ContainedProcessCleanupMachine.next(receipt: killing, owner: owner, now: 61, observation: .liveExact), .signalKILL)
        let killIssued = try XCTUnwrap(killing.markingKillSignalIssued(owner: owner, deadline: 60))
        XCTAssertEqual(ContainedProcessCleanupMachine.next(receipt: killIssued, owner: owner, now: 61, observation: .liveExact), .reapLeader)
        XCTAssertEqual(ContainedProcessCleanupMachine.next(receipt: killIssued, owner: owner, now: 61, observation: .leaderReapedAndExtinct), .retainFence)
        let reaped = try XCTUnwrap(killIssued.markingLeaderReaped(owner: owner, deadline: 60))
        XCTAssertEqual(ContainedProcessCleanupMachine.next(receipt: reaped, owner: owner, now: 61, observation: .leaderReapedAndExtinct), .extinguished)
        let resumed = try XCTUnwrap(killing.reclaimed(by: UUID(), now: 61, until: 90))
        XCTAssertEqual(resumed.phase, .kill, "restart ownership must not rewind persisted KILL to TERM")
    }

    func testReceiptKeepsEachRecordedMemberExecutableAndArgvBinding() throws {
        let leader = ContainedProcessIdentity(pid: 51, startSeconds: 100, startMicroseconds: 1)
        let member = ContainedProcessIdentity(pid: 52, startSeconds: 101, startMicroseconds: 2)
        let receipt = ContainedProcessReceipt(
            token: UUID(), executable: "/usr/bin/pmset", commandFingerprint: "0123456789abcdef", leader: leader,
            members: [
                .init(identity: leader, executable: "/usr/bin/pmset", commandFingerprint: "0123456789abcdef"),
                .init(identity: member, executable: "/bin/launchctl", commandFingerprint: "fedcba9876543210"),
            ], processGroupID: 51, sessionID: 9, rootDeadlineNanoseconds: 10, cleanupDeadlineNanoseconds: 20
        )
        XCTAssertEqual(ContainedProcessReceipt.parse(receipt.storagePayload), receipt)
        XCTAssertNil(ContainedProcessReceipt.parse(receipt.storagePayload.replacingOccurrences(of: "fedcba9876543210", with: "not-a-fingerprint")))
    }

    func testInventoryAdapterRejectsFullBufferAndSizeRace() {
        XCTAssertTrue(ContainedProcessRunner.inventoryReadIsStable(initialBytes: 8, capacity: 12, actualBytes: 8, afterBytes: 8))
        XCTAssertFalse(ContainedProcessRunner.inventoryReadIsStable(initialBytes: 8, capacity: 12, actualBytes: 12, afterBytes: 12))
        XCTAssertFalse(ContainedProcessRunner.inventoryReadIsStable(initialBytes: 8, capacity: 12, actualBytes: 8, afterBytes: 16))
    }

    func testDarwinWaitStatusDecodingDoesNotDependOnUnavailableCMacros() {
        XCTAssertEqual(ContainedProcessRunner.waitStatusNormalExitCode(0x2a00), 42)
        XCTAssertNil(ContainedProcessRunner.waitStatusSignal(0x2a00))
        XCTAssertEqual(ContainedProcessRunner.waitStatusSignal(SIGTERM), SIGTERM)
        XCTAssertNil(ContainedProcessRunner.waitStatusNormalExitCode(SIGTERM))
        XCTAssertNil(ContainedProcessRunner.waitStatusSignal(0x7f), "stopped is not a signal termination")
        XCTAssertNil(ContainedProcessRunner.waitStatusNormalExitCode(0x7f))
    }

    func testProductionLeaderReapAdapterRetriesEINTRAndNeverTreatsECHILDAsProof() {
        let leader = ContainedProcessIdentity(pid: 41, startSeconds: 100, startMicroseconds: 7)
        let receipt = ContainedProcessReceipt(token: UUID(), executable: "/usr/bin/pmset", commandFingerprint: "0123456789abcdef",
                                               leader: leader, members: [.init(identity: leader, executable: "/usr/bin/pmset", commandFingerprint: "0123456789abcdef")],
                                               processGroupID: 41, sessionID: 9, rootDeadlineNanoseconds: 10, cleanupDeadlineNanoseconds: 20)
        var calls = 0
        XCTAssertTrue(ContainedProcessRunner.reapLeaderIfExited(receipt) { pid in
            calls += 1
            return calls == 1 ? (-1, EINTR) : (pid, 0)
        })
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(ContainedProcessRunner.reapLeaderIfExited(receipt) { _ in (-1, ECHILD) })
        XCTAssertEqual(ContainedProcessRunner.reapLeaderOutcome(receipt, maximumInterrupts: 2) { _ in (-1, EINTR) }, .interruptedLimit)
    }

    /// This is the same receipt transition used by the coordinator's queued
    /// production cleanup path: ECHILD consumes a durable attempt, expiry
    /// turns it into one retained ambiguity, and it cannot become removal.
    func testExpiredUnprovenLeaderReapFencesExactlyOnce() throws {
        let owner = UUID()
        let leader = ContainedProcessIdentity(pid: 41, startSeconds: 100, startMicroseconds: 7)
        let member = ContainedProcessMember(identity: leader, executable: "/usr/bin/pmset", commandFingerprint: "0123456789abcdef")
        let base = ContainedProcessReceipt(token: UUID(), executable: "/usr/bin/pmset", commandFingerprint: "0123456789abcdef",
                                           leader: leader, members: [member], processGroupID: 41, sessionID: 9,
                                           rootDeadlineNanoseconds: 10, cleanupDeadlineNanoseconds: 100)
        let claimed = try XCTUnwrap(base.claimed(by: owner, until: 50))
        let issued = try XCTUnwrap(claimed.markingTermSignalIssued(owner: owner, deadline: 50))
        let attempted = try XCTUnwrap(issued.recordingReapAttempt(owner: owner, deadline: 50))
        XCTAssertEqual(ContainedProcessRunner.reapLeaderOutcome(attempted) { _ in (-1, ECHILD) }, .echild)
        XCTAssertEqual(ContainedProcessCleanupMachine.next(receipt: attempted, owner: owner, now: 49, observation: .leaderReapedAndExtinct), .reapLeader)
        XCTAssertEqual(ContainedProcessCleanupMachine.next(receipt: attempted, owner: owner, now: 50, observation: .leaderReapedAndExtinct), .retainFence)
        let ambiguous = try XCTUnwrap(attempted.advancing(to: .ambiguous, owner: owner, deadline: 50))
        XCTAssertFalse(ambiguous.leaderReaped)
        XCTAssertEqual(ContainedProcessCleanupMachine.next(receipt: ambiguous, owner: owner, now: 51, observation: .leaderReapedAndExtinct), .retainFence)
    }

    func testCoreRunnerFixtureDecisionNeverCompletesWithSurvivingDescendant() {
        let base = ContainedProcessRunner.FixtureState(
            leaderExited: true, groupGone: false, stdoutEOF: true, stderrEOF: true,
            outputExceeded: false, now: 10, deadline: 10, killDeadline: 20,
            cleanupDeadline: 30, phase: 0
        )
        XCTAssertEqual(ContainedProcessRunner.fixtureDecision(base), .term)
        XCTAssertEqual(
            ContainedProcessRunner.fixtureDecision(.init(
                leaderExited: true, groupGone: true, stdoutEOF: true, stderrEOF: true,
                outputExceeded: false, now: 10, deadline: 20, killDeadline: 30,
                cleanupDeadline: 40, phase: 0
            )),
            .completed
        )
    }

    func testCoreRunnerFixtureOutputLimitAndCleanupAreFailClosed() {
        XCTAssertEqual(
            ContainedProcessRunner.fixtureDecision(.init(
                leaderExited: false, groupGone: false, stdoutEOF: false, stderrEOF: false,
                outputExceeded: true, now: 1, deadline: 20, killDeadline: 30,
                cleanupDeadline: 40, phase: 0
            )),
            .term
        )
        XCTAssertEqual(
            ContainedProcessRunner.fixtureDecision(.init(
                leaderExited: false, groupGone: false, stdoutEOF: false, stderrEOF: false,
                outputExceeded: false, now: 40, deadline: 10, killDeadline: 20,
                cleanupDeadline: 30, phase: 2
            )),
            .containmentFailure
        )
    }

    func testCoreRunnerScriptedAdapterCoversSetupStreamsGroupsAndDescriptorClosure() {
        let base = ContainedProcessRunner.FixtureAdapterState(
            setup: .ready, stdout: .interrupted, stderr: .wouldBlock,
            group: .live, leaderExited: false, outputExceeded: false,
            deadlineExpired: false, termDeadlineExpired: false, cleanupDeadlineExpired: false
        )
        XCTAssertEqual(ContainedProcessRunner.fixtureEvaluation(base), .wait)
        XCTAssertEqual(
            ContainedProcessRunner.fixtureEvaluation(.init(
                setup: .ready, stdout: .eof, stderr: .eof, group: .gone,
                leaderExited: true, outputExceeded: false,
                deadlineExpired: false, termDeadlineExpired: false, cleanupDeadlineExpired: false
            )),
            .completed
        )
        XCTAssertEqual(
            ContainedProcessRunner.fixtureEvaluation(.init(
                setup: .ready, stdout: .open, stderr: .open, group: .live,
                leaderExited: false, outputExceeded: true,
                deadlineExpired: false, termDeadlineExpired: false, cleanupDeadlineExpired: false
            )),
            .term
        )
        for setup in [
            ContainedProcessRunner.FixtureSetup.pipeFailure,
            .fcntlFailure, .fileActionFailure, .attributeFailure, .descriptorClosureFailure
        ] {
            XCTAssertEqual(
                ContainedProcessRunner.fixtureEvaluation(.init(
                    setup: setup, stdout: .open, stderr: .open, group: .live,
                    leaderExited: false, outputExceeded: false,
                    deadlineExpired: false, termDeadlineExpired: false, cleanupDeadlineExpired: false
                )),
                .containmentFailure
            )
        }
        XCTAssertEqual(
            ContainedProcessRunner.fixtureEvaluation(.init(
                setup: .spawnFailure, stdout: .open, stderr: .open, group: .live,
                leaderExited: false, outputExceeded: false,
                deadlineExpired: false, termDeadlineExpired: false, cleanupDeadlineExpired: false
            )),
            .launchFailed
        )
        XCTAssertEqual(
            ContainedProcessRunner.fixtureEvaluation(.init(
                setup: .ready, stdout: .open, stderr: .open, group: .ambiguous,
                leaderExited: true, outputExceeded: false,
                deadlineExpired: false, termDeadlineExpired: false, cleanupDeadlineExpired: false
            )),
            .containmentFailure
        )
    }

    func testCoreRunnerSynchronousCleanupFixturesRetainOwnershipUntilReaped() {
        XCTAssertEqual(
            ContainedProcessRunner.cleanupTransition(.init(
                phase: .term, group: .live, leaderExited: false, reapSucceeded: false,
                signal: .sent, termDeadlineExpired: false
            )),
            .signalTerm
        )
        XCTAssertEqual(
            ContainedProcessRunner.cleanupTransition(.init(
                phase: .term, group: .live, leaderExited: false, reapSucceeded: false,
                signal: .sent, termDeadlineExpired: true
            )),
            .signalKill
        )
        XCTAssertEqual(
            ContainedProcessRunner.cleanupTransition(.init(
                phase: .kill, group: .gone, leaderExited: true, reapSucceeded: false,
                signal: .failed, termDeadlineExpired: true
            )),
            .retainOwnership
        )
        XCTAssertEqual(
            ContainedProcessRunner.cleanupTransition(.init(
                phase: .kill, group: .gone, leaderExited: true, reapSucceeded: true,
                signal: .gone, termDeadlineExpired: true
            )),
            .reaped
        )
    }
}

/// Closed-adapter coverage: `Shell.run` is exercised only with scripted system
/// adapters, so these fixtures cannot spawn, signal, inspect, or reap a process.
final class ShellRunnerTests: XCTestCase {
    func testRunnerSystemAdapterReleasesReservationForEveryPreSpawnFailure() {
        for stage in Shell.SetupStage.allCases where stage != .reaperReservation {
            let reservation = Shell.DeferredChildReaper.Reservation(id: UUID())
            var releases = 0
            let adapter = Shell.RunnerSystemAdapter(
                reserve: { reservation }, bind: { _, _ in true }, release: { _ in releases += 1; return true }, transfer: { _, _ in true },
                prepareSpawn: { _ in .failure(stage, "fixture") }, close: { _ in }, makeNonblocking: { _ in true },
                observe: { _, _ in .running }, group: { _, _ in .unknown }, signal: { _, _, value in value },
                poll: { _, _, _ in 0 }, errno: { 0 }, drain: { _, _ in .eof },
                reapAttempt: { _, _ in .reaped },
                pause: { _ in }, now: { 1 }
            )
            let result = Shell.run(.fixture(executable: "/bin/cat", arguments: ["/fixture"]), system: adapter)
            XCTAssertEqual(result.outcome, .spawnFailed, "stage=\(stage)")
            XCTAssertEqual(releases, 1, "stage=\(stage)")
        }
        let unavailable = Shell.RunnerSystemAdapter(
            reserve: { nil }, bind: { _, _ in false }, release: { _ in XCTFail("unreserved release"); return false }, transfer: { _, _ in false },
            prepareSpawn: { _ in XCTFail("unreserved spawn"); return .failure(.spawn, "unreachable") }, close: { _ in }, makeNonblocking: { _ in false },
            observe: { _, _ in .fatal }, group: { _, _ in .unknown }, signal: { _, _, state in state }, poll: { _, _, _ in -1 }, errno: { EIO },
            drain: { _, _ in .fatal }, reapAttempt: { _, _ in .fatal }, pause: { _ in }, now: { 0 }
        )
        XCTAssertEqual(Shell.run(.fixture(executable: "/bin/cat", arguments: ["/fixture"]), system: unavailable).outcome, .spawnFailed)
    }

    func testRunnerSystemAdapterPostSpawnNonblockingFailureClosesAndTransfersOnce() {
        final class Clock: @unchecked Sendable { var values: [UInt64] = [0, 1, 600_000_000, 4_000_000_000]; func next() -> UInt64 { values.isEmpty ? 4_000_000_000 : values.removeFirst() } }
        let clock = Clock(), reservation = Shell.DeferredChildReaper.Reservation(id: UUID())
        var closes: [Int32] = [], nonblocking: [Int32] = [], signals: [Int32] = [], transfers = 0
        let adapter = Shell.RunnerSystemAdapter(
            reserve: { reservation }, bind: { _, _ in true }, release: { _ in XCTFail("unexpected release"); return true }, transfer: { _, _ in transfers += 1; return true },
            prepareSpawn: { _ in .success(.init(child: 70, stdout: 6, stderr: 7)) }, close: { closes.append($0) },
            makeNonblocking: { nonblocking.append($0); return false },
            observe: { _, _ in .running }, group: { _, _ in .live }, signal: { _, signal, _ in signals.append(signal); return false },
            poll: { _, _, _ in 0 }, errno: { 0 }, drain: { _, _ in .eof }, reapAttempt: { _, _ in .pending }, pause: { _ in }, now: { clock.next() }
        )
        let result = Shell.run(.fixture(executable: "/bin/cat", arguments: ["/fixture"]), system: adapter)
        XCTAssertEqual(result.outcome, .containmentFailed)
        XCTAssertEqual(nonblocking, [6, 7], "the run-level post-spawn failure seam is exercised exactly once per descriptor")
        XCTAssertEqual(closes, [6, 7])
        XCTAssertEqual(signals, [SIGTERM, SIGKILL])
        XCTAssertEqual(transfers, 1)
        XCTAssertTrue(result.stderr.contains("childReapOwnershipTransferredAfterpending"))
    }

    func testRunnerSystemAdapterBindFailureContainsChildWithoutTrapOrFalseRelease() {
        final class Clock: @unchecked Sendable {
            var values: [UInt64] = [0, 1, 600_000_000, 4_000_000_000]
            func next() -> UInt64 { values.isEmpty ? 4_000_000_000 : values.removeFirst() }
        }
        let clock = Clock(), reservation = Shell.DeferredChildReaper.Reservation(id: UUID())
        var binds = 0, releases = 0, transfers = 0
        var closes: [Int32] = [], signals: [Int32] = []
        let adapter = Shell.RunnerSystemAdapter(
            reserve: { reservation },
            bind: { _, child in binds += 1; XCTAssertEqual(child, 701); return false },
            release: { _ in releases += 1; return true },
            transfer: { _, child in transfers += 1; XCTAssertEqual(child, 701); return true },
            prepareSpawn: { _ in .success(.init(child: 701, stdout: 60, stderr: 61)) },
            close: { closes.append($0) }, makeNonblocking: { _ in true },
            observe: { _, _ in .running }, group: { _, _ in .live },
            signal: { _, signal, _ in signals.append(signal); return false },
            poll: { _, _, _ in 0 }, errno: { 0 }, drain: { _, _ in .eof },
            reapAttempt: { _, _ in .pending }, pause: { _ in }, now: { clock.next() }
        )
        let result = Shell.run(.fixture(executable: "/bin/cat", arguments: ["/fixture"]), system: adapter)
        XCTAssertEqual(result.outcome, .containmentFailed)
        XCTAssertEqual(binds, 1)
        XCTAssertEqual(releases, 0, "a failed bind is never disguised as reservation release")
        XCTAssertEqual(transfers, 1)
        XCTAssertEqual(closes, [60, 61])
        XCTAssertEqual(signals, [SIGTERM, SIGKILL])
        XCTAssertTrue(result.stderr.contains("Could not bind spawned child"))
        XCTAssertTrue(result.stderr.contains("childReapOwnershipTransferredAfterpending"))
    }

    func testRunnerSystemAdapterDrivesBoundChildToSynchronousReapWithoutSpawn() {
        let reservation = Shell.DeferredChildReaper.Reservation(id: UUID())
        var calls: [String] = []
        let adapter = Shell.RunnerSystemAdapter(
            reserve: { calls.append("reserve"); return reservation }, bind: { _, child in calls.append("bind:\(child)"); return true },
            release: { _ in calls.append("release"); return true }, transfer: { _, _ in calls.append("transfer"); return true },
            prepareSpawn: { _ in calls.append("spawn"); return .success(.init(child: 71, stdout: 8, stderr: 9)) },
            close: { calls.append("close:\($0)") }, makeNonblocking: { calls.append("nonblock:\($0)"); return true },
            observe: { _, _ in calls.append("waitid"); return .exited }, group: { _, _ in calls.append("group"); return .goneESRCH },
            signal: { _, signal, _ in calls.append("signal:\(signal)"); return true }, poll: { _, _, _ in calls.append("poll"); return 0 }, errno: { 0 },
            drain: { descriptor, _ in calls.append("drain:\(descriptor)"); return .eof },
            reapAttempt: { _, _ in calls.append("reap"); return .reaped },
            pause: { _ in }, now: { 1 }
        )
        let result = Shell.run(.fixture(executable: "/bin/cat", arguments: ["/fixture"]), system: adapter)
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(calls.filter { $0 == "bind:71" }.count, 1)
        XCTAssertEqual(calls.filter { $0 == "reap" }.count, 1)
        XCTAssertFalse(calls.contains { $0.hasPrefix("signal:") })
        XCTAssertEqual(calls.filter { $0.hasPrefix("close:") }.count, 2)
    }

    func testRunnerSystemAdapterReportsTransferredFinalReapWithoutPostReapSignal() {
        let reservation = Shell.DeferredChildReaper.Reservation(id: UUID())
        var calls: [String] = []
        let adapter = Shell.RunnerSystemAdapter(
            reserve: { reservation }, bind: { _, _ in calls.append("bind"); return true }, release: { _ in calls.append("release"); return true },
            transfer: { _, _ in calls.append("transfer"); return true }, prepareSpawn: { _ in .success(.init(child: 72, stdout: 10, stderr: 11)) },
            close: { calls.append("close:\($0)") }, makeNonblocking: { _ in true }, observe: { _, _ in .exited }, group: { _, _ in .goneESRCH },
            signal: { _, signal, state in calls.append("signal:\(signal)"); return state }, poll: { _, _, _ in 0 }, errno: { 0 }, drain: { _, _ in .eof },
            reapAttempt: { _, _ in calls.append("reap-transfer"); return .pending }, pause: { _ in }, now: { 1 }
        )
        let result = Shell.run(.fixture(executable: "/bin/cat", arguments: ["/fixture"]), system: adapter)
        XCTAssertEqual(result.outcome, .containmentFailed)
        XCTAssertEqual(calls.filter { $0 == "reap-transfer" }.count, 1)
        XCTAssertFalse(calls.contains { $0.hasPrefix("signal:") })
    }

    func testRunnerSystemAdapterScriptsTermKillAndNoSignalAfterOwnershipTransfer() {
        final class Clock: @unchecked Sendable {
            var values: [UInt64] = [0, 6_000_000_000, 7_000_000_000, 11_000_000_000]
            func next() -> UInt64 { values.isEmpty ? 11_000_000_000 : values.removeFirst() }
        }
        let clock = Clock(), reservation = Shell.DeferredChildReaper.Reservation(id: UUID())
        var signals: [Int32] = [], transfers = 0
        let adapter = Shell.RunnerSystemAdapter(
            reserve: { reservation }, bind: { _, _ in true }, release: { _ in true }, transfer: { _, _ in transfers += 1; return true },
            prepareSpawn: { _ in .success(.init(child: 73, stdout: 12, stderr: 13)) }, close: { _ in }, makeNonblocking: { _ in true },
            observe: { _, _ in .running }, group: { _, _ in .live }, signal: { _, signal, _ in signals.append(signal); return false },
            poll: { _, _, _ in 0 }, errno: { 0 }, drain: { _, _ in .eof },
            reapAttempt: { _, _ in .pending }, pause: { _ in }, now: { clock.next() }
        )
        let result = Shell.run(.fixture(executable: "/bin/cat", arguments: ["/fixture"]), system: adapter)
        XCTAssertEqual(result.outcome, .containmentFailed)
        XCTAssertTrue(signals.contains(SIGTERM))
        XCTAssertTrue(signals.contains(SIGKILL))
        XCTAssertEqual(transfers, 1, "pending reap transfers exactly once after all group signals")
    }

    func testRunnerSystemAdapterRoutesFatalPollToBoundedContainment() {
        final class Clock: @unchecked Sendable {
            var values: [UInt64] = [0, 1, 600_000_000, 4_000_000_000, 8_000_000_000]
            func next() -> UInt64 { values.isEmpty ? 8_000_000_000 : values.removeFirst() }
        }
        let clock = Clock(), reservation = Shell.DeferredChildReaper.Reservation(id: UUID())
        var signals: [Int32] = [], reaps = 0
        let adapter = Shell.RunnerSystemAdapter(
            reserve: { reservation }, bind: { _, _ in true }, release: { _ in true }, transfer: { _, _ in true },
            prepareSpawn: { _ in .success(.init(child: 74, stdout: 14, stderr: 15)) }, close: { _ in }, makeNonblocking: { _ in true },
            observe: { _, _ in .running }, group: { _, _ in .live }, signal: { _, signal, _ in signals.append(signal); return false },
            poll: { _, _, _ in -1 }, errno: { EIO }, drain: { _, _ in .open },
            reapAttempt: { _, _ in reaps += 1; return .pending }, pause: { _ in }, now: { clock.next() }
        )
        let result = Shell.run(.fixture(executable: "/bin/cat", arguments: ["/fixture"]), system: adapter)
        XCTAssertEqual(result.outcome, .containmentFailed)
        XCTAssertEqual(reaps, 1)
        XCTAssertTrue(signals.contains(SIGTERM))
        XCTAssertTrue(signals.contains(SIGKILL))
    }

    func testRunnerSystemAdapterRoutesFatalWaitObservationToBoundedContainment() {
        final class Clock: @unchecked Sendable {
            var values: [UInt64] = [0, 1, 600_000_000, 4_000_000_000, 8_000_000_000]
            func next() -> UInt64 { values.isEmpty ? 8_000_000_000 : values.removeFirst() }
        }
        let clock = Clock(), reservation = Shell.DeferredChildReaper.Reservation(id: UUID())
        var reaps = 0
        let adapter = Shell.RunnerSystemAdapter(
            reserve: { reservation }, bind: { _, _ in true }, release: { _ in true }, transfer: { _, _ in true },
            prepareSpawn: { _ in .success(.init(child: 75, stdout: 16, stderr: 17)) }, close: { _ in }, makeNonblocking: { _ in true },
            observe: { _, _ in .fatal }, group: { _, _ in .unknown }, signal: { _, _, _ in false },
            poll: { _, _, _ in 0 }, errno: { 0 }, drain: { _, _ in .open },
            reapAttempt: { _, _ in reaps += 1; return .fatal }, pause: { _ in }, now: { clock.next() }
        )
        XCTAssertEqual(Shell.run(.fixture(executable: "/bin/cat", arguments: ["/fixture"]), system: adapter).outcome, .containmentFailed)
        XCTAssertEqual(reaps, 1)
    }

    func testRunnerSystemAdapterDrainsBothStreamsBeyondRetentionToEOF() {
        let reservation = Shell.DeferredChildReaper.Reservation(id: UUID())
        var drained: [Int32] = []
        var chunks: [Int32: Int] = [:]
        let adapter = Shell.RunnerSystemAdapter(
            reserve: { reservation }, bind: { _, _ in true }, release: { _ in true }, transfer: { _, _ in true },
            prepareSpawn: { _ in .success(.init(child: 76, stdout: 18, stderr: 19)) }, close: { _ in }, makeNonblocking: { _ in true },
            observe: { _, _ in .exited }, group: { _, _ in .goneESRCH }, signal: { _, _, state in state }, poll: { _, _, _ in 0 }, errno: { 0 },
            drain: { descriptor, sink in
                drained.append(descriptor)
                chunks[descriptor, default: 0] += 1
                let payload = Array((descriptor == 18 ? (chunks[descriptor] == 1 ? "abcd" : "efgh") : (chunks[descriptor] == 1 ? "UVWX" : "YZ12")).utf8)
                payload.withUnsafeBytes { sink.append($0) }
                return chunks[descriptor] == 1 ? .open : .eof
            }, reapAttempt: { _, _ in .reaped }, pause: { _ in }, now: { 1 }
        )
        let result = Shell.run(.fixture(executable: "/bin/cat", arguments: ["/fixture"], maximumOutputBytes: 3), system: adapter)
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(drained, [18, 19, 18, 19])
        XCTAssertEqual(chunks[18], 2)
        XCTAssertEqual(chunks[19], 2)
        XCTAssertEqual(result.stdout, "abc\n[output truncated]")
        XCTAssertEqual(result.stderr, "UVW\n[output truncated]")
    }

    func testRunnerSystemAdapterKeepsExitedLeaderOpenWhileDescendantOwnsGroup() {
        final class Clock: @unchecked Sendable {
            var values: [UInt64] = [0, 6_000_000_000, 7_000_000_000, 11_000_000_000]
            func next() -> UInt64 { values.isEmpty ? 11_000_000_000 : values.removeFirst() }
        }
        let clock = Clock(), reservation = Shell.DeferredChildReaper.Reservation(id: UUID())
        var signals: [Int32] = []
        let adapter = Shell.RunnerSystemAdapter(
            reserve: { reservation }, bind: { _, _ in true }, release: { _ in true }, transfer: { _, _ in true },
            prepareSpawn: { _ in .success(.init(child: 77, stdout: 20, stderr: 21)) }, close: { _ in }, makeNonblocking: { _ in true },
            observe: { _, _ in .exited }, group: { _, _ in .live }, signal: { _, signal, _ in signals.append(signal); return false },
            poll: { _, _, _ in 0 }, errno: { 0 }, drain: { _, _ in .eof },
            reapAttempt: { _, _ in .pending }, pause: { _ in }, now: { clock.next() }
        )
        XCTAssertEqual(Shell.run(.fixture(executable: "/bin/cat", arguments: ["/fixture"]), system: adapter).outcome, .containmentFailed)
        XCTAssertTrue(signals.contains(SIGTERM))
        XCTAssertTrue(signals.contains(SIGKILL))
    }

    func testDeferredPollReducerCapsFatalBackoffWithoutStarvingOtherObservedChildren() {
        XCTAssertEqual(Shell.deferredPollDelayMilliseconds(consecutiveFatalWaitErrors: 0), 25)
        XCTAssertEqual(Shell.deferredPollDelayMilliseconds(consecutiveFatalWaitErrors: 1), 50)
        XCTAssertEqual(Shell.deferredPollDelayMilliseconds(consecutiveFatalWaitErrors: 6), 1_000)
        XCTAssertEqual(Shell.deferredPollDelayMilliseconds(consecutiveFatalWaitErrors: 99), 1_000)
        let pending = Shell.DeferredWaitAdapter(waitNoHang: { _ in 0 }, errno: { 0 })
        let reaped = Shell.DeferredWaitAdapter(waitNoHang: { child in child }, errno: { 0 })
        XCTAssertEqual(Shell.deferredWaitOutcome(80, adapter: pending), .pending)
        XCTAssertEqual(Shell.deferredWaitOutcome(81, adapter: reaped), .reaped)
    }

    func testReapAttemptClassifierMapsExactlyOneTerminalOwnershipOperation() {
        XCTAssertEqual(Shell.reapDecision(for: .reaped), .release)
        XCTAssertEqual(Shell.reapDecision(for: .noChild), .release)
        XCTAssertEqual(Shell.reapDecision(for: .pending), .transfer)
        XCTAssertEqual(Shell.reapDecision(for: .interrupted), .transfer)
        XCTAssertEqual(Shell.reapDecision(for: .fatal), .transfer)
    }

    func testRunLevelFinishPropagatesEveryReleaseAndTransferResultExactly() {
        struct Scenario {
            let name: String
            let attempt: Shell.ReapAttempt
            let releaseSucceeds: Bool
            let transferSucceeds: Bool
            let expectedReapCalls: Int
            let expectedReleaseCalls: Int
            let expectedTransferCalls: Int
            let expectedOutcome: ProcessOutcome
            let evidence: String
        }
        let scenarios = [
            Scenario(name: "reaped", attempt: .reaped, releaseSucceeds: true, transferSucceeds: true,
                     expectedReapCalls: 1, expectedReleaseCalls: 1, expectedTransferCalls: 0,
                     expectedOutcome: .completed, evidence: ""),
            Scenario(name: "ECHILD", attempt: .noChild, releaseSucceeds: true, transferSucceeds: true,
                     expectedReapCalls: 1, expectedReleaseCalls: 1, expectedTransferCalls: 0,
                     expectedOutcome: .completed, evidence: ""),
            Scenario(name: "pending", attempt: .pending, releaseSucceeds: true, transferSucceeds: true,
                     expectedReapCalls: 1, expectedReleaseCalls: 0, expectedTransferCalls: 1,
                     expectedOutcome: .containmentFailed, evidence: "childReapOwnershipTransferredAfterpending"),
            Scenario(name: "interrupted", attempt: .interrupted, releaseSucceeds: true, transferSucceeds: true,
                     expectedReapCalls: 3, expectedReleaseCalls: 0, expectedTransferCalls: 1,
                     expectedOutcome: .containmentFailed, evidence: "childReapOwnershipTransferredAfterinterrupted"),
            Scenario(name: "fatal", attempt: .fatal, releaseSucceeds: true, transferSucceeds: true,
                     expectedReapCalls: 1, expectedReleaseCalls: 0, expectedTransferCalls: 1,
                     expectedOutcome: .containmentFailed, evidence: "childReapOwnershipTransferredAfterfatal"),
            Scenario(name: "release-false", attempt: .reaped, releaseSucceeds: false, transferSucceeds: true,
                     expectedReapCalls: 1, expectedReleaseCalls: 1, expectedTransferCalls: 0,
                     expectedOutcome: .containmentFailed, evidence: "reservationReleaseFailedAfterreaped"),
            Scenario(name: "transfer-false", attempt: .pending, releaseSucceeds: true, transferSucceeds: false,
                     expectedReapCalls: 1, expectedReleaseCalls: 0, expectedTransferCalls: 1,
                     expectedOutcome: .containmentFailed, evidence: "childReapOwnershipTransferFailedAfterpending"),
        ]
        for (index, scenario) in scenarios.enumerated() {
            let reservation = Shell.DeferredChildReaper.Reservation(id: UUID())
            var reapCalls = 0, releaseCalls = 0, transferCalls = 0
            let child = pid_t(800 + index)
            let adapter = Shell.RunnerSystemAdapter(
                reserve: { reservation }, bind: { _, boundChild in boundChild == child },
                release: { _ in releaseCalls += 1; return scenario.releaseSucceeds },
                transfer: { _, transferredChild in transferCalls += 1; return scenario.transferSucceeds && transferredChild == child },
                prepareSpawn: { _ in .success(.init(child: child, stdout: 100 + Int32(index * 2), stderr: 101 + Int32(index * 2))) },
                close: { _ in }, makeNonblocking: { _ in true }, observe: { _, _ in .exited },
                group: { _, _ in .goneESRCH }, signal: { _, _, state in state },
                poll: { _, _, _ in 0 }, errno: { 0 }, drain: { _, _ in .eof },
                reapAttempt: { _, _ in reapCalls += 1; return scenario.attempt },
                pause: { _ in }, now: { 1 }
            )
            let result = Shell.run(.fixture(executable: "/bin/cat", arguments: ["/fixture"]), system: adapter)
            XCTAssertEqual(result.outcome, scenario.expectedOutcome, scenario.name)
            XCTAssertEqual(reapCalls, scenario.expectedReapCalls, scenario.name)
            XCTAssertEqual(releaseCalls, scenario.expectedReleaseCalls, scenario.name)
            XCTAssertEqual(transferCalls, scenario.expectedTransferCalls, scenario.name)
            if !scenario.evidence.isEmpty { XCTAssertTrue(result.stderr.contains(scenario.evidence), scenario.name) }
        }
    }

    func testSharedFinishReportsTruthfulTerminalEvidenceIncludingFailedOperations() {
        final class Calls: @unchecked Sendable {
            var reap = 0
            var release = 0
            var transfer = 0
        }
        struct Scenario {
            let attempt: Shell.ReapAttempt
            let releaseSucceeds: Bool
            let transferSucceeds: Bool
            let expectedOperation: Shell.ReapTerminalOperation
            let expectedSucceeded: Bool
            let expectedCompleted: Bool
            let expectedReap: Int
            let evidence: String
        }
        let scenarios = [
            Scenario(attempt: .reaped, releaseSucceeds: true, transferSucceeds: true,
                     expectedOperation: .release, expectedSucceeded: true, expectedCompleted: true,
                     expectedReap: 1, evidence: "childReaped;reservationReleased"),
            Scenario(attempt: .noChild, releaseSucceeds: true, transferSucceeds: true,
                     expectedOperation: .release, expectedSucceeded: true, expectedCompleted: true,
                     expectedReap: 1, evidence: "childAlreadyReaped;reservationReleased"),
            Scenario(attempt: .pending, releaseSucceeds: true, transferSucceeds: true,
                     expectedOperation: .transfer, expectedSucceeded: true, expectedCompleted: false,
                     expectedReap: 1, evidence: "childReapOwnershipTransferredAfterpending"),
            Scenario(attempt: .interrupted, releaseSucceeds: true, transferSucceeds: true,
                     expectedOperation: .transfer, expectedSucceeded: true, expectedCompleted: false,
                     expectedReap: 3, evidence: "childReapOwnershipTransferredAfterinterrupted"),
            Scenario(attempt: .fatal, releaseSucceeds: true, transferSucceeds: true,
                     expectedOperation: .transfer, expectedSucceeded: true, expectedCompleted: false,
                     expectedReap: 1, evidence: "childReapOwnershipTransferredAfterfatal"),
            Scenario(attempt: .reaped, releaseSucceeds: false, transferSucceeds: true,
                     expectedOperation: .release, expectedSucceeded: false, expectedCompleted: false,
                     expectedReap: 1, evidence: "reservationReleaseFailedAfterreaped"),
            Scenario(attempt: .pending, releaseSucceeds: true, transferSucceeds: false,
                     expectedOperation: .transfer, expectedSucceeded: false, expectedCompleted: false,
                     expectedReap: 1, evidence: "childReapOwnershipTransferFailedAfterpending"),
        ]
        for (index, scenario) in scenarios.enumerated() {
            let calls = Calls(), reservation = Shell.DeferredChildReaper.Reservation(id: UUID())
            let child = pid_t(950 + index)
            let adapter = Shell.RunnerSystemAdapter(
                reserve: { reservation }, bind: { _, _ in true },
                release: { _ in calls.release += 1; return scenario.releaseSucceeds },
                transfer: { _, transferredChild in calls.transfer += 1; return scenario.transferSucceeds && transferredChild == child },
                prepareSpawn: { _ in .failure(.spawn, "unused") }, close: { _ in }, makeNonblocking: { _ in true },
                observe: { _, _ in .running }, group: { _, _ in .unknown }, signal: { _, _, state in state },
                poll: { _, _, _ in 0 }, errno: { 0 }, drain: { _, _ in .eof },
                reapAttempt: { _, _ in calls.reap += 1; return scenario.attempt },
                pause: { _ in }, now: { 1 }
            )
            var status: Int32 = 0
            let result = Shell.finishOrTransferReap(
                child, reservation: reservation, status: &status,
                monotonicNow: { 1 }, system: adapter
            )
            XCTAssertEqual(result.terminalOperation, scenario.expectedOperation)
            XCTAssertEqual(result.terminalOperationSucceeded, scenario.expectedSucceeded)
            XCTAssertEqual(result.completedSynchronously, scenario.expectedCompleted)
            XCTAssertEqual(result.evidence, scenario.evidence)
            XCTAssertEqual(calls.reap, scenario.expectedReap)
            XCTAssertEqual(calls.release, scenario.expectedOperation == .release ? 1 : 0)
            XCTAssertEqual(calls.transfer, scenario.expectedOperation == .transfer ? 1 : 0)
        }
    }

    func testCompletionRequiresHeldLeaderQuiescentMembersAndBothDrainedStreams() {
        let complete = Shell.RunnerFixtureState(
            directChildReaped: true, processGroupQuiescent: true,
            stdoutEOF: true, stderrEOF: true, cleanupDeadlineExpired: false
        )
        XCTAssertEqual(Shell.fixtureOutcome(complete), .complete)
        XCTAssertEqual(Shell.fixtureOutcome(.init(
            directChildReaped: false, processGroupQuiescent: true,
            stdoutEOF: true, stderrEOF: true, cleanupDeadlineExpired: false
        )), .wait)
        XCTAssertEqual(Shell.fixtureOutcome(.init(
            directChildReaped: true, processGroupQuiescent: false,
            stdoutEOF: true, stderrEOF: true, cleanupDeadlineExpired: false
        )), .wait)
        XCTAssertEqual(Shell.fixtureOutcome(.init(
            directChildReaped: true, processGroupQuiescent: true,
            stdoutEOF: false, stderrEOF: true, cleanupDeadlineExpired: false
        )), .wait)
    }

    func testTimeoutReducerRetriesSignalsUntilStableGroupIsQuiescent() {
        var machine = Shell.RunnerMachine(commandDeadline: 10, termBudget: 2, cleanupBudget: 3)
        XCTAssertEqual(machine.advance(now: 10, childReaped: false, group: .live, stdout: .wouldBlock, stderr: .wouldBlock), .wait(.term))
        XCTAssertEqual(machine.advance(now: 11, childReaped: false, group: .live, stdout: .interrupted, stderr: .wouldBlock), .wait(.term))
        XCTAssertEqual(machine.advance(now: 12, childReaped: false, group: .live, stdout: .wouldBlock, stderr: .wouldBlock), .wait(.kill))
        XCTAssertEqual(machine.advance(now: 13, childReaped: true, group: .goneESRCH, stdout: .eof, stderr: .eof), .completed)

        var fatalObservation = Shell.RunnerMachine(commandDeadline: 100, termBudget: 2, cleanupBudget: 3)
        // The live waitid/poll/read adapters route fatal observations through
        // this same reducer rather than silently treating them as progress.
        fatalObservation.forceCleanup(now: 7)
        XCTAssertEqual(fatalObservation.advance(now: 7, childReaped: false, group: .live, stdout: .open, stderr: .open), .wait(.term))
    }

    func testCleanupDeadlineAndNoReusableGroupAfterESRCHAreModeled() {
        var machine = Shell.RunnerMachine(commandDeadline: 1, termBudget: 1, cleanupBudget: 1)
        XCTAssertEqual(machine.advance(now: 1, childReaped: false, group: .live, stdout: .open, stderr: .open), .wait(.term))
        XCTAssertEqual(machine.advance(now: 2, childReaped: false, group: .unknown, stdout: .open, stderr: .open), .wait(.kill))
        XCTAssertEqual(machine.advance(now: 3, childReaped: false, group: .unknown, stdout: .open, stderr: .open), .containmentFailed)

        var gone = Shell.RunnerMachine(commandDeadline: 1)
        XCTAssertEqual(gone.advance(now: 1, childReaped: false, group: .goneESRCH, stdout: .open, stderr: .open), .wait(.none))
        XCTAssertEqual(gone.advance(now: 2, childReaped: false, group: .live, stdout: .open, stderr: .open), .wait(.none))

        XCTAssertEqual(Shell.fixtureOutcome(.init(
            directChildReaped: true, processGroupQuiescent: false,
            stdoutEOF: false, stderrEOF: false, cleanupDeadlineExpired: true
        )), .containmentFailed(childReapFailed: false))
        XCTAssertEqual(Shell.fixtureOutcome(.init(
            directChildReaped: false, processGroupQuiescent: false,
            stdoutEOF: false, stderrEOF: false, cleanupDeadlineExpired: true
        )), .containmentFailed(childReapFailed: true))
    }

    func testSetupAndOutputFixturesKeepFailureAndTruncationDeterministic() {
        for stage in Shell.SetupStage.allCases {
            XCTAssertEqual(Shell.setupFailure(stage).outcome, .spawnFailed)
        }
        let output = BoundedProcessOutput(maximumBytes: 3)
        Array("abcdef".utf8).withUnsafeBytes { output.append($0) }
        Array("UVWXYZ".utf8).withUnsafeBytes { output.append($0) }
        XCTAssertEqual(output.text(), "abc\n[output truncated]")
        XCTAssertEqual(Shell.reconciliationOutcome(timedOut: true, commandClass: .reversibleMutation, reconcile: { false }), .failed)
    }

    func testDescriptorAndDrainAdaptersExerciseStandardFDsAndDualStreamCaps() {
        var closed: [Int32] = []
        var next: Int32 = 3
        let descriptors = Shell.DescriptorAdapter(
            duplicateAboveStandardStreams: { _ in defer { next += 1 }; return next },
            close: { closed.append($0) }
        )
        var pipe: [Int32] = [STDIN_FILENO, STDOUT_FILENO]
        XCTAssertTrue(Shell.normalizePipeDescriptors(&pipe, adapter: descriptors))
        XCTAssertEqual(pipe, [3, 4])
        XCTAssertEqual(closed, [STDIN_FILENO, STDOUT_FILENO])

        var stdoutCalls = 0
        let stdout = BoundedProcessOutput(maximumBytes: 3)
        let stdoutAdapter = Shell.DrainAdapter(
            read: { _, buffer, _ in
                stdoutCalls += 1
                guard stdoutCalls == 1 else { return -1 }
                let values = Array("abcdef".utf8)
                let destination = buffer!.assumingMemoryBound(to: UInt8.self)
                for (index, value) in values.enumerated() { destination[index] = value }
                return values.count
            },
            errno: { EAGAIN }
        )
        var stderrCalls = 0
        let stderr = BoundedProcessOutput(maximumBytes: 3)
        let stderrAdapter = Shell.DrainAdapter(
            read: { _, buffer, _ in
                stderrCalls += 1
                guard stderrCalls == 1 else { return -1 }
                let values = Array("UVWXYZ".utf8)
                let destination = buffer!.assumingMemoryBound(to: UInt8.self)
                for (index, value) in values.enumerated() { destination[index] = value }
                return values.count
            },
            errno: { EAGAIN }
        )
        XCTAssertEqual(Shell.drainAvailable(descriptor: 10, output: stdout, adapter: stdoutAdapter), .open)
        XCTAssertEqual(Shell.drainAvailable(descriptor: 11, output: stderr, adapter: stderrAdapter), .open)
        XCTAssertEqual(stdout.text(), "abc\n[output truncated]")
        XCTAssertEqual(stderr.text(), "UVW\n[output truncated]")

        let fatalRead = Shell.DrainAdapter(read: { _, _, _ in -1 }, errno: { EIO })
        XCTAssertEqual(Shell.drainAvailable(descriptor: 12, output: BoundedProcessOutput(maximumBytes: 1), adapter: fatalRead), .fatal)

        var unwound: [Int32] = []
        let failedDup = Shell.DescriptorAdapter(
            duplicateAboveStandardStreams: { descriptor in descriptor == STDIN_FILENO ? 3 : -1 },
            close: { unwound.append($0) }
        )
        var failedPipe: [Int32] = [STDIN_FILENO, STDERR_FILENO]
        XCTAssertFalse(Shell.normalizePipeDescriptors(&failedPipe, adapter: failedDup))
        XCTAssertEqual(unwound, [3])
    }

    func testGroupAdapterRejectsGrowthAndAcceptsOnlyStableCompleteSnapshot() {
        let leader: pid_t = 41
        let stable = Shell.GroupMembershipAdapter(
            probe: { _ in .bytes(Int32(MemoryLayout<pid_t>.size)) },
            read: { _, _ in .members([leader], bytes: Int32(MemoryLayout<pid_t>.size)) }
        )
        XCTAssertEqual(Shell.stableGroupMembers(leader, adapter: stable), [leader])

        let capacityFilled = Shell.GroupMembershipAdapter(
            probe: { _ in .bytes(Int32(MemoryLayout<pid_t>.size)) },
            read: { _, capacity in .members([leader, 99], bytes: capacity) }
        )
        XCTAssertNil(Shell.stableGroupMembers(leader, adapter: capacityFilled))

        final class GrowthScript: @unchecked Sendable {
            var probes = 0
            func probe() -> Shell.GroupMembershipAdapter.Read {
                probes += 1
                return .bytes(probes == 1 ? Int32(MemoryLayout<pid_t>.size) : Int32(2 * MemoryLayout<pid_t>.size))
            }
        }
        let growth = GrowthScript()
        let race = Shell.GroupMembershipAdapter(
            probe: { _ in growth.probe() },
            read: { _, _ in .members([leader], bytes: Int32(MemoryLayout<pid_t>.size)) }
        )
        XCTAssertNil(Shell.stableGroupMembers(leader, adapter: race))
    }

    func testDurableReapOwnershipIsClaimedOnceAndReleasedOnce() {
        var ledger = Shell.ReapOwnershipLedger(maximumPending: 1)
        let first = try! XCTUnwrap(ledger.reserve())
        XCTAssertNil(ledger.reserve())
        XCTAssertTrue(ledger.bind(first, child: 77))
        XCTAssertFalse(ledger.bind(first, child: 77))
        XCTAssertTrue(ledger.transfer(first, child: 77))
        XCTAssertFalse(ledger.transfer(first, child: 77))
        XCTAssertTrue(ledger.release(first))
        XCTAssertFalse(ledger.release(first))
        XCTAssertNotNil(ledger.reserve())
    }

    func testReservationIdentityCollisionFailsClosedWithoutOverwritingLiveOwner() {
        var ledger = Shell.ReapOwnershipLedger(maximumPending: 3)
        let firstID = UUID(), secondID = UUID()
        XCTAssertEqual(ledger.reserve(generateID: { firstID }), firstID)
        XCTAssertTrue(ledger.bind(firstID, child: 901))
        var generated = [firstID, secondID]
        XCTAssertEqual(ledger.reserve(generateID: { generated.removeFirst() }), secondID)
        XCTAssertEqual(ledger.entries[firstID], .bound(901))
        XCTAssertEqual(ledger.entries[secondID], .reserved)
        XCTAssertEqual(ledger.entries.count, 2)
        XCTAssertNil(ledger.reserve(generateID: { firstID }))
        XCTAssertEqual(ledger.entries.count, 2, "a collision run cannot overwrite or consume a live reservation")

        // A bind-failure containment path may transfer its still-reserved
        // token, but it cannot steal a child identity already owned elsewhere.
        XCTAssertTrue(ledger.transfer(secondID, child: 902))
        XCTAssertFalse(ledger.transfer(firstID, child: 902))
    }

    func testDeferredPollAdapterDoesNotStarveLaterChildrenAndClassifiesErrors() {
        let pending = Shell.DeferredWaitAdapter(waitNoHang: { _ in 0 }, errno: { 0 })
        let reaped = Shell.DeferredWaitAdapter(waitNoHang: { child in child }, errno: { 0 })
        let interrupted = Shell.DeferredWaitAdapter(waitNoHang: { _ in -1 }, errno: { EINTR })
        let fatal = Shell.DeferredWaitAdapter(waitNoHang: { _ in -1 }, errno: { EIO })
        // Each pending child is independently polled; a non-exiting first
        // child cannot prevent a reaped later child from being released.
        XCTAssertEqual(Shell.deferredWaitOutcome(1, adapter: pending), .pending)
        XCTAssertEqual(Shell.deferredWaitOutcome(2, adapter: reaped), .reaped)
        XCTAssertEqual(Shell.deferredWaitOutcome(3, adapter: interrupted), .interrupted)
        XCTAssertEqual(Shell.deferredWaitOutcome(4, adapter: fatal), .fatal)
    }
}
