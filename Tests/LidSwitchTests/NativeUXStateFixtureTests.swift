import Dispatch
import Foundation
import LidSwitchCore
import XCTest
@testable import LidSwitch

final class NativeUXStateFixtureTests: XCTestCase {
    func testInitialDelayedRefreshUsesOneNoncriticalLabelAndSpinnerContract() {
        let contract = PowerControllerDisplayContract.make(
            snapshot: .empty,
            operationPhase: .idle,
            isChecking: true
        )

        XCTAssertEqual(contract.title, "Checking current macOS state…")
        XCTAssertEqual(contract.menuBarSymbol, "arrow.triangle.2.circlepath")
        XCTAssertEqual(contract.panelSymbol, "arrow.triangle.2.circlepath")
        XCTAssertEqual(contract.tone, .neutral)
        XCTAssertFalse(contract.accessibilityState.contains("Power status unavailable"))
        XCTAssertTrue(contract.accessibilityState.contains("initial safety check"))
    }

    func testStartingContractOutranksTheEmptySnapshotAndKeepsCancelAvailable() {
        let contract = PowerControllerDisplayContract.make(
            snapshot: .empty,
            operationPhase: .starting,
            isChecking: true
        )

        XCTAssertEqual(contract.title, "Starting and verifying…")
        XCTAssertEqual(contract.menuBarSymbol, "clock.badge.checkmark")
        XCTAssertEqual(contract.panelSymbol, "clock.fill")
        XCTAssertEqual(contract.tone, .progress)
        XCTAssertTrue(contract.detail.contains("Cancel and Restore remains available"))
        XCTAssertEqual(
            PowerControllerPrimaryAction.resolve(snapshot: .empty, operationPhase: .starting),
            .cancelStart
        )
    }

    func testEndingRestoringContractOutranksAStaleActiveSnapshot() {
        let active = makeActiveSnapshot(sessionID: UUID())
        let contract = PowerControllerDisplayContract.make(
            snapshot: active,
            operationPhase: .endingRestoring,
            isChecking: false
        )

        XCTAssertEqual(contract.title, "Ending and restoring…")
        XCTAssertEqual(contract.menuBarSymbol, "arrow.triangle.2.circlepath")
        XCTAssertEqual(contract.panelSymbol, "arrow.triangle.2.circlepath")
        XCTAssertEqual(contract.tone, .progress)
        XCTAssertNotEqual(contract.tone, .active)
        XCTAssertFalse(contract.accessibilityState.contains("Protection active"))
        XCTAssertTrue(contract.accessibilityState.contains("not reporting protection as active"))
        XCTAssertEqual(
            PowerControllerPrimaryAction.resolve(
                snapshot: active,
                operationPhase: .endingRestoring
            ),
            .stopAndRestore
        )
        XCTAssertEqual(
            PowerControllerPrimaryAction.resolve(
                snapshot: makeSnapshot(sleepDisabled: true),
                operationPhase: .endingRestoring
            ),
            .restoreSleep
        )
        XCTAssertEqual(
            PowerControllerPrimaryAction.resolve(
                snapshot: makeSnapshot(),
                operationPhase: .endingRestoring
            ),
            .endingRestoringProgress
        )
    }

    func testCancelRestoringIsNoncriticalAndPreservesAuthoritativeSafetyRouting() {
        let ready = makeSnapshot()
        let pending = makeSnapshot(ownedSessionID: UUID())
        let restore = makeSnapshot(sleepDisabled: true)
        let contract = PowerControllerDisplayContract.make(
            snapshot: ready,
            operationPhase: .cancelRestoring,
            isChecking: false
        )

        XCTAssertEqual(contract.title, "Canceling and restoring…")
        XCTAssertEqual(contract.tone, .neutral)
        XCTAssertEqual(contract.menuBarSymbol, "arrow.triangle.2.circlepath")
        XCTAssertEqual(
            PowerControllerPrimaryAction.resolve(snapshot: ready, operationPhase: .cancelRestoring),
            .cancelRestoringProgress
        )
        XCTAssertEqual(
            PowerControllerPrimaryAction.resolve(snapshot: pending, operationPhase: .cancelRestoring),
            .stopAndRestore
        )
        XCTAssertEqual(
            PowerControllerPrimaryAction.resolve(snapshot: restore, operationPhase: .cancelRestoring),
            .restoreSleep
        )
    }

    func testAdministratorProgressContractsAreSpecificAndMaskStaleActiveTruth() {
        let active = makeActiveSnapshot(sessionID: UUID())
        let safe = makeSnapshot()
        let recovery = makeRecoveryRequiredSnapshot()
        let cases: [(
            PowerControllerOperationPhase,
            String,
            String,
            String,
            PowerControllerPrimaryAction
        )] = [
            (
                .preparingHelper,
                "Preparing safe helper…",
                "shield.lefthalf.filled",
                "replacing old startup behavior",
                .preparingHelperProgress
            ),
            (
                .removingHelper,
                "Removing helper…",
                "trash.circle",
                "removing helper components",
                .removingHelperProgress
            ),
        ]

        for (phase, title, symbol, detailPhrase, progressAction) in cases {
            let contract = PowerControllerDisplayContract.make(
                snapshot: active,
                operationPhase: phase,
                isChecking: false
            )
            XCTAssertEqual(contract.title, title)
            XCTAssertEqual(contract.menuBarSymbol, symbol)
            XCTAssertEqual(contract.panelSymbol, symbol)
            XCTAssertEqual(contract.tone, .progress)
            XCTAssertNotEqual(contract.tone, .active)
            XCTAssertTrue(contract.detail.contains(detailPhrase))
            XCTAssertTrue(
                contract.accessibilityState.lowercased()
                    .contains(String(title.dropLast()).lowercased())
            )
            XCTAssertTrue(contract.accessibilityState.contains("not being reported active"))
            XCTAssertFalse(contract.accessibilityState.contains("Protection active"))
            XCTAssertEqual(
                PowerControllerPrimaryAction.resolve(snapshot: active, operationPhase: phase),
                .stopAndRestore
            )
            XCTAssertEqual(
                PowerControllerPrimaryAction.resolve(snapshot: recovery, operationPhase: phase),
                .restoreSleep
            )
            XCTAssertEqual(
                PowerControllerPrimaryAction.resolve(snapshot: safe, operationPhase: phase),
                progressAction
            )
        }
    }

