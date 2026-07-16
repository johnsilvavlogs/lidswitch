import AppKit
import Combine
import Foundation
import IOKit.ps
import LidSwitchCore

enum PowerControllerAlert: Equatable {
    // This alert is emitted only when the bounded helper-rollback waiter fails
    // to prove the terminal session safe. A later authoritative snapshot may
    // clear it, but only after the exact same safe-idle predicate succeeds.
    case rollbackVerificationFailure(reason: String)
    case operationFailure(message: String)

    var message: String {
        switch self {
        case let .rollbackVerificationFailure(reason):
            return "The safety monitor ended this session (\(reason)), and LidSwitch could not verify a complete rollback. Use Restore Sleep before starting another session or quitting."
        case let .operationFailure(message):
            return message
        }
    }
}

enum PowerControllerOperationPhase: Equatable, Sendable {
    case idle
    case starting
    case cancelRestoring
    case endingRestoring
    case preparingHelper
    case removingHelper
    case recoveryRequired
}

enum PowerControllerStatusTone: Equatable, Sendable {
    case neutral
    case progress
    case active
    case warning
}

enum PowerControllerPrimaryAction: Equatable, Sendable {
    case cancelStart
    case stopAndRestore
    case restoreSleep
    case cancelRestoringProgress
    case endingRestoringProgress
    case preparingHelperProgress
    case removingHelperProgress
    case prepareHelper
    case startSession

    var usesCommandK: Bool {
        switch self {
        case .cancelStart, .stopAndRestore, .restoreSleep, .startSession:
            return true
        case .cancelRestoringProgress, .endingRestoringProgress,
             .preparingHelperProgress, .removingHelperProgress, .prepareHelper:
            return false
        }
    }

    static func resolve(
        snapshot: PowerSnapshot,
        operationPhase: PowerControllerOperationPhase
    ) -> Self {
        if operationPhase == .starting { return .cancelStart }
        // Authoritative safety actions outrank any outstanding rollback waiter.
        if snapshot.sessionActive || snapshot.sessionPending { return .stopAndRestore }
        if snapshot.restoreRequired { return .restoreSleep }
        if operationPhase == .recoveryRequired { return .restoreSleep }
        if operationPhase == .cancelRestoring { return .cancelRestoringProgress }
        if operationPhase == .endingRestoring { return .endingRestoringProgress }
        if operationPhase == .preparingHelper { return .preparingHelperProgress }
        if operationPhase == .removingHelper { return .removingHelperProgress }
        if !snapshot.helperReady || snapshot.legacyResiduePresent { return .prepareHelper }
        return .startSession
    }
}

/// One native truth surface for the menu-bar label, panel status block, and
/// VoiceOver. Transient controller truth deliberately outranks both the empty
/// bootstrap snapshot and a stale active snapshot during bounded rollback.
struct PowerControllerDisplayContract: Equatable, Sendable {
    let title: String
    let detail: String
    let accessibilityState: String
    let menuBarSymbol: String
    let panelSymbol: String
    let tone: PowerControllerStatusTone

    static func make(
        snapshot: PowerSnapshot,
        operationPhase: PowerControllerOperationPhase,
        isChecking: Bool
    ) -> Self {
        if operationPhase == .recoveryRequired {
            return Self(
                title: "Recovery required",
                detail: "LidSwitch could not prove a detached safe-idle state. Protection is not being reported active; Restore Sleep remains available.",
                accessibilityState: "LidSwitch, recovery required. Protection is not being reported active because a detached safe-idle state was not proved. Restore Sleep remains available.",
                menuBarSymbol: "exclamationmark.triangle.fill",
                panelSymbol: "exclamationmark.triangle.fill",
                tone: .warning
            )
        }

        if operationPhase == .endingRestoring {
            return progress(
                title: "Ending and restoring…",
                detail: "Protection is ending. LidSwitch is verifying safe idle before reporting success or recovery required.",
                accessibility: "LidSwitch, ending and restoring. LidSwitch is not reporting protection as active while it verifies that the system sleep override is off.",
                menuBarSymbol: "arrow.triangle.2.circlepath",
                panelSymbol: "arrow.triangle.2.circlepath"
            )
        }

        if operationPhase == .preparingHelper {
            return progress(
                title: "Preparing safe helper…",
                detail: "LidSwitch is restoring safe idle, replacing old startup behavior, and verifying the crash-safe helper before reporting ready.",
                accessibility: "LidSwitch, preparing safe helper. Protection is not being reported active while LidSwitch restores safe idle, replaces old startup behavior, and verifies the helper.",
                menuBarSymbol: "shield.lefthalf.filled",
                panelSymbol: "shield.lefthalf.filled"
            )
        }

        if operationPhase == .removingHelper {
            return progress(
                title: "Removing helper…",
                detail: "LidSwitch is restoring safe idle, removing helper components, and verifying their absence before reporting success.",
                accessibility: "LidSwitch, removing helper. Protection is not being reported active while LidSwitch restores safe idle, removes helper components, and verifies their absence.",
                menuBarSymbol: "trash.circle",
                panelSymbol: "trash.circle"
            )
        }

        if operationPhase == .cancelRestoring {
            return progress(
                title: "Canceling and restoring…",
                detail: "Protection is ending. LidSwitch is verifying safe idle before reporting success.",
                accessibility: "LidSwitch, canceling and restoring. Protection may still be ending while LidSwitch verifies that the system sleep override is off.",
                menuBarSymbol: "arrow.triangle.2.circlepath",
                panelSymbol: "arrow.triangle.2.circlepath",
                tone: .neutral
            )
        }

        if operationPhase == .starting {
            return progress(
                title: "Starting and verifying…",
                detail: "Protection may not yet be active. Cancel and Restore remains available while LidSwitch waits for helper confirmation.",
                accessibility: "LidSwitch, starting and verifying. Protection may not be active yet. Cancel and Restore is available.",
                menuBarSymbol: "clock.badge.checkmark",
                panelSymbol: "clock.fill"
            )
        }

        let isInitialCheck = snapshot.checkedAt == .distantPast
            && (isChecking || snapshot.installationInventoryPending)
        if isInitialCheck {
            return progress(
                title: "Checking current macOS state…",
                detail: "Reading the current power source and system sleep override. Protection stays off until this check finishes.",
                accessibility: "LidSwitch, checking current macOS state. Protection remains off until the initial safety check finishes.",
                menuBarSymbol: "arrow.triangle.2.circlepath",
                panelSymbol: "arrow.triangle.2.circlepath",
                tone: .neutral
            )
        }

        if snapshot.installationInventoryPending && !snapshot.sessionActive {
            return progress(
                title: "Checking installation…",
                detail: "Checking the installed helper and app bundle. Protection stays off until this exact check finishes.",
                accessibility: "LidSwitch, checking installation. Protection remains off until the exact installation check finishes.",
                menuBarSymbol: "arrow.triangle.2.circlepath",
                panelSymbol: "arrow.triangle.2.circlepath",
                tone: .neutral
            )
        }

        let tone: PowerControllerStatusTone
        let menuBarSymbol: String
        let panelSymbol: String
        if snapshot.hasCriticalSafetyIssue {
            tone = .warning
            menuBarSymbol = "exclamationmark.triangle.fill"
            panelSymbol = "exclamationmark.triangle.fill"
        } else if snapshot.sessionActive {
            tone = .active
            menuBarSymbol = "checkmark.shield.fill"
            panelSymbol = "checkmark.circle.fill"
        } else if snapshot.sessionPending {
            tone = .progress
            menuBarSymbol = "clock.badge.checkmark"
            panelSymbol = "clock.fill"
        } else {
            tone = .neutral
            menuBarSymbol = snapshot.helperReady
                ? (snapshot.source.isAC ? "shield" : "powerplug")
                : "shield.slash"
            panelSymbol = "circle"
        }

        return Self(
            title: snapshot.statusTitle,
            detail: snapshot.statusDetail,
            accessibilityState: snapshot.accessibilityState,
            menuBarSymbol: menuBarSymbol,
            panelSymbol: panelSymbol,
            tone: tone
        )
    }

    private static func progress(
        title: String,
        detail: String,
        accessibility: String,
        menuBarSymbol: String,
        panelSymbol: String,
        tone: PowerControllerStatusTone = .progress
    ) -> Self {
        Self(
            title: title,
            detail: detail,
            accessibilityState: accessibility,
            menuBarSymbol: menuBarSymbol,
            panelSymbol: panelSymbol,
            tone: tone
        )
    }
}

struct PowerControllerInventoryFixtureResult: Sendable {
    let snapshot: PowerSnapshot
    let rejection: PowerInspector.InstallationInventoryRejection?
}

private final class SnapshotProviderBox: @unchecked Sendable {
    typealias FastCompletion = @Sendable (PowerSnapshot) -> Void
    typealias InventoryCompletion = @Sendable (
        PowerSnapshot,
        PowerInspector.InstallationInventoryRejection?
    ) -> Void

    private let loader: @Sendable (
        UUID?,
        Bool,
        @escaping FastCompletion,
        @escaping InventoryCompletion
    ) -> Void
    let invalidateInventory: @Sendable () -> Void

    init(
        cached: @escaping @Sendable (UUID?) -> PowerSnapshot,
        forceFresh: @escaping @Sendable (UUID?) -> PowerSnapshot,
        invalidateInventory: @escaping @Sendable () -> Void = {}
    ) {
        loader = { ownedSessionID, force, fastCompletion, inventoryCompletion in
            if force { invalidateInventory() }
            Task.detached {
                let next = force ? forceFresh(ownedSessionID) : cached(ownedSessionID)
                fastCompletion(next)
                inventoryCompletion(next, nil)
            }
        }
        self.invalidateInventory = invalidateInventory
    }

    init(
        resultProvider: @escaping @Sendable (
            UUID?,
            Bool
        ) -> PowerControllerInventoryFixtureResult,
        invalidateInventory: @escaping @Sendable () -> Void = {}
    ) {
        loader = { ownedSessionID, force, fastCompletion, inventoryCompletion in
            if force { invalidateInventory() }
            Task.detached {
                let result = resultProvider(ownedSessionID, force)
                fastCompletion(result.snapshot)
                inventoryCompletion(result.snapshot, result.rejection)
            }
        }
        self.invalidateInventory = invalidateInventory
    }

    init() {
        loader = { ownedSessionID, force, fastCompletion, inventoryCompletion in
            if force {
                // Force-fresh callers must never observe a prior valid
                // inventory while their exact authorization check is pending.
                PowerInspector.invalidateInstallationInventory()
            }
            fastCompletion(PowerInspector.dynamicSnapshot(ownedSessionID: ownedSessionID))
            PowerInspector.requestInstallationInventory(
                policy: force ? .forceFresh : .reuseIfFresh
            ) { result in
                inventoryCompletion(
                    PowerInspector.dynamicSnapshot(
                        ownedSessionID: ownedSessionID,
                        inventory: result.inventory
                    ),
                    result.rejection
                )
            }
        }
        invalidateInventory = PowerInspector.invalidateInstallationInventory
    }

