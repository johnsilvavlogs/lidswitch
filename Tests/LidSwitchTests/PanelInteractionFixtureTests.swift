import Dispatch
import Foundation
import LidSwitchCore
import XCTest
@testable import LidSwitch

/// Exercises the presentation consumed by the actual panel against controller
/// transitions, with held reads and exact-session END replies. No live services.
final class PanelInteractionFixtureTests: XCTestCase {
    @MainActor
    func testOffDuringHeldActiveRefreshEndsExactSessionAndRejectsStalePublication() async throws {
        let fixture = PanelFixture()
        let controller = makeController(fixture)
        controller.refresh()
        await settle(controller)
        controller.setKeepAwakeEnabled(true)
        await waitUntil { controller.activeSessionIDForTesting != nil }
        let session = try XCTUnwrap(controller.activeSessionIDForTesting)
        controller.simulateHeartbeatAcknowledgeForTesting(sessionID: session, epoch: controller.sessionEpochForTesting)
        await settle(controller)
        XCTAssertTrue(controller.snapshot.sessionActive)

        fixture.update { $0.holdNextRead = true }
        defer { fixture.releaseRead.signal() }
        controller.refreshManually()
        let entered = await Task.detached { fixture.waitForRead() }.value
        XCTAssertTrue(entered)
        XCTAssertTrue(controller.isChecking)
        let panel = LidSwitchPanelPresentation(controller: controller)
        XCTAssertTrue(panel.masterEnabled)
        XCTAssertFalse(panel.sourceChoicesEnabled)
        XCTAssertFalse(panel.commandKRestoresSleep)
        XCTAssertTrue(panel.masterHint.contains("Turn off"))
        controller.setKeepAwakeEnabled(false)
        XCTAssertEqual(controller.operationPhase, .endingRestoring)
        XCTAssertFalse(LidSwitchPanelPresentation(controller: controller).masterEnabled)
        fixture.releaseRead.signal()
        await settle(controller)

        XCTAssertEqual(fixture.read { $0.endedSessions }, [session])
        XCTAssertEqual(fixture.read { $0.policies }, [.pluggedInOnly])
        XCTAssertEqual(fixture.read { $0.preparations }, 0)
        XCTAssertFalse(controller.snapshot.sleepDisabled)
        XCTAssertEqual(controller.snapshot.acIdleSleepMinutes, 5)
        XCTAssertEqual(controller.snapshot.batteryIdleSleepMinutes, 7)
        XCTAssertNil(controller.cleanupOwnerSessionIDForTesting)
        XCTAssertFalse(controller.isKeepAwakeOn)
        XCTAssertTrue(LidSwitchPanelPresentation(controller: controller).masterEnabled)
    }

    @MainActor
    func testOffDuringPausedRefreshCannotRearmWhenSelectedSourceReturns() async {
        let fixture = PanelFixture()
        fixture.update { $0.source = .battery(percent: 70) }
        let controller = makeController(fixture)
        controller.refresh()
        await settle(controller)
        controller.setKeepAwakeEnabled(true)
        await settle(controller)
        XCTAssertEqual(controller.displayedStatus.title, "Paused")
        XCTAssertTrue(controller.isKeepAwakeOn)

        fixture.update { $0.source = .ac; $0.holdNextRead = true }
        defer { fixture.releaseRead.signal() }
        controller.refreshManually()
        let entered = await Task.detached { fixture.waitForRead() }.value
        XCTAssertTrue(entered)
        XCTAssertTrue(LidSwitchPanelPresentation(controller: controller).masterEnabled)
        controller.setKeepAwakeEnabled(false)
        fixture.releaseRead.signal()
        await settle(controller)
        XCTAssertFalse(controller.isKeepAwakeOn)
        XCTAssertTrue(fixture.read { $0.policies.isEmpty })
        XCTAssertEqual(fixture.read { $0.preparations }, 0)
    }

