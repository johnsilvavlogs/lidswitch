import Dispatch
import Foundation
import LidSwitchCore
import XCTest
@testable import LidSwitch

final class OneSwitchControllerFixtureTests: XCTestCase {
    func testSourceChoicesRoundTripWithoutPersistingActivationAndLegacyBatteryCannotMigrateAsConsent() throws {
        let root = try TestSandbox.makeDirectory(label: "one-switch-preferences").url
        let file = root.appendingPathComponent("desired-state")
        let policy = try UserStateFileCapability.AncestryPolicy.testSandbox(root: root)
        let selected = PowerPreferences(keepAwakeEnabled: true, allowBatteryKeepAwake: true,
                                        allowPluggedInKeepAwake: false)
        try DesiredStateStore.write(selected, supportDirectory: root, stateFile: file, ancestryPolicy: policy)
        XCTAssertEqual(DesiredStateStore.readPreferences(from: file, capabilityPolicy: policy),
                       .value(selected.withKeepAwakeEnabled(false)))
        XCTAssertEqual(selected.storagePayload,
                       "schema=2\nmode=disabled\nplugged_in=disabled\nbattery=enabled\n")
        XCTAssertEqual(PowerPreferences.disabled.sessionPowerPolicy, .pluggedInOnly)
        let noSources = PowerPreferences(keepAwakeEnabled: false, allowBatteryKeepAwake: false,
                                          allowPluggedInKeepAwake: false)
        XCTAssertNil(PowerPreferences.parse(noSources.storagePayload).sessionPowerPolicy)
        let legacy = PowerPreferences.parse("mode=enabled\nbattery=enabled\n")
        XCTAssertTrue(legacy.invalidPersistenceDetected)
        XCTAssertTrue(legacy.legacyBatteryResidueDetected)
        XCTAssertFalse(legacy.allowBatteryKeepAwake)
        XCTAssertFalse(legacy.keepAwakeEnabled)
        XCTAssertEqual(PowerPreferences.parse(legacy.storagePayload), .disabled)
    }

    @MainActor
    func testBatteryDefaultsOffAndAnExcludedSourceWaitsWithoutCreatingAuthority() async {
        let state = SwitchFixtureBox(SwitchFixtureState(source: .battery(percent: 70)))
        let controller = makeController(state)
        controller.setKeepAwakeEnabled(true)
        assertTrue(await settles(controller))
        XCTAssertFalse(controller.powerPreferences.allowBatteryKeepAwake)
        XCTAssertTrue(controller.isKeepAwakeOn)
        XCTAssertNil(controller.activeSessionIDForTesting)
        XCTAssertEqual(controller.displayedStatus.title, "Paused")
        XCTAssertTrue(state.read { $0.policies.isEmpty })
        controller.setKeepAwakeEnabled(false)
        XCTAssertFalse(controller.isKeepAwakeOn)
    }

    @MainActor
    func testSavedBatteryChoiceStartsOffAndOneSwitchPassesItsPolicy() async throws {
        let state = SwitchFixtureBox(SwitchFixtureState(
            source: .battery(percent: 72),
            preferences: PowerPreferences(keepAwakeEnabled: false, allowBatteryKeepAwake: true,
                                          allowPluggedInKeepAwake: false)
        ))
        let controller = makeController(state)
        controller.refresh()
        assertTrue(await settles(controller))
        XCTAssertFalse(controller.isKeepAwakeOn)
        XCTAssertTrue(controller.powerPreferences.allowBatteryKeepAwake)
        XCTAssertFalse(controller.powerPreferences.allowPluggedInKeepAwake)

        controller.setKeepAwakeEnabled(true)
        assertTrue(await issued(controller))
        XCTAssertEqual(state.read { $0.policies }, [.batteryOnly])
        XCTAssertEqual(state.read { $0.heartbeatPolicies }, [.batteryOnly])
        try await acknowledge(controller)
        XCTAssertEqual(controller.displayedStatus.title, "Awake")
        controller.setKeepAwakeEnabled(false)
        assertTrue(await settles(controller))
        XCTAssertFalse(controller.isKeepAwakeOn)
        XCTAssertNil(controller.cleanupOwnerSessionIDForTesting)
        XCTAssertEqual(state.read { $0.events.filter { $0 == "prepare" }.count }, 0)
        XCTAssertEqual(state.read { $0.events.filter { $0 == "terminate" }.count }, 1)
    }

    @MainActor
    func testExcludedKnownSourceRestoresThenWaitsAndResumesOnlyWithinLiveRequest() async throws {
        let state = SwitchFixtureBox(SwitchFixtureState())
        let controller = makeController(state)
        controller.setKeepAwakeEnabled(true)
        assertTrue(await issued(controller))
        try await acknowledge(controller)
        let firstID = try XCTUnwrap(controller.activeSessionIDForTesting)
        state.mutate {
            $0.source = .battery(percent: 80)
            $0.restore(firstID)
        }
        controller.simulateHeartbeatEndForTesting(sessionID: firstID,
                                                 epoch: controller.sessionEpochForTesting,
                                                 reason: "power-source-excluded")
        assertTrue(await settles(controller))
        XCTAssertTrue(controller.isKeepAwakeOn)
        XCTAssertNil(controller.activeSessionIDForTesting)
        XCTAssertNil(controller.cleanupOwnerSessionIDForTesting)
        XCTAssertEqual(controller.displayedStatus.title, "Paused")
        XCTAssertEqual(state.read { $0.policies.count }, 1)

        state.mutate { $0.source = .ac }
        controller.refresh()
        assertTrue(await issued(controller))
        XCTAssertNotEqual(controller.activeSessionIDForTesting, firstID)
        XCTAssertEqual(state.read { $0.policies }, [.pluggedInOnly, .pluggedInOnly])
        controller.setKeepAwakeEnabled(false)
        assertTrue(await settles(controller))
        state.mutate { $0.source = .battery(percent: 80) }
        controller.refresh()
        assertTrue(await settles(controller))
        state.mutate { $0.source = .ac }
        controller.refresh()
        assertTrue(await settles(controller))
        XCTAssertEqual(state.read { $0.policies.count }, 2)
        XCTAssertFalse(controller.isKeepAwakeOn)
    }