    func load(
        ownedSessionID: UUID?,
        forceFresh: Bool,
        fastCompletion: @escaping FastCompletion,
        inventoryCompletion: @escaping InventoryCompletion
    ) {
        loader(ownedSessionID, forceFresh, fastCompletion, inventoryCompletion)
    }
}

private enum RefreshPurpose: Sendable {
    case start(requestID: UUID)
    case prepareConvergence(operationEpoch: Int)
    case uninstallConvergence(operationEpoch: Int)
}

private struct PendingRefreshIntent {
    var forceFresh: Bool
    var purpose: RefreshPurpose?
}

enum PowerControllerSideEffectError: Error, Equatable {
    case productionMutationBlockedInTest
}

enum PowerControllerLeaseIssueResolution: Equatable, Sendable {
    case issued(ActivationLease)
    case reconnected(ActivationLease)
    /// An authenticated exact-session BEGIN/RECONNECT response proved this
    /// generation never became active. It is authority proof only; it is not
    /// a substitute for a later power-rollback proof.
    case idle(HelperControlReply)
    case terminal(HelperControlReply)
    case authorityMayRemain(String)
}

// All controller-owned state transitions pass through this narrow boundary.
// Production uses the same stores, heartbeat, activity, helper operations, and
// termination behavior as before; tests inject the fixture instance so an
// accidental successful Start/Cancellation path cannot touch user artifacts.
struct PowerControllerSideEffects: @unchecked Sendable {
    typealias HeartbeatFactory = @Sendable (
        UUID,
        @escaping @Sendable (UUID) -> Void,
        @escaping @Sendable (UUID, String) -> Void,
        @escaping @Sendable () -> Bool
    ) -> SessionHeartbeatCoordinator?

    let writeDesiredStateDisabled: @Sendable () throws -> Void
    let issueLease: @Sendable (UUID) throws -> PowerControllerLeaseIssueResolution
    let revokeLease: @Sendable () throws -> Void
    /// The production client returns an authenticated terminal/idle response
    /// when available. Fixtures may return nil; nil must never clear cleanup
    /// ownership or turn a recovery state green.
    let terminateLease: @Sendable (UUID, HelperGenerationTerminationIntent) -> HelperGenerationTerminationResolution?
    let makeHeartbeat: HeartbeatFactory
    let beginActivity: @MainActor @Sendable () -> NSObjectProtocol
    let endActivity: @MainActor @Sendable (NSObjectProtocol) -> Void
    let prepareHelper: @Sendable () throws -> AdministratorOperationResult
    let restoreSleep: @Sendable () throws -> AdministratorOperationResult
    let uninstallHelper: @Sendable () throws -> AdministratorOperationResult
    let terminateApplication: @MainActor @Sendable () -> Void

    // Production composition must inject the authenticated raw-XPC client.
    // The nil default exists only so fixture tests can prove the mutation guard;
    // it never discovers or connects to a production service implicitly.
    static func production(client: RawHelperControlClient? = nil) -> Self {
        let testRuntimeDetector = isXCTestProcess
        return Self(
        writeDesiredStateDisabled: {
            guard !testRuntimeDetector() else { throw PowerControllerSideEffectError.productionMutationBlockedInTest }
            try DesiredStateStore.write(.disabled)
        },
        issueLease: {
            guard !testRuntimeDetector() else { throw PowerControllerSideEffectError.productionMutationBlockedInTest }
            guard let client else { throw HelperControlError.unavailable }
            switch try client.resolveBegin(sessionID: $0) {
            case let .issued(reply):
                return .issued(Self.activationLease(sessionID: $0, reply: reply))
            case let .reconnected(reply):
                return .reconnected(Self.activationLease(sessionID: $0, reply: reply))
            case let .idle(reply):
                return .idle(reply)
            case let .terminal(reply):
                return .terminal(reply)
            case let .authorityMayRemain(reason):
                return .authorityMayRemain(reason)
            }
        },
        revokeLease: {
            guard !testRuntimeDetector() else { throw PowerControllerSideEffectError.productionMutationBlockedInTest }
            // Compatibility surface for the mutation-guard fixture only. A
            // production generation can be terminated only with its exact
            // session ID through `terminateLease` (RECONNECT then END/RESTORE).
            throw HelperControlError.rejected("session-bound-termination-required")
        },
        terminateLease: { sessionID, intent in
            guard !testRuntimeDetector(), let client else { return nil }
            return client.terminateGeneration(sessionID: sessionID, intent: intent)
        },
        makeHeartbeat: { sessionID, onAcknowledged, onEnded, claimCleanup in
            guard !testRuntimeDetector(), let client else { return nil }
            return SessionHeartbeatCoordinator(
                observe: { sessionID in
                    // One-second heartbeat ticks intentionally avoid XPC
                    // SNAPSHOT. Native AC plus durable terminal status are the
                    // observation surface; BEGIN and eight-second RENEW are
                    // the authenticated authority exchanges.
                    // Native AC is the app-side renewal prerequisite. The
                    // status file is diagnostic projection: a missing, stale,
                    // or corrupt active publication cannot revoke the exact
                    // in-memory generation that BEGIN/RENEW established.
                    Self.rawXPCHeartbeatObservation(
                        sessionID: sessionID,
                        native: PowerInspector.sessionHeartbeatObservation(sessionID: sessionID),
                        now: Date()
                    )
                },
                renew: { sessionID, mode, commitGuard in
                    try Self.guardedHeartbeatRenewal(
                        testRuntimeDetector: testRuntimeDetector,
                        renew: {
                            guard commitGuard() else { throw HelperControlError.rejected("stale-renewal") }
                            let advance: HelperLeaseAdvance
                            switch mode {
                            case .recoverTransportOnce:
                                advance = try client.renew(sessionID: sessionID)
                            case .directOnly:
                                advance = try client.renewDirect(sessionID: sessionID)
                            }
                            switch advance {
                            case let .renewed(expiryMonotonic):
                                return .renewed(expiryMonotonic: expiryMonotonic)
                            case let .reconnected(originalExpiryMonotonic):
                                return .reconnected(originalExpiryMonotonic: originalExpiryMonotonic)
                            case let .reconnectedButUnbound(reason):
                                return .reconnectedButUnbound(reason: reason)
                            case let .indeterminateNoAdvance(reason):
                                return .indeterminateNoAdvance(reason: reason)
                            }
                        }
                    )
                },
                revoke: {
                    guard claimCleanup() else { return }
                    let resolution = Self.guardedHeartbeatTermination(
                        testRuntimeDetector: testRuntimeDetector,
                        terminate: { client.terminateGeneration(sessionID: sessionID, intent: .restore) }
                    )
                    HeartbeatTerminalProofHandoff.record(sessionID: sessionID, resolution: resolution)
                },
                endRemote: { endedSessionID, reason in
                    guard claimCleanup() else { return }
                    let intent: HelperGenerationTerminationIntent = reason == "user-end" ? .end : .restore
                    let resolution = Self.guardedHeartbeatTermination(
                        testRuntimeDetector: testRuntimeDetector,
                        terminate: { client.terminateGeneration(sessionID: endedSessionID, intent: intent) }
                    )
                    HeartbeatTerminalProofHandoff.record(sessionID: endedSessionID, resolution: resolution)
                },
                onAcknowledged: onAcknowledged,
                onEnded: onEnded
            )
        },
        beginActivity: {
            guard !testRuntimeDetector() else { return NSObject() }
            return ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Maintain the user-confirmed LidSwitch session lease"
            )
        },
        endActivity: {
            guard !testRuntimeDetector() else { return }
            ProcessInfo.processInfo.endActivity($0)
        },
        prepareHelper: {
            guard !testRuntimeDetector() else { throw PowerControllerSideEffectError.productionMutationBlockedInTest }
            try ActivationLeaseStore.reconcileRecognizedLegacyLease()
            try DesiredStateStore.write(.disabled)
            try LegacyAutostartManager.remove()
            return try PrivilegedHelperManager.install()
        },
        restoreSleep: {
            guard !testRuntimeDetector() else { throw PowerControllerSideEffectError.productionMutationBlockedInTest }
            return try PrivilegedHelperManager.restoreSleepNow()
        },
        uninstallHelper: {
            guard !testRuntimeDetector() else { throw PowerControllerSideEffectError.productionMutationBlockedInTest }
            try DesiredStateStore.write(.disabled)
            try LegacyAutostartManager.remove()
            return try PrivilegedHelperManager.uninstall()
        },
        terminateApplication: {
            guard !testRuntimeDetector() else { return }
            NSApplication.shared.terminate(nil)
        }
        )
    }

    private static func isXCTestProcess() -> Bool {
        isXCTestRuntime(
            executable: ProcessInfo.processInfo.arguments.first ?? "",
            environment: ProcessInfo.processInfo.environment
        )
    }

    private static func activationLease(
        sessionID: UUID,
        reply: HelperControlReply
    ) -> ActivationLease {
        let issuedMonotonic = MonotonicClock.seconds()
        return ActivationLease(
            sessionID: sessionID,
            bootID: "authenticated-xpc",
            expiresAt: Date().addingTimeInterval(max(0, reply.expiryMonotonic - issuedMonotonic)),
            issuedMonotonic: issuedMonotonic,
            expiresMonotonic: reply.expiryMonotonic,
            ownerUID: getuid(),
            systemBuild: SystemBuild.current() ?? "unknown"
        )
    }

    /// Raw-XPC authority is coordinator-owned: its session/phase/expiry commit
    /// guard is in memory, while the helper publishes the independent durable
    /// active fact. The legacy lease file is migration/diagnostic residue and
    /// intentionally cannot authorize or block this path.
    static func rawXPCHeartbeatObservation(
        sessionID _: UUID,
        native: SessionHeartbeatObservation,
        now _: Date
    ) -> SessionHeartbeatObservation {
        let status = native.helperStatus
        return SessionHeartbeatObservation(
            power: native.power,
            authority: native.power == .ac ? .verified : .indeterminate,
            helperStatus: status
        )
    }

    private static func isXCTestRuntime(executable: String, environment: [String: String]) -> Bool {
        executable.contains(".xctest")
            || executable.hasSuffix("/xctest")
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }

    private static func guardedHeartbeatRenewal(
        testRuntimeDetector: @escaping @Sendable () -> Bool,
        renew: @escaping @Sendable () throws -> SessionHeartbeatAdvance
    ) throws -> SessionHeartbeatAdvance {
        guard !testRuntimeDetector() else {
            throw PowerControllerSideEffectError.productionMutationBlockedInTest
        }
        return try renew()
    }

    @discardableResult
    private static func guardedHeartbeatRevocation(
        testRuntimeDetector: @escaping @Sendable () -> Bool,
        revoke: @escaping @Sendable () -> Void
    ) -> Bool {
        guard !testRuntimeDetector() else { return false }
        revoke()
        return true
    }

    private static func guardedHeartbeatTermination(
        testRuntimeDetector: @escaping @Sendable () -> Bool,
        terminate: @escaping @Sendable () -> HelperGenerationTerminationResolution?
    ) -> HelperGenerationTerminationResolution? {
        guard !testRuntimeDetector() else { return nil }
        return terminate()
    }

    #if DEBUG
    static func isXCTestRuntimeForTesting(executable: String, environment: [String: String]) -> Bool {
        isXCTestRuntime(executable: executable, environment: environment)
    }

    static func guardedHeartbeatRenewalForTesting(
        testRuntimeDetector: @escaping @Sendable () -> Bool,
        renew: @escaping @Sendable () throws -> SessionHeartbeatAdvance
    ) throws -> SessionHeartbeatAdvance {
        try guardedHeartbeatRenewal(testRuntimeDetector: testRuntimeDetector, renew: renew)
    }

    static func guardedHeartbeatRenewalForTesting(
        testRuntimeDetector: @escaping @Sendable () -> Bool,
        renew: @escaping @Sendable () throws -> TimeInterval
    ) throws -> TimeInterval {
        guard !testRuntimeDetector() else {
            throw PowerControllerSideEffectError.productionMutationBlockedInTest
        }
        return try renew()
    }

    static func guardedHeartbeatRevocationForTesting(
        testRuntimeDetector: @escaping @Sendable () -> Bool,
        revoke: @escaping @Sendable () -> Void
    ) -> Bool {
        guardedHeartbeatRevocation(testRuntimeDetector: testRuntimeDetector, revoke: revoke)
    }
    #endif

    #if DEBUG
    // Intentionally no-op: this fixture is suitable only for unit tests. It
    // does not create, revoke, or inspect any production artifact.
    static let fixture = recordingFixture { _ in }

    static func recordingFixture(
        _ record: @escaping @Sendable (String) -> Void,
        terminalResolution: @escaping @Sendable (UUID, HelperGenerationTerminationIntent) -> HelperGenerationTerminationResolution? = { _, _ in nil }
    ) -> Self {
        recordingFixture(
            record,
            administratorResult: fixtureAdministratorResult,
            terminalResolution: terminalResolution
        )
    }

    static func recordingFixture(
        _ record: @escaping @Sendable (String) -> Void,
        administratorResult: @escaping @Sendable (AdministratorOperation) -> AdministratorOperationResult,
        terminalResolution: @escaping @Sendable (UUID, HelperGenerationTerminationIntent) -> HelperGenerationTerminationResolution? = { _, _ in nil }
    ) -> Self {
        Self(
        writeDesiredStateDisabled: { record("desired-state-disabled") },
        issueLease: { sessionID in
            record("lease-issue")
            return .issued(ActivationLease(
                sessionID: sessionID,
                bootID: "fixture",
                expiresAt: .distantFuture,
                issuedMonotonic: 0,
                expiresMonotonic: .greatestFiniteMagnitude,
                ownerUID: getuid(),
                systemBuild: "fixture"
            ))
        },
        revokeLease: { record("lease-revoke") },
        terminateLease: { sessionID, intent in
            record("lease-revoke")
            return terminalResolution(sessionID, intent)
        },
        makeHeartbeat: { _, _, _, _ in
            record("heartbeat")
            return nil
        },
        beginActivity: {
            record("activity-begin")
            return NSObject()
        },
        endActivity: { _ in record("activity-end") },
        prepareHelper: {
            record("prepare-helper")
            return administratorResult(.install)
        },
        restoreSleep: {
            record("restore-sleep")
            return administratorResult(.userRestore)
        },
        uninstallHelper: {
            record("uninstall-helper")
            return administratorResult(.uninstall)
        },
        terminateApplication: { record("terminate") }
        )
    }

    static func lifecycleFixture(
        _ record: @escaping @Sendable (String) -> Void,
        issueLease: @escaping @Sendable (UUID) throws -> PowerControllerLeaseIssueResolution,
        terminateLease: @escaping @Sendable (UUID, HelperGenerationTerminationIntent) -> Void,
        makeHeartbeat: @escaping HeartbeatFactory,
        terminalResolution: @escaping @Sendable (UUID, HelperGenerationTerminationIntent) -> HelperGenerationTerminationResolution? = { _, _ in nil }
    ) -> Self {
        Self(
        writeDesiredStateDisabled: { record("desired-state-disabled") },
        issueLease: { sessionID in
            record("lease-issue")
            return try issueLease(sessionID)
        },
        revokeLease: { record("lease-revoke-legacy") },
        terminateLease: { sessionID, intent in
            terminateLease(sessionID, intent)
            return terminalResolution(sessionID, intent)
        },
        makeHeartbeat: makeHeartbeat,
        beginActivity: {
            record("activity-begin")
            return NSObject()
        },
        endActivity: { _ in record("activity-end") },
        prepareHelper: {
            record("prepare-helper")
            return fixtureAdministratorResult(.install)
        },
        restoreSleep: {
            record("restore-sleep")
            return fixtureAdministratorResult(.userRestore)
        },
        uninstallHelper: {
            record("uninstall-helper")
            return fixtureAdministratorResult(.uninstall)
        },
        terminateApplication: { record("terminate") }
        )
    }

    private static func fixtureAdministratorResult(
        _ operation: AdministratorOperation
    ) -> AdministratorOperationResult {
        .safeIdle(.init(
            transactionID: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            operation: operation,
            state: .terminal,
            outcome: .safeIdle,
            sessionID: nil,
            reason: "fixture"
        ))
    }
    #endif
}