    @MainActor
    func testOffDuringSetupFinishesInstallationWithoutActivationAndCannotToggleBackPrematurely() async {
        let fixture = PanelFixture()
        fixture.update { $0.helperReady = false; $0.holdPreparation = true }
        defer { fixture.releasePreparation.signal() }
        let controller = makeController(fixture)
        controller.refresh()
        await settle(controller)
        var panel = LidSwitchPanelPresentation(controller: controller)
        XCTAssertTrue(panel.masterEnabled)
        XCTAssertNil(panel.inlineAction) // first setup still uses one switch
        controller.setKeepAwakeEnabled(true)
        let entered = await Task.detached { fixture.waitForPreparation() }.value
        XCTAssertTrue(entered)
        XCTAssertEqual(controller.operationPhase, .preparingHelper)
        panel = LidSwitchPanelPresentation(controller: controller)
        XCTAssertTrue(panel.masterEnabled)
        XCTAssertFalse(panel.sourceChoicesEnabled)
        XCTAssertNil(panel.inlineAction)
        XCTAssertTrue(panel.masterHint.contains("finish setup"))

        controller.setKeepAwakeEnabled(false)
        panel = LidSwitchPanelPresentation(controller: controller)
        XCTAssertFalse(panel.masterEnabled)
        XCTAssertEqual(panel.guidance, "Finishing setup. Keep Mac awake will stay off.")
        controller.setKeepAwakeEnabled(true) // controller also rejects a stale ON
        XCTAssertFalse(controller.isKeepAwakeOn)
        fixture.releasePreparation.signal()
        await settle(controller)
        XCTAssertTrue(controller.snapshot.helperReady)
        XCTAssertFalse(controller.isKeepAwakeOn)
        XCTAssertTrue(fixture.read { $0.policies.isEmpty })
        XCTAssertEqual(fixture.read { $0.preparations }, 1)
        XCTAssertEqual(fixture.read { $0.restores }, 0)
        XCTAssertTrue(LidSwitchPanelPresentation(controller: controller).masterEnabled)
    }

    @MainActor
    func testUnavailableReadsOfferInlineRefreshAndRecoverWithoutActivationOrAdministration() async {
        for failure in PanelReadFailure.allCases {
            let fixture = PanelFixture()
            fixture.update { $0.failure = failure }
            let controller = makeController(fixture)
            controller.refresh()
            await settle(controller)
            let panel = LidSwitchPanelPresentation(controller: controller)
            XCTAssertFalse(panel.masterEnabled, "\(failure)")
            XCTAssertEqual(panel.inlineAction?.kind, .refresh, "\(failure)")
            XCTAssertEqual(panel.inlineAction?.isEnabled, true)
            XCTAssertTrue(panel.masterHint.contains("Refresh"))
            XCTAssertFalse(panel.masterHint.contains("Command-K turns it on"))
            fixture.update { $0.failure = nil }
            controller.refreshManually()
            await settle(controller)
            XCTAssertTrue(LidSwitchPanelPresentation(controller: controller).masterEnabled)
            XCTAssertNil(LidSwitchPanelPresentation(controller: controller).inlineAction)
            XCTAssertFalse(controller.isKeepAwakeOn)
            XCTAssertTrue(fixture.read { $0.policies.isEmpty })
            XCTAssertEqual(fixture.read { $0.preparations + $0.restores }, 0)
        }
    }

    @MainActor
    func testSourceChoicesRemainEditableWhenEmptyAndPersistWithoutActivationAfterRestart() async {
        let fixture = PanelFixture()
        let controller = makeController(fixture)
        controller.refresh()
        await settle(controller)
        controller.setAllowPluggedInKeepAwake(false)
        let empty = LidSwitchPanelPresentation(controller: controller)
        XCTAssertFalse(empty.masterEnabled)
        XCTAssertTrue(empty.sourceChoicesEnabled)
        XCTAssertEqual(empty.guidance, "Choose at least one power source below.")
        XCTAssertNil(empty.inlineAction)
        controller.setAllowBatteryKeepAwake(true)
        XCTAssertTrue(LidSwitchPanelPresentation(controller: controller).masterEnabled)
        XCTAssertFalse(controller.powerPreferences.allowPluggedInKeepAwake)
        XCTAssertTrue(controller.powerPreferences.allowBatteryKeepAwake)
        XCTAssertFalse(controller.isKeepAwakeOn)

        let restarted = makeController(fixture)
        restarted.refresh()
        await settle(restarted)
        XCTAssertFalse(restarted.isKeepAwakeOn)
        XCTAssertEqual(restarted.powerPreferences, controller.powerPreferences)
        XCTAssertTrue(fixture.read { $0.policies.isEmpty })
        XCTAssertEqual(fixture.read { $0.preparations + $0.restores }, 0)
    }