    @MainActor
    func testChangingSourcesWhileOnEndsOldPolicyBeforeSavingAndStartingNewGeneration() async throws {
        let state = SwitchFixtureBox(SwitchFixtureState())
        let controller = makeController(state)
        controller.setKeepAwakeEnabled(true)
        assertTrue(await issued(controller))
        try await acknowledge(controller)
        let firstID = try XCTUnwrap(controller.activeSessionIDForTesting)
        controller.setAllowBatteryKeepAwake(true)
        assertTrue(await eventually {
            controller.activeSessionIDForTesting != nil && controller.activeSessionIDForTesting != firstID
        })
        XCTAssertTrue(controller.isKeepAwakeOn)
        XCTAssertEqual(state.read { $0.policies }, [.pluggedInOnly, .all])
        XCTAssertEqual(state.read { $0.heartbeatPolicies }, [.pluggedInOnly, .all])
        let events = state.read { $0.events }
        let endIndex = try XCTUnwrap(events.firstIndex(of: "terminate"))
        let saveIndex = try XCTUnwrap(events.firstIndex(of: "preferences"))
        let nextBeginIndex = try XCTUnwrap(events.lastIndex(of: "begin"))
        XCTAssertLessThan(endIndex, saveIndex)
        XCTAssertLessThan(saveIndex, nextBeginIndex)
        try await acknowledge(controller)

        controller.setAllowPluggedInKeepAwake(false)
        assertTrue(await settles(controller))
        XCTAssertTrue(controller.isKeepAwakeOn)
        XCTAssertEqual(controller.displayedStatus.title, "Paused")
        XCTAssertEqual(state.read { $0.policies.count }, 2)
        controller.setAllowBatteryKeepAwake(false)
        XCTAssertFalse(controller.isKeepAwakeOn)
        XCTAssertNil(controller.powerPreferences.sessionPowerPolicy)
        state.mutate { $0.source = .battery(percent: 70) }
        controller.refresh()
        assertTrue(await settles(controller))
        XCTAssertEqual(state.read { $0.policies.count }, 2)
    }

    @MainActor
    func testUnknownSourceAndFaultEndCannotRearmOnLaterGoodPower() async throws {
        for reason in ["power-source-unknown", "renew-failed"] {
            let state = SwitchFixtureBox(SwitchFixtureState())
            let controller = makeController(state)
            controller.setKeepAwakeEnabled(true)
            assertTrue(await issued(controller))
            try await acknowledge(controller)
            let sessionID = try XCTUnwrap(controller.activeSessionIDForTesting)
            state.mutate {
                $0.restore(sessionID)
                if reason == "power-source-unknown" { $0.source = .unknown("fixture") }
            }
            controller.simulateHeartbeatEndForTesting(sessionID: sessionID,
                                                     epoch: controller.sessionEpochForTesting, reason: reason)
            assertTrue(await settles(controller))
            XCTAssertFalse(controller.isKeepAwakeOn)
            state.mutate { $0.source = .ac }
            controller.refresh()
            assertTrue(await settles(controller))
            XCTAssertEqual(state.read { $0.policies.count }, 1)
            XCTAssertFalse(controller.isKeepAwakeOn)
        }
    }

    @MainActor
    func testOneTimeInstallContinuesRequestedSwitchWithoutAnotherToggleOrRoutinePreparation() async throws {
        let state = SwitchFixtureBox(SwitchFixtureState(helperReady: false))
        let controller = makeController(state)
        controller.setKeepAwakeEnabled(true)
        assertTrue(await issued(controller))
        XCTAssertEqual(state.read { $0.events.filter { $0 == "prepare" }.count }, 1)
        try await acknowledge(controller)
        controller.setKeepAwakeEnabled(false)
        assertTrue(await settles(controller))
        controller.setKeepAwakeEnabled(true)
        assertTrue(await issued(controller))
        XCTAssertEqual(state.read { $0.events.filter { $0 == "prepare" }.count }, 1)
        controller.setKeepAwakeEnabled(false)
        assertTrue(await settles(controller))
    }