/// Transfers the exact terminal receipt across the existing bool-only heartbeat
/// factory boundary. A claim inserts one session-bound owner and the immediate
/// END/RESTORE closure consumes it exactly once; this preserves fixture API
/// compatibility while never retaining a receipt past the terminal exchange.
private final class HeartbeatTerminalProofHandoff: @unchecked Sendable {
    private static let shared = HeartbeatTerminalProofHandoff()
    private let lock = NSLock()
    private var pendingOwners: [UUID: RemoteAuthorityCleanupOwnership] = [:]

    static func claim(_ owner: RemoteAuthorityCleanupOwnership) -> Bool {
        guard owner.claimTerminalEffect() else { return false }
        shared.lock.lock()
        shared.pendingOwners[owner.sessionID] = owner
        shared.lock.unlock()
        return true
    }

    static func record(
        sessionID: UUID,
        resolution: HelperGenerationTerminationResolution?
    ) {
        shared.lock.lock()
        let owner = shared.pendingOwners.removeValue(forKey: sessionID)
        shared.lock.unlock()
        owner?.recordAuthenticatedTerminalProof(resolution)
    }
}

/// Session- and generation-bound ownership for the one raw END/RESTORE effect.
/// The claim is independent of transport success: after crossing the terminal
/// boundary only a fresh safe-idle observation may release controller cleanup
/// responsibility. Reference identity prevents a stale callback or waiter from
/// clearing a later session's owner.
private final class RemoteAuthorityCleanupOwnership: @unchecked Sendable {
    private enum State {
        case beginInFlight
        case authorityIssued
        case protocolTerminal
        case terminalEffectClaimed
        case safeIdleProven
    }

    let sessionID: UUID
    let generation: Int
    /// Captured from the force-fresh pre-BEGIN snapshot. Zero is a legitimate
    /// user setting and is deliberately preserved as a value, not a sentinel.
    let originalACIdleSleepMinutes: Int
    private let lock = NSLock()
    private var state: State = .beginInFlight
    private var authenticatedTerminalProof: HelperControlReply?

    init(sessionID: UUID, generation: Int, originalACIdleSleepMinutes: Int) {
        self.sessionID = sessionID
        self.generation = generation
        self.originalACIdleSleepMinutes = originalACIdleSleepMinutes
    }

    func markAuthorityIssued() {
        lock.lock(); defer { lock.unlock() }
        guard case .beginInFlight = state else { return }
        state = .authorityIssued
    }

    func markProtocolTerminal() {
        lock.lock(); defer { lock.unlock() }
        guard case .beginInFlight = state else { return }
        state = .protocolTerminal
    }

    /// Retain only an authenticated exact-session response that proves the
    /// terminal exchange also restored the two power values this generation
    /// changed. A malformed, active, recovery-required, mismatched, or
    /// incomplete reply remains non-green.
    func recordAuthenticatedTerminalProof(
        _ resolution: HelperGenerationTerminationResolution?
    ) {
        let reply: HelperControlReply?
        switch resolution {
        case let .terminated(candidate), let .alreadyIdle(candidate), let .alreadyTerminal(candidate):
            reply = candidate
        case .authorityMayRemain, .none:
            reply = nil
        }
        guard let reply,
              reply.sessionID == sessionID,
              reply.state == .idle || reply.state == .terminal,
              reply.power == .ac,
              reply.sleepDisabled == false,
              reply.acSleepMinutes == originalACIdleSleepMinutes
        else { return }
        lock.lock(); defer { lock.unlock() }
        authenticatedTerminalProof = reply
    }

    /// A root status is projection-only, but it can prove post-terminal power
    /// convergence when it names this exact generation. Ordinary inactive or
    /// terminal observations must be fresh. An exact-session `peer-restore`
    /// terminal is durable across a long battery interval only when its
    /// projection tuple proves it was written during the current boot. A nil,
    /// unrelated, active, prior-boot, malformed-monotonic, or
    /// recovery-required record is intentionally not a cleanup release signal.
    func provesFullRollback(_ snapshot: PowerSnapshot) -> Bool {
        guard let status = snapshot.helperStatus else { return false }
        let currentBootID = BootIdentity.current()
        let currentMonotonic = MonotonicClock.seconds()
        let terminalPeerRestore = status.state == "terminal"
            && status.reason == "peer-restore"
            && currentBootID != nil
            && status.bootID == currentBootID
            && status.updatedMonotonic?.isFinite == true
            && status.updatedMonotonic.map { $0 >= 0 && $0 <= currentMonotonic } == true
        let statusIsCurrent = status.isFresh(at: snapshot.checkedAt)
            || terminalPeerRestore
        guard snapshot.ownedSessionID == nil,
              snapshot.source.isAC,
              snapshot.sleepDisabledVerified,
              !snapshot.sleepDisabled,
              snapshot.acIdleSleepMinutes == originalACIdleSleepMinutes,
              status.sessionID == sessionID,
              statusIsCurrent,
              status.state == "inactive" || status.state == "terminal",
              !snapshot.helperRecoveryRequired
        else { return false }
        return true
    }

    var hasAuthenticatedTerminalProof: Bool {
        lock.lock(); defer { lock.unlock() }
        return authenticatedTerminalProof != nil
    }