    @MainActor
    func testContainmentWarningKeepsAuthenticatedRestoreAheadOfSourceGuidanceAndRepair() async {
        let fixture = PanelFixture()
        fixture.update {
            $0.sleepDisabled = true
            $0.recoveryReason = "containment-extinction-unproven"
            $0.preferences.allowPluggedInKeepAwake = false
        }
        let controller = makeController(fixture)
        controller.refresh()
        await settle(controller)
        var panel = LidSwitchPanelPresentation(controller: controller)
        XCTAssertEqual(controller.primaryAction, .restoreSleep)
        XCTAssertEqual(panel.inlineAction?.kind, .restoreSleep)
        XCTAssertEqual(panel.inlineAction?.isEnabled, true)
        XCTAssertFalse(panel.masterEnabled)
        XCTAssertFalse(panel.sourceChoicesEnabled)
        XCTAssertTrue(panel.commandKRestoresSleep)
        XCTAssertTrue(panel.guidance?.contains("Restore Sleep") == true)

        // Only an actual typed failure, not the public containment label, can
        // move the controller to repair. Do not manufacture a safe snapshot.
        controller.restoreNow()
        await settle(controller)
        panel = LidSwitchPanelPresentation(controller: controller)
        XCTAssertEqual(fixture.read { $0.restores }, 1)
        XCTAssertEqual(fixture.read { $0.preparations }, 0)
        XCTAssertTrue(controller.snapshot.sleepDisabled)
        XCTAssertTrue(controller.restoreRequiresHelperRepair)
        XCTAssertEqual(panel.inlineAction?.kind, .prepareHelper)
        XCTAssertEqual(panel.inlineAction?.title, "Repair Helper")
        XCTAssertFalse(panel.commandKRestoresSleep)
        XCTAssertFalse(panel.masterEnabled)
        XCTAssertFalse(panel.sourceChoicesEnabled)
    }

    @MainActor
    private func makeController(_ fixture: PanelFixture) -> PowerController {
        let base = PowerControllerSideEffects.recordingFixture(
            { _ in }, administratorResult: { operation in fixture.administratorResult(operation) },
            terminalResolution: { session, _ in fixture.end(session) }
        )
        var effects = PowerControllerSideEffects(
            writeDesiredStateDisabled: base.writeDesiredStateDisabled, issueLease: base.issueLease,
            revokeLease: base.revokeLease, terminateLease: base.terminateLease,
            makeHeartbeat: base.makeHeartbeat, beginActivity: base.beginActivity, endActivity: base.endActivity,
            prepareHelper: base.prepareHelper,
            restoreSleep: {
                fixture.update { $0.restores += 1 }
                throw HelperControlError.rejected("containment-extinction-unproven")
            },
            uninstallHelper: base.uninstallHelper, terminateApplication: base.terminateApplication
        )
        effects.issueLeaseWithPolicy = { session, policy in fixture.begin(session, policy: policy) }
        effects.writePowerPreferences = { preferences in
            fixture.update { $0.preferences = preferences }
        }
        effects.makeHeartbeatWithPolicy = { _, _, _, _, _ in nil }
        return PowerController(
            bootstrap: false,
            snapshotProvider: { owned in fixture.snapshot(owned: owned) },
            forceFreshSnapshotProvider: { owned in fixture.inspectedSnapshot(owned: owned) },
            sideEffects: effects,
            safeRollbackWaiter: { fixture.snapshot(owned: nil) },
            restoreVerificationWaiter: { fixture.snapshot(owned: nil) },
            announcementHandler: { _ in }
        )
    }

    @MainActor
    private func settle(_ controller: PowerController, file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil(file: file, line: line) { !controller.isBusy && !controller.isChecking }
    }

    @MainActor
    private func waitUntil(file: StaticString = #filePath, line: UInt = #line,
                           _ predicate: @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(predicate(), "Controller did not settle", file: file, line: line)
    }
}

private enum PanelReadFailure: CaseIterable, Equatable { case source, sleep, inventory }

private final class PanelFixture: @unchecked Sendable {
    struct State {
        var source: PowerSource = .ac
        var preferences: PowerPreferences = .disabled
        var helperReady = true
        var sleepDisabled = false
        var issuedSession: UUID?
        var acSleep = 5
        var batterySleep = 7
        var originalAC: Int?
        var originalBattery: Int?
        var recoveryReason: String?
        var terminalSession: UUID?
        var failure: PanelReadFailure?
        var holdNextRead = false
        var holdPreparation = false
        var policies: [SessionPowerPolicy] = []
        var endedSessions: [UUID] = []
        var preparations = 0
        var restores = 0
    }
    private let lock = NSLock()
    private var state = State()
    private let readEntered = DispatchSemaphore(value: 0)
    private let preparationEntered = DispatchSemaphore(value: 0)
    let releaseRead = DispatchSemaphore(value: 0)
    let releasePreparation = DispatchSemaphore(value: 0)