    @MainActor
    func testHeldInitialPreparationPreservesOnAcrossInterimInventoryChangesAndStartsExactlyOnce() async throws {
        let state = SwitchFixtureBox(SwitchFixtureState(helperReady: false))
        let inventoryInTransition = SwitchFixtureBox(false)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let controller = makeHeldPreparationController(state, inventoryInTransition: inventoryInTransition,
                                                      entered: entered, release: release)
        controller.setKeepAwakeEnabled(true)
        let reached = await Task.detached { heldStartWasEntered(entered) }.value
        XCTAssertTrue(reached)
        XCTAssertTrue(controller.isKeepAwakeOn)
        XCTAssertEqual(controller.operationPhase, .preparingHelper)

        inventoryInTransition.mutate { $0 = true }
        controller.refresh()
        assertTrue(await eventually { !controller.isChecking && controller.snapshot.installationInventoryIndeterminate })
        XCTAssertTrue(controller.isKeepAwakeOn)
        XCTAssertEqual(controller.operationPhase, .preparingHelper)
        XCTAssertTrue(state.read { $0.policies.isEmpty })

        inventoryInTransition.mutate { $0 = false }
        release.signal()
        assertTrue(await issued(controller))
        try await acknowledge(controller)
        controller.refresh()
        assertTrue(await settles(controller))
        XCTAssertTrue(controller.isKeepAwakeOn)
        XCTAssertTrue(controller.snapshot.sessionActive)
        XCTAssertEqual(state.read { $0.policies }, [.pluggedInOnly])
        XCTAssertEqual(state.read { $0.events.filter { $0 == "prepare" }.count }, 1)
        XCTAssertEqual(state.read { $0.events.filter { $0 == "begin" }.count }, 1)
        controller.setKeepAwakeEnabled(false)
        assertTrue(await settles(controller))
    }

    @MainActor
    func testHeldPreparationCannotResumeAfterCancellationSafetyFailureOrFailedFinalConvergence() async {
        for cancellation in HeldPreparationCancellation.allCases {
            let state = SwitchFixtureBox(SwitchFixtureState(helperReady: false))
            let inventoryInTransition = SwitchFixtureBox(false)
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let controller = makeHeldPreparationController(
                state, inventoryInTransition: inventoryInTransition, entered: entered, release: release,
                failPreparation: cancellation == .administratorFailure
            )
            controller.setKeepAwakeEnabled(true)
            let reached = await Task.detached { heldStartWasEntered(entered) }.value
            XCTAssertTrue(reached, cancellation.rawValue)
            inventoryInTransition.mutate { $0 = true }
            controller.refresh()
            assertTrue(await eventually { !controller.isChecking && controller.snapshot.installationInventoryIndeterminate })
            XCTAssertTrue(controller.isKeepAwakeOn, cancellation.rawValue)

            switch cancellation {
            case .unknownSource:
                state.mutate { $0.source = .unknown("fixture") }
                controller.refresh()
                assertTrue(await eventually { !controller.isChecking })
                XCTAssertFalse(controller.isKeepAwakeOn)
                state.mutate { $0.source = .ac }
            case .recoveryRequired:
                state.mutate {
                    $0.projectedStatus = .init(state: "recovery-required", reason: "fixture",
                                              sessionID: nil, updatedAt: Date())
                }
                controller.refresh()
                assertTrue(await eventually { !controller.isChecking })
                XCTAssertFalse(controller.isKeepAwakeOn)
                state.mutate { $0.projectedStatus = nil }
            case .explicitOff:
                controller.setKeepAwakeEnabled(false)
                XCTAssertFalse(controller.isKeepAwakeOn)
            case .termination:
                let replies = SwitchFixtureBox([Bool]())
                controller.prepareForSystemTermination { restored in replies.mutate { $0.append(restored) } }
                XCTAssertEqual(replies.read { $0 }, [false])
                XCTAssertFalse(controller.isKeepAwakeOn)
            case .finalVerificationFailure, .administratorFailure:
                break
            }
            if cancellation != .finalVerificationFailure { inventoryInTransition.mutate { $0 = false } }
            release.signal()
            assertTrue(await settles(controller))
            XCTAssertFalse(controller.isKeepAwakeOn, cancellation.rawValue)
            XCTAssertTrue(state.read { $0.policies.isEmpty }, cancellation.rawValue)
            if cancellation == .finalVerificationFailure || cancellation == .administratorFailure {
                XCTAssertNotNil(controller.errorMessage)
            }

            inventoryInTransition.mutate { $0 = false }
            state.mutate { $0.helperReady = true }
            controller.refresh()
            assertTrue(await settles(controller))
            XCTAssertFalse(controller.isKeepAwakeOn, cancellation.rawValue)
            XCTAssertTrue(state.read { $0.policies.isEmpty }, cancellation.rawValue)
        }
    }

