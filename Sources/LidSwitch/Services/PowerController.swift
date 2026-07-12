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

@MainActor
final class PowerController: ObservableObject {
    @Published private(set) var snapshot: PowerSnapshot = .empty
    @Published private(set) var isBusy = false
    @Published private(set) var isStarting = false
    @Published private(set) var alert: PowerControllerAlert?

    var errorMessage: String? { alert?.message }

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
    private var sessionWasAcknowledged = false
    private var activityToken: NSObjectProtocol?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var nextTerminationIsAuthorized = false
    private var pendingStopCompletion: ((Bool) -> Void)?
    private var startRequestID: UUID?
    private let snapshotProvider: (UUID?) -> PowerSnapshot
    private let safeRollbackWaiter: @Sendable () -> PowerSnapshot
    private let announcementHandler: (String) -> Void

    init(
        bootstrap: Bool = true,
        snapshotProvider: @escaping (UUID?) -> PowerSnapshot = { PowerInspector.snapshot(ownedSessionID: $0) },
        safeRollbackWaiter: @escaping @Sendable () -> PowerSnapshot = {
            PowerController.waitForSnapshot(
                timeout: PowerController.helperRollbackVerificationTimeout,
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
        self.snapshotProvider = snapshotProvider
        self.safeRollbackWaiter = safeRollbackWaiter
        self.announcementHandler = announcementHandler
        // A session belongs to one app process. A fresh process never adopts a
        // predecessor's lease; revoking it makes the helper restore immediately.
        guard bootstrap else { return }
        try? ActivationLeaseStore.revoke()
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
        if snapshot.hasCriticalSafetyIssue {
            return "exclamationmark.triangle.fill"
        }
        if snapshot.sessionActive {
            return "checkmark.shield.fill"
        }
        if snapshot.sessionPending {
            return "clock.badge.checkmark"
        }
        if snapshot.helperReady {
            return snapshot.source.isAC ? "shield" : "powerplug"
        }
        return "shield.slash"
    }

    var requiresTerminationCleanup: Bool {
        activeSessionID != nil
            || snapshot.activationLease != nil
            || snapshot.sleepDisabled
            || snapshot.helperRecoveryRequired
    }

    func refresh() {
        let previousStatus = snapshot.statusTitle
        let next = snapshotProvider(activeSessionID)
        snapshot = next
        reconcileRollbackVerificationFailure(after: next)

        // The serial heartbeat is the sole authority for an owned active
        // generation. A full UI refresh must never revoke a healthy lease from
        // an independently unreadable inspection field; the heartbeat already
        // checks native AC state, lease validity, and fresh helper status every
        // second. This also prevents a power-source notification from creating
        // a second, competing termination path.
        if activeSessionID != nil {
            return
        }

        if next.hasCriticalSafetyIssue, next.statusTitle != previousStatus {
            announce(next.accessibilityState)
        }
    }

    func prepareHelper() {
        guard !isBusy else { return }
        guard snapshot.canPrepareHelper, snapshot.sleepDisabledVerified else {
            alert = .operationFailure(message: snapshot.statusDetail)
            announce(snapshot.statusDetail)
            return
        }

        endLocalSession(revokeLease: true)
        isBusy = true
        alert = nil

        Task.detached {
            do {
                try DesiredStateStore.write(.disabled)
                try LegacyAutostartManager.remove()
                try PrivilegedHelperManager.install()
                let next = Self.waitForSnapshot(timeout: 4, ownedSessionID: nil) { candidate in
                    candidate.helperReady
                        && !candidate.legacyResiduePresent
                        && candidate.sleepDisabledVerified
                        && !candidate.sleepDisabled
                        && !candidate.helperRecoveryRequired
                }
                await MainActor.run {
                    let prepared = next.helperReady
                        && !next.legacyResiduePresent
                        && next.sleepDisabledVerified
                        && !next.sleepDisabled
                        && !next.helperRecoveryRequired
                    self.snapshot = next
                    self.isBusy = false
                    if prepared {
                        self.announce("The crash-safe helper is ready. Protection remains off.")
                    } else {
                        self.alert = .operationFailure(message: "The helper was installed, but its safe ready state could not be verified. Protection remains off.")
                        self.announce(self.errorMessage ?? "The helper safe state could not be verified.")
                    }
                }
            } catch {
                await self.finishFailure(error, fallback: "The helper could not be prepared. Protection remains off.")
            }
        }
    }

    func startSession() {
        guard !isBusy else { return }
        let requestID = UUID()
        startRequestID = requestID
        isBusy = true
        isStarting = true
        alert = nil
        announce("Starting LidSwitch session. Waiting for helper confirmation.")

        Task { @MainActor [weak self] in
            await Task.yield()
            self?.continueStart(requestID: requestID)
        }
    }

    private func continueStart(requestID: UUID) {
        guard startRequestID == requestID, isStarting else { return }
        refresh()
        guard snapshot.canStartSession else {
            isStarting = false
            isBusy = false
            startRequestID = nil
            alert = .operationFailure(message: "Session did not start. \(snapshot.statusDetail) Protection remains off.")
            announce(errorMessage ?? "Session did not start. Protection remains off.")
            return
        }

        let sessionID = UUID()
        activeSessionID = sessionID
        sessionWasAcknowledged = false
        beginActivity()

        do {
            try DesiredStateStore.write(.disabled)
            let lease = try ActivationLeaseStore.issue(sessionID: sessionID)
            scheduleHeartbeat(for: sessionID, initialLeaseExpiresMonotonic: lease.expiresMonotonic)
        } catch {
            endLocalSession(revokeLease: true)
            isStarting = false
            isBusy = false
            startRequestID = nil
            let detail = errorMessage(for: error, fallback: "Nothing was enabled.")
            alert = .operationFailure(message: "Session did not start. \(detail) Protection remains off.")
            announce(errorMessage ?? "Session did not start. Protection remains off.")
            return
        }

        // Acknowledgement is intentionally owned by the serial heartbeat.
        // Full UI inspection can be arbitrarily slow without starving start.
    }

#if DEBUG
    func invalidateStartRequestForTesting() {
        startRequestID = nil
        isStarting = false
        isBusy = false
    }
#endif

    func stopSession() {
        stopSession(quitWhenRestored: false, completion: nil)
    }

    func restoreNow() {
        guard !isBusy else { return }
        endLocalSession(revokeLease: true)
        isBusy = true
        alert = nil

        Task.detached {
            do {
                try PrivilegedHelperManager.restoreSleepNow()
                let next = Self.waitForSnapshot(
                    timeout: Self.restoreTimeout,
                    ownedSessionID: nil,
                    condition: Self.isVerifiedSafeIdle
                )
                await MainActor.run {
                    let restored = Self.isVerifiedSafeIdle(next)
                    self.snapshot = next
                    self.isBusy = false
                    if restored {
                        self.announce("System sleep has been restored.")
                    } else {
                        self.alert = .operationFailure(message: "LidSwitch could not verify that the macOS sleep override is off. Keep LidSwitch open and try Restore Sleep again.")
                        self.announce(self.errorMessage ?? "System sleep restoration could not be verified.")
                    }
                }
            } catch {
                await self.finishFailure(error, fallback: "System sleep could not be restored.")
            }
        }
    }

    func uninstallHelper() {
        guard !isBusy else { return }
        endLocalSession(revokeLease: true)
        isBusy = true
        alert = nil

        Task.detached {
            do {
                try DesiredStateStore.write(.disabled)
                try LegacyAutostartManager.remove()
                try PrivilegedHelperManager.uninstall()
                let next = Self.waitForSnapshot(timeout: Self.restoreTimeout, ownedSessionID: nil) { candidate in
                    candidate.sleepDisabledVerified
                        && !candidate.sleepDisabled
                        && !candidate.helperArtifactsPresent
                        && !candidate.helperLoaded
                        && candidate.activationLease == nil
                        && !candidate.helperRecoveryRequired
                }
                await MainActor.run {
                    let removed = next.sleepDisabledVerified
                        && !next.sleepDisabled
                        && !next.helperArtifactsPresent
                        && !next.helperLoaded
                        && next.activationLease == nil
                        && !next.helperRecoveryRequired
                    self.snapshot = next
                    self.isBusy = false
                    if removed {
                        self.announce("The helper was removed and system sleep was restored.")
                    } else {
                        self.alert = .operationFailure(message: "Removal completed, but the safe uninstalled state could not be verified.")
                        self.announce(self.errorMessage ?? "Helper removal could not be verified.")
                    }
                }
            } catch {
                await self.finishFailure(error, fallback: "The helper could not be removed safely.")
            }
        }
    }

    func quitSafely() {
        guard !isBusy else { return }
        stopSession(quitWhenRestored: true, completion: nil)
    }

    func prepareForSystemTermination(completion: @escaping (Bool) -> Void) {
        guard !isBusy else {
            alert = .operationFailure(message: "LidSwitch is still finishing a safety operation. Wait for it to complete, then use Restore and Quit again.")
            announce(errorMessage ?? "A LidSwitch safety operation is still in progress.")
            completion(false)
            return
        }
        stopSession(quitWhenRestored: false, completion: completion)
    }

    func consumeAuthorizedTermination() -> Bool {
        defer { nextTerminationIsAuthorized = false }
        return nextTerminationIsAuthorized
    }

    func revokeForImmediateTermination() {
        endLocalSession(revokeLease: true)
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceRunLoopSource = nil
        }
    }

    private func stopSession(
        quitWhenRestored: Bool,
        completion: ((Bool) -> Void)?
    ) {
        guard !isBusy else {
            completion?(false)
            return
        }

        endLocalSession(revokeLease: true)
        isBusy = true
        alert = nil
        pendingStopCompletion = completion

        let safeRollbackWaiter = safeRollbackWaiter
        Task.detached {
            let next = safeRollbackWaiter()
            await MainActor.run {
                let restored = Self.isVerifiedSafeIdle(next)
                self.snapshot = next
                self.isBusy = false
                let completion = self.pendingStopCompletion
                self.pendingStopCompletion = nil
                if restored {
                    self.announce("Protection off. System sleep has been restored.")
                    completion?(true)
                    if quitWhenRestored {
                        self.nextTerminationIsAuthorized = true
                        NSApplication.shared.terminate(nil)
                    }
                } else {
                    self.alert = .operationFailure(message: "LidSwitch stopped renewing the session, but macOS still reports an active sleep override. Use Restore Sleep before quitting.")
                    self.announce(self.errorMessage ?? "Restore required before quitting.")
                    completion?(false)
                }
            }
        }
    }

#if DEBUG
    nonisolated static var helperRollbackVerificationTimeoutForTesting: TimeInterval {
        helperRollbackVerificationTimeout
    }

    func simulateHeartbeatEndForTesting(sessionID: UUID, reason: String) {
        activeSessionID = sessionID
        heartbeatDidEnd(sessionID, reason: reason)
    }

    func simulateNewSessionForTesting(_ sessionID: UUID) {
        activeSessionID = sessionID
        isBusy = false
        isStarting = false
    }
#endif

    private func scheduleHeartbeat(for sessionID: UUID, initialLeaseExpiresMonotonic: TimeInterval) {
        heartbeat?.stop(reason: "superseded-session")
        let coordinator = SessionHeartbeatCoordinator(
            observe: { PowerInspector.sessionHeartbeatObservation(sessionID: $0) },
            renew: { _, commitGuard in
                try ActivationLeaseStore.issue(sessionID: sessionID, commitGuard: commitGuard).expiresMonotonic
            },
            revoke: { try? ActivationLeaseStore.revoke() },
            onAcknowledged: { [weak self] acknowledgedID in
                Task { @MainActor in self?.heartbeatDidAcknowledge(acknowledgedID) }
            },
            onEnded: { [weak self] endedID, reason in
                Task { @MainActor in self?.heartbeatDidEnd(endedID, reason: reason) }
            }
        )
        heartbeat = coordinator
        coordinator.start(
            sessionID: sessionID,
            initialLeaseExpiresMonotonic: initialLeaseExpiresMonotonic
        )
    }

    private func heartbeatDidAcknowledge(_ sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        sessionWasAcknowledged = true
        isStarting = false
        isBusy = false
        startRequestID = nil
        announce("Protection active — plugged in.")
        Task.detached {
            let next = PowerInspector.snapshot(ownedSessionID: sessionID)
            await MainActor.run {
                guard self.activeSessionID == sessionID else { return }
                self.snapshot = next
            }
        }
    }

    private func heartbeatDidEnd(_ sessionID: UUID, reason: String) {
        guard activeSessionID == sessionID else { return }
        heartbeat = nil
        activeSessionID = nil
        sessionWasAcknowledged = false
        isStarting = false
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
                guard self.activeSessionID == nil else { return }
                let restored = Self.isVerifiedSafeIdle(next)
                self.snapshot = next
                self.isBusy = false
                if restored {
                    self.alert = nil
                    self.announce("Protection off. System sleep has been restored.")
                } else {
                    self.alert = .rollbackVerificationFailure(reason: reason)
                    self.announce(self.errorMessage ?? "Restore required before continuing.")
                }
            }
        }
    }

    private func endLocalSession(
        revokeLease: Bool,
        reason: String = "local-session-ended",
        announcement: String? = nil
    ) {
        heartbeat?.stop(reason: reason)
        heartbeat = nil
        activeSessionID = nil
        sessionWasAcknowledged = false
        isStarting = false
        startRequestID = nil
        if revokeLease {
            try? ActivationLeaseStore.revoke()
        }
        endActivity()
        if let announcement {
            announce(announcement)
        }
    }

    // All authoritative refresh callers (bootstrap, the 30-second timer,
    // power-source notifications, and manual Refresh) converge through this
    // one reconciliation point. It deliberately clears no generic operation
    // error and refuses to act while any newer local session exists.
    private func reconcileRollbackVerificationFailure(after snapshot: PowerSnapshot) {
        guard case .rollbackVerificationFailure = alert,
              activeSessionID == nil,
              Self.isVerifiedSafeIdle(snapshot)
        else { return }

        alert = nil
        announce("System sleep restored. Protection off.")
    }

    private func beginActivity() {
        endActivity()
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Maintain the user-confirmed LidSwitch session lease"
        )
    }

    private func endActivity() {
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
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

    private func finishFailure(_ error: Error, fallback: String) {
        snapshot = PowerInspector.snapshot(ownedSessionID: activeSessionID)
        isBusy = false
        alert = .operationFailure(message: errorMessage(for: error, fallback: fallback))
        announce(errorMessage ?? fallback)
    }

    private func errorMessage(for error: Error, fallback: String) -> String {
        let description = (error as NSError).localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? fallback : description
    }

    private func announce(_ message: String) {
        announcementHandler(message)
    }

    nonisolated private static func isVerifiedSafeIdle(_ candidate: PowerSnapshot) -> Bool {
        candidate.sleepDisabledVerified
            && !candidate.sleepDisabled
            && candidate.activationLease == nil
            && !candidate.helperRecoveryRequired
    }

    nonisolated private static func waitForSnapshot(
        timeout: TimeInterval,
        ownedSessionID: UUID?,
        condition: (PowerSnapshot) -> Bool
    ) -> PowerSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = PowerInspector.snapshot(ownedSessionID: ownedSessionID)
        while !condition(latest), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            latest = PowerInspector.snapshot(ownedSessionID: ownedSessionID)
        }
        return latest
    }
}