    /// Returns true for exactly one caller. The transition happens before the
    /// raw side effect, so a lost terminal reply cannot enable a duplicate.
    func claimTerminalEffect() -> Bool {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .beginInFlight, .authorityIssued:
            state = .terminalEffectClaimed
            return true
        case .protocolTerminal, .terminalEffectClaimed, .safeIdleProven:
            return false
        }
    }

    func markSafeIdleProven() {
        lock.lock(); defer { lock.unlock() }
        state = .safeIdleProven
    }

    func markProtocolTerminalResolved() {
        lock.lock(); defer { lock.unlock() }
        guard case .protocolTerminal = state else { return }
        state = .safeIdleProven
    }

    var requiresSafetyResolution: Bool {
        lock.lock(); defer { lock.unlock() }
        if case .safeIdleProven = state { return false }
        return true
    }
}

@MainActor
final class PowerController: ObservableObject {
    @Published private(set) var snapshot: PowerSnapshot = .empty
    @Published private(set) var isBusy = false
    @Published private(set) var operationPhase: PowerControllerOperationPhase = .idle
    @Published private(set) var isChecking = false
    @Published private(set) var alert: PowerControllerAlert?

    var errorMessage: String? { alert?.message }
    var isStarting: Bool { operationPhase == .starting }
    var isCancelRestoring: Bool { operationPhase == .cancelRestoring }
    var isEndingRestoring: Bool { operationPhase == .endingRestoring }

    var displayedStatus: PowerControllerDisplayContract {
        .make(snapshot: snapshot, operationPhase: operationPhase, isChecking: isChecking)
    }

    var primaryAction: PowerControllerPrimaryAction {
        .resolve(snapshot: snapshot, operationPhase: operationPhase)
    }

    nonisolated private static let refreshInterval: TimeInterval = 30
    nonisolated private static let restoreTimeout: TimeInterval = 8
    // Helper rollback can perform three bounded read/write/read attempts for
    // both SleepDisabled and AC sleep (~18.4s worst case). Keep automatic
    // termination verification above that bound, with margin, but below the
    // 45-second live acceptance deadline. User-invoked restore/preparation
    // operations retain their existing, shorter bounds.
    nonisolated private static let helperRollbackVerificationTimeout: TimeInterval = 30

    private var refreshTimer: Timer?
    private var heartbeat: SessionHeartbeatCoordinator?
    private var activeSessionID: UUID?
    private var cleanupOwnership: RemoteAuthorityCleanupOwnership?
    private var sessionWasAcknowledged = false
    private var activityToken: NSObjectProtocol?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var nextTerminationIsAuthorized = false
    private var terminationInvalidated = false
    private struct PendingTerminationReply {
        let id: UUID
        let completion: (Bool) -> Void
    }
    private var pendingTerminationReply: PendingTerminationReply?
    private var startRequestID: UUID?
    private let snapshotProviders: SnapshotProviderBox
    private let sideEffects: PowerControllerSideEffects
    private let safeRollbackWaiter: @Sendable () -> PowerSnapshot
    private let restoreVerificationWaiter: @Sendable () -> PowerSnapshot
    private let announcementHandler: (String) -> Void
    private var refreshInFlight = false
    private var activeRefreshForceFresh = false
    private var refreshGeneration = 0
    private var refreshAttempt = 0
    private var activeRefreshAttempt = 0
    private var sessionEpoch = 0
    private var pendingRefresh: PendingRefreshIntent?
    private var activeRefreshPurpose: RefreshPurpose?
    // One retry budget covers every rejected inventory publication for a
    // controller generation. Otherwise repeated external invalidation could
    // turn `.superseded` into an unbounded loop just as filesystem drift could.
    private var inventoryRetryGeneration: Int?

