import Dispatch
import Foundation
import LidSwitchCore
import XCTest
@testable import LidSwitch

/// Real controller prompt history and panel actions; all external effects are
/// isolated. Failed/aborted installs leave the fixture installation untouched.
final class SetupRetryFixtureTests: XCTestCase {
    @MainActor
    func testCanceledOrFailedAutomaticSetupOffersExplicitRetryWithoutAnotherAutomaticPrompt() async throws {
        for failure in SetupRetryFailure.allCases {
            let fixture = SetupRetryFixture(helperPresent: false)
            fixture.configureInstall(failure: failure, held: true)
            defer { fixture.releaseInstall.signal() }
            let controller = makeController(fixture)
            controller.refresh()
            await settle(controller)
            controller.setAllowBatteryKeepAwake(true)
            let preferences = controller.powerPreferences
            XCTAssertFalse(controller.requiresExplicitHelperPreparation)
            XCTAssertTrue(LidSwitchPanelPresentation(controller: controller).masterEnabled)
            XCTAssertNil(LidSwitchPanelPresentation(controller: controller).inlineAction)

            controller.setKeepAwakeEnabled(true)
            let entered = await Task.detached { fixture.waitForInstall() }.value
            XCTAssertTrue(entered, failure.rawValue)
            XCTAssertEqual(controller.operationPhase, .preparingHelper)
            XCTAssertTrue(controller.requiresExplicitHelperPreparation)
            XCTAssertTrue(LidSwitchPanelPresentation(controller: controller).masterEnabled)
            if failure == .offWhileAuthorizing {
                controller.setKeepAwakeEnabled(false)
                XCTAssertFalse(controller.isKeepAwakeOn)
                XCTAssertFalse(LidSwitchPanelPresentation(controller: controller).masterEnabled)
            }
            fixture.releaseInstall.signal()
            await settle(controller)
            XCTAssertEqual(fixture.installCount, 1)
            XCTAssertFalse(controller.snapshot.helperReady)
            XCTAssertFalse(controller.isKeepAwakeOn)
            try assertExplicitInstall(controller)

            // Refresh is not a new authorization gesture. A stale ON callback
            // must still meet the original process-lifetime automatic guard.
            controller.refreshManually()
            await settle(controller)
            controller.setKeepAwakeEnabled(true)
            await settle(controller)
            XCTAssertEqual(fixture.installCount, 1)
            XCTAssertFalse(controller.isKeepAwakeOn)
            XCTAssertTrue(controller.errorMessage?.contains("Choose Install Helper") == true)
            try assertExplicitInstall(controller)

            try await performExplicitInstall(controller, fixture: fixture)
            XCTAssertEqual(fixture.installCount, 2)
            XCTAssertEqual(controller.powerPreferences, preferences)
            XCTAssertEqual(fixture.preferences, preferences)
            XCTAssertFalse(fixture.events.contains("begin"))
            XCTAssertFalse(fixture.events.contains("restore-sleep"))
            XCTAssertEqual(controller.snapshot.acIdleSleepMinutes, 5)
            XCTAssertEqual(controller.snapshot.batteryIdleSleepMinutes, 7)
        }
    }

    @MainActor
    func testSameProcessRemovalAfterObservingReadyHelperOffersExplicitInstallAndStaysOff() async throws {
        let fixture = SetupRetryFixture(helperPresent: true)
        let controller = makeController(fixture)
        controller.refresh()
        await settle(controller)
        XCTAssertTrue(controller.snapshot.helperReady)
        XCTAssertTrue(controller.requiresExplicitHelperPreparation)
        controller.setAllowBatteryKeepAwake(true)
        controller.setAllowPluggedInKeepAwake(false)
        let preferences = controller.powerPreferences

        // Exercise successful removal through the real administrator boundary
        // and its fresh convergence; do not assign a clean controller snapshot.
        controller.uninstallHelper()
        await settle(controller)
        XCTAssertEqual(fixture.removalCount, 1)
        XCTAssertFalse(controller.snapshot.helperArtifactsPresent)
        XCTAssertEqual(controller.snapshot.helperLaunchdState, .absent)
        XCTAssertTrue(controller.requiresExplicitHelperPreparation)
        XCTAssertFalse(controller.isKeepAwakeOn)
        try assertExplicitInstall(controller)
        controller.refreshManually()
        await settle(controller)
        controller.setKeepAwakeEnabled(true)
        await settle(controller)
        XCTAssertEqual(fixture.installCount, 0)
        XCTAssertFalse(controller.isKeepAwakeOn)
        try assertExplicitInstall(controller)

        try await performExplicitInstall(controller, fixture: fixture)
        XCTAssertEqual(fixture.installCount, 1)
        XCTAssertEqual(fixture.removalCount, 1)
        XCTAssertEqual(controller.powerPreferences, preferences)
        XCTAssertFalse(fixture.events.contains("begin"))
        XCTAssertFalse(fixture.events.contains("restore-sleep"))

        let restarted = makeController(fixture)
        restarted.refresh()
        await settle(restarted)
        XCTAssertFalse(restarted.isKeepAwakeOn)
        XCTAssertEqual(restarted.powerPreferences, preferences)
        XCTAssertEqual(fixture.installCount, 1)
        XCTAssertFalse(fixture.events.contains("begin"))
    }