    func testAdministratorSpinnerAccessibilityNamesPrepareAndRemoveOperations() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent("Sources/LidSwitch/Views/LidSwitchPanel.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Preparing the LidSwitch helper safely"))
        XCTAssertTrue(source.contains("Removing the LidSwitch helper safely"))
        XCTAssertLessThan(
            try XCTUnwrap(source.range(of: "operationPhase == .preparingHelper")).lowerBound,
            try XCTUnwrap(source.range(of: "return \"LidSwitch operation in progress\"")).lowerBound
        )
        XCTAssertLessThan(
            try XCTUnwrap(source.range(of: "operationPhase == .removingHelper")).lowerBound,
            try XCTUnwrap(source.range(of: "return \"LidSwitch operation in progress\"")).lowerBound
        )
    }

    func testActivePendingRestoreAndRecoveryShareOneTitleAndAccessibilityContract() {
        let sessionID = UUID()
        let now = Date()
        let active = makeSnapshot(
            sleepDisabled: true,
            ownedSessionID: sessionID,
            status: HelperStatusRecord(
                state: "active",
                reason: "fixture",
                sessionID: sessionID,
                updatedAt: now
            ),
            checkedAt: now
        )
        let pending = makeSnapshot(ownedSessionID: sessionID)
        let restore = makeSnapshot(sleepDisabled: true)
        let recovery = makeSnapshot(
            status: HelperStatusRecord(
                state: "recovery-required",
                reason: "fixture",
                sessionID: nil,
                updatedAt: now
            ),
            checkedAt: now
        )
        let cases: [(PowerSnapshot, PowerControllerPrimaryAction)] = [
            (active, .stopAndRestore),
            (pending, .stopAndRestore),
            (restore, .restoreSleep),
            (recovery, .restoreSleep),
        ]

        for (snapshot, expectedAction) in cases {
            let contract = PowerControllerDisplayContract.make(
                snapshot: snapshot,
                operationPhase: .idle,
                isChecking: false
            )
            XCTAssertEqual(contract.title, snapshot.statusTitle)
            XCTAssertEqual(contract.detail, snapshot.statusDetail)
            XCTAssertEqual(contract.accessibilityState, snapshot.accessibilityState)
            XCTAssertEqual(
                PowerControllerPrimaryAction.resolve(snapshot: snapshot, operationPhase: .idle),
                expectedAction
            )
        }
    }

    func testCurrentBootPeerDeathTerminalPersistsAfterDelayedRelaunchWithoutRearm() throws {
        let sessionID = UUID()
        let now = Date()
        let currentBootID = try XCTUnwrap(BootIdentity.current())
        let monotonicNow = MonotonicClock.seconds()
        let delayedRelaunchTerminal = makeSnapshot(
            status: HelperStatusRecord(
                state: "terminal",
                reason: "peer-process-invalid",
                sessionID: sessionID,
                updatedAt: now.addingTimeInterval(-1_200),
                bootID: currentBootID,
                updatedMonotonic: max(0, monotonicNow - 1)
            ),
            checkedAt: now
        )
        let previousBootTerminal = makeSnapshot(
            status: HelperStatusRecord(
                state: "terminal",
                reason: "peer-process-invalid",
                sessionID: sessionID,
                updatedAt: now.addingTimeInterval(-1_200),
                bootID: "previous-boot",
                updatedMonotonic: 1
            ),
            checkedAt: now
        )

        XCTAssertTrue(delayedRelaunchTerminal.previousPeerProcessEndedSafely)
        XCTAssertFalse(delayedRelaunchTerminal.sessionActive)
        XCTAssertFalse(delayedRelaunchTerminal.sessionPending)
        XCTAssertFalse(delayedRelaunchTerminal.restoreRequired)
        XCTAssertTrue(delayedRelaunchTerminal.canStartSession)
        XCTAssertEqual(delayedRelaunchTerminal.statusTitle, "Previous session ended safely")
        XCTAssertTrue(delayedRelaunchTerminal.statusDetail.contains("LidSwitch stopped running"))
        XCTAssertTrue(delayedRelaunchTerminal.statusDetail.contains("restored system sleep"))
        XCTAssertEqual(
            PowerControllerPrimaryAction.resolve(snapshot: delayedRelaunchTerminal, operationPhase: .idle),
            .startSession,
            "the informational terminal record must not auto-start, rearm, or block an explicit new Start"
        )

        XCTAssertFalse(previousBootTerminal.previousPeerProcessEndedSafely)
        XCTAssertEqual(previousBootTerminal.statusTitle, "Ready for monitored session")
        XCTAssertFalse(PowerSnapshot.isCurrentBootPeerProcessSafeIdle(
            helperStatus: HelperStatusRecord(
                state: "terminal",
                reason: "peer-process-invalid",
                sessionID: sessionID,
                updatedAt: now,
                bootID: currentBootID,
                updatedMonotonic: monotonicNow + 1
            ),
            ownedSessionID: nil,
            sleepDisabledVerified: true,
            sleepDisabled: false,
            acIdleSleepMinutes: 5,
            helperRecoveryRequired: false,
            currentBootID: currentBootID,
            currentMonotonic: monotonicNow
        ))
    }

    func testCommandKSemanticsAreLimitedToActualSafetyActions() {
        XCTAssertTrue(PowerControllerPrimaryAction.cancelStart.usesCommandK)
        XCTAssertTrue(PowerControllerPrimaryAction.stopAndRestore.usesCommandK)
        XCTAssertTrue(PowerControllerPrimaryAction.restoreSleep.usesCommandK)
        XCTAssertTrue(PowerControllerPrimaryAction.startSession.usesCommandK)
        XCTAssertFalse(PowerControllerPrimaryAction.cancelRestoringProgress.usesCommandK)
        XCTAssertFalse(PowerControllerPrimaryAction.endingRestoringProgress.usesCommandK)
        XCTAssertFalse(PowerControllerPrimaryAction.preparingHelperProgress.usesCommandK)
        XCTAssertFalse(PowerControllerPrimaryAction.removingHelperProgress.usesCommandK)
        XCTAssertFalse(PowerControllerPrimaryAction.prepareHelper.usesCommandK)
    }

    @MainActor
    func testPreflightCancelIssuesNoLease() async {
        let preflightEntered = DispatchSemaphore(value: 0)
        let releasePreflight = DispatchSemaphore(value: 0)
        let events = UXLockedBox([String]())
        let safe = makeSnapshot()
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in
                preflightEntered.signal()
                _ = releasePreflight.wait(timeout: .now() + 2)
                return safe
            },
            sideEffects: .recordingFixture { event in
                events.mutate { $0.append(event) }
            },
            safeRollbackWaiter: { safe },
            announcementHandler: { _ in }
        )

        controller.startSession()
        XCTAssertEqual(preflightEntered.wait(timeout: .now() + 1), .success)
        controller.cancelPendingStart()
        releasePreflight.signal()
        let completed = await eventually { !controller.isBusy && !controller.isCancelRestoring }

        XCTAssertTrue(completed)
        XCTAssertEqual(events.read { $0.filter { $0 == "lease-issue" }.count }, 0)
        XCTAssertEqual(events.read { $0.filter { $0 == "lease-revoke" }.count }, 0)
    }

    @MainActor
    func testWillTerminateInvalidatesHeldStartPreflightBeforeBegin() async {
        let preflightEntered = DispatchSemaphore(value: 0)
        let releasePreflight = DispatchSemaphore(value: 0)
        let events = UXLockedBox([String]())
        let safe = makeSnapshot()
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in
                preflightEntered.signal()
                _ = releasePreflight.wait(timeout: .now() + 2)
                return safe
            },
            sideEffects: .recordingFixture { event in
                events.mutate { $0.append(event) }
            },
            safeRollbackWaiter: { safe },
            announcementHandler: { _ in }
        )
        let delegate = LidSwitchApplicationDelegate()
        LidSwitchApplicationDelegate.controller = controller
        defer { LidSwitchApplicationDelegate.controller = nil }

        controller.startSession()
        XCTAssertEqual(preflightEntered.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(controller.requiresTerminationCleanup)
        let preTerminationEpoch = controller.sessionEpochForTesting

        delegate.applicationWillTerminate(
            Notification(name: Notification.Name("fixture-will-terminate"))
        )

        XCTAssertGreaterThan(controller.sessionEpochForTesting, preTerminationEpoch)
        XCTAssertFalse(controller.isStarting)
        XCTAssertFalse(controller.isBusy)
        releasePreflight.signal()
        await assertEventually { !controller.isChecking }

        let recorded = events.read { $0 }
        XCTAssertFalse(recorded.contains("desired-state-disabled"))
        XCTAssertFalse(recorded.contains("lease-issue"))
        XCTAssertFalse(recorded.contains("heartbeat"))
        XCTAssertFalse(recorded.contains("activity-begin"))
        XCTAssertNil(controller.activeSessionIDForTesting)

        controller.startSession()
        XCTAssertFalse(controller.isStarting)
        XCTAssertEqual(events.read { $0 }, recorded)
    }

    @MainActor
    func testRestoreAndQuitCancelsHeldStartPreflightBeforeAnyAuthorityCanBegin() async {
        let preflightEntered = DispatchSemaphore(value: 0)
        let releasePreflight = DispatchSemaphore(value: 0)
        let events = UXLockedBox([String]())
        let completion = UXLockedBox<Bool?>(nil)
        let safe = makeSnapshot()
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in
                preflightEntered.signal()
                _ = releasePreflight.wait(timeout: .now() + 2)
                return safe
            },
            sideEffects: .recordingFixture { event in
                events.mutate { $0.append(event) }
            },
            safeRollbackWaiter: { safe },
            announcementHandler: { _ in }
        )

        controller.startSession()
        XCTAssertEqual(preflightEntered.wait(timeout: .now() + 1), .success)
        let startEpoch = controller.sessionEpochForTesting
        controller.prepareForSystemTermination { restored in
            completion.mutate { $0 = restored }
        }

        await assertEventually { completion.read { $0 } != nil }
        XCTAssertEqual(completion.read { $0 }, true)
        XCTAssertGreaterThan(controller.sessionEpochForTesting, startEpoch)
        XCTAssertFalse(controller.isStarting)
        XCTAssertFalse(controller.isBusy)
        XCTAssertNil(controller.activeSessionIDForTesting)

        releasePreflight.signal()
        await assertEventually { !controller.isChecking }

        // `lease-issue` is the fixture boundary that represents authenticated
        // BEGIN. None of these authority or process-activity effects may occur
        // after Restore & Quit invalidates the held preflight generation.
        let recorded = events.read { $0 }
        XCTAssertFalse(recorded.contains("desired-state-disabled"))
        XCTAssertFalse(recorded.contains("lease-issue"))
        XCTAssertFalse(recorded.contains("heartbeat"))
        XCTAssertFalse(recorded.contains("activity-begin"))
        XCTAssertFalse(recorded.contains("lease-revoke"))
    }

    @MainActor
    func testRestoreAndQuitReportsFailureWhenPendingStartCannotProveSafeIdle() async {
        let preflightEntered = DispatchSemaphore(value: 0)
        let releasePreflight = DispatchSemaphore(value: 0)
        let events = UXLockedBox([String]())
        let completion = UXLockedBox<Bool?>(nil)
        let safe = makeSnapshot()
        let unsafe = makeSnapshot(sleepDisabled: true)
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in
                preflightEntered.signal()
                _ = releasePreflight.wait(timeout: .now() + 2)
                return safe
            },
            sideEffects: .recordingFixture { event in
                events.mutate { $0.append(event) }
            },
            safeRollbackWaiter: { unsafe },
            announcementHandler: { _ in }
        )

        controller.startSession()
        XCTAssertEqual(preflightEntered.wait(timeout: .now() + 1), .success)
        controller.prepareForSystemTermination { restored in
            completion.mutate { $0 = restored }
        }

        await assertEventually { completion.read { $0 } != nil }
        XCTAssertEqual(completion.read { $0 }, false)
        XCTAssertEqual(controller.snapshot, unsafe)
        XCTAssertEqual(controller.displayedStatus.title, "Restore required")
        XCTAssertEqual(controller.displayedStatus.tone, .warning)
        XCTAssertNotNil(controller.errorMessage)

        releasePreflight.signal()
        await assertEventually { !controller.isChecking }
        XCTAssertTrue(events.read { $0 }.isEmpty)
    }

    @MainActor
    func testHeldPreflightTerminationReplySurvivesRestoreEscalationFailureExactlyOnce() async {
        let preflightEntered = DispatchSemaphore(value: 0)
        let releasePreflight = DispatchSemaphore(value: 0)
        let rollbackEntered = DispatchSemaphore(value: 0)
        let releaseRollback = DispatchSemaphore(value: 0)
        let rollbackReturned = DispatchSemaphore(value: 0)
        let snapshotCalls = UXLockedBox(0)
        let events = UXLockedBox([String]())
        let replies = UXLockedBox([Bool]())
        let safe = makeSnapshot()
        let unsafe = makeSnapshot(sleepDisabled: true)
        let current = UXLockedBox(safe)
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in
                let call = snapshotCalls.mutate { value -> Int in
                    value += 1
                    return value
                }
                if call == 1 {
                    preflightEntered.signal()
                    _ = releasePreflight.wait(timeout: .now() + 2)
                }
                return current.read { $0 }
            },
            sideEffects: .recordingFixture { event in
                events.mutate { $0.append(event) }
            },
            safeRollbackWaiter: {
                rollbackEntered.signal()
                _ = releaseRollback.wait(timeout: .now() + 2)
                rollbackReturned.signal()
                return unsafe
            },
            restoreVerificationWaiter: { unsafe },
            announcementHandler: { _ in }
        )

        controller.startSession()
        XCTAssertEqual(preflightEntered.wait(timeout: .now() + 1), .success)
        controller.prepareForSystemTermination { restored in
            replies.mutate { $0.append(restored) }
        }
        XCTAssertEqual(rollbackEntered.wait(timeout: .now() + 1), .success)

        releasePreflight.signal()
        await assertEventually { !controller.isChecking }
        current.mutate { $0 = unsafe }
        controller.refreshManually()
        await assertEventually {
            controller.snapshot == unsafe
                && !controller.isChecking
                && controller.primaryAction == .restoreSleep
        }

        controller.restoreNow()
        await assertEventually { replies.read { $0.count } == 1 }
        XCTAssertEqual(replies.read { $0 }, [false])
        XCTAssertFalse(controller.isBusy)
        XCTAssertEqual(controller.operationPhase, .idle)
        XCTAssertEqual(controller.primaryAction, .restoreSleep)

        releaseRollback.signal()
        XCTAssertEqual(rollbackReturned.wait(timeout: .now() + 1), .success)
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(replies.read { $0 }, [false])
        let recorded = events.read { $0 }
        XCTAssertEqual(recorded.filter { $0 == "restore-sleep" }.count, 1)
        XCTAssertFalse(recorded.contains("desired-state-disabled"))
        XCTAssertFalse(recorded.contains("lease-issue"))
        XCTAssertFalse(recorded.contains("heartbeat"))
        XCTAssertFalse(recorded.contains("activity-begin"))
        XCTAssertFalse(recorded.contains("lease-revoke"))
    }

    @MainActor
    func testIssuedAuthorityTerminationReplySurvivesRestoreEscalationWithOneCleanup() async {
        let rollbackEntered = DispatchSemaphore(value: 0)
        let releaseRollback = DispatchSemaphore(value: 0)
        let rollbackReturned = DispatchSemaphore(value: 0)
        let events = UXLockedBox([String]())
        let replies = UXLockedBox([Bool]())
        let safe = makeSnapshot()
        let unsafe = makeSnapshot(sleepDisabled: true)
        let current = UXLockedBox(safe)
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in current.read { $0 } },
            sideEffects: .recordingFixture(
                { event in events.mutate { $0.append(event) } },
                terminalResolution: { sessionID, _ in
                    .terminated(Self.protocolTerminalReply(sessionID: sessionID))
                }
            ),
            safeRollbackWaiter: {
                rollbackEntered.signal()
                _ = releaseRollback.wait(timeout: .now() + 2)
                rollbackReturned.signal()
                return unsafe
            },
            restoreVerificationWaiter: { safe },
            announcementHandler: { _ in }
        )

        controller.startSession()
        await assertEventually {
            events.read { $0.contains("lease-issue") } && controller.isStarting
        }
        controller.prepareForSystemTermination { restored in
            replies.mutate { $0.append(restored) }
        }
        XCTAssertEqual(rollbackEntered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(events.read { $0.filter { $0 == "lease-revoke" }.count }, 1)

        current.mutate { $0 = unsafe }
        controller.refreshManually()
        await assertEventually {
            controller.snapshot == unsafe
                && !controller.isChecking
                && controller.primaryAction == .restoreSleep
        }
        controller.restoreNow()
        await assertEventually { replies.read { $0.count } == 1 }
        XCTAssertEqual(replies.read { $0 }, [true])
        XCTAssertFalse(controller.isBusy)
        XCTAssertEqual(controller.operationPhase, .idle)

        releaseRollback.signal()
        XCTAssertEqual(rollbackReturned.wait(timeout: .now() + 1), .success)
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(replies.read { $0 }, [true])
        let recorded = events.read { $0 }
        XCTAssertEqual(recorded.filter { $0 == "desired-state-disabled" }.count, 1)
        XCTAssertEqual(recorded.filter { $0 == "lease-issue" }.count, 1)
        XCTAssertEqual(recorded.filter { $0 == "heartbeat" }.count, 1)
        XCTAssertEqual(recorded.filter { $0 == "activity-begin" }.count, 1)
        XCTAssertEqual(recorded.filter { $0 == "activity-end" }.count, 1)
        XCTAssertEqual(recorded.filter { $0 == "lease-revoke" }.count, 1)
        XCTAssertEqual(recorded.filter { $0 == "restore-sleep" }.count, 1)
    }

    @MainActor
    func testIssuedAuthorityTerminationReplySurvivesStopEscalationWithOneCleanup() async {
        let firstRollbackEntered = DispatchSemaphore(value: 0)
        let releaseFirstRollback = DispatchSemaphore(value: 0)
        let firstRollbackReturned = DispatchSemaphore(value: 0)
        let rollbackCalls = UXLockedBox(0)
        let events = UXLockedBox([String]())
        let replies = UXLockedBox([Bool]())
        let safe = makeSnapshot()
        let stalePending = makeSnapshot(ownedSessionID: UUID())
        let current = UXLockedBox(safe)
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in current.read { $0 } },
            sideEffects: .recordingFixture(
                { event in events.mutate { $0.append(event) } },
                terminalResolution: { sessionID, _ in
                    .terminated(Self.protocolTerminalReply(sessionID: sessionID))
                }
            ),
            safeRollbackWaiter: {
                let call = rollbackCalls.mutate { value -> Int in
                    value += 1
                    return value
                }
                if call == 1 {
                    firstRollbackEntered.signal()
                    _ = releaseFirstRollback.wait(timeout: .now() + 2)
                    firstRollbackReturned.signal()
                    return stalePending
                }
                return safe
            },
            announcementHandler: { _ in }
        )

        controller.startSession()
        await assertEventually {
            events.read { $0.contains("lease-issue") } && controller.isStarting
        }
        controller.prepareForSystemTermination { restored in
            replies.mutate { $0.append(restored) }
        }
        XCTAssertEqual(firstRollbackEntered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(events.read { $0.filter { $0 == "lease-revoke" }.count }, 1)

        current.mutate { $0 = stalePending }
        controller.refreshManually()
        await assertEventually {
            controller.snapshot == stalePending
                && !controller.isChecking
                && controller.primaryAction == .stopAndRestore
        }
        controller.stopSession()
        await assertEventually { replies.read { $0.count } == 1 }
        XCTAssertEqual(replies.read { $0 }, [true])
        XCTAssertEqual(rollbackCalls.read { $0 }, 2)
        XCTAssertFalse(controller.isBusy)
        XCTAssertEqual(controller.operationPhase, .idle)

        releaseFirstRollback.signal()
        XCTAssertEqual(firstRollbackReturned.wait(timeout: .now() + 1), .success)
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(replies.read { $0 }, [true])
        let recorded = events.read { $0 }
        XCTAssertEqual(recorded.filter { $0 == "desired-state-disabled" }.count, 1)
        XCTAssertEqual(recorded.filter { $0 == "lease-issue" }.count, 1)
        XCTAssertEqual(recorded.filter { $0 == "heartbeat" }.count, 1)
        XCTAssertEqual(recorded.filter { $0 == "activity-begin" }.count, 1)
        XCTAssertEqual(recorded.filter { $0 == "activity-end" }.count, 1)
        XCTAssertEqual(recorded.filter { $0 == "lease-revoke" }.count, 1)
        XCTAssertFalse(recorded.contains("restore-sleep"))
    }

    @MainActor
    func testIssuedLeaseCancelRevokesExactlyOnce() async {
        let events = UXLockedBox([String]())
        let safe = makeSnapshot()
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in safe },
            sideEffects: .recordingFixture(
                { event in events.mutate { $0.append(event) } },
                terminalResolution: { sessionID, _ in
                    .terminated(Self.protocolTerminalReply(sessionID: sessionID))
                }
            ),
            safeRollbackWaiter: { safe },
            announcementHandler: { _ in }
        )

        controller.startSession()
        let issued = await eventually {
            events.read { $0.contains("lease-issue") } && controller.isStarting
        }
        XCTAssertTrue(issued)
        controller.cancelPendingStart()
        let completed = await eventually { !controller.isBusy && !controller.isCancelRestoring }

        XCTAssertTrue(completed)
        XCTAssertEqual(events.read { $0.filter { $0 == "lease-issue" }.count }, 1)
        XCTAssertEqual(events.read { $0.filter { $0 == "lease-revoke" }.count }, 1)
    }

    @MainActor
    func testRestoreAndQuitRevokesIssuedPendingStartExactlyOnceBeforeReplyingTrue() async {
        let events = UXLockedBox([String]())
        let completion = UXLockedBox<Bool?>(nil)
        let safe = makeSnapshot()
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in safe },
            sideEffects: .recordingFixture(
                { event in events.mutate { $0.append(event) } },
                terminalResolution: { sessionID, _ in
                    .terminated(Self.protocolTerminalReply(sessionID: sessionID))
                }
            ),
            safeRollbackWaiter: { safe },
            announcementHandler: { _ in }
        )

        controller.startSession()
        await assertEventually {
            events.read { $0.contains("lease-issue") } && controller.isStarting
        }
        controller.prepareForSystemTermination { restored in
            completion.mutate { $0 = restored }
        }

        await assertEventually { completion.read { $0 } != nil }
        XCTAssertEqual(completion.read { $0 }, true)
        XCTAssertEqual(events.read { $0.filter { $0 == "lease-issue" }.count }, 1)
        XCTAssertEqual(events.read { $0.filter { $0 == "lease-revoke" }.count }, 1)
        XCTAssertEqual(events.read { $0.filter { $0 == "activity-begin" }.count }, 1)
        XCTAssertEqual(events.read { $0.filter { $0 == "activity-end" }.count }, 1)
        XCTAssertNil(controller.activeSessionIDForTesting)
        XCTAssertFalse(controller.isBusy)
    }

    @MainActor
    func testHeldCancelWaiterRemainsInCancelRestoringPhase() async {
        let waiterEntered = DispatchSemaphore(value: 0)
        let releaseWaiter = DispatchSemaphore(value: 0)
        let safe = makeSnapshot()
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in safe },
        sideEffects: .recordingFixture(
            { _ in },
            terminalResolution: { sessionID, _ in
                .terminated(Self.protocolTerminalReply(sessionID: sessionID))
            }
        ),
            safeRollbackWaiter: {
                waiterEntered.signal()
                _ = releaseWaiter.wait(timeout: .now() + 2)
                return safe
            },
            announcementHandler: { _ in }
        )

        controller.startSession()
        let issued = await eventually { controller.activeSessionIDForTesting != nil }
        XCTAssertTrue(issued)
        controller.cancelPendingStart()
        XCTAssertEqual(waiterEntered.wait(timeout: .now() + 1), .success)

        XCTAssertTrue(controller.isBusy)
        XCTAssertTrue(controller.isCancelRestoring)
        XCTAssertEqual(controller.operationPhase, .cancelRestoring)
        XCTAssertEqual(controller.displayedStatus.title, "Canceling and restoring…")
        XCTAssertEqual(controller.primaryAction, .cancelRestoringProgress)

        releaseWaiter.signal()
        let completed = await eventually { !controller.isBusy && controller.operationPhase == .idle }
        XCTAssertTrue(completed)
    }

    @MainActor
    func testUnexpectedOwnedRollbackBecomesActionableRecoveryInsteadOfPermanentProgress() async {
        let sessionID = UUID()
        let safe = makeSnapshot()
        let stalePending = makeSnapshot(ownedSessionID: sessionID)
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in safe },
        sideEffects: .recordingFixture(
            { _ in },
            terminalResolution: { sessionID, _ in
                .terminated(Self.protocolTerminalReply(sessionID: sessionID))
            }
        ),
            safeRollbackWaiter: { stalePending },
            announcementHandler: { _ in }
        )

        controller.startSession()
        await assertEventually { controller.activeSessionIDForTesting != nil }
        controller.cancelPendingStart()
        await assertEventually {
            !controller.isBusy && controller.operationPhase == .recoveryRequired
        }

        XCTAssertEqual(controller.snapshot, stalePending)
        XCTAssertEqual(controller.displayedStatus.title, "Recovery required")
        XCTAssertEqual(controller.displayedStatus.tone, .warning)
        XCTAssertEqual(controller.primaryAction, .stopAndRestore)
        XCTAssertFalse(controller.displayedStatus.accessibilityState.contains("Protection active"))

        controller.refreshManually()
        await assertEventually {
            !controller.isChecking
                && controller.operationPhase == .idle
                && controller.snapshot == safe
        }
        XCTAssertNil(controller.errorMessage)
    }

    @MainActor
    func testHeartbeatEndHeldRollbackMasksStaleActiveThenConvergesSafe() async {
        let waiterEntered = DispatchSemaphore(value: 0)
        let releaseWaiter = DispatchSemaphore(value: 0)
        let sessionID = UUID()
        let active = makeActiveSnapshot(sessionID: sessionID)
        let safe = makeSnapshot()
        let current = UXLockedBox(active)
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in current.read { $0 } },
            sideEffects: .fixture,
            safeRollbackWaiter: {
                waiterEntered.signal()
                _ = releaseWaiter.wait(timeout: .now() + 2)
                return safe
            },
            announcementHandler: { _ in }
        )

        controller.refresh()
        await assertEventually { controller.snapshot == active && !controller.isChecking }
        controller.simulateNewSessionForTesting(sessionID)
        let epoch = controller.sessionEpochForTesting
        controller.simulateHeartbeatEndForTesting(
            sessionID: sessionID,
            epoch: epoch,
            reason: "fixture-heartbeat-end"
        )
        XCTAssertEqual(waiterEntered.wait(timeout: .now() + 1), .success)

        assertEndingRestoringTruth(controller)

        current.mutate { $0 = safe }
        releaseWaiter.signal()
        await assertEventually {
            !controller.isBusy && controller.operationPhase == .idle
        }
        XCTAssertEqual(controller.snapshot, safe)
        XCTAssertEqual(controller.displayedStatus.title, safe.statusTitle)
        XCTAssertEqual(controller.displayedStatus.tone, .neutral)
        XCTAssertNil(controller.errorMessage)
    }

    @MainActor
    func testUserStopHeldRollbackMasksStaleActiveThenConvergesFailure() async {
        let waiterEntered = DispatchSemaphore(value: 0)
        let releaseWaiter = DispatchSemaphore(value: 0)
        let waiterCalls = UXLockedBox(0)
        let sessionID = UUID()
        let active = makeActiveSnapshot(sessionID: sessionID)
        let failure = makeSnapshot(sleepDisabled: true)
        let current = UXLockedBox(active)
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in current.read { $0 } },
            sideEffects: .fixture,
            safeRollbackWaiter: {
                let call = waiterCalls.mutate { value -> Int in
                    value += 1
                    return value
                }
                if call == 1 {
                    waiterEntered.signal()
                    _ = releaseWaiter.wait(timeout: .now() + 2)
                }
                return failure
            },
            announcementHandler: { _ in }
        )

        controller.refresh()
        await assertEventually { controller.snapshot == active && !controller.isChecking }
        controller.simulateNewSessionForTesting(sessionID)
        controller.stopSession()
        XCTAssertEqual(waiterEntered.wait(timeout: .now() + 1), .success)

        assertEndingRestoringTruth(controller)

        current.mutate { $0 = failure }
        releaseWaiter.signal()
        await assertEventually {
            !controller.isBusy && controller.operationPhase == .idle
        }
        XCTAssertEqual(controller.snapshot, failure)
        XCTAssertEqual(controller.displayedStatus.title, "Restore required")
        XCTAssertEqual(controller.displayedStatus.tone, .warning)
        XCTAssertNotNil(controller.errorMessage)
    }

    @MainActor
    func testExplicitRestoreHeldVerificationMasksStaleActiveThenConvergesSafe() async {
        let waiterEntered = DispatchSemaphore(value: 0)
        let releaseWaiter = DispatchSemaphore(value: 0)
        let sessionID = UUID()
        let active = makeActiveSnapshot(sessionID: sessionID)
        let safe = makeSnapshot()
        let current = UXLockedBox(active)
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in current.read { $0 } },
            sideEffects: .fixture,
            restoreVerificationWaiter: {
                waiterEntered.signal()
                _ = releaseWaiter.wait(timeout: .now() + 2)
                return safe
            },
            announcementHandler: { _ in }
        )

        controller.refresh()
        await assertEventually { controller.snapshot == active && !controller.isChecking }
        controller.simulateNewSessionForTesting(sessionID)
        controller.restoreNow()
        XCTAssertEqual(waiterEntered.wait(timeout: .now() + 1), .success)

        assertEndingRestoringTruth(controller)

        current.mutate { $0 = safe }
        releaseWaiter.signal()
        await assertEventually {
            !controller.isBusy
                && !controller.isChecking
                && controller.operationPhase == .idle
                && controller.snapshot == safe
        }
        XCTAssertEqual(controller.displayedStatus.title, safe.statusTitle)
        XCTAssertEqual(controller.displayedStatus.tone, .neutral)
        XCTAssertNil(controller.errorMessage)
    }

    @MainActor
    func testHeldActiveUninstallMasksStaleGreenThenConvergesSafeUninstalled() async {
        let administratorEntered = DispatchSemaphore(value: 0)
        let releaseAdministrator = DispatchSemaphore(value: 0)
        let sessionID = UUID()
        let active = makeActiveSnapshot(sessionID: sessionID)
        let removed = makeSnapshot(helperArtifactsPresent: false, helperLoaded: false)
        let current = UXLockedBox(active)
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in current.read { $0 } },
            sideEffects: .recordingFixture(
                { _ in },
                administratorResult: { operation in
                    administratorEntered.signal()
                    _ = releaseAdministrator.wait(timeout: .now() + 2)
                    return Self.safeAdministratorResult(operation: operation)
                }
            ),
            announcementHandler: { _ in }
        )

        controller.refresh()
        await assertEventually { controller.snapshot == active && !controller.isChecking }
        controller.simulateNewSessionForTesting(sessionID)
        controller.uninstallHelper()
        XCTAssertEqual(administratorEntered.wait(timeout: .now() + 1), .success)

        assertAdministratorProgressTruth(
            controller,
            phase: .removingHelper,
            title: "Removing helper…",
            symbol: "trash.circle"
        )

        current.mutate { $0 = removed }
        releaseAdministrator.signal()
        await assertEventually {
            !controller.isBusy
                && !controller.isChecking
                && controller.operationPhase == .idle
                && controller.snapshot == removed
        }
        XCTAssertEqual(controller.displayedStatus.title, "Protection off")
        XCTAssertEqual(controller.displayedStatus.tone, .neutral)
        XCTAssertNil(controller.errorMessage)
    }

    @MainActor
    func testHeldActiveUninstallMasksStaleGreenThenPublishesRecoveryFailure() async {
        let administratorEntered = DispatchSemaphore(value: 0)
        let releaseAdministrator = DispatchSemaphore(value: 0)
        let sessionID = UUID()
        let active = makeActiveSnapshot(sessionID: sessionID)
        let recovery = makeRecoveryRequiredSnapshot()
        let current = UXLockedBox(active)
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in current.read { $0 } },
            sideEffects: .recordingFixture(
                { _ in },
                administratorResult: { operation in
                    administratorEntered.signal()
                    _ = releaseAdministrator.wait(timeout: .now() + 2)
                    return Self.recoveryRequiredAdministratorResult(operation: operation)
                }
            ),
            restoreVerificationWaiter: { recovery },
            announcementHandler: { _ in }
        )

        controller.refresh()
        await assertEventually { controller.snapshot == active && !controller.isChecking }
        controller.simulateNewSessionForTesting(sessionID)
        controller.uninstallHelper()
        XCTAssertEqual(administratorEntered.wait(timeout: .now() + 1), .success)

        assertAdministratorProgressTruth(
            controller,
            phase: .removingHelper,
            title: "Removing helper…",
            symbol: "trash.circle"
        )

        current.mutate { $0 = recovery }
        releaseAdministrator.signal()
        await assertEventually {
            !controller.isBusy
                && controller.operationPhase == .idle
                && controller.snapshot == recovery
        }
        XCTAssertEqual(controller.displayedStatus.title, "Recovery required")
        XCTAssertEqual(controller.displayedStatus.tone, .warning)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.displayedStatus.accessibilityState.contains("Protection active"))
    }

    @MainActor
    func testHeldActivePrepareMasksStaleGreenThenConvergesSafeReady() async {
        let administratorEntered = DispatchSemaphore(value: 0)
        let releaseAdministrator = DispatchSemaphore(value: 0)
        let sessionID = UUID()
        let active = makeActiveSnapshot(sessionID: sessionID)
        let safe = makeSnapshot()
        let current = UXLockedBox(active)
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in current.read { $0 } },
            sideEffects: .recordingFixture(
                { _ in },
                administratorResult: { operation in
                    administratorEntered.signal()
                    _ = releaseAdministrator.wait(timeout: .now() + 2)
                    return Self.safeAdministratorResult(operation: operation)
                }
            ),
            announcementHandler: { _ in }
        )

        controller.refresh()
        await assertEventually { controller.snapshot == active && !controller.isChecking }
        controller.simulateNewSessionForTesting(sessionID)
        controller.prepareHelper()
        XCTAssertEqual(administratorEntered.wait(timeout: .now() + 1), .success)

        assertAdministratorProgressTruth(
            controller,
            phase: .preparingHelper,
            title: "Preparing safe helper…",
            symbol: "shield.lefthalf.filled"
        )

        current.mutate { $0 = safe }
        releaseAdministrator.signal()
        await assertEventually {
            !controller.isBusy
                && !controller.isChecking
                && controller.operationPhase == .idle
                && controller.snapshot == safe
        }
        XCTAssertEqual(controller.displayedStatus.title, safe.statusTitle)
        XCTAssertEqual(controller.displayedStatus.tone, .neutral)
        XCTAssertNil(controller.errorMessage)
    }

    @MainActor
    func testCancelSafeAndFailureAnnouncementsAreExactAndSingle() async {
        let safeMessage = "Session canceled. Protection off. System sleep restored."
        let failureMessage = PowerControllerAlert
            .rollbackVerificationFailure(reason: "pending-start-cancelled")
            .message

        let safeAnnouncements = UXLockedBox([String]())
        let safe = makeSnapshot()
        let safeController = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in safe },
            sideEffects: .recordingFixture(
                { _ in },
                terminalResolution: { sessionID, _ in
                    .terminated(Self.protocolTerminalReply(sessionID: sessionID))
                }
            ),
            safeRollbackWaiter: { safe },
            announcementHandler: { message in
                safeAnnouncements.mutate { $0.append(message) }
            }
        )
        safeController.startSession()
        _ = await eventually { safeController.activeSessionIDForTesting != nil }
        safeController.cancelPendingStart()
        _ = await eventually { !safeController.isBusy }

        let failureAnnouncements = UXLockedBox([String]())
        let unsafe = makeSnapshot(sleepDisabled: true)
        let failureController = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in safe },
            sideEffects: .fixture,
            safeRollbackWaiter: { unsafe },
            announcementHandler: { message in
                failureAnnouncements.mutate { $0.append(message) }
            }
        )
        failureController.startSession()
        _ = await eventually { failureController.activeSessionIDForTesting != nil }
        failureController.cancelPendingStart()
        _ = await eventually { !failureController.isBusy }

        XCTAssertEqual(safeAnnouncements.read { $0.filter { $0 == safeMessage }.count }, 1)
        XCTAssertEqual(failureAnnouncements.read { $0.filter { $0 == failureMessage }.count }, 1)
        XCTAssertEqual(failureController.errorMessage, failureMessage)
    }

    @MainActor
    func testStaleAcknowledgeAndEndAfterCancelAndNextSessionAreInert() async throws {
        let announcements = UXLockedBox([String]())
        let safe = makeSnapshot()
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in safe },
            sideEffects: .recordingFixture(
                { _ in },
                terminalResolution: { sessionID, _ in
                    .terminated(Self.protocolTerminalReply(sessionID: sessionID))
                }
            ),
            safeRollbackWaiter: { safe },
            announcementHandler: { message in
                announcements.mutate { $0.append(message) }
            }
        )

        controller.startSession()
        _ = await eventually { controller.activeSessionIDForTesting != nil }
        let staleEpoch = controller.sessionEpochForTesting
        controller.cancelPendingStart()
        _ = await eventually { !controller.isBusy }

        controller.startSession()
        let nextScheduled = await eventually {
            controller.activeSessionIDForTesting != nil
                && controller.sessionEpochForTesting > staleEpoch
                && controller.isStarting
        }
        XCTAssertTrue(nextScheduled)
        let nextSessionID = try XCTUnwrap(controller.activeSessionIDForTesting)
        let nextEpoch = controller.sessionEpochForTesting

        // Use the next UUID intentionally: UUID-only matching would accept
        // these callbacks, while the captured scheduling epoch rejects them.
        controller.simulateHeartbeatAcknowledgeForTesting(
            sessionID: nextSessionID,
            epoch: staleEpoch
        )
        controller.simulateHeartbeatEndForTesting(
            sessionID: nextSessionID,
            epoch: staleEpoch,
            reason: "stale-generation"
        )

        XCTAssertTrue(controller.isStarting)
        XCTAssertTrue(controller.isBusy)
        XCTAssertEqual(controller.activeSessionIDForTesting, nextSessionID)
        XCTAssertEqual(controller.sessionEpochForTesting, nextEpoch)
        XCTAssertEqual(
            announcements.read { $0.filter { $0 == "Protection active — plugged in." }.count },
            0
        )

        controller.simulateHeartbeatAcknowledgeForTesting(
            sessionID: nextSessionID,
            epoch: nextEpoch
        )
        XCTAssertFalse(controller.isStarting)
        XCTAssertFalse(controller.isBusy)
        controller.simulateHeartbeatEndForTesting(
            sessionID: nextSessionID,
            epoch: staleEpoch,
            reason: "stale-generation-after-ack"
        )
        XCTAssertFalse(controller.isBusy)
        XCTAssertEqual(controller.activeSessionIDForTesting, nextSessionID)
        XCTAssertEqual(controller.sessionEpochForTesting, nextEpoch)
        XCTAssertEqual(
            announcements.read { $0.filter { $0 == "Protection active — plugged in." }.count },
            1
        )
    }

    @MainActor
    func testIndeterminateBeginFailureStaysRestoringThenRecoveryRequiredUntilFreshSafeProof() async {
        let waiterEntered = DispatchSemaphore(value: 0)
        let releaseWaiter = DispatchSemaphore(value: 0)
        let events = UXLockedBox([String]())
        let safe = makeSnapshot()
        let unsafe = makeSnapshot(
            status: HelperStatusRecord(
                state: "active",
                reason: "fixture-rearm-window",
                sessionID: UUID(),
                updatedAt: Date()
            )
        )
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in safe },
            sideEffects: .lifecycleFixture(
                { event in events.mutate { $0.append(event) } },
                issueLease: { _ in .authorityMayRemain("begin-and-reconnect-indeterminate") },
                terminateLease: { _, intent in
                    events.mutate { $0.append(intent == .end ? "remote-end" : "remote-restore") }
                },
                makeHeartbeat: { _, _, _, _ in nil }
            ),
            safeRollbackWaiter: {
                waiterEntered.signal()
                _ = releaseWaiter.wait(timeout: .now() + 2)
                return unsafe
            },
            announcementHandler: { _ in }
        )

        controller.startSession()
        await assertEventually {
            events.read { $0.contains("lease-issue") }
                && controller.isCancelRestoring
        }
        XCTAssertEqual(waiterEntered.wait(timeout: .now() + 1), .success)

        XCTAssertTrue(controller.isBusy)
        XCTAssertTrue(controller.isCancelRestoring)
        XCTAssertEqual(controller.displayedStatus.title, "Canceling and restoring…")
        XCTAssertNotNil(controller.cleanupOwnerSessionIDForTesting)
        XCTAssertNotNil(controller.cleanupOwnerGenerationForTesting)
        XCTAssertEqual(events.read { $0.filter { $0 == "lease-issue" }.count }, 1)
        XCTAssertEqual(events.read { $0.filter { $0 == "remote-restore" }.count }, 1)
        XCTAssertFalse(events.read { $0.contains("activity-begin") })
        XCTAssertFalse(controller.displayedStatus.accessibilityState.contains("Protection active"))

        releaseWaiter.signal()
        await assertEventually {
            !controller.isBusy && controller.operationPhase == .recoveryRequired
        }
        XCTAssertEqual(controller.snapshot, unsafe)
        XCTAssertEqual(controller.displayedStatus.title, "Recovery required")
        XCTAssertTrue(controller.requiresTerminationCleanup)
        XCTAssertNotNil(controller.cleanupOwnerSessionIDForTesting)
        XCTAssertEqual(events.read { $0.filter { $0 == "remote-restore" }.count }, 1)
        XCTAssertFalse(controller.errorMessage?.contains("Protection remains off") == true)
    }

    @MainActor
    func testAuthenticatedTerminalBeginResolutionClearsOnlyNoAuthorityOwnerWithoutPowerClaim() async {
        let waiterCalls = UXLockedBox(0)
        let events = UXLockedBox([String]())
        let safe = makeSnapshot()
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in safe },
            sideEffects: .lifecycleFixture(
                { event in events.mutate { $0.append(event) } },
                issueLease: { sessionID in .terminal(Self.protocolTerminalReply(sessionID: sessionID)) },
                terminateLease: { _, _ in events.mutate { $0.append("unexpected-remote-terminal") } },
                makeHeartbeat: { _, _, _, _ in nil }
            ),
            safeRollbackWaiter: {
                waiterCalls.mutate { $0 += 1 }
                return safe
            },
            announcementHandler: { _ in }
        )

        controller.startSession()
        await assertEventually { !controller.isBusy && controller.operationPhase == .idle }
        XCTAssertEqual(waiterCalls.read { $0 }, 0)
        XCTAssertNil(controller.cleanupOwnerSessionIDForTesting)
        XCTAssertFalse(events.read { $0.contains("unexpected-remote-terminal") })
        XCTAssertFalse(events.read { $0.contains("activity-begin") })
        XCTAssertFalse(controller.requiresTerminationCleanup)
        XCTAssertEqual(controller.displayedStatus.title, "Ready for monitored session")
        XCTAssertTrue(controller.errorMessage?.contains("Session did not start") == true)
        XCTAssertTrue(controller.errorMessage?.contains("no power rollback was claimed") == true)
        XCTAssertFalse(events.read { $0.contains("unexpected-remote-terminal") })
    }

    func testGenerationBoundRollbackProofRejectsNilStaleUnrelatedWrongStateAndChangedPower() {
        let sessionID = UUID()
        let otherSessionID = UUID()
        let now = Date()
        let exactTerminal = HelperStatusRecord(
            state: "terminal",
            reason: "fixture",
            sessionID: sessionID,
            updatedAt: now
        )
        let exactInactive = HelperStatusRecord(
            state: "inactive",
            reason: "fixture",
            sessionID: sessionID,
            updatedAt: now
        )

        XCTAssertFalse(PowerController.cleanupProofForTesting(
            sessionID: sessionID, originalACIdleSleepMinutes: 5, snapshot: makeSnapshot()
        ), "nil root status cannot clear cleanup")
        XCTAssertFalse(PowerController.cleanupProofForTesting(
            sessionID: sessionID,
            originalACIdleSleepMinutes: 5,
            snapshot: makeSnapshot(status: HelperStatusRecord(
                state: "terminal", reason: "stale", sessionID: sessionID,
                updatedAt: now.addingTimeInterval(-30)
            ), checkedAt: now)
        ), "stale status cannot clear cleanup")
        XCTAssertFalse(PowerController.cleanupProofForTesting(
            sessionID: sessionID,
            originalACIdleSleepMinutes: 5,
            snapshot: makeSnapshot(status: HelperStatusRecord(
                state: "terminal", reason: "other", sessionID: otherSessionID, updatedAt: now
            ), checkedAt: now)
        ), "unrelated generation cannot clear cleanup")
        XCTAssertFalse(PowerController.cleanupProofForTesting(
            sessionID: sessionID,
            originalACIdleSleepMinutes: 5,
            snapshot: makeSnapshot(status: HelperStatusRecord(
                state: "active", reason: "still-active", sessionID: sessionID, updatedAt: now
            ), checkedAt: now)
        ), "active status cannot clear cleanup")
        XCTAssertFalse(PowerController.cleanupProofForTesting(
            sessionID: sessionID,
            originalACIdleSleepMinutes: 5,
            snapshot: makeSnapshot(status: HelperStatusRecord(
                state: "recovery-required", reason: "rollback-pending", sessionID: sessionID, updatedAt: now
            ), checkedAt: now)
        ), "recovery-required status cannot clear cleanup")
        XCTAssertFalse(PowerController.cleanupProofForTesting(
            sessionID: sessionID,
            originalACIdleSleepMinutes: 5,
            snapshot: makeSnapshot(acIdleSleepMinutes: nil, status: exactTerminal, checkedAt: now)
        ), "missing AC idle value cannot be reported restored")
        XCTAssertFalse(PowerController.cleanupProofForTesting(
            sessionID: sessionID,
            originalACIdleSleepMinutes: 5,
            snapshot: makeSnapshot(acIdleSleepMinutes: 4, status: exactTerminal, checkedAt: now)
        ), "changed AC idle setting cannot be reported restored")
        XCTAssertFalse(PowerController.cleanupProofForTesting(
            sessionID: sessionID,
            originalACIdleSleepMinutes: 5,
            snapshot: makeSnapshot(sleepDisabledVerified: false, status: exactTerminal, checkedAt: now)
        ), "unverified SleepDisabled cannot clear cleanup")
        XCTAssertFalse(PowerController.cleanupProofForTesting(
            sessionID: sessionID,
            originalACIdleSleepMinutes: 5,
            snapshot: makeSnapshot(sleepDisabled: true, status: exactTerminal, checkedAt: now)
        ), "SleepDisabled=true cannot clear cleanup")
        XCTAssertTrue(PowerController.cleanupProofForTesting(
            sessionID: sessionID,
            originalACIdleSleepMinutes: 5,
            snapshot: makeSnapshot(status: exactInactive, checkedAt: now)
        ))
        XCTAssertTrue(PowerController.cleanupProofForTesting(
            sessionID: sessionID,
            originalACIdleSleepMinutes: 0,
            snapshot: makeSnapshot(acIdleSleepMinutes: 0, status: exactTerminal, checkedAt: now)
        ), "a legitimate original AC idle value of zero must be preserved")
    }

    func testAuthenticatedTerminalReplyProofRequiresExactSessionAndCompletePowerValues() {
        let sessionID = UUID()
        let exact = Self.terminalReply(sessionID: sessionID, acIdleSleepMinutes: 5)
        XCTAssertTrue(PowerController.authenticatedCleanupReplyProofForTesting(
            sessionID: sessionID,
            originalACIdleSleepMinutes: 5,
            resolution: .terminated(exact)
        ))
        XCTAssertFalse(PowerController.authenticatedCleanupReplyProofForTesting(
            sessionID: sessionID,
            originalACIdleSleepMinutes: 5,
            resolution: .terminated(Self.terminalReply(sessionID: UUID(), acIdleSleepMinutes: 5))
        ))
        XCTAssertFalse(PowerController.authenticatedCleanupReplyProofForTesting(
            sessionID: sessionID,
            originalACIdleSleepMinutes: 5,
            resolution: .terminated(HelperControlReply(
                reason: "bad-power", sessionID: sessionID, expiryMonotonic: 0,
                state: .terminal, power: .ac, sleepDisabled: true, acSleepMinutes: 5
            ))
        ))
        XCTAssertFalse(PowerController.authenticatedCleanupReplyProofForTesting(
            sessionID: sessionID,
            originalACIdleSleepMinutes: 5,
            resolution: .terminated(Self.terminalReply(sessionID: sessionID, acIdleSleepMinutes: nil))
        ))
    }

    @MainActor
    func testStaleFailedStartWaiterCannotReleaseLaterGenerationCleanupOwner() async throws {
        let firstWaiterEntered = DispatchSemaphore(value: 0)
        let releaseFirstWaiter = DispatchSemaphore(value: 0)
        let waiterCalls = UXLockedBox(0)
        let issueCalls = UXLockedBox(0)
        let issuedSessions = UXLockedBox(Set<UUID>())
        let terminalEffects = UXLockedBox(0)
        let safe = makeSnapshot()
        let firstGenerationSafeSnapshot = UXLockedBox(safe)
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in safe },
            sideEffects: .lifecycleFixture(
                { _ in },
                issueLease: { sessionID in
                    let call = issueCalls.mutate { value -> Int in
                        value += 1
                        return value
                    }
                    if call == 1 {
                        firstGenerationSafeSnapshot.mutate {
                            $0 = Self.firstGenerationTerminalSnapshot(sessionID: sessionID)
                        }
                        return .authorityMayRemain("fixture-first-generation")
                    }
                    issuedSessions.mutate { $0.insert(sessionID) }
                    return .issued(Self.fixtureLease(sessionID: sessionID))
                },
                terminateLease: { _, _ in terminalEffects.mutate { $0 += 1 } },
                makeHeartbeat: { _, _, _, _ in nil },
                terminalResolution: { sessionID, _ in
                    issuedSessions.read { $0.contains(sessionID) }
                        ? .terminated(Self.protocolTerminalReply(sessionID: sessionID))
                        : nil
                }
            ),
            safeRollbackWaiter: {
                let call = waiterCalls.mutate { value -> Int in
                    value += 1
                    return value
                }
                if call == 1 {
                    firstWaiterEntered.signal()
                    _ = releaseFirstWaiter.wait(timeout: .now() + 2)
                }
                return firstGenerationSafeSnapshot.read { $0 }
            },
            restoreVerificationWaiter: { firstGenerationSafeSnapshot.read { $0 } },
            announcementHandler: { _ in }
        )

        controller.startSession()
        await assertEventually {
            issueCalls.read { $0 } == 1 && controller.isCancelRestoring
        }
        XCTAssertEqual(firstWaiterEntered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(terminalEffects.read { $0 }, 1)

        controller.restoreNow()
        await assertEventually {
            !controller.isBusy && controller.cleanupOwnerSessionIDForTesting == nil
        }

        controller.startSession()
        await assertEventually {
            controller.isStarting && controller.cleanupOwnerSessionIDForTesting != nil
        }
        let laterSessionID = try XCTUnwrap(controller.cleanupOwnerSessionIDForTesting)
        let laterGeneration = try XCTUnwrap(controller.cleanupOwnerGenerationForTesting)

        releaseFirstWaiter.signal()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(controller.cleanupOwnerSessionIDForTesting, laterSessionID)
        XCTAssertEqual(controller.cleanupOwnerGenerationForTesting, laterGeneration)
        XCTAssertTrue(controller.isStarting)
        XCTAssertEqual(terminalEffects.read { $0 }, 1)

        controller.cancelPendingStart()
        await assertEventually { !controller.isBusy }
        XCTAssertEqual(terminalEffects.read { $0 }, 2)
        XCTAssertNil(controller.cleanupOwnerSessionIDForTesting)
    }

    @MainActor
    func testRealHeartbeatRestoreAndQuitOwnsOneRemoteTerminalEffectAndOneReentrantReply() async throws {
        let events = UXLockedBox([String]())
        let replies = UXLockedBox([Bool]())
        let coordinatorBox = UXLockedBox<SessionHeartbeatCoordinator?>(nil)
        let safe = makeSnapshot()
        let controllerBox = UXLockedBox<PowerController?>(nil)
        let diagnosticsDirectory = try TestSandbox.makeDirectory(label: "controller-heartbeat")
        addTeardownBlock {
            try FileManager.default.removeItem(at: diagnosticsDirectory.url)
        }
        let diagnostics = SessionDiagnosticStore(
            file: diagnosticsDirectory.url.appendingPathComponent("diagnostics")
        )
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in safe },
            sideEffects: .lifecycleFixture(
                { event in events.mutate { $0.append(event) } },
                issueLease: { sessionID in .issued(Self.fixtureLease(sessionID: sessionID)) },
                terminateLease: { _, _ in events.mutate { $0.append("direct-terminal") } },
                makeHeartbeat: { _, onAcknowledged, onEnded, claimCleanup in
                    let coordinator = SessionHeartbeatCoordinator(
                        observationInterval: 60,
                        renewalInterval: 8,
                        observe: { _ in
                            SessionHeartbeatObservation(
                                power: .ac,
                                authority: .verified,
                                helperStatus: nil
                            )
                        },
                        renew: { _, _ in .renewed(expiryMonotonic: MonotonicClock.seconds() + 30) },
                        revoke: {
                            events.mutate { $0.append(claimCleanup() ? "heartbeat-restore" : "duplicate-terminal") }
                        },
                        endRemote: { endedSessionID, _ in
                            events.mutate { $0.append(claimCleanup() ? "heartbeat-end" : "duplicate-terminal") }
                            PowerController.recordHeartbeatTerminalProofForTesting(
                                sessionID: endedSessionID,
                                resolution: .terminated(Self.protocolTerminalReply(sessionID: endedSessionID))
                            )
                        },
                        diagnostics: diagnostics,
                        onAcknowledged: onAcknowledged,
                        onEnded: onEnded
                    )
                    coordinatorBox.mutate { $0 = coordinator }
                    return coordinator
                }
            ),
            safeRollbackWaiter: { safe },
            announcementHandler: { _ in }
        )
        controllerBox.mutate { $0 = controller }

        controller.startSession()
        await assertEventually {
            coordinatorBox.read { $0 != nil }
                && !controller.isStarting
                && !controller.isBusy
        }
        XCTAssertNotNil(controller.cleanupOwnerSessionIDForTesting)

        controller.prepareForSystemTermination { restored in
            replies.mutate { $0.append(restored) }
            // AppKit can synchronously re-enter will-terminate from this reply.
            MainActor.assumeIsolated {
                controllerBox.read { $0 }?.revokeForImmediateTermination()
            }
        }

        await assertEventually { replies.read { $0.count } == 1 }
        XCTAssertEqual(replies.read { $0 }, [true])
        XCTAssertEqual(events.read { $0.filter { $0 == "heartbeat-end" }.count }, 1)
        XCTAssertFalse(events.read { $0.contains("heartbeat-restore") })
        XCTAssertFalse(events.read { $0.contains("direct-terminal") })
        XCTAssertFalse(events.read { $0.contains("duplicate-terminal") })
        XCTAssertEqual(events.read { $0.filter { $0 == "activity-end" }.count }, 1)
        XCTAssertNil(controller.cleanupOwnerSessionIDForTesting)
    }

    @MainActor
    func testImmediateTerminationAndDuplicateLifecycleEntryClaimOneRemoteCleanup() async {
        let events = UXLockedBox([String]())
        let safe = makeSnapshot()
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in safe },
            sideEffects: .lifecycleFixture(
                { event in events.mutate { $0.append(event) } },
                issueLease: { sessionID in .issued(Self.fixtureLease(sessionID: sessionID)) },
                terminateLease: { _, _ in events.mutate { $0.append("remote-terminal") } },
                makeHeartbeat: { _, _, _, _ in nil }
            ),
            announcementHandler: { _ in }
        )

        controller.startSession()
        await assertEventually {
            controller.isStarting && controller.cleanupOwnerSessionIDForTesting != nil
        }
        controller.revokeForImmediateTermination()
        controller.revokeForImmediateTermination()

        XCTAssertEqual(events.read { $0.filter { $0 == "remote-terminal" }.count }, 1)
        XCTAssertEqual(events.read { $0.filter { $0 == "activity-end" }.count }, 1)
        XCTAssertNil(controller.activeSessionIDForTesting)
        XCTAssertFalse(controller.isBusy)
        XCTAssertFalse(controller.isStarting)
    }

    func testHeartbeatInFlightRenewalOrdersTerminalLatchBeforeSingleRemoteEffect() throws {
        let diagnosticsDirectory = try TestSandbox.makeDirectory(label: "heartbeat-order")
        addTeardownBlock {
            try FileManager.default.removeItem(at: diagnosticsDirectory.url)
        }
        let diagnosticFile = diagnosticsDirectory.url.appendingPathComponent("diagnostics")
        let monotonic = UXLockedBox<TimeInterval>(0)
        let renewEntered = DispatchSemaphore(value: 0)
        let releaseRenew = DispatchSemaphore(value: 0)
        let renewalFinished = DispatchSemaphore(value: 0)
        let stopScheduled = DispatchSemaphore(value: 0)
        let stopFinished = DispatchSemaphore(value: 0)
        let commitGuard = UXLockedBox<(@Sendable () -> Bool)?>(nil)
        let events = UXLockedBox([String]())
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 1,
            renewalInterval: 8,
            monotonicNow: { monotonic.read { $0 } },
            observe: { _ in
                SessionHeartbeatObservation(power: .ac, authority: .verified, helperStatus: nil)
            },
            renew: { _, guardCommit in
                XCTAssertTrue(guardCommit())
                commitGuard.mutate { $0 = guardCommit }
                renewEntered.signal()
                _ = releaseRenew.wait(timeout: .now() + 2)
                return .renewed(expiryMonotonic: 38)
            },
            revoke: { events.mutate { $0.append("remote-restore") } },
            endRemote: { _, _ in
                XCTAssertFalse(commitGuard.read { $0?() ?? true })
                events.mutate { $0.append("remote-end") }
            },
            diagnostics: SessionDiagnosticStore(file: diagnosticFile),
            onAcknowledged: { _ in },
            onEnded: { _, _ in events.mutate { $0.append("callback") } }
        )
        coordinator.start(
            sessionID: UUID(),
            initialLeaseExpiresMonotonic: 30,
            initiallyAcknowledged: true
        )
        monotonic.mutate { $0 = 8 }

        DispatchQueue.global().async {
            coordinator.evaluateForTesting()
            renewalFinished.signal()
        }
        XCTAssertEqual(renewEntered.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async {
            stopScheduled.signal()
            _ = coordinator.stop(reason: "user-end")
            stopFinished.signal()
        }
        XCTAssertEqual(stopScheduled.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(events.read { $0.isEmpty })

        releaseRenew.signal()
        XCTAssertEqual(renewalFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(stopFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(events.read { $0 }, ["remote-end"])
        XCTAssertTrue(coordinator.stop(reason: "duplicate-stop"))
        XCTAssertEqual(events.read { $0 }, ["remote-end"])
    }

    func testHeartbeatSafetyEndPublishesCallbackAfterSingleRemoteCleanup() throws {
        let events = UXLockedBox([String]())
        let claimed = UXLockedBox(false)
        let diagnosticsDirectory = try TestSandbox.makeDirectory(label: "heartbeat-safety-end")
        addTeardownBlock {
            try FileManager.default.removeItem(at: diagnosticsDirectory.url)
        }
        let diagnostics = SessionDiagnosticStore(
            file: diagnosticsDirectory.url.appendingPathComponent("diagnostics")
        )
        let claimOnce: @Sendable () -> Bool = {
            claimed.mutate { value in
                guard !value else { return false }
                value = true
                return true
            }
        }
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 1,
            renewalInterval: 8,
            observe: { _ in
                SessionHeartbeatObservation(power: .disconnected, authority: .verified, helperStatus: nil)
            },
            renew: { _, _ in .renewed(expiryMonotonic: MonotonicClock.seconds() + 30) },
            revoke: {
                if claimOnce() { events.mutate { $0.append("remote-cleanup") } }
            },
            diagnostics: diagnostics,
            onAcknowledged: { _ in },
            onEnded: { _, _ in events.mutate { $0.append("callback") } }
        )
        coordinator.start(
            sessionID: UUID(),
            initialLeaseExpiresMonotonic: MonotonicClock.seconds() + 30,
            initiallyAcknowledged: true
        )
        coordinator.evaluateForTesting()

        XCTAssertEqual(events.read { $0 }, ["remote-cleanup", "callback"])
        XCTAssertTrue(coordinator.stop(reason: "duplicate-lifecycle-entry"))
        XCTAssertEqual(events.read { $0 }, ["remote-cleanup", "callback"])
    }

    @MainActor
    private func assertEventually(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let fulfilled = await eventually(condition)
        XCTAssertTrue(fulfilled, file: file, line: line)
    }

    @MainActor
    private func eventually(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    private func makeSnapshot(
        sleepDisabled: Bool = false,
        sleepDisabledVerified: Bool = true,
        acIdleSleepMinutes: Int? = 5,
        ownedSessionID: UUID? = nil,
        status: HelperStatusRecord? = nil,
        helperArtifactsPresent: Bool = true,
        helperLoaded: Bool = true,
        checkedAt: Date = Date()
    ) -> PowerSnapshot {
        let safeTerminal = HelperStatusRecord(
            state: "terminal",
            reason: "fixture-safe-idle",
            sessionID: nil,
            updatedAt: checkedAt
        )
        return PowerSnapshot(
            source: .ac,
            sleepDisabled: sleepDisabled,
            sleepDisabledVerified: sleepDisabledVerified,
            acIdleSleepMinutes: acIdleSleepMinutes,
            preferences: .disabled,
            helperArtifactsPresent: helperArtifactsPresent,
            helperLoaded: helperLoaded,
            helperNeedsUpdate: false,
            legacyLoginItemPresent: false,
            legacyLoginItemLoaded: false,
            activationLease: nil,
            ownedSessionID: ownedSessionID,
            helperStatus: status ?? safeTerminal,
            systemBuild: "25F84",
            systemBuildQualified: true,
            bundleIntegrityValid: true,
            bundleVersionValid: true,
            checkedAt: checkedAt,
            installationInventoryState: .valid
        )
    }

    private static func fixtureLease(sessionID: UUID) -> ActivationLease {
        let now = MonotonicClock.seconds()
        return ActivationLease(
            sessionID: sessionID,
            bootID: "fixture",
            expiresAt: Date().addingTimeInterval(30),
            issuedMonotonic: now,
            expiresMonotonic: now + 30,
            ownerUID: 501,
            systemBuild: "fixture"
        )
    }

    private static func protocolTerminalReply(sessionID: UUID) -> HelperControlReply {
        terminalReply(sessionID: sessionID, acIdleSleepMinutes: 5)
    }

    private static func firstGenerationTerminalSnapshot(sessionID: UUID) -> PowerSnapshot {
        let now = Date()
        return PowerSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true,
            acIdleSleepMinutes: 5,
            preferences: .disabled,
            helperArtifactsPresent: true,
            helperLoaded: true,
            helperNeedsUpdate: false,
            legacyLoginItemPresent: false,
            legacyLoginItemLoaded: false,
            activationLease: nil,
            ownedSessionID: nil,
            helperStatus: HelperStatusRecord(
                state: "terminal",
                reason: "fixture-first-generation",
                sessionID: sessionID,
                updatedAt: now
            ),
            systemBuild: "25F84",
            systemBuildQualified: true,
            bundleIntegrityValid: true,
            bundleVersionValid: true,
            checkedAt: now,
            installationInventoryState: .valid
        )
    }

    private static func terminalReply(
        sessionID: UUID,
        acIdleSleepMinutes: Int?
    ) -> HelperControlReply {
        HelperControlReply(
            reason: "reconnect-proved-terminal",
            sessionID: sessionID,
            expiryMonotonic: 0,
            state: .terminal,
            power: .ac,
            sleepDisabled: false,
            acSleepMinutes: acIdleSleepMinutes
        )
    }

    private func makeActiveSnapshot(sessionID: UUID) -> PowerSnapshot {
        let now = Date()
        return makeSnapshot(
            sleepDisabled: true,
            ownedSessionID: sessionID,
            status: HelperStatusRecord(
                state: "active",
                reason: "fixture",
                sessionID: sessionID,
                updatedAt: now
            ),
            checkedAt: now
        )
    }

    private func makeRecoveryRequiredSnapshot() -> PowerSnapshot {
        makeSnapshot(
            status: HelperStatusRecord(
                state: "recovery-required",
                reason: "fixture-admin-failure",
                sessionID: nil,
                updatedAt: Date()
            )
        )
    }

    private static func safeAdministratorResult(
        operation: AdministratorOperation
    ) -> AdministratorOperationResult {
        .safeIdle(.init(
            transactionID: UUID(),
            operation: operation,
            state: .terminal,
            outcome: .safeIdle,
            sessionID: nil,
            reason: "fixture"
        ))
    }

    private static func recoveryRequiredAdministratorResult(
        operation: AdministratorOperation
    ) -> AdministratorOperationResult {
        .recoveryRequired(.init(
            transactionID: UUID(),
            operation: operation,
            state: .terminal,
            outcome: .recoveryRequired,
            sessionID: nil,
            reason: "fixture-admin-failure"
        ))
    }

    @MainActor
    private func assertAdministratorProgressTruth(
        _ controller: PowerController,
        phase: PowerControllerOperationPhase,
        title: String,
        symbol: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(controller.isBusy, file: file, line: line)
        XCTAssertTrue(controller.requiresTerminationCleanup, file: file, line: line)
        XCTAssertEqual(controller.operationPhase, phase, file: file, line: line)
        XCTAssertEqual(controller.displayedStatus.title, title, file: file, line: line)
        XCTAssertEqual(controller.displayedStatus.menuBarSymbol, symbol, file: file, line: line)
        XCTAssertEqual(controller.displayedStatus.panelSymbol, symbol, file: file, line: line)
        XCTAssertEqual(controller.displayedStatus.tone, .progress, file: file, line: line)
        XCTAssertNotEqual(controller.displayedStatus.tone, .active, file: file, line: line)
        XCTAssertEqual(controller.primaryAction, .stopAndRestore, file: file, line: line)
        XCTAssertTrue(
            controller.displayedStatus.accessibilityState.contains("not being reported active"),
            file: file,
            line: line
        )
        XCTAssertFalse(
            controller.displayedStatus.accessibilityState.contains("Protection active"),
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertEndingRestoringTruth(
        _ controller: PowerController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(controller.isBusy, file: file, line: line)
        XCTAssertTrue(controller.requiresTerminationCleanup, file: file, line: line)
        XCTAssertTrue(controller.isEndingRestoring, file: file, line: line)
        XCTAssertEqual(controller.operationPhase, .endingRestoring, file: file, line: line)
        XCTAssertEqual(controller.displayedStatus.title, "Ending and restoring…", file: file, line: line)
        XCTAssertEqual(
            controller.displayedStatus.menuBarSymbol,
            "arrow.triangle.2.circlepath",
            file: file,
            line: line
        )
        XCTAssertEqual(
            controller.displayedStatus.panelSymbol,
            "arrow.triangle.2.circlepath",
            file: file,
            line: line
        )
        XCTAssertEqual(controller.displayedStatus.tone, .progress, file: file, line: line)
        XCTAssertNotEqual(controller.displayedStatus.tone, .active, file: file, line: line)
        XCTAssertEqual(controller.primaryAction, .stopAndRestore, file: file, line: line)
        XCTAssertFalse(
            controller.displayedStatus.accessibilityState.contains("Protection active"),
            file: file,
            line: line
        )
    }
}

private final class UXLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func read<Result>(_ body: (Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(value)
    }

    @discardableResult
    func mutate<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