    init(
        bootstrap: Bool = true,
        snapshotProvider: (@Sendable (UUID?) -> PowerSnapshot)? = nil,
        forceFreshSnapshotProvider: (@Sendable (UUID?) -> PowerSnapshot)? = nil,
        inventoryResultProvider: (@Sendable (
            UUID?,
            Bool
        ) -> PowerControllerInventoryFixtureResult)? = nil,
        inventoryInvalidator: (@Sendable () -> Void)? = nil,
        sideEffects: PowerControllerSideEffects,
        safeRollbackWaiter: @escaping @Sendable () -> PowerSnapshot = {
            PowerController.waitForSnapshot(
                timeout: PowerController.helperRollbackVerificationTimeout,
                ownedSessionID: nil,
                condition: PowerController.isVerifiedSafeIdle
            )
        },
        restoreVerificationWaiter: @escaping @Sendable () -> PowerSnapshot = {
            PowerController.waitForSnapshot(
                timeout: PowerController.restoreTimeout,
                ownedSessionID: nil,
                condition: PowerController.isVerifiedSafeIdle
            )
        },
        announcementHandler: @escaping (String) -> Void = { message in
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }
    ) {
        if let inventoryResultProvider {
            snapshotProviders = SnapshotProviderBox(
                resultProvider: inventoryResultProvider,
                invalidateInventory: inventoryInvalidator ?? {}
            )
        } else if let snapshotProvider {
            snapshotProviders = SnapshotProviderBox(
                cached: snapshotProvider,
                forceFresh: forceFreshSnapshotProvider ?? snapshotProvider,
                invalidateInventory: inventoryInvalidator ?? {}
            )
        } else {
            snapshotProviders = SnapshotProviderBox()
        }
        self.sideEffects = sideEffects
        self.safeRollbackWaiter = safeRollbackWaiter
        self.restoreVerificationWaiter = restoreVerificationWaiter
        self.announcementHandler = announcementHandler
        // The helper restores on restart and never resumes a prior session.
        // Merely launching the GUI must not send a privileged restore request.
        guard bootstrap else { return }
        refresh()
        installPowerSourceObserver()
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: Self.refreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    var menuBarSymbol: String {
        displayedStatus.menuBarSymbol
    }

    var requiresTerminationCleanup: Bool {
        isBusy
            || operationPhase != .idle
            || startRequestID != nil
            || activeRefreshPurpose != nil
            || pendingRefresh?.purpose != nil
            || pendingTerminationReply != nil
            || activeSessionID != nil
            || heartbeat != nil
            || cleanupOwnership?.requiresSafetyResolution == true
            || activityToken != nil
            || snapshot.activationLease != nil
            || snapshot.sleepDisabled
            || snapshot.helperRecoveryRequired
    }

    func refresh(forceFresh: Bool = false) {
        refresh(forceFresh: forceFresh, purpose: nil)
    }

    private func refresh(forceFresh: Bool, purpose: RefreshPurpose?) {
        // A newer native notification must invalidate a running force-fresh
        // result (power truth may already have changed), but its Start purpose
        // is carried into one coalesced force-fresh rerun rather than dropped.
        if refreshInFlight, activeRefreshForceFresh, purpose == nil {
            refreshGeneration &+= 1
            let carriedPurpose = activeRefreshPurpose
            if var pendingRefresh {
                pendingRefresh.forceFresh = true
                if pendingRefresh.purpose == nil {
                    pendingRefresh.purpose = carriedPurpose
                }
                self.pendingRefresh = pendingRefresh
            } else {
                pendingRefresh = PendingRefreshIntent(forceFresh: true, purpose: carriedPurpose)
            }
            return
        }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isChecking = true
        guard !refreshInFlight else {
            if var pendingRefresh {
                pendingRefresh.forceFresh = pendingRefresh.forceFresh || forceFresh
                if let purpose {
                    assert(pendingRefresh.purpose == nil, "only one pending refresh purpose is supported")
                    if pendingRefresh.purpose == nil { pendingRefresh.purpose = purpose }
                }
                self.pendingRefresh = pendingRefresh
            } else {
                pendingRefresh = PendingRefreshIntent(forceFresh: forceFresh, purpose: purpose)
            }
            return
        }
        launchRefresh(generation: generation, forceFresh: forceFresh, purpose: purpose)
    }

    func refreshManually() {
        refresh(forceFresh: true)
    }

    private func launchRefresh(
        generation: Int,
        forceFresh: Bool,
        purpose: RefreshPurpose?
    ) {
        refreshAttempt &+= 1
        let attempt = refreshAttempt
        activeRefreshAttempt = attempt
        refreshInFlight = true
        activeRefreshForceFresh = forceFresh
        activeRefreshPurpose = purpose
        let epoch = sessionEpoch
        let ownedSessionID = activeSessionID
        snapshotProviders.load(
            ownedSessionID: ownedSessionID,
            forceFresh: forceFresh,
            fastCompletion: { next in
                Task { @MainActor in
                    self.publishFastRefresh(
                        next,
                        generation: generation,
                        attempt: attempt,
                        epoch: epoch
                    )
                }
            },
            inventoryCompletion: { next, rejection in
                Task { @MainActor in
                    self.completeRefresh(
                        next,
                        generation: generation,
                        attempt: attempt,
                        epoch: epoch,
                        inventoryRejection: rejection
                    )
                }
            }
        )
    }

    private func publishFastRefresh(
        _ next: PowerSnapshot,
        generation: Int,
        attempt: Int,
        epoch: Int
    ) {
        guard refreshInFlight,
              attempt == activeRefreshAttempt,
              epoch == sessionEpoch,
              generation == refreshGeneration
        else { return }
        snapshot = next
        reconcileRollbackVerificationFailure(after: next)
    }

    private func completeRefresh(
        _ next: PowerSnapshot,
        generation: Int,
        attempt: Int,
        epoch: Int,
        inventoryRejection: PowerInspector.InstallationInventoryRejection?
    ) {
        // Fast and inventory callbacks cross independent tasks. Accept exactly
        // one terminal callback for the active launch so a delayed fast result
        // or duplicate completion cannot overwrite a newer retry/publication.
        guard refreshInFlight, attempt == activeRefreshAttempt else { return }
        refreshInFlight = false
        activeRefreshForceFresh = false
        guard epoch == sessionEpoch else {
            carryActivePurposeIntoPendingRefresh()
            launchPendingRefreshOrFinish()
            return
        }
        guard generation == refreshGeneration else {
            carryActivePurposeIntoPendingRefresh()
            launchPendingRefreshOrFinish()
            return
        }

        var terminalSnapshot = next
        switch inventoryRejection {
        case .some(_) where inventoryRetryGeneration != generation:
            // One same-generation force retry converts a transient rejection
            // into a fresh answer without allowing a Start/admin purpose to
            // observe or authorize against the rejected candidate.
            inventoryRetryGeneration = generation
            scheduleForcedInventoryRetry()
            return
        case .some(_):
            // Repeated drift or supersession is terminal for this controller
            // generation. Publish a typed fail-closed result so the active
            // purpose resolves instead of hanging or retrying without a bound.
            terminalSnapshot = next.withIndeterminateInstallationInventory(
                reason: "Installation verification could not stabilize across both bounded attempts."
            )
        case nil:
            if inventoryRetryGeneration == generation {
                inventoryRetryGeneration = nil
            }
        }

        let previousStatus = snapshot.statusTitle
        snapshot = terminalSnapshot
        isChecking = false
        reconcileRollbackVerificationFailure(after: terminalSnapshot)
        let purpose = activeRefreshPurpose
        activeRefreshPurpose = nil
        switch purpose {
        case let .some(.start(requestID)):
            continueStart(requestID: requestID, freshSnapshot: terminalSnapshot)
        case let .some(.prepareConvergence(operationEpoch)):
            completePrepareConvergence(terminalSnapshot, operationEpoch: operationEpoch)
        case let .some(.uninstallConvergence(operationEpoch)):
            completeUninstallConvergence(terminalSnapshot, operationEpoch: operationEpoch)
        case .none:
            break
        }

        // The serial heartbeat remains the sole termination authority for an
        // owned generation; UI inspection only publishes current context.
        if activeSessionID == nil,
           terminalSnapshot.hasCriticalSafetyIssue,
           terminalSnapshot.statusTitle != previousStatus
        {
            announce(terminalSnapshot.accessibilityState)
        }
    }

    private func scheduleForcedInventoryRetry() {
        carryActivePurposeIntoPendingRefresh()
        if var pendingRefresh {
            pendingRefresh.forceFresh = true
            self.pendingRefresh = pendingRefresh
        } else {
            pendingRefresh = PendingRefreshIntent(forceFresh: true, purpose: nil)
        }
        launchPendingRefreshOrFinish()
    }

    private func carryActivePurposeIntoPendingRefresh() {
        guard let purpose = activeRefreshPurpose else { return }
        let remainsCurrent: Bool
        switch purpose {
        case let .start(requestID):
            remainsCurrent = startRequestID == requestID
        case let .prepareConvergence(operationEpoch):
            remainsCurrent = sessionEpoch == operationEpoch && activeSessionID == nil
        case let .uninstallConvergence(operationEpoch):
            remainsCurrent = sessionEpoch == operationEpoch && activeSessionID == nil
        }
        guard remainsCurrent else {
            activeRefreshPurpose = nil
            return
        }
        activeRefreshPurpose = nil
        if var pendingRefresh {
            if pendingRefresh.purpose == nil { pendingRefresh.purpose = purpose }
            pendingRefresh.forceFresh = true
            self.pendingRefresh = pendingRefresh
        } else {
            pendingRefresh = PendingRefreshIntent(forceFresh: true, purpose: purpose)
        }
    }

    private func launchPendingRefreshOrFinish() {
        guard let pendingRefresh else {
            isChecking = false
            return
        }
        self.pendingRefresh = nil
        launchRefresh(
            generation: refreshGeneration,
            forceFresh: pendingRefresh.forceFresh,
            purpose: pendingRefresh.purpose
        )
    }

    #if DEBUG
    var refreshCompletionOutstandingForTesting: Bool {
        activeRefreshPurpose != nil || pendingRefresh?.purpose != nil
    }

    func requestStartRefreshForTesting(_ requestID: UUID) {
        startRequestID = requestID
        operationPhase = .starting
        refresh(forceFresh: true, purpose: .start(requestID: requestID))
    }
    #endif

    func prepareHelper() {
        guard !isBusy, !isChecking else { return }
        guard snapshot.canPrepareHelper, snapshot.sleepDisabledVerified else {
            alert = .operationFailure(message: snapshot.statusDetail)
            announce(snapshot.statusDetail)
            return
        }

        let operationEpoch = beginAdministratorConvergence(
            reason: "install-migration",
            phase: .preparingHelper
        )
        let failureVerificationWaiter = restoreVerificationWaiter

        Task.detached {
            do {
                let result = try self.sideEffects.prepareHelper()
                try Self.requireAdministratorSafeIdle(
                    result,
                    fallback: "The helper transaction did not prove a safe idle state."
                )
                await MainActor.run {
                    guard self.sessionEpoch == operationEpoch, self.activeSessionID == nil else { return }
                    self.refresh(
                        forceFresh: true,
                        purpose: .prepareConvergence(operationEpoch: operationEpoch)
                    )
                }
            } catch {
                let next = failureVerificationWaiter()
                await self.finishAdministratorFailure(
                    error,
                    fallback: "The helper could not be prepared. Protection remains off.",
                    next: next,
                    operationEpoch: operationEpoch,
                    expectedPhase: .preparingHelper
                )
            }
        }
    }

    private func completePrepareConvergence(_ next: PowerSnapshot, operationEpoch: Int) {
        guard sessionEpoch == operationEpoch,
              activeSessionID == nil,
              operationPhase == .preparingHelper
        else { return }
        guard Self.hasNoOwnedSession(next) else {
            alert = .operationFailure(message: "The helper transaction finished, but a fresh detached session state was not proved. LidSwitch is keeping recovery controls active.")
            announce(errorMessage ?? "A detached session state could not be verified.")
            operationPhase = .recoveryRequired
            isBusy = false
            return
        }
        if Self.isVerifiedSafeIdle(next) {
            releaseCleanupOwnership(cleanupOwnership, afterSafeSnapshot: next)
        }
        let prepared = next.helperReady
            && !next.legacyResiduePresent
            && next.sleepDisabledVerified
            && !next.sleepDisabled
            && !next.helperRecoveryRequired
        if prepared {
            alert = nil
            announce("The crash-safe helper is ready. Protection remains off.")
        } else {
            alert = .operationFailure(message: "The helper was installed, but its exact safe ready state could not be verified. Protection remains off.")
            announce(errorMessage ?? "The helper safe state could not be verified.")
        }
        operationPhase = .idle
        isBusy = false
    }

    func startSession() {
        guard !terminationInvalidated,
              !isBusy,
              !isChecking,
              cleanupOwnership == nil
        else { return }
        let requestID = UUID()
        startRequestID = requestID
        isBusy = true
        operationPhase = .starting
        alert = nil
        announce("Starting LidSwitch session. Waiting for helper confirmation.")

        // Start authorization never uses a cached inspection. It waits for a
        // generation-matched force-fresh result without blocking MainActor.
        refresh(forceFresh: true, purpose: .start(requestID: requestID))
    }

    private func continueStart(requestID: UUID, freshSnapshot: PowerSnapshot) {
        guard !terminationInvalidated,
              startRequestID == requestID,
              isStarting
        else { return }
        guard freshSnapshot.canStartSession else {
            guard Self.hasNoOwnedSession(freshSnapshot) else {
                alert = .operationFailure(message: "Session did not start because the fresh preflight retained an unexpected session identity. Cancel and Restore remains available.")
                announce(errorMessage ?? "Cancel and Restore is required.")
                return
            }
            operationPhase = .idle
            isBusy = false
            startRequestID = nil
            alert = .operationFailure(message: "Session did not start. \(freshSnapshot.statusDetail) Protection remains off.")
            announce(errorMessage ?? "Session did not start. Protection remains off.")
            return
        }

        // Full rollback is a value-preserving contract. Do not cross BEGIN if
        // the force-fresh preflight could not capture the user's AC idle
        // setting; treating unknown as a value could later report a changed
        // setting as restored.
        guard let originalACIdleSleepMinutes = freshSnapshot.acIdleSleepMinutes else {
            operationPhase = .idle
            isBusy = false
            startRequestID = nil
            alert = .operationFailure(message: "Session did not start because LidSwitch could not capture the current AC idle sleep setting. Protection remains off.")
            announce(errorMessage ?? "The AC idle sleep setting could not be verified.")
            return
        }

        let sessionID = UUID()
        sessionEpoch &+= 1
        let generation = sessionEpoch
        activeSessionID = sessionID
        sessionWasAcknowledged = false

        do {
            try sideEffects.writeDesiredStateDisabled()
        } catch {
            let detail = errorMessage(for: error, fallback: "Nothing was enabled.")
            beginFailedStartResolution(
                sessionID: sessionID,
                cleanupOwner: nil,
                detail: detail
            )
            return
        }

        // Install the exact generation owner immediately before crossing the
        // only authority-creating boundary. A thrown/indeterminate exchange is
        // not safe-idle proof; it leaves this owner eligible for one terminal
        // claim and then enters detached verification below.
        let cleanupOwner = RemoteAuthorityCleanupOwnership(
            sessionID: sessionID,
            generation: generation,
            originalACIdleSleepMinutes: originalACIdleSleepMinutes
        )
        cleanupOwnership = cleanupOwner

        let resolution: PowerControllerLeaseIssueResolution
        do {
            resolution = try sideEffects.issueLease(sessionID)
        } catch {
            beginFailedStartResolution(
                sessionID: sessionID,
                cleanupOwner: cleanupOwner,
                detail: errorMessage(for: error, fallback: "The helper did not resolve the Start request.")
            )
            return
        }

        switch resolution {
        case let .issued(lease), let .reconnected(lease):
            cleanupOwner.markAuthorityIssued()
            beginActivity()
            scheduleHeartbeat(
                for: sessionID,
                initialLeaseExpiresMonotonic: lease.expiresMonotonic,
                cleanupOwner: cleanupOwner
            )
        case let .idle(reply):
            cleanupOwner.markProtocolTerminal()
            resolveNoAuthorityBegin(
                sessionID: sessionID,
                cleanupOwner: cleanupOwner,
                reply: reply,
                detail: "The helper proved the requested generation remained idle (\(reply.reason))."
            )
        case let .terminal(reply):
            cleanupOwner.markProtocolTerminal()
            resolveNoAuthorityBegin(
                sessionID: sessionID,
                cleanupOwner: cleanupOwner,
                reply: reply,
                detail: "The helper proved the requested generation terminal (\(reply.reason))."
            )
        case let .authorityMayRemain(reason):
            beginFailedStartResolution(
                sessionID: sessionID,
                cleanupOwner: cleanupOwner,
                detail: "The helper could not prove that the requested generation was idle (\(reason))."
            )
        }

        // Acknowledgement is intentionally owned by the serial heartbeat.
        // Full UI inspection can be arbitrarily slow without starving start.
    }

    /// BEGIN/RECONNECT may authenticate that this exact generation never
    /// became active. That closes only this owner's authority question: it
    /// does not fabricate a power rollback, issue END/RESTORE, or turn an
    /// unrelated/nil snapshot into a success signal.
    private func resolveNoAuthorityBegin(
        sessionID: UUID,
        cleanupOwner: RemoteAuthorityCleanupOwnership,
        reply: HelperControlReply,
        detail: String
    ) {
        guard activeSessionID == sessionID,
              cleanupOwnership === cleanupOwner,
              reply.sessionID == sessionID,
              reply.state == .idle || reply.state == .terminal
        else { return }
        startRequestID = nil
        sessionEpoch &+= 1
        endLocalSession(
            revokeLease: false,
            reason: "begin-protocol-terminal",
            operationPhaseAfterEnd: .idle
        )
        cleanupOwner.markProtocolTerminalResolved()
        cleanupOwnership = nil
        isBusy = false
        operationPhase = .idle
        alert = .operationFailure(message: "Session did not start. \(detail) The helper authenticated that this generation never became active; no power rollback was claimed.")
        announce(errorMessage ?? "Session did not start. No power rollback was claimed.")
    }

    private func beginFailedStartResolution(
        sessionID: UUID,
        cleanupOwner: RemoteAuthorityCleanupOwnership?,
        detail: String
    ) {
        guard activeSessionID == sessionID else { return }
        if let cleanupOwner {
            guard cleanupOwnership === cleanupOwner else { return }
        } else {
            guard cleanupOwnership == nil else { return }
        }

        // Invalidate late preflight/heartbeat/activity publication first, then
        // claim at most one bounded raw terminal effect. Neither a failed send
        // nor a protocol-terminal reply is presented as safe idle: only the
        // detached fresh waiter below can publish Protection off.
        startRequestID = nil
        sessionEpoch &+= 1
        operationPhase = .cancelRestoring
        isBusy = true
        alert = nil
        endLocalSession(
            revokeLease: cleanupOwner?.requiresSafetyResolution == true,
            reason: "start-failed",
            operationPhaseAfterEnd: .cancelRestoring
        )
        let operationEpoch = sessionEpoch
        let expectedOwner = cleanupOwner
        let terminationReplyID = pendingTerminationReply?.id
        snapshotProviders.invalidateInventory()
        let safeRollbackWaiter = safeRollbackWaiter

        Task.detached {
            let next = safeRollbackWaiter()
            await MainActor.run {
                guard self.sessionEpoch == operationEpoch,
                      self.operationPhase == .cancelRestoring,
                      self.activeSessionID == nil
                else { return }
                self.snapshot = next
                let restored = self.provesCompleteRollback(next, for: expectedOwner)
                guard restored else {
                    self.alert = .operationFailure(message: "Session did not start, and LidSwitch could not prove safe idle at the end of its bounded check. \(detail) Use Restore Sleep or Refresh before trying again.")
                    self.announce(self.errorMessage ?? "Session failed. Restore required before continuing.")
                    self.operationPhase = .recoveryRequired
                    self.isBusy = false
                    self.resolveTerminationReply(false, expectedID: terminationReplyID)
                    return
                }
                self.releaseCleanupOwnership(expectedOwner, afterSafeSnapshot: next)
                self.alert = .operationFailure(message: "Session did not start. \(detail) Protection remains off.")
                self.announce(self.errorMessage ?? "Session did not start. Protection remains off.")
                self.operationPhase = .idle
                self.isBusy = false
                self.resolveTerminationReply(true, expectedID: terminationReplyID)
            }
        }
    }

#if DEBUG
    func invalidateStartRequestForTesting() {
        startRequestID = nil
        operationPhase = .idle
        isBusy = false
        sessionEpoch &+= 1
    }
#endif

    func cancelPendingStart() {
        cancelPendingStart(terminationReplyID: nil)
    }

    private func cancelPendingStart(terminationReplyID: UUID?) {
        guard isStarting else { return }
        // Invalidating before revocation makes every stale preflight or helper
        // acknowledgement inert. The generation-bound claim remains the only
        // owner shared by direct and heartbeat terminal mechanics.
        startRequestID = nil
        sessionEpoch &+= 1
        let cancelRequiresRevocation = activeSessionID != nil
            || heartbeat != nil
            || cleanupOwnership?.requiresSafetyResolution == true
        let expectedOwner = cleanupOwnership
        operationPhase = .cancelRestoring
        isBusy = true
        alert = nil
        endLocalSession(
            revokeLease: cancelRequiresRevocation,
            reason: "pending-start-cancelled",
            operationPhaseAfterEnd: .cancelRestoring
        )
        let operationEpoch = sessionEpoch
        let safeRollbackWaiter = safeRollbackWaiter
        Task.detached {
            let next = safeRollbackWaiter()
            await MainActor.run {
                guard self.sessionEpoch == operationEpoch,
                      self.operationPhase == .cancelRestoring,
                      self.activeSessionID == nil
                else { return }
                self.snapshot = next
                guard Self.hasNoOwnedSession(next) else {
                    self.alert = .rollbackVerificationFailure(reason: "pending-start-cancelled")
                    self.announce(self.errorMessage ?? "Restore required before continuing.")
                    self.operationPhase = .recoveryRequired
                    self.isBusy = false
                    self.resolveTerminationReply(false, expectedID: terminationReplyID)
                    return
                }
                let restored = self.provesCompleteRollback(next, for: expectedOwner)
                if restored {
                    self.releaseCleanupOwnership(expectedOwner, afterSafeSnapshot: next)
                    self.alert = nil
                    self.announce("Session canceled. Protection off. System sleep restored.")
                } else {
                    self.alert = .rollbackVerificationFailure(reason: "pending-start-cancelled")
                    self.announce(self.errorMessage ?? "Restore required before continuing.")
                }
                self.operationPhase = .idle
                self.isBusy = false
                self.resolveTerminationReply(restored, expectedID: terminationReplyID)
                if terminationReplyID == nil, next.installationInventoryPending {
                    self.refresh()
                }
            }
        }
    }

    func stopSession() {
        stopSession(
            quitWhenRestored: false,
            terminationReplyID: pendingTerminationReply?.id
        )
    }

    func restoreNow() {
        guard !isBusy || isCancelRestoring else { return }
        let terminationReplyID = pendingTerminationReply?.id
        let expectedOwner = cleanupOwnership
        operationPhase = .endingRestoring
        isBusy = true
        alert = nil
        endLocalSession(
            revokeLease: true,
            reason: "explicit-restore",
            operationPhaseAfterEnd: .endingRestoring
        )
        let operationEpoch = sessionEpoch
        snapshotProviders.invalidateInventory()
        let restoreVerificationWaiter = restoreVerificationWaiter

        Task.detached {
            var administratorFailureMessage: String?
            do {
                let result = try self.sideEffects.restoreSleep()
                try Self.requireAdministratorSafeIdle(
                    result,
                    fallback: "The administrator restore did not prove a safe idle state."
                )
            } catch {
                let detail = (error as NSError).localizedDescription
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                administratorFailureMessage = detail.isEmpty
                    ? "The administrator recovery did not complete."
                    : detail
            }

            let next = restoreVerificationWaiter()
            await MainActor.run {
                guard self.sessionEpoch == operationEpoch, self.activeSessionID == nil else { return }
                self.snapshot = next
                guard Self.hasNoOwnedSession(next) else {
                    self.alert = .operationFailure(message: "LidSwitch could not prove that the prior session identity was detached. Recovery controls remain active.")
                    self.announce(self.errorMessage ?? "A detached session state could not be verified.")
                    self.operationPhase = .recoveryRequired
                    self.isBusy = false
                    self.resolveTerminationReply(false, expectedID: terminationReplyID)
                    return
                }
                let restored = self.provesCompleteRollback(next, for: expectedOwner)
                if restored {
                    self.releaseCleanupOwnership(expectedOwner, afterSafeSnapshot: next)
                    self.alert = nil
                    self.announce("System sleep has been restored.")
                } else {
                    let detail = administratorFailureMessage
                        ?? "macOS still reports an active sleep override."
                    self.alert = .operationFailure(message: "LidSwitch could not verify that the macOS sleep override is off. \(detail) Keep LidSwitch open and try Restore Sleep again.")
                    self.announce(self.errorMessage ?? "System sleep restoration could not be verified.")
                }
                self.operationPhase = .idle
                self.isBusy = false
                self.resolveTerminationReply(restored, expectedID: terminationReplyID)
                if terminationReplyID == nil { self.refresh(forceFresh: true) }
            }
        }
    }

    func uninstallHelper() {
        guard !isBusy, !isChecking else { return }
        let operationEpoch = beginAdministratorConvergence(
            reason: "uninstall-helper",
            phase: .removingHelper
        )
        let failureVerificationWaiter = restoreVerificationWaiter

        Task.detached {
            do {
                let result = try self.sideEffects.uninstallHelper()
                try Self.requireAdministratorSafeIdle(
                    result,
                    fallback: "The uninstall transaction did not prove a safe idle state."
                )
                await MainActor.run {
                    guard self.sessionEpoch == operationEpoch, self.activeSessionID == nil else { return }
                    self.refresh(
                        forceFresh: true,
                        purpose: .uninstallConvergence(operationEpoch: operationEpoch)
                    )
                }
            } catch {
                let next = failureVerificationWaiter()
                await self.finishAdministratorFailure(
                    error,
                    fallback: "The helper could not be removed safely.",
                    next: next,
                    operationEpoch: operationEpoch,
                    expectedPhase: .removingHelper
                )
            }
        }
    }

    private func completeUninstallConvergence(_ next: PowerSnapshot, operationEpoch: Int) {
        guard sessionEpoch == operationEpoch,
              activeSessionID == nil,
              operationPhase == .removingHelper
        else { return }
        guard Self.hasNoOwnedSession(next) else {
            alert = .operationFailure(message: "Removal finished, but a fresh detached session state was not proved. LidSwitch is keeping recovery controls active.")
            announce(errorMessage ?? "A detached session state could not be verified.")
            operationPhase = .recoveryRequired
            isBusy = false
            return
        }
        if Self.isVerifiedSafeIdle(next) {
            releaseCleanupOwnership(cleanupOwnership, afterSafeSnapshot: next)
        }
        let removed = next.sleepDisabledVerified
            && !next.sleepDisabled
            && !next.helperArtifactsPresent
            && next.helperLaunchdState == .absent
            && !next.helperRecoveryRequired
            && !next.installationInventoryPending
            && !next.installationInventoryIndeterminate
        if removed {
            alert = nil
            announce("The helper was removed and system sleep was restored.")
        } else {
            alert = .operationFailure(message: "Removal completed, but the exact safe uninstalled state could not be verified.")
            announce(errorMessage ?? "Helper removal could not be verified.")
        }
        operationPhase = .idle
        isBusy = false
    }

    func quitSafely() {
        guard !isBusy else { return }
        // The panel has already collected an explicit Restore-and-Quit
        // confirmation.  Match the application-delegate path: when this
        // process owns no cleanup work, do not launch a redundant
        // administrator transaction merely to quit an already-idle app.
        // Mark the next AppKit termination callback as authorized so it does
        // not present a second confirmation dialog.
        guard requiresTerminationCleanup else {
            nextTerminationIsAuthorized = true
            sideEffects.terminateApplication()
            return
        }
        stopSession(quitWhenRestored: true, terminationReplyID: nil)
    }

    func prepareForSystemTermination(completion: @escaping (Bool) -> Void) {
        // Restore & Quit is an authoritative cancellation request, not an
        // ordinary busy-state query. Invalidate a pending Start generation
        // immediately so a held preflight cannot issue desired state, a lease,
        // BEGIN, a heartbeat, or an activity after AppKit has asked to quit.
        if isStarting {
            guard let replyID = registerTerminationReply(completion) else { return }
            cancelPendingStart(terminationReplyID: replyID)
            return
        }
        guard !isBusy else {
            alert = .operationFailure(message: "LidSwitch is still finishing a safety operation. Wait for it to complete, then use Restore and Quit again.")
            announce(errorMessage ?? "A LidSwitch safety operation is still in progress.")
            completion(false)
            return
        }
        guard let replyID = registerTerminationReply(completion) else { return }
        stopSession(quitWhenRestored: false, terminationReplyID: replyID)
    }

    private func registerTerminationReply(
        _ completion: @escaping (Bool) -> Void
    ) -> UUID? {
        guard pendingTerminationReply == nil else {
            completion(false)
            return nil
        }
        let id = UUID()
        pendingTerminationReply = PendingTerminationReply(id: id, completion: completion)
        return id
    }

    private func resolveTerminationReply(_ restored: Bool, expectedID: UUID?) {
        guard let expectedID,
              let pendingTerminationReply,
              pendingTerminationReply.id == expectedID
        else { return }
        // Release ownership before calling AppKit. A synchronous lifecycle
        // callback or stale waiter can never consume the same reply twice.
        self.pendingTerminationReply = nil
        pendingTerminationReply.completion(restored)
    }

    func consumeAuthorizedTermination() -> Bool {
        defer { nextTerminationIsAuthorized = false }
        return nextTerminationIsAuthorized
    }

    func revokeForImmediateTermination() {
        // Will-terminate is an unconditional generation boundary. Invalidate a
        // held Start preflight before inspecting whether BEGIN or a heartbeat
        // exists, so its late completion can never acquire root authority.
        let pendingReplyID = pendingTerminationReply?.id
        resolveTerminationReply(false, expectedID: pendingReplyID)
        terminationInvalidated = true
        sessionEpoch &+= 1
        startRequestID = nil
        activeRefreshPurpose = nil
        pendingRefresh = nil
        operationPhase = .idle
        isBusy = false
        // A successful Restore-and-Quit has already consumed the generation's
        // claim. AppKit re-entry can observe the owner, but cannot append a
        // second raw terminal effect.
        if cleanupOwnership?.requiresSafetyResolution == true
            || activeSessionID != nil
            || heartbeat != nil
        {
            endLocalSession(revokeLease: true, reason: "peer-termination")
        }
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceRunLoopSource = nil
        }
    }