    @MainActor
    func testExplicitRetryStillRequiresVerifiedSleepAndTrustedBundle() async throws {
        for failure in SetupRetryReadFailure.allCases {
            let fixture = SetupRetryFixture(helperPresent: false)
            fixture.configureInstall(failure: .failed, held: false)
            let controller = makeController(fixture)
            controller.refresh()
            await settle(controller)
            controller.setKeepAwakeEnabled(true)
            await settle(controller)
            XCTAssertEqual(fixture.installCount, 1)
            try assertExplicitInstall(controller)

            fixture.failRead(failure)
            controller.refreshManually()
            await settle(controller)
            let panel = LidSwitchPanelPresentation(controller: controller)
            XCTAssertFalse(panel.masterEnabled)
            XCTAssertFalse(panel.inlineAction?.kind == .prepareHelper && panel.inlineAction?.isEnabled == true)
            XCTAssertNotEqual(controller.displayedStatus.tone, .neutral)
            controller.prepareHelper() // even a stale inline callback is gated
            await settle(controller)
            XCTAssertEqual(fixture.installCount, 1)
            XCTAssertFalse(controller.snapshot.helperReady)
            XCTAssertFalse(controller.isKeepAwakeOn)
            XCTAssertFalse(fixture.events.contains("begin"))
        }
    }

    @MainActor
    private func assertExplicitInstall(_ controller: PowerController,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let panel = LidSwitchPanelPresentation(controller: controller)
        let action = try XCTUnwrap(panel.inlineAction, file: file, line: line)
        XCTAssertTrue(controller.requiresExplicitHelperPreparation, file: file, line: line)
        XCTAssertEqual(controller.primaryAction, .prepareHelper, file: file, line: line)
        XCTAssertEqual(action.kind, .prepareHelper, file: file, line: line)
        XCTAssertEqual(action.title, "Install Helper", file: file, line: line)
        XCTAssertTrue(action.isEnabled, file: file, line: line)
        XCTAssertFalse(panel.masterEnabled, file: file, line: line)
        XCTAssertFalse(panel.commandKRestoresSleep, file: file, line: line)
        XCTAssertTrue(panel.masterHint.contains("Install Helper"), file: file, line: line)
        XCTAssertTrue(panel.guidance?.contains("Install Helper") == true, file: file, line: line)
        XCTAssertTrue(controller.displayedStatus.detail.contains("Choose Install Helper"), file: file, line: line)
        XCTAssertTrue(controller.displayedStatus.accessibilityState.contains("Choose Install Helper"), file: file, line: line)
    }

    @MainActor
    private func performExplicitInstall(_ controller: PowerController, fixture: SetupRetryFixture) async throws {
        try assertExplicitInstall(controller)
        fixture.configureInstall(failure: nil, held: true)
        defer { fixture.releaseInstall.signal() }
        // This is the actual panel's .prepareHelper action, not an injected
        // reset of prompt history, activation intent or verification state.
        controller.prepareHelper()
        let entered = await Task.detached { fixture.waitForInstall() }.value
        XCTAssertTrue(entered)
        XCTAssertEqual(controller.operationPhase, .preparingHelper)
        XCTAssertTrue(controller.requiresExplicitHelperPreparation)
        XCTAssertFalse(controller.isKeepAwakeOn)
        XCTAssertFalse(LidSwitchPanelPresentation(controller: controller).masterEnabled)
        controller.setKeepAwakeEnabled(true)
        XCTAssertFalse(controller.isKeepAwakeOn)
        fixture.releaseInstall.signal()
        await settle(controller)
        XCTAssertTrue(controller.snapshot.helperReady)
        XCTAssertNil(controller.errorMessage)
        XCTAssertFalse(controller.snapshot.sleepDisabled)
        XCTAssertTrue(controller.snapshot.sleepDisabledVerified)
        XCTAssertNil(controller.activeSessionIDForTesting)
        XCTAssertNil(controller.cleanupOwnerSessionIDForTesting)
        XCTAssertFalse(controller.isKeepAwakeOn)
        XCTAssertTrue(controller.requiresExplicitHelperPreparation)
        XCTAssertTrue(LidSwitchPanelPresentation(controller: controller).masterEnabled)
        XCTAssertNil(LidSwitchPanelPresentation(controller: controller).inlineAction)
        controller.refreshManually()
        await settle(controller)
        XCTAssertFalse(controller.isKeepAwakeOn)
    }