    func read<T>(_ body: (State) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(state)
    }
    func update(_ body: (inout State) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&state)
    }
    func waitForRead() -> Bool { readEntered.wait(timeout: .now() + 2) == .success }
    func waitForPreparation() -> Bool { preparationEntered.wait(timeout: .now() + 2) == .success }

    func inspectedSnapshot(owned: UUID?) -> PowerSnapshot {
        let captured = snapshot(owned: owned)
        var hold = false
        update { hold = $0.holdNextRead; $0.holdNextRead = false }
        if hold {
            readEntered.signal()
            _ = releaseRead.wait(timeout: .now() + 5)
        }
        return captured // intentionally stale when OFF overlaps this read
    }

    func snapshot(owned: UUID?) -> PowerSnapshot {
        read { value in
            let base = PowerSnapshot(
                source: value.failure == .source ? .unknown("fixture") : value.source,
                sleepDisabled: value.sleepDisabled, sleepDisabledVerified: value.failure != .sleep,
                acIdleSleepMinutes: value.acSleep, batteryIdleSleepMinutes: value.batterySleep,
                preferences: value.preferences,
                helperArtifactsPresent: value.helperReady, helperLoaded: value.helperReady,
                helperNeedsUpdate: false, legacyLoginItemPresent: false, legacyLoginItemLoaded: false,
                activationLease: nil, ownedSessionID: owned,
                helperStatus: .init(state: value.recoveryReason != nil ? "recovery-required"
                                    : value.sleepDisabled ? "active" : "terminal",
                                    reason: value.recoveryReason ?? "fixture",
                                    sessionID: owned ?? value.terminalSession, updatedAt: Date()),
                systemBuild: "fixture", systemBuildQualified: true, bundleIntegrityValid: true,
                bundleVersionValid: true, checkedAt: Date(), installationInventoryState: .valid
            )
            return value.failure == .inventory
                ? base.withIndeterminateInstallationInventory(reason: "Fixture read interrupted.") : base
        }
    }

    func begin(_ session: UUID, policy: SessionPowerPolicy) -> PowerControllerLeaseIssueResolution {
        update {
            $0.issuedSession = session
            $0.originalAC = $0.acSleep
            $0.originalBattery = $0.batterySleep
            if policy.pluggedIn { $0.acSleep = 0 }
            if policy.onBattery { $0.batterySleep = 0 }
            $0.sleepDisabled = true
            $0.policies.append(policy)
        }
        let now = MonotonicClock.seconds()
        return .issued(ActivationLease(sessionID: session, bootID: "fixture", expiresAt: Date().addingTimeInterval(30),
                                       issuedMonotonic: now, expiresMonotonic: now + 30,
                                       ownerUID: 501, systemBuild: "fixture"))
    }

    func end(_ session: UUID) -> HelperGenerationTerminationResolution {
        lock.lock(); defer { lock.unlock() }
        guard state.issuedSession == session, let ac = state.originalAC, let battery = state.originalBattery else {
            return .authorityMayRemain("fixture-session-mismatch")
        }
        state.endedSessions.append(session)
        state.acSleep = ac
        state.batterySleep = battery
        state.sleepDisabled = false
        state.terminalSession = session
        state.issuedSession = nil
        return .terminated(HelperControlReply(reason: "peer-end", sessionID: session, expiryMonotonic: 0,
                                              state: .terminal, power: state.source.isAC ? .ac : .disconnected,
                                              sleepDisabled: false, acSleepMinutes: ac, batterySleepMinutes: battery))
    }

    func administratorResult(_ operation: AdministratorOperation) -> AdministratorOperationResult {
        update { $0.preparations += 1 }
        if read({ $0.holdPreparation }) {
            preparationEntered.signal()
            guard releasePreparation.wait(timeout: .now() + 5) == .success else {
                return .recoveryRequired(.init(transactionID: UUID(), operation: operation, state: .terminal,
                                               outcome: .recoveryRequired, sessionID: nil, reason: "fixture-timeout"))
            }
        }
        guard read({ !$0.sleepDisabled && $0.issuedSession == nil && $0.recoveryReason == nil }) else {
            return .recoveryRequired(.init(transactionID: UUID(), operation: operation, state: .terminal,
                                           outcome: .recoveryRequired, sessionID: nil, reason: "fixture-not-idle"))
        }
        update { $0.helperReady = true }
        return .safeIdle(.init(transactionID: UUID(), operation: operation, state: .terminal,
                               outcome: .safeIdle, sessionID: nil, reason: "fixture"))
    }
}