    private func stopSession(
        quitWhenRestored: Bool,
        terminationReplyID: UUID?
    ) {
        guard !isBusy || isCancelRestoring else {
            resolveTerminationReply(false, expectedID: terminationReplyID)
            return
        }

        operationPhase = .endingRestoring
        isBusy = true
        alert = nil
        let expectedOwner = cleanupOwnership
        endLocalSession(
            revokeLease: true,
            reason: "user-end",
            operationPhaseAfterEnd: .endingRestoring
        )
        let operationEpoch = sessionEpoch
        // If the normal authenticated END cannot prove idle, the fallback
        // administrator mutation must never race a cached installation view.
        snapshotProviders.invalidateInventory()

        let safeRollbackWaiter = safeRollbackWaiter
        Task.detached {
            var next = safeRollbackWaiter()
            var administratorFailureMessage: String?
            if !(expectedOwner?.provesFullRollback(next) == true
                    || expectedOwner?.hasAuthenticatedTerminalProof == true
                    || (expectedOwner == nil && Self.isVerifiedSafeIdle(next))) {
                do {
                    let result = try self.sideEffects.restoreSleep()
                    try Self.requireAdministratorSafeIdle(
                        result,
                        fallback: "Restore-and-Quit did not prove a safe idle state."
                    )
                    self.snapshotProviders.invalidateInventory()
                    next = safeRollbackWaiter()
                } catch {
                    let detail = (error as NSError).localizedDescription
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    administratorFailureMessage = detail.isEmpty
                        ? "The administrator recovery did not complete."
                        : detail
                }
            }
            await MainActor.run {
                guard self.sessionEpoch == operationEpoch, self.activeSessionID == nil else { return }
                let restored = self.provesCompleteRollback(next, for: expectedOwner)
                self.snapshot = next
                guard Self.hasNoOwnedSession(next) else {
                    self.alert = .operationFailure(message: "LidSwitch stopped renewing the session, but a fresh detached session state was not proved. Keep LidSwitch open and retry Restore Sleep.")
                    self.announce(self.errorMessage ?? "A detached session state could not be verified.")
                    self.operationPhase = .recoveryRequired
                    self.isBusy = false
                    self.resolveTerminationReply(false, expectedID: terminationReplyID)
                    return
                }
                if restored {
                    self.releaseCleanupOwnership(expectedOwner, afterSafeSnapshot: next)
                    self.announce("Protection off. System sleep has been restored.")
                    if quitWhenRestored {
                        self.nextTerminationIsAuthorized = true
                        self.sideEffects.terminateApplication()
                    } else if terminationReplyID == nil {
                        self.refresh(forceFresh: true)
                    }
                } else {
                    let detail = administratorFailureMessage
                        ?? "macOS still reports an active sleep override."
                    self.alert = .operationFailure(message: "LidSwitch stopped renewing the session, but safe idle was not proved. \(detail) Keep LidSwitch open and retry Restore Sleep.")
                    self.announce(self.errorMessage ?? "Restore required before quitting.")
                    if terminationReplyID == nil { self.refresh(forceFresh: true) }
                }
                self.operationPhase = .idle
                self.isBusy = false
                self.resolveTerminationReply(restored, expectedID: terminationReplyID)
            }
        }
    }

#if DEBUG
    nonisolated static var helperRollbackVerificationTimeoutForTesting: TimeInterval {
        helperRollbackVerificationTimeout
    }

