import Foundation
import LidSwitchCore
import LidSwitchXPCBridge
import XCTest
@testable import LidSwitch

final class DetachedRestoreRepairFixtureTests: XCTestCase {
    @MainActor
    func testPublicContainmentWarningStillAttemptsPromptFreeRestore() async {
        let fixture = Fixture(reason: "containment-extinction-unproven")
        fixture.update { $0.restoreError = nil; $0.restoreConverges = true }
        let controller = makeController(fixture)
        controller.refresh()
        await settle(controller)
        XCTAssertTrue(controller.snapshot.helperReady)
        XCTAssertTrue(controller.snapshot.sleepDisabled)
        XCTAssertEqual(controller.primaryAction, .restoreSleep)
        XCTAssertFalse(controller.isKeepAwakeOn)

        controller.restoreNow()
        await settle(controller)
        XCTAssertEqual(fixture.read { $0.restores }, 1)
        XCTAssertEqual(fixture.read { $0.repairs }, 0)
        XCTAssertFalse(controller.snapshot.sleepDisabled)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.primaryAction, .startSession)
        XCTAssertFalse(controller.isKeepAwakeOn)
    }

    @MainActor
    func testRejectedOrdinaryRestoreLatchesRepairAcrossRefreshWithoutLosingSourceChoices() async {
        let fixture = Fixture(reason: "containment-pending")
        fixture.update { $0.restoreError = .rejected("containment-extinction-unproven") }
        let controller = makeController(fixture)
        controller.refresh()
        await settle(controller)
        XCTAssertEqual(controller.primaryAction, .restoreSleep)
        controller.restoreNow()
        await settle(controller)
        XCTAssertEqual(fixture.read { $0.restores }, 1)
        XCTAssertEqual(controller.operationPhase, .recoveryRequired)
        XCTAssertEqual(controller.primaryAction, .prepareHelper)
        XCTAssertTrue(controller.restoreRequiresHelperRepair)
        XCTAssertFalse(controller.errorMessage?.contains("try Restore Sleep again") == true)
        controller.refresh()
        await settle(controller)
        controller.restoreNow()
        await settle(controller)
        XCTAssertEqual(fixture.read { $0.restores }, 1)
        XCTAssertEqual(fixture.read { $0.repairs }, 0)
        XCTAssertTrue(controller.powerPreferences.allowPluggedInKeepAwake)
        XCTAssertTrue(controller.powerPreferences.allowBatteryKeepAwake)
        XCTAssertFalse(controller.isKeepAwakeOn)

        controller.prepareHelper()
        await settle(controller)
        XCTAssertEqual(fixture.read { $0.repairs }, 1)
        XCTAssertFalse(controller.snapshot.sleepDisabled)
        XCTAssertFalse(controller.restoreRequiresHelperRepair)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.primaryAction, .startSession)
        XCTAssertFalse(controller.isKeepAwakeOn) // repair cannot auto-arm
    }

    @MainActor
    func testAuthenticationFailureOffersRepairEvenWhenInstallationInventoryLooksReady() async {
        let fixture = Fixture(reason: "recovery-required")
        fixture.update { $0.restoreError = .transport(Int32(LS_XPC_STATUS_AUTHENTICATION_OR_PROTOCOL_FAILURE.rawValue)) }
        let controller = makeController(fixture)
        controller.refresh()
        await settle(controller)
        controller.restoreNow()
        await settle(controller)
        XCTAssertTrue(controller.snapshot.helperReady)
        XCTAssertEqual(controller.primaryAction, .prepareHelper)
        XCTAssertTrue(controller.errorMessage?.contains("identity or reply") == true)
        XCTAssertEqual(fixture.read { $0.repairs }, 0)
    }

    @MainActor
    func testInterruptedRestoreStaysPromptFreeAndCanConvergeOnRetry() async {
        let fixture = Fixture(reason: "recovery-required")
        fixture.update { $0.restoreError = .indeterminateTransport(60) }
        let controller = makeController(fixture)
        controller.refresh()
        await settle(controller)
        controller.restoreNow()
        await settle(controller)
        XCTAssertEqual(controller.primaryAction, .restoreSleep)
        XCTAssertFalse(controller.restoreRequiresHelperRepair)
        XCTAssertEqual(fixture.read { $0.repairs }, 0)

        fixture.update { $0.restoreError = nil; $0.restoreConverges = true }
        controller.restoreNow()
        await settle(controller)
        XCTAssertEqual(fixture.read { $0.restores }, 2)
        XCTAssertEqual(fixture.read { $0.repairs }, 0)
        XCTAssertFalse(controller.snapshot.sleepDisabled)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.primaryAction, .startSession)
    }

    @MainActor
    func testPendingCleanupDoesNotDemandAdministratorRepair() async {
        let fixture = Fixture(reason: "containment-pending")
        let controller = makeController(fixture)
        controller.refresh()
        await settle(controller)
        controller.restoreNow()
        await settle(controller)
        XCTAssertEqual(controller.primaryAction, .restoreSleep)
        XCTAssertFalse(controller.restoreRequiresHelperRepair)
        XCTAssertEqual(fixture.read { $0.repairs }, 0)
        fixture.update { $0.restoreError = nil; $0.restoreConverges = true }
        controller.restoreNow()
        await settle(controller)
        XCTAssertEqual(fixture.read { $0.restores }, 2)
        XCTAssertEqual(fixture.read { $0.repairs }, 0)
        XCTAssertNil(controller.errorMessage)
        XCTAssertFalse(controller.snapshot.sleepDisabled)
    }

    @MainActor
    func testRepairReceiptAloneCannotHideAnUnrestoredNativeOverride() async {
        let fixture = Fixture(reason: "containment-extinction-unproven")
        fixture.update { $0.repairConverges = false }
        let controller = makeController(fixture)
        controller.refresh()
        await settle(controller)
        controller.prepareHelper()
        await settle(controller)
        XCTAssertEqual(fixture.read { $0.repairs }, 1)
        XCTAssertTrue(controller.snapshot.sleepDisabled)
        XCTAssertEqual(controller.primaryAction, .restoreSleep)
        XCTAssertEqual(controller.displayedStatus.tone, .warning)
        XCTAssertFalse(controller.isKeepAwakeOn)
        XCTAssertNotNil(controller.errorMessage)
    }

    @MainActor
    func testInstallHandoffFinishesThroughAuthenticatedRestoreWithoutRearming() async {
        let fixture = Fixture(reason: "containment-extinction-unproven")
        fixture.update {
            $0.repairConverges = false
            $0.repairReason = "containment-extinguished-explicit-recovery-required"
            $0.restoreError = nil
            $0.restoreConverges = true
        }
        let controller = makeController(fixture)
        controller.refresh()
        await settle(controller)
        controller.prepareHelper()
        await settle(controller)
        XCTAssertEqual(fixture.read { $0.repairs }, 1)
        XCTAssertEqual(fixture.read { $0.restores }, 1)
        XCTAssertFalse(controller.snapshot.sleepDisabled)
        XCTAssertNil(controller.errorMessage)
        XCTAssertFalse(controller.isKeepAwakeOn)
        XCTAssertEqual(controller.primaryAction, .startSession)
        XCTAssertTrue(controller.powerPreferences.allowPluggedInKeepAwake)
        XCTAssertTrue(controller.powerPreferences.allowBatteryKeepAwake)
    }

    @MainActor
    func testInstallHandoffCannotCompleteWithoutAuthenticatedRestore() async {
        let fixture = Fixture(reason: "containment-extinction-unproven")
        fixture.update {
            $0.repairConverges = false
            $0.repairReason = "containment-extinguished-explicit-recovery-required"
            $0.restoreError = .unavailable
        }
        let controller = makeController(fixture)
        controller.refresh()
        await settle(controller)
        controller.prepareHelper()
        await settle(controller)
        XCTAssertEqual(fixture.read { $0.restores }, 1)
        XCTAssertTrue(controller.snapshot.sleepDisabled)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertTrue(controller.snapshot.restoreRequired)
        XCTAssertEqual(controller.primaryAction, .restoreSleep)
        XCTAssertFalse(controller.isKeepAwakeOn)
    }

    @MainActor
    func testLaterVerifiedSafeIdleClearsOnlyTheRestoreFailureAndItsRepairLatch() async {
        let fixture = Fixture(reason: "containment-pending")
        fixture.update { $0.restoreError = .rejected("containment-extinction-unproven") }
        let controller = makeController(fixture)
        controller.refresh()
        await settle(controller)
        controller.restoreNow()
        await settle(controller)
        XCTAssertTrue(controller.restoreRequiresHelperRepair)
        XCTAssertNotNil(controller.errorMessage)
        fixture.update { $0.safe = true }
        controller.refresh()
        await settle(controller)
        XCTAssertNil(controller.errorMessage)
        XCTAssertFalse(controller.restoreRequiresHelperRepair)
        XCTAssertEqual(controller.operationPhase, .idle)
        XCTAssertEqual(controller.primaryAction, .startSession)
    }

    func testOwnedSessionAndProgressKeepTheirExistingSafetyActions() {
        let fixture = Fixture(reason: "containment-extinction-unproven")
        let owned = fixture.snapshot(owned: UUID())
        XCTAssertEqual(PowerControllerPrimaryAction.resolve(
            snapshot: owned, operationPhase: .idle, restoreRequiresRepair: true
        ), .stopAndRestore)
        XCTAssertEqual(PowerControllerPrimaryAction.resolve(
            snapshot: owned, operationPhase: .starting, restoreRequiresRepair: true
        ), .cancelStart)
        let status = PowerControllerDisplayContract.make(
            snapshot: fixture.snapshot(), operationPhase: .preparingHelper,
            isChecking: false, restoreRequiresRepair: true
        )
        XCTAssertEqual(status.tone, .progress)
    }

    @MainActor
    private func makeController(_ fixture: Fixture) -> PowerController {
        let base = PowerControllerSideEffects.fixture
        let effects = PowerControllerSideEffects(
            writeDesiredStateDisabled: base.writeDesiredStateDisabled,
            issueLease: base.issueLease, revokeLease: base.revokeLease,
            terminateLease: base.terminateLease, makeHeartbeat: base.makeHeartbeat,
            beginActivity: base.beginActivity, endActivity: base.endActivity,
            prepareHelper: {
                fixture.update { $0.repairs += 1; if $0.repairConverges { $0.safe = true } }
                if let reason = fixture.read({ $0.repairReason }) {
                    return .recoveryRequired(.init(
                        transactionID: UUID(), operation: .install, state: .terminal,
                        outcome: .recoveryRequired, sessionID: nil, reason: reason
                    ))
                }
                return .safeIdle(.init(transactionID: UUID(), operation: .install,
                                       state: .terminal, outcome: .safeIdle, sessionID: nil, reason: "fixture"))
            },
            restoreSleep: {
                fixture.update { $0.restores += 1 }
                if let error = fixture.read({ $0.restoreError }) { throw error }
                fixture.update { if $0.restoreConverges { $0.safe = true } }
                return HelperControlReply(
                    reason: "idle", sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                    expiryMonotonic: 0, state: .idle, power: .ac,
                    sleepDisabled: false, acSleepMinutes: 5, batterySleepMinutes: 2
                )
            },
            uninstallHelper: base.uninstallHelper,
            terminateApplication: base.terminateApplication
        )
        return PowerController(
            bootstrap: false, snapshotProvider: { fixture.snapshot(owned: $0) },
            sideEffects: effects, safeRollbackWaiter: { fixture.snapshot() },
            restoreVerificationWaiter: { fixture.snapshot() }, announcementHandler: { _ in }
        )
    }

    @MainActor
    private func settle(_ controller: PowerController) async {
        for _ in 0..<500 {
            if !controller.isBusy && !controller.isChecking { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Fixture controller did not settle")
    }

    private struct State {
        let reason: String
        var safe = false
        var restores = 0
        var repairs = 0
        var restoreError: HelperControlError? = .rejected("containment-pending")
        var restoreConverges = false
        var repairConverges = true
        var repairReason: String?
    }

    private final class Fixture: @unchecked Sendable {
        private let lock = NSLock()
        private var state: State

        init(reason: String) { state = State(reason: reason) }

        func read<T>(_ body: (State) -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body(state)
        }

        func update(_ body: (inout State) -> Void) {
            lock.lock(); defer { lock.unlock() }
            body(&state)
        }

        func snapshot(owned: UUID? = nil) -> PowerSnapshot {
            read { value in
                let now = Date()
                return PowerSnapshot(
                    source: .ac, sleepDisabled: !value.safe, sleepDisabledVerified: true,
                    acIdleSleepMinutes: 5, batteryIdleSleepMinutes: 2,
                    preferences: .init(keepAwakeEnabled: false, allowBatteryKeepAwake: true,
                                       allowPluggedInKeepAwake: true),
                    helperArtifactsPresent: true, helperLoaded: true, helperNeedsUpdate: false,
                    legacyLoginItemPresent: false, legacyLoginItemLoaded: false,
                    activationLease: nil, ownedSessionID: owned,
                    helperStatus: .init(state: value.safe ? "inactive" : "recovery-required",
                                        reason: value.safe ? "idle" : value.reason, sessionID: nil, updatedAt: now),
                    systemBuild: "fixture", systemBuildQualified: true,
                    bundleIntegrityValid: true, bundleVersionValid: true, checkedAt: now
                )
            }
        }
    }
}