    @MainActor
    func testOffCancelsHeldStartBeforeAnyAuthorityOrPreferenceMutation() async {
        let state = SwitchFixtureBox(SwitchFixtureState())
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { owned in state.read { $0.snapshot(owned: owned) } },
            forceFreshSnapshotProvider: { owned in
                entered.signal()
                _ = release.wait(timeout: .now() + 3)
                return state.read { $0.snapshot(owned: owned) }
            },
            sideEffects: effects(state),
            safeRollbackWaiter: { state.read { $0.snapshot(owned: nil) } },
            restoreVerificationWaiter: { state.read { $0.snapshot(owned: nil) } },
            announcementHandler: { _ in }
        )
        controller.setKeepAwakeEnabled(true)
        let reached = await Task.detached { heldStartWasEntered(entered) }.value
        XCTAssertTrue(reached)
        XCTAssertTrue(controller.isStarting)
        XCTAssertEqual(controller.primaryAction, .cancelStart)
        controller.setKeepAwakeEnabled(false)
        release.signal()
        assertTrue(await settles(controller))
        XCTAssertFalse(controller.isKeepAwakeOn)
        XCTAssertTrue(state.read { $0.events.isEmpty })
        XCTAssertNil(controller.activeSessionIDForTesting)
    }

    func testBatteryRollbackRequiresExactSessionAndEverySelectedBaseline() {
        let sessionID = UUID()
        var state = SwitchFixtureState(source: .battery(percent: 60))
        state.restore(sessionID)
        XCTAssertTrue(PowerController.cleanupProofForTesting(
            sessionID: sessionID, originalACIdleSleepMinutes: 5,
            snapshot: state.snapshot(owned: nil), powerPolicy: .all, originalBatteryIdleSleepMinutes: 7
        ))
        state.batterySleep = nil
        XCTAssertFalse(PowerController.cleanupProofForTesting(
            sessionID: sessionID, originalACIdleSleepMinutes: 5,
            snapshot: state.snapshot(owned: nil), powerPolicy: .all, originalBatteryIdleSleepMinutes: 7
        ))
        state.batterySleep = 8
        XCTAssertFalse(PowerController.cleanupProofForTesting(
            sessionID: sessionID, originalACIdleSleepMinutes: 5,
            snapshot: state.snapshot(owned: nil), powerPolicy: .batteryOnly, originalBatteryIdleSleepMinutes: 7
        ))
        let valid = HelperControlReply(reason: "peer-end", sessionID: sessionID, expiryMonotonic: 0,
                                       state: .terminal, power: .disconnected, sleepDisabled: false,
                                       acSleepMinutes: 5, batterySleepMinutes: 7)
        XCTAssertTrue(PowerController.authenticatedCleanupReplyProofForTesting(
            sessionID: sessionID, originalACIdleSleepMinutes: 5, resolution: .terminated(valid),
            powerPolicy: .all, originalBatteryIdleSleepMinutes: 7
        ))
        let missing = HelperControlReply(reason: "peer-end", sessionID: sessionID, expiryMonotonic: 0,
                                         state: .terminal, power: .disconnected, sleepDisabled: false,
                                         acSleepMinutes: 5)
        XCTAssertFalse(PowerController.authenticatedCleanupReplyProofForTesting(
            sessionID: sessionID, originalACIdleSleepMinutes: 5, resolution: .terminated(missing),
            powerPolicy: .all, originalBatteryIdleSleepMinutes: 7
        ))
    }

    func testKnownBatteryHeartbeatAuthorityCanRenewButUnknownCannot() {
        let sessionID = UUID()
        let battery = PowerControllerSideEffects.rawXPCHeartbeatObservation(
            sessionID: sessionID, native: .init(power: .battery, authority: .indeterminate, helperStatus: nil), now: Date()
        )
        let unknown = PowerControllerSideEffects.rawXPCHeartbeatObservation(
            sessionID: sessionID, native: .init(power: .unknown, authority: .verified, helperStatus: nil), now: Date()
        )
        XCTAssertEqual(battery.authority, .verified)
        XCTAssertEqual(unknown.authority, .indeterminate)
    }

    func testHeartbeatRefreshUsesOnlyNewFreshExactSessionProjectionsOnSelectedPower() {
        let sessionID = UUID()
        let now = Date()
        let callbacks = SwitchFixtureBox([UUID]())
        let gate = ActiveSessionProjectionRefreshGate(sessionID: sessionID, powerPolicy: .all)
        let first = HelperStatusRecord(state: "active", reason: "verified", sessionID: sessionID, updatedAt: now)
        let renewed = HelperStatusRecord(state: "active", reason: "renewed", sessionID: sessionID,
                                         updatedAt: now.addingTimeInterval(8))
        let candidates: [(SessionHeartbeatObservation.Power, HelperStatusRecord, Date)] = [
            (.battery, first, now),
            (.battery, first, now),
            (.battery, renewed, now.addingTimeInterval(8)),
            (.unknown, renewed, now.addingTimeInterval(8)),
            (.battery, .init(state: "active", reason: "renewed", sessionID: UUID(), updatedAt: now), now),
            (.battery, first, now.addingTimeInterval(13)),
            (.battery, .init(state: "terminal", reason: "peer-end", sessionID: sessionID, updatedAt: now), now),
            (.battery, renewed, now)
        ]
        for (power, status, checkedAt) in candidates {
            let native = SessionHeartbeatObservation(power: power, authority: .indeterminate, helperStatus: status)
            let observation = PowerControllerSideEffects.observedHeartbeatProjection(
                sessionID: sessionID, native: native, now: checkedAt, refreshGate: gate,
                onAcknowledged: { callbackID in callbacks.mutate { $0.append(callbackID) } }
            )
            XCTAssertEqual(observation.helperStatus, status)
        }
        XCTAssertEqual(callbacks.read { $0 }, [sessionID, sessionID])
        let pluggedInGate = ActiveSessionProjectionRefreshGate(sessionID: sessionID, powerPolicy: .pluggedInOnly)
        XCTAssertFalse(pluggedInGate.shouldRefresh(
            .init(power: .battery, authority: .verified, helperStatus: first), at: now
        ))
    }

    @MainActor
    func testAcknowledgedMasterBeginWaitsForExactFreshProjectionWithoutRestoreWarning() async throws {
        let previousSessionID = UUID()
        let state = SwitchFixtureBox(SwitchFixtureState(
            projectedStatus: .init(state: "terminal", reason: "peer-end", sessionID: previousSessionID,
                                   updatedAt: Date())
        ))
        let holdProjection = SwitchFixtureBox(true)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let controller = makeHeldProjectionController(state, holdProjection: holdProjection,
                                                      entered: entered, release: release)
        controller.setKeepAwakeEnabled(true)
        assertTrue(await issued(controller))
        let sessionID = try XCTUnwrap(controller.activeSessionIDForTesting)
        controller.simulateHeartbeatAcknowledgeForTesting(sessionID: sessionID,
                                                          epoch: controller.sessionEpochForTesting)
        let reached = await Task.detached { heldStartWasEntered(entered) }.value
        XCTAssertTrue(reached)
        assertPendingProjection(controller)
        XCTAssertTrue(controller.isStarting)
        XCTAssertTrue(controller.isChecking)

        holdProjection.mutate { $0 = false }
        release.signal()
        assertTrue(await settles(controller))
        XCTAssertTrue(controller.snapshot.restoreRequired)
        XCTAssertEqual(controller.snapshot.helperStatus?.sessionID, previousSessionID)
        assertPendingProjection(controller)

        for candidate in [
            HelperStatusRecord(state: "active", reason: "verified", sessionID: sessionID,
                               updatedAt: Date().addingTimeInterval(-20)),
            HelperStatusRecord(state: "active", reason: "verified", sessionID: UUID(), updatedAt: Date()),
        ] {
            state.mutate { $0.projectedStatus = candidate }
            controller.refresh()
            assertTrue(await settles(controller))
            XCTAssertTrue(controller.snapshot.restoreRequired)
            assertPendingProjection(controller)
        }
        state.mutate { $0.omitProjectedStatus = true }
        controller.refresh()
        assertTrue(await settles(controller))
        XCTAssertNil(controller.snapshot.helperStatus)
        XCTAssertTrue(controller.snapshot.restoreRequired)
        assertPendingProjection(controller)

        state.mutate {
            $0.omitProjectedStatus = false
            $0.projectedStatus = .init(state: "active", reason: "verified", sessionID: sessionID,
                                       updatedAt: Date())
        }
        controller.refresh()
        assertTrue(await settles(controller))
        XCTAssertEqual(controller.displayedStatus.title, "Awake")
        XCTAssertEqual(controller.displayedStatus.tone, .active)
        XCTAssertFalse(controller.snapshot.restoreRequired)
        XCTAssertEqual(state.read { $0.policies }, [.pluggedInOnly])
        XCTAssertFalse(state.read { $0.events.contains("terminate") })
        controller.setKeepAwakeEnabled(false)
        assertTrue(await settles(controller))
    }

    @MainActor
    func testSourcePolicyRestartWaitsForNewProjectionAndCanStopWhileDeliveryIsHeld() async throws {
        let state = SwitchFixtureBox(SwitchFixtureState())
        let holdProjection = SwitchFixtureBox(false)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let controller = makeHeldProjectionController(state, holdProjection: holdProjection,
                                                      entered: entered, release: release)
        controller.setKeepAwakeEnabled(true)
        assertTrue(await issued(controller))
        try await acknowledge(controller)
        let previousSessionID = try XCTUnwrap(controller.activeSessionIDForTesting)
        state.mutate {
            $0.projectedStatus = .init(state: "terminal", reason: "peer-end", sessionID: previousSessionID,
                                       updatedAt: Date())
        }
        holdProjection.mutate { $0 = true }
        controller.setAllowBatteryKeepAwake(true)
        assertTrue(await eventually {
            controller.activeSessionIDForTesting != nil && controller.activeSessionIDForTesting != previousSessionID
        })
        let sessionID = try XCTUnwrap(controller.activeSessionIDForTesting)
        controller.simulateHeartbeatAcknowledgeForTesting(sessionID: sessionID,
                                                          epoch: controller.sessionEpochForTesting)
        let reached = await Task.detached { heldStartWasEntered(entered) }.value
        XCTAssertTrue(reached)
        assertPendingProjection(controller)
        holdProjection.mutate { $0 = false }
        release.signal()
        assertTrue(await settles(controller))
        XCTAssertTrue(controller.snapshot.restoreRequired)
        assertPendingProjection(controller)
        XCTAssertEqual(state.read { $0.policies }, [.pluggedInOnly, .all])

        state.mutate {
            $0.projectedStatus = .init(state: "active", reason: "verified", sessionID: sessionID,
                                       updatedAt: Date())
        }
        controller.refresh()
        assertTrue(await settles(controller))
        XCTAssertEqual(controller.displayedStatus.title, "Awake")
        XCTAssertFalse(controller.isStarting)
        state.mutate {
            $0.projectedStatus = .init(state: "active", reason: "verified", sessionID: sessionID,
                                       updatedAt: Date().addingTimeInterval(-20))
        }
        controller.refresh()
        assertTrue(await settles(controller))
        assertPendingProjection(controller)
        XCTAssertTrue(controller.isStarting)

        holdProjection.mutate { $0 = true }
        controller.refresh()
        let heldAgain = await Task.detached { heldStartWasEntered(entered) }.value
        XCTAssertTrue(heldAgain)
        controller.setKeepAwakeEnabled(false)
        assertTrue(await eventually { controller.activeSessionIDForTesting == nil && !controller.isBusy })
        XCTAssertFalse(controller.isKeepAwakeOn)
        XCTAssertNil(controller.cleanupOwnerSessionIDForTesting)
        XCTAssertEqual(state.read { $0.events.filter { $0 == "terminate" }.count }, 2)
        holdProjection.mutate { $0 = false }
        release.signal()
        assertTrue(await settles(controller))
        XCTAssertEqual(state.read { $0.policies }, [.pluggedInOnly, .all])
        XCTAssertNotEqual(controller.displayedStatus.title, "Awake")
    }

    @MainActor
    func testAcknowledgedOwnedGenerationKeepsRecoveryTerminalAndUnknownSleepWarnings() async throws {
        for warning in ["recovery-required", "terminal", "unknown-sleep"] {
            let state = SwitchFixtureBox(SwitchFixtureState())
            let controller = makeController(state)
            controller.setKeepAwakeEnabled(true)
            assertTrue(await issued(controller))
            try await acknowledge(controller)
            let sessionID = try XCTUnwrap(controller.activeSessionIDForTesting)
            state.mutate {
                if warning == "unknown-sleep" {
                    $0.sleepDisabledVerified = false
                } else {
                    $0.projectedStatus = .init(state: warning, reason: "fixture", sessionID: sessionID,
                                               updatedAt: Date())
                    if warning == "terminal" { $0.sleepDisabled = false }
                }
            }
            controller.refresh()
            assertTrue(await settles(controller))
            XCTAssertEqual(controller.displayedStatus.tone, .warning, warning)
            XCTAssertNotEqual(controller.displayedStatus.title, "Verifying…", warning)
            XCTAssertNotEqual(controller.displayedStatus.title, "Awake", warning)
            XCTAssertEqual(controller.primaryAction, .stopAndRestore, warning)
            state.mutate { $0.projectedStatus = nil; $0.sleepDisabledVerified = true }
            controller.setKeepAwakeEnabled(false)
            assertTrue(await settles(controller))
        }

        let state = SwitchFixtureBox(SwitchFixtureState(sleepDisabled: true))
        let controller = makeController(state)
        controller.refresh()
        assertTrue(await settles(controller))
        XCTAssertNil(controller.activeSessionIDForTesting)
        XCTAssertTrue(controller.snapshot.restoreRequired)
        XCTAssertEqual(controller.displayedStatus.title, "Restore required")
        XCTAssertEqual(controller.displayedStatus.tone, .warning)
        XCTAssertEqual(controller.primaryAction, .restoreSleep)
    }

    @MainActor
    func testRenewedBatteryProjectionRefreshesAnAgedActiveDisplayWithoutRearmingOrAnnouncingAgain() async throws {
        let state = SwitchFixtureBox(SwitchFixtureState(
            source: .battery(percent: 72),
            preferences: PowerPreferences(keepAwakeEnabled: false, allowBatteryKeepAwake: true)
        ))
        let announcements = SwitchFixtureBox([String]())
        let controller = PowerController(
            bootstrap: false, snapshotProvider: { owned in state.read { $0.snapshot(owned: owned) } },
            sideEffects: effects(state),
            safeRollbackWaiter: { state.read { $0.snapshot(owned: nil) } },
            restoreVerificationWaiter: { state.read { $0.snapshot(owned: nil) } },
            announcementHandler: { message in announcements.mutate { $0.append(message) } }
        )
        controller.setKeepAwakeEnabled(true)
        assertTrue(await issued(controller))
        try await acknowledge(controller)
        let sessionID = try XCTUnwrap(controller.activeSessionIDForTesting)
        let epoch = controller.sessionEpochForTesting
        let monotonic = MonotonicClock.seconds()
        let now = Date()
        state.mutate {
            $0.projectedStatus = HelperStatusRecord(
                state: "active", reason: "verified", sessionID: sessionID,
                updatedAt: now.addingTimeInterval(-20), bootID: BootIdentity.current(),
                updatedMonotonic: monotonic - 20
            )
        }
        controller.refresh()
        assertTrue(await settles(controller))
        XCTAssertTrue(controller.snapshot.restoreRequired)
        assertPendingProjection(controller)

        let fresh = HelperStatusRecord(state: "active", reason: "renewed", sessionID: sessionID,
                                       updatedAt: Date(), bootID: BootIdentity.current(),
                                       updatedMonotonic: MonotonicClock.seconds())
        state.mutate { $0.projectedStatus = fresh }
        let gate = ActiveSessionProjectionRefreshGate(sessionID: sessionID, powerPolicy: .all)
        _ = PowerControllerSideEffects.observedHeartbeatProjection(
            sessionID: sessionID, native: .init(power: .battery, authority: .indeterminate, helperStatus: fresh),
            now: Date(), refreshGate: gate,
            onAcknowledged: { acknowledgedID in
                Task { @MainActor in
                    controller.simulateHeartbeatAcknowledgeForTesting(sessionID: acknowledgedID, epoch: epoch)
                }
            }
        )
        assertTrue(await eventually { !controller.isChecking && controller.snapshot.sessionActive })
        XCTAssertEqual(controller.displayedStatus.title, "Awake")
        XCTAssertFalse(controller.snapshot.restoreRequired)
        XCTAssertTrue(controller.isKeepAwakeOn)
        XCTAssertTrue(controller.powerPreferences.allowBatteryKeepAwake)
        XCTAssertEqual(controller.activeSessionIDForTesting, sessionID)
        XCTAssertEqual(state.read { $0.policies }, [.all])
        XCTAssertEqual(announcements.read { $0.filter { $0 == "Keep Mac awake on battery." }.count }, 1)
        state.mutate { $0.projectedStatus = nil }
        controller.setKeepAwakeEnabled(false)
        assertTrue(await settles(controller))
    }

    func testPolicySeamsRespectTheProductionMutationGuardInXCTest() throws {
        let effects = PowerControllerSideEffects.production()
        let writer = try XCTUnwrap(effects.writePowerPreferences)
        let issue = try XCTUnwrap(effects.issueLeaseWithPolicy)
        let heartbeat = try XCTUnwrap(effects.makeHeartbeatWithPolicy)
        XCTAssertThrowsError(try writer(.disabled)) {
            XCTAssertEqual($0 as? PowerControllerSideEffectError, .productionMutationBlockedInTest)
        }
        XCTAssertThrowsError(try issue(UUID(), .all)) {
            XCTAssertEqual($0 as? PowerControllerSideEffectError, .productionMutationBlockedInTest)
        }
        XCTAssertNil(heartbeat(UUID(), .all, { _ in }, { _, _ in }, { true }))
    }

    @MainActor
    private func makeHeldProjectionController(
        _ state: SwitchFixtureBox<SwitchFixtureState>, holdProjection: SwitchFixtureBox<Bool>,
        entered: DispatchSemaphore, release: DispatchSemaphore
    ) -> PowerController {
        PowerController(
            bootstrap: false,
            inventoryResultProvider: { owned, _ in
                if owned != nil, holdProjection.read({ $0 }) {
                    entered.signal()
                    _ = release.wait(timeout: .now() + 5)
                }
                return .init(snapshot: state.read { $0.snapshot(owned: owned) }, rejection: nil)
            },
            sideEffects: effects(state),
            safeRollbackWaiter: { state.read { $0.snapshot(owned: nil) } },
            restoreVerificationWaiter: { state.read { $0.snapshot(owned: nil) } },
            announcementHandler: { _ in }
        )
    }

    @MainActor
    private func assertPendingProjection(_ controller: PowerController,
                                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(controller.isKeepAwakeOn, file: file, line: line)
        XCTAssertEqual(controller.displayedStatus.title, "Verifying…", file: file, line: line)
        XCTAssertEqual(controller.displayedStatus.tone, .progress, file: file, line: line)
        XCTAssertEqual(controller.primaryAction, .stopAndRestore, file: file, line: line)
        XCTAssertFalse(controller.snapshot.sessionActive, file: file, line: line)
    }

    @MainActor
    private func makeController(_ state: SwitchFixtureBox<SwitchFixtureState>) -> PowerController {
        PowerController(bootstrap: false, snapshotProvider: { owned in state.read { $0.snapshot(owned: owned) } },
                        sideEffects: effects(state),
                        safeRollbackWaiter: { state.read { $0.snapshot(owned: nil) } },
                        restoreVerificationWaiter: { state.read { $0.snapshot(owned: nil) } },
                        announcementHandler: { _ in })
    }

    private func effects(_ state: SwitchFixtureBox<SwitchFixtureState>) -> PowerControllerSideEffects {
        var effects = PowerControllerSideEffects.recordingFixture(
            { event in state.mutate { $0.events.append(event) } },
            terminalResolution: { sessionID, _ in
                state.mutate {
                    $0.events.append("terminate")
                    $0.restore(sessionID)
                }
                return state.read { value -> HelperGenerationTerminationResolution? in
                    .terminated(HelperControlReply(reason: "peer-end", sessionID: sessionID, expiryMonotonic: 0,
                                                   state: .terminal, power: value.source.isAC ? .ac : .disconnected,
                                                   sleepDisabled: false, acSleepMinutes: value.acSleep,
                                                   batterySleepMinutes: value.batterySleep))
                }
            }
        )
        effects.writePowerPreferences = { preferences in
            state.mutate { $0.events.append("preferences"); $0.preferences = preferences }
        }
        effects.issueLeaseWithPolicy = { sessionID, policy in
            state.mutate { $0.events.append("begin"); $0.policies.append(policy); $0.sleepDisabled = true }
            let monotonic = MonotonicClock.seconds()
            return .issued(ActivationLease(sessionID: sessionID, bootID: "fixture", expiresAt: Date().addingTimeInterval(30),
                                           issuedMonotonic: monotonic, expiresMonotonic: monotonic + 30,
                                           ownerUID: 501, systemBuild: "fixture"))
        }
        effects.makeHeartbeatWithPolicy = { _, policy, _, _, _ in
            state.mutate { $0.heartbeatPolicies.append(policy) }
            return nil
        }
        effects = replacingPrepare(effects, state: state)
        return effects
    }

    private func replacingPrepare(_ base: PowerControllerSideEffects,
                                  state: SwitchFixtureBox<SwitchFixtureState>,
                                  preparation: (@Sendable () throws -> AdministratorOperationResult)? = nil) -> PowerControllerSideEffects {
        let prepare: @Sendable () throws -> AdministratorOperationResult = preparation ?? {
            state.mutate { $0.events.append("prepare"); $0.helperReady = true }
            return .safeIdle(.init(transactionID: UUID(), operation: .install, state: .terminal,
                                   outcome: .safeIdle, sessionID: nil, reason: "fixture"))
        }
        return PowerControllerSideEffects(
            writeDesiredStateDisabled: base.writeDesiredStateDisabled, issueLease: base.issueLease,
            revokeLease: base.revokeLease, terminateLease: base.terminateLease, makeHeartbeat: base.makeHeartbeat,
            beginActivity: base.beginActivity, endActivity: base.endActivity,
            prepareHelper: prepare,
            restoreSleep: base.restoreSleep, uninstallHelper: base.uninstallHelper,
            terminateApplication: base.terminateApplication, writePowerPreferences: base.writePowerPreferences,
            issueLeaseWithPolicy: base.issueLeaseWithPolicy, makeHeartbeatWithPolicy: base.makeHeartbeatWithPolicy
        )
    }

    @MainActor
    private func makeHeldPreparationController(
        _ state: SwitchFixtureBox<SwitchFixtureState>, inventoryInTransition: SwitchFixtureBox<Bool>,
        entered: DispatchSemaphore, release: DispatchSemaphore, failPreparation: Bool = false
    ) -> PowerController {
        let heldEffects = replacingPrepare(effects(state), state: state, preparation: {
            state.mutate { $0.events.append("prepare") }
            entered.signal()
            guard release.wait(timeout: .now() + 5) == .success, !failPreparation else {
                throw NSError(domain: "HeldPreparationFixture", code: 1)
            }
            state.mutate { $0.helperReady = true }
            return .safeIdle(.init(transactionID: UUID(), operation: .install, state: .terminal,
                                   outcome: .safeIdle, sessionID: nil, reason: "fixture"))
        })
        return PowerController(
            bootstrap: false,
            snapshotProvider: { owned in
                let snapshot = state.read { $0.snapshot(owned: owned) }
                return inventoryInTransition.read { $0 }
                    ? snapshot.withIndeterminateInstallationInventory(reason: "Helper replacement is in progress.")
                    : snapshot
            },
            sideEffects: heldEffects,
            safeRollbackWaiter: { state.read { $0.snapshot(owned: nil) } },
            restoreVerificationWaiter: { state.read { $0.snapshot(owned: nil) } },
            announcementHandler: { _ in }
        )
    }

    @MainActor
    private func assertTrue(_ result: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(result, file: file, line: line)
    }

    @MainActor
    private func acknowledge(_ controller: PowerController) async throws {
        let sessionID = try XCTUnwrap(controller.activeSessionIDForTesting)
        controller.simulateHeartbeatAcknowledgeForTesting(sessionID: sessionID, epoch: controller.sessionEpochForTesting)
        assertTrue(await eventually { !controller.isChecking && !controller.isBusy })
    }

    @MainActor
    private func issued(_ controller: PowerController) async -> Bool {
        await eventually { controller.activeSessionIDForTesting != nil }
    }

    @MainActor
    private func settles(_ controller: PowerController) async -> Bool {
        await eventually { !controller.isBusy && !controller.isChecking }
    }

    @MainActor
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }
}