    func simulateHeartbeatEndForTesting(sessionID: UUID, reason: String) {
        activeSessionID = sessionID
        heartbeatDidEnd(sessionID, epoch: sessionEpoch, reason: reason)
    }

    func simulateNewSessionForTesting(_ sessionID: UUID) {
        sessionEpoch &+= 1
        activeSessionID = sessionID
        isBusy = false
        operationPhase = .idle
    }

    var activeSessionIDForTesting: UUID? { activeSessionID }
    var sessionEpochForTesting: Int { sessionEpoch }
    var cleanupOwnerSessionIDForTesting: UUID? { cleanupOwnership?.sessionID }
    var cleanupOwnerGenerationForTesting: Int? { cleanupOwnership?.generation }

    nonisolated static func cleanupProofForTesting(
        sessionID: UUID,
        originalACIdleSleepMinutes: Int,
        snapshot: PowerSnapshot
    ) -> Bool {
        RemoteAuthorityCleanupOwnership(
            sessionID: sessionID,
            generation: 1,
            originalACIdleSleepMinutes: originalACIdleSleepMinutes
        ).provesFullRollback(snapshot)
    }

    nonisolated static func authenticatedCleanupReplyProofForTesting(
        sessionID: UUID,
        originalACIdleSleepMinutes: Int,
        resolution: HelperGenerationTerminationResolution?
    ) -> Bool {
        let owner = RemoteAuthorityCleanupOwnership(
            sessionID: sessionID,
            generation: 1,
            originalACIdleSleepMinutes: originalACIdleSleepMinutes
        )
        owner.recordAuthenticatedTerminalProof(resolution)
        return owner.hasAuthenticatedTerminalProof
    }

    nonisolated static func heartbeatAuthenticatedCleanupReplyProofForTesting(
        sessionID: UUID,
        originalACIdleSleepMinutes: Int,
        resolution: HelperGenerationTerminationResolution?
    ) -> Bool {
        let owner = RemoteAuthorityCleanupOwnership(
            sessionID: sessionID,
            generation: 1,
            originalACIdleSleepMinutes: originalACIdleSleepMinutes
        )
        guard HeartbeatTerminalProofHandoff.claim(owner) else { return false }
        HeartbeatTerminalProofHandoff.record(sessionID: sessionID, resolution: resolution)
        return owner.hasAuthenticatedTerminalProof
    }

    /// Lets a lifecycle fixture provide the same exact-session terminal
    /// receipt that production records after its raw heartbeat END/RESTORE
    /// exchange. The default fixture path remains nil and therefore cannot
    /// accidentally make an indeterminate cleanup green.
    nonisolated static func recordHeartbeatTerminalProofForTesting(
        sessionID: UUID,
        resolution: HelperGenerationTerminationResolution?
    ) {
        HeartbeatTerminalProofHandoff.record(sessionID: sessionID, resolution: resolution)
    }

    func simulateHeartbeatAcknowledgeForTesting(sessionID: UUID, epoch: Int) {
        heartbeatDidAcknowledge(sessionID, epoch: epoch)
    }

    func simulateHeartbeatEndForTesting(sessionID: UUID, epoch: Int, reason: String) {
        heartbeatDidEnd(sessionID, epoch: epoch, reason: reason)
    }
#endif

    private func scheduleHeartbeat(
        for sessionID: UUID,
        initialLeaseExpiresMonotonic: TimeInterval,
        cleanupOwner: RemoteAuthorityCleanupOwnership
    ) {
        guard cleanupOwnership === cleanupOwner,
              cleanupOwner.sessionID == sessionID
        else { return }
        heartbeat?.stop(reason: "superseded-session")
        let heartbeatEpoch = sessionEpoch
        let coordinator = sideEffects.makeHeartbeat(
            sessionID,
            { [weak self] acknowledgedID in
                Task { @MainActor in
                    self?.heartbeatDidAcknowledge(acknowledgedID, epoch: heartbeatEpoch)
                }
            },
            { [weak self] endedID, reason in
                Task { @MainActor in
                    self?.heartbeatDidEnd(endedID, epoch: heartbeatEpoch, reason: reason)
                }
            },
            {
                HeartbeatTerminalProofHandoff.claim(cleanupOwner)
            }
        )
        guard let coordinator else { return }
        heartbeat = coordinator
        coordinator.start(
            sessionID: sessionID,
            initialLeaseExpiresMonotonic: initialLeaseExpiresMonotonic,
            initiallyAcknowledged: true
        )
    }

    nonisolated private static func acceptsHeartbeatCallback(
        callbackSessionID: UUID,
        callbackEpoch: Int,
        activeSessionID: UUID?,
        currentEpoch: Int
    ) -> Bool {
        callbackSessionID == activeSessionID && callbackEpoch == currentEpoch
    }

