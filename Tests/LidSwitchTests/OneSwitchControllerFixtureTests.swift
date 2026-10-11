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
                                  state: SwitchFixtureBox<SwitchFixtureState>) -> PowerControllerSideEffects {
        PowerControllerSideEffects(
            writeDesiredStateDisabled: base.writeDesiredStateDisabled, issueLease: base.issueLease,
            revokeLease: base.revokeLease, terminateLease: base.terminateLease, makeHeartbeat: base.makeHeartbeat,
            beginActivity: base.beginActivity, endActivity: base.endActivity,
            prepareHelper: {
                state.mutate { $0.events.append("prepare"); $0.helperReady = true }
                return .safeIdle(.init(transactionID: UUID(), operation: .install, state: .terminal,
                                       outcome: .safeIdle, sessionID: nil, reason: "fixture"))
            },
            restoreSleep: base.restoreSleep, uninstallHelper: base.uninstallHelper,
            terminateApplication: base.terminateApplication, writePowerPreferences: base.writePowerPreferences,
            issueLeaseWithPolicy: base.issueLeaseWithPolicy, makeHeartbeatWithPolicy: base.makeHeartbeatWithPolicy
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

private struct SwitchFixtureState {
    var source: PowerSource = .ac
    var preferences: PowerPreferences = .disabled
    var helperReady = true
    var sleepDisabled = false
    var acSleep: Int? = 5
    var batterySleep: Int? = 7
    var terminalSession: UUID?
    var policies: [SessionPowerPolicy] = []
    var heartbeatPolicies: [SessionPowerPolicy] = []
    var events: [String] = []

    mutating func restore(_ sessionID: UUID) {
        sleepDisabled = false
        terminalSession = sessionID
    }

    func snapshot(owned: UUID?) -> PowerSnapshot {
        let now = Date()
        return PowerSnapshot(source: source, sleepDisabled: sleepDisabled, sleepDisabledVerified: true,
                             acIdleSleepMinutes: acSleep, batteryIdleSleepMinutes: batterySleep,
                             preferences: preferences, helperArtifactsPresent: helperReady, helperLoaded: helperReady,
                             helperNeedsUpdate: false, legacyLoginItemPresent: false, legacyLoginItemLoaded: false,
                             activationLease: nil, ownedSessionID: owned,
                             helperStatus: .init(state: sleepDisabled ? "active" : "terminal", reason: "fixture",
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