// Keep the blocking wait on the detached worker through a synchronous seam;
// DispatchSemaphore.wait is unavailable directly from an async context.
private func heldStartWasEntered(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 2) == .success
}

private enum HeldPreparationCancellation: String, CaseIterable, Equatable {
    case unknownSource, recoveryRequired, explicitOff, termination, finalVerificationFailure, administratorFailure
}

private struct SwitchFixtureState {
    var source: PowerSource = .ac
    var preferences: PowerPreferences = .disabled
    var helperReady = true
    var sleepDisabled = false
    var sleepDisabledVerified = true
    var acSleep: Int? = 5
    var batterySleep: Int? = 7
    var terminalSession: UUID?
    var projectedStatus: HelperStatusRecord?
    var omitProjectedStatus = false
    var policies: [SessionPowerPolicy] = []
    var heartbeatPolicies: [SessionPowerPolicy] = []
    var events: [String] = []

    mutating func restore(_ sessionID: UUID) {
        sleepDisabled = false
        terminalSession = sessionID
    }

    func snapshot(owned: UUID?) -> PowerSnapshot {
        let now = Date()
        return PowerSnapshot(source: source, sleepDisabled: sleepDisabled, sleepDisabledVerified: sleepDisabledVerified,
                             acIdleSleepMinutes: acSleep, batteryIdleSleepMinutes: batterySleep,
                             preferences: preferences, helperArtifactsPresent: helperReady, helperLoaded: helperReady,
                             helperNeedsUpdate: false, legacyLoginItemPresent: false, legacyLoginItemLoaded: false,
                             activationLease: nil, ownedSessionID: owned,
                             helperStatus: omitProjectedStatus ? nil : projectedStatus ?? .init(
                                state: sleepDisabled ? "active" : "terminal", reason: "fixture",
                                sessionID: owned ?? terminalSession, updatedAt: now),
                             systemBuild: "fixture", systemBuildQualified: true, bundleIntegrityValid: true,
                             bundleVersionValid: true, checkedAt: now, installationInventoryState: .valid)
    }
}

private final class SwitchFixtureBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read<Result>(_ read: (Value) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }
        return read(value)
    }
    func mutate(_ update: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        update(&value)
    }
}