    private func heartbeatDidAcknowledge(_ sessionID: UUID, epoch: Int) {
        guard Self.acceptsHeartbeatCallback(
            callbackSessionID: sessionID,
            callbackEpoch: epoch,
            activeSessionID: activeSessionID,
            currentEpoch: sessionEpoch
        ) else { return }
        sessionWasAcknowledged = true
        operationPhase = .idle
        isBusy = false
        startRequestID = nil
        announce("Protection active — plugged in.")
        refresh()
    }

    private func heartbeatDidEnd(_ sessionID: UUID, epoch: Int, reason: String) {
        guard Self.acceptsHeartbeatCallback(
            callbackSessionID: sessionID,
            callbackEpoch: epoch,
            activeSessionID: activeSessionID,
            currentEpoch: sessionEpoch
        ) else { return }
        // Invalidate every detached inspection and restoration waiter before
        // publishing the terminal state. A snapshot captured for the just-ended
        // generation must never make the UI look active again after rollback.
        let expectedOwner = cleanupOwnership
        sessionEpoch &+= 1
        let terminationEpoch = sessionEpoch
        heartbeat = nil
        activeSessionID = nil
        sessionWasAcknowledged = false
        operationPhase = .endingRestoring
        // Keep the UI in a bounded restoring state until the helper's rollback
        // becomes observable. An immediate snapshot can catch the helper's
        // durable restore-pending marker and otherwise leave a stale red alert
        // onscreen after rollback has already completed.
        isBusy = true
        startRequestID = nil
        endActivity()
        alert = nil
        announce(
            reason == "power-disconnected"
                ? "Power disconnected. The LidSwitch session ended and will not restart automatically."
                : "The LidSwitch session ended and will not restart automatically."
        )
        let safeRollbackWaiter = safeRollbackWaiter
        Task.detached {
            let next = safeRollbackWaiter()
            await MainActor.run {
                guard self.sessionEpoch == terminationEpoch, self.activeSessionID == nil else { return }
                self.snapshot = next
                guard Self.hasNoOwnedSession(next) else {
                    self.alert = .rollbackVerificationFailure(reason: reason)
                    self.announce(self.errorMessage ?? "Restore required before continuing.")
                    self.operationPhase = .recoveryRequired
                    self.isBusy = false
                    return
                }
                let restored = self.provesCompleteRollback(next, for: expectedOwner)
                if restored {
                    self.releaseCleanupOwnership(expectedOwner, afterSafeSnapshot: next)
                    self.alert = nil
                    self.announce("Protection off. System sleep has been restored.")
                    self.operationPhase = .idle
                } else {
                    self.alert = .rollbackVerificationFailure(reason: reason)
                    self.announce(self.errorMessage ?? "Restore required before continuing.")
                    // Keep the primary action aligned with the retained cleanup
                    // owner. Publishing Start here creates a silent no-op because
                    // startSession must reject while cleanup ownership remains.
                    self.operationPhase = .recoveryRequired
                }
                self.isBusy = false
                if next.installationInventoryPending { self.refresh() }
            }
        }
    }

    private func endLocalSession(
        revokeLease: Bool,
        reason: String = "local-session-ended",
        operationPhaseAfterEnd: PowerControllerOperationPhase = .idle,
        announcement: String? = nil
    ) {
        sessionEpoch &+= 1
        let cleanupOwner = cleanupOwnership
        let heartbeatOwnedCleanup = heartbeat != nil
        let directCleanupOwned = revokeLease
            && !heartbeatOwnedCleanup
            && cleanupOwner?.claimTerminalEffect() == true
        // The coordinator uses the same owner claim inside its serial terminal
        // latch. Direct and heartbeat paths therefore compete for one exact
        // generation token rather than separately deciding to END/RESTORE.
        heartbeat?.stop(reason: reason)
        heartbeat = nil
        activeSessionID = nil
        sessionWasAcknowledged = false
        operationPhase = operationPhaseAfterEnd
        startRequestID = nil
        if directCleanupOwned, let cleanupOwner {
            let intent: HelperGenerationTerminationIntent = reason == "user-end" ? .end : .restore
            cleanupOwner.recordAuthenticatedTerminalProof(
                sideEffects.terminateLease(cleanupOwner.sessionID, intent)
            )
        }
        endActivity()
        if let announcement {
            announce(announcement)
        }
    }

    private func releaseCleanupOwnership(
        _ expectedOwner: RemoteAuthorityCleanupOwnership?,
        afterSafeSnapshot snapshot: PowerSnapshot
    ) {
        guard let expectedOwner else {
            // A nil expected owner must never clear an owner installed by a
            // later generation.
            return
        }
        guard cleanupOwnership === expectedOwner else { return }
        guard expectedOwner.provesFullRollback(snapshot)
                || expectedOwner.hasAuthenticatedTerminalProof
        else { return }
        expectedOwner.markSafeIdleProven()
        cleanupOwnership = nil
    }

    private func provesCompleteRollback(
        _ snapshot: PowerSnapshot,
        for expectedOwner: RemoteAuthorityCleanupOwnership?
    ) -> Bool {
        if let expectedOwner {
            return expectedOwner.provesFullRollback(snapshot)
                || expectedOwner.hasAuthenticatedTerminalProof
        }
        return Self.isVerifiedSafeIdle(snapshot)
    }

    // All authoritative refresh callers (bootstrap, the 30-second timer,
    // power-source notifications, and manual Refresh) converge through this
    // one reconciliation point. It deliberately clears no generic operation
    // error and refuses to act while any newer local session exists.
    private func reconcileRollbackVerificationFailure(after snapshot: PowerSnapshot) {
        guard activeSessionID == nil,
              provesCompleteRollback(snapshot, for: cleanupOwnership)
        else { return }

        releaseCleanupOwnership(cleanupOwnership, afterSafeSnapshot: snapshot)

        if case .rollbackVerificationFailure = alert {
            alert = nil
            announce("System sleep restored. Protection off.")
        }
        if operationPhase == .recoveryRequired {
            operationPhase = .idle
        }
    }

    private func beginActivity() {
        endActivity()
        activityToken = sideEffects.beginActivity()
    }

    private func endActivity() {
        if let activityToken {
            sideEffects.endActivity(activityToken)
            self.activityToken = nil
        }
    }

    private func installPowerSourceObserver() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let unmanagedSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let controller = Unmanaged<PowerController>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                controller.refresh()
            }
        }, context) else { return }
        let source = unmanagedSource.takeRetainedValue()
        powerSourceRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private func beginAdministratorConvergence(
        reason: String,
        phase: PowerControllerOperationPhase
    ) -> Int {
        // The stale active snapshot deliberately remains visible underneath
        // the operation phase. Publish the non-success phase synchronously,
        // before any revocation or detached administrator work can begin.
        operationPhase = phase
        isBusy = true
        alert = nil
        endLocalSession(
            revokeLease: true,
            reason: reason,
            operationPhaseAfterEnd: phase
        )
        snapshotProviders.invalidateInventory()
        return sessionEpoch
    }

    private func finishAdministratorFailure(
        _ error: Error,
        fallback: String,
        next: PowerSnapshot,
        operationEpoch: Int,
        expectedPhase: PowerControllerOperationPhase
    ) {
        guard sessionEpoch == operationEpoch,
              activeSessionID == nil,
              operationPhase == expectedPhase
        else { return }

        // The injected/production waiter is bounded and reads with no owned
        // session identity. A contract violation becomes an actionable warning
        // state rather than stale green or permanent progress.
        snapshot = next
        alert = .operationFailure(message: errorMessage(for: error, fallback: fallback))
        announce(errorMessage ?? fallback)
        guard Self.hasNoOwnedSession(next) else {
            operationPhase = .recoveryRequired
            isBusy = false
            return
        }
        if Self.isVerifiedSafeIdle(next) {
            releaseCleanupOwnership(cleanupOwnership, afterSafeSnapshot: next)
        }
        operationPhase = .idle
        isBusy = false
        if next.installationInventoryPending { refresh(forceFresh: true) }
    }

    private func errorMessage(for error: Error, fallback: String) -> String {
        let description = (error as NSError).localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? fallback : description
    }

    nonisolated private static func requireAdministratorSafeIdle(
        _ result: AdministratorOperationResult,
        fallback: String
    ) throws {
        guard result.provesSafeIdle else {
            let message: String
            switch result {
            case let .recoveryRequired(receipt):
                message = "Recovery is required (\(receipt.reason)). No new session was enabled."
            case let .failed(receipt):
                message = "The administrator transaction failed (\(receipt.reason)). Verify LidSwitch status before retrying."
            case let .installedButStopped(receipt):
                message = "The helper is stopped (\(receipt.reason)). Safe idle was not proved to this caller; keep LidSwitch open and repair the installation before starting or quitting."
            case let .notStarted(_, reason):
                if reason == "administrator-operation-already-running" {
                    message = "Another LidSwitch administrator operation is already running. This request made no changes; wait for the active operation to finish, then refresh."
                } else if reason == "administrator-launch-failed"
                            || reason == "administrator-launch-rejected"
                            || reason == "administrator-command-exceeds-safe-argument-budget" {
                    message = "LidSwitch could not open the administrator authorization prompt, so the transaction did not start. Nothing was enabled."
                } else {
                    message = "Administrator authorization did not start the transaction. Nothing was enabled."
                }
            case .completionIndeterminate:
                message = "The administrator wait ended before a terminal receipt was available. The root transaction may still finish; refresh status before retrying."
            case .safeIdle:
                message = fallback
            }
            throw NSError(
                domain: "LidSwitch.AdministratorTransaction",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private func announce(_ message: String) {
        announcementHandler(message)
    }

    nonisolated private static func isVerifiedSafeIdle(_ candidate: PowerSnapshot) -> Bool {
        guard candidate.ownedSessionID == nil,
              candidate.source.isAC,
              candidate.sleepDisabledVerified,
              !candidate.sleepDisabled,
              candidate.acIdleSleepMinutes != nil,
              let status = candidate.helperStatus,
              status.isFresh(at: candidate.checkedAt),
              status.state == "inactive" || status.state == "terminal",
              !candidate.helperRecoveryRequired
        else { return false }
        return true
    }

    nonisolated private static func hasNoOwnedSession(_ candidate: PowerSnapshot) -> Bool {
        candidate.ownedSessionID == nil
    }

    nonisolated private static func waitForSnapshot(
        timeout: TimeInterval,
        ownedSessionID: UUID?,
        condition: (PowerSnapshot) -> Bool
    ) -> PowerSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        // Rollback/termination proof is intentionally dynamic-only. Static
        // codesign, helper comparison, and launchd inventory cannot improve
        // proof that the live sleep override is off, and must never delay it.
        var latest = PowerInspector.rollbackDynamicSnapshot(ownedSessionID: ownedSessionID)
        while !condition(latest), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            latest = PowerInspector.rollbackDynamicSnapshot(ownedSessionID: ownedSessionID)
        }
        return latest
    }
}