    @MainActor
    private func makeController(_ fixture: SetupRetryFixture) -> PowerController {
        var effects = PowerControllerSideEffects.recordingFixture(
            { fixture.record($0) }, administratorResult: { fixture.administer($0) }
        )
        effects.writePowerPreferences = { fixture.savePreferences($0) }
        effects.issueLeaseWithPolicy = { _, _ in
            fixture.record("begin")
            return .authorityMayRemain("unexpected-setup-activation")
        }
        effects.makeHeartbeatWithPolicy = { _, _, _, _, _ in nil }
        return PowerController(
            bootstrap: false,
            snapshotProvider: { fixture.snapshot(owned: $0) },
            forceFreshSnapshotProvider: { fixture.snapshot(owned: $0) },
            sideEffects: effects,
            safeRollbackWaiter: { fixture.snapshot(owned: nil) },
            restoreVerificationWaiter: { fixture.snapshot(owned: nil) },
            announcementHandler: { _ in }
        )
    }

    @MainActor
    private func settle(_ controller: PowerController, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 {
            if !controller.isBusy && !controller.isChecking { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Controller did not settle", file: file, line: line)
    }
}

private enum SetupRetryFailure: String, CaseIterable, Sendable { case authorizationCanceled, failed, offWhileAuthorizing }
private enum SetupRetryReadFailure: CaseIterable, Equatable, Sendable { case sleep, bundle }

private final class SetupRetryFixture: @unchecked Sendable {
    private struct State {
        var helperPresent: Bool
        var preferences: PowerPreferences = .disabled
        var installFailure: SetupRetryFailure?
        var holdInstall = false
        var readFailure: SetupRetryReadFailure?
        var installs = 0
        var removals = 0
        var events: [String] = []
    }
    private let lock = NSLock()
    private var state: State
    private let installEntered = DispatchSemaphore(value: 0)
    let releaseInstall = DispatchSemaphore(value: 0)

    init(helperPresent: Bool) { state = State(helperPresent: helperPresent) }

    private func read<T>(_ body: (State) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(state)
    }
    private func update(_ body: (inout State) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&state)
    }
    var installCount: Int { read { $0.installs } }
    var removalCount: Int { read { $0.removals } }
    var preferences: PowerPreferences { read { $0.preferences } }
    var events: [String] { read { $0.events } }
    func record(_ event: String) { update { $0.events.append(event) } }
    func savePreferences(_ preferences: PowerPreferences) { update { $0.preferences = preferences } }
    func failRead(_ failure: SetupRetryReadFailure) { update { $0.readFailure = failure } }
    func configureInstall(failure: SetupRetryFailure?, held: Bool) {
        update { $0.installFailure = failure; $0.holdInstall = held }
    }
    func waitForInstall() -> Bool { installEntered.wait(timeout: .now() + 2) == .success }

    func snapshot(owned: UUID?) -> PowerSnapshot {
        read { value in
            PowerSnapshot(
                source: .ac, sleepDisabled: false, sleepDisabledVerified: value.readFailure != .sleep,
                acIdleSleepMinutes: 5, batteryIdleSleepMinutes: 7, preferences: value.preferences,
                helperArtifactsPresent: value.helperPresent, helperLoaded: value.helperPresent,
                helperNeedsUpdate: false, legacyLoginItemPresent: false, legacyLoginItemLoaded: false,
                activationLease: nil, ownedSessionID: owned,
                helperStatus: value.helperPresent
                    ? .init(state: "inactive", reason: "fixture-idle", sessionID: nil, updatedAt: Date()) : nil,
                systemBuild: "fixture", systemBuildQualified: true,
                bundleIntegrityValid: value.readFailure != .bundle, bundleVersionValid: true,
                checkedAt: Date(), installationInventoryState: .valid
            )
        }
    }

    func administer(_ operation: AdministratorOperation) -> AdministratorOperationResult {
        if operation == .install {
            update { $0.installs += 1 }
            let configuration = read { ($0.installFailure, $0.holdInstall) }
            if configuration.1 {
                installEntered.signal()
                guard releaseInstall.wait(timeout: .now() + 5) == .success else {
                    return .completionIndeterminate(transactionID: UUID(), operation: operation, reason: "fixture-timeout")
                }
            }
            switch configuration.0 {
            case .authorizationCanceled?, .offWhileAuthorizing?:
                return .notStarted(operation: operation, reason: "administrator-launch-rejected")
            case .failed?:
                return .failed(.init(transactionID: UUID(), operation: operation, state: .terminal,
                                     outcome: .operationFailed, sessionID: nil, reason: "fixture-install-failed"))
            case nil:
                break
            }
        } else if operation == .uninstall {
            update { $0.removals += 1 }
        } else {
            return .notStarted(operation: operation, reason: "unexpected-restore")
        }
        lock.lock(); defer { lock.unlock() }
        // These scenarios begin with unchanged idle sleep settings and no
        // issued authority. A failed read or unexpected BEGIN cannot be made
        // safe by an install/removal receipt. Never clear recovery evidence.
        guard state.readFailure == nil, !state.events.contains("begin") else {
            return .recoveryRequired(.init(transactionID: UUID(), operation: operation, state: .terminal,
                                           outcome: .recoveryRequired, sessionID: nil, reason: "fixture-not-idle"))
        }
        state.helperPresent = operation == .install
        return .safeIdle(.init(transactionID: UUID(), operation: operation, state: .terminal,
                               outcome: .safeIdle, sessionID: nil, reason: "fixture-verified-idle"))
    }
}
