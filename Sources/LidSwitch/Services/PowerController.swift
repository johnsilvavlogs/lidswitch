import AppKit
import Combine
import Foundation
import IOKit.ps
import LidSwitchCore

@MainActor
final class PowerController: ObservableObject {
    @Published private(set) var snapshot: PowerSnapshot = .empty
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?

    nonisolated private static let refreshInterval: TimeInterval = 30
    nonisolated private static let heartbeatInterval: TimeInterval = 8
    nonisolated private static let acknowledgementTimeout: TimeInterval = 6
    nonisolated private static let restoreTimeout: TimeInterval = 8

    private var refreshTimer: Timer?
    private var heartbeatTimer: Timer?
    private var activeSessionID: UUID?
    private var sessionWasAcknowledged = false
    private var activityToken: NSObjectProtocol?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var nextTerminationIsAuthorized = false
    private var pendingStopCompletion: ((Bool) -> Void)?

    init() {
        // A session belongs to one app process. A fresh process never adopts a
        // predecessor's lease; revoking it makes the helper restore immediately.
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
        let next = PowerInspector.snapshot(ownedSessionID: activeSessionID)
        snapshot = next

        guard let sessionID = activeSessionID else {
            if next.hasCriticalSafetyIssue, next.statusTitle != previousStatus {
                announce(next.accessibilityState)
            }
            return
        }

        let matchingStoppedStatus = next.helperStatus?.sessionID == sessionID
            && next.helperStatus?.state != "active"
        let acknowledgedSessionLostVerification = sessionWasAcknowledged && !next.sessionActive
        if !next.source.isAC || matchingStoppedStatus || acknowledgedSessionLostVerification {
            endLocalSession(
                revokeLease: true,
                announcement: !next.source.isAC
                    ? "Power disconnected. The LidSwitch session ended and will not restart automatically."
                    : "The LidSwitch session ended and the system sleep setting is being restored."
            )
            snapshot = PowerInspector.snapshot(ownedSessionID: activeSessionID)
        }
    }

    func prepareHelper() {
        guard !isBusy else { return }
        guard snapshot.canPrepareHelper, snapshot.sleepDisabledVerified else {
            errorMessage = snapshot.statusDetail
            announce(snapshot.statusDetail)
            return
        }

        endLocalSession(revokeLease: true)
        isBusy = true
        errorMessage = nil

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
                        self.errorMessage = "The helper was installed, but its safe ready state could not be verified. Protection remains off."
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
        refresh()
        guard snapshot.canStartSession else {
            errorMessage = snapshot.statusDetail
            announce(snapshot.statusDetail)
            return
        }

        isBusy = true
        errorMessage = nil
        let sessionID = UUID()
        activeSessionID = sessionID
        sessionWasAcknowledged = false
        beginActivity()

        do {
            try DesiredStateStore.write(.disabled)
            _ = try ActivationLeaseStore.issue(sessionID: sessionID)
            scheduleHeartbeat(for: sessionID)
        } catch {
            endLocalSession(revokeLease: true)
            isBusy = false
            errorMessage = errorMessage(for: error, fallback: "The monitored session could not start. Nothing was enabled.")
            announce(errorMessage ?? "The monitored session could not start.")
            return
        }

        Task.detached {
            let next = Self.waitForSnapshot(
                timeout: Self.acknowledgementTimeout,
                ownedSessionID: sessionID
            ) { candidate in
                candidate.sessionActive
                    && candidate.activationLease?.sessionID == sessionID
                    && candidate.helperStatus?.sessionID == sessionID
            }
            await MainActor.run {
                guard self.activeSessionID == sessionID else { return }
                self.snapshot = next
                self.isBusy = false
                if next.sessionActive,
                   next.activationLease?.sessionID == sessionID,
                   next.source.isAC
                {
                    self.sessionWasAcknowledged = true
                    self.announce("Protection active — plugged in.")
                } else {
                    self.endLocalSession(revokeLease: true)
                    self.errorMessage = "The helper did not verify the live system override. Check the current status; use Restore Sleep whenever recovery or power verification is required."
                    self.snapshot = PowerInspector.snapshot(ownedSessionID: self.activeSessionID)
                    self.announce(self.errorMessage ?? "The monitored session did not start.")
                }
            }
        }
    }

    func stopSession() {
        stopSession(quitWhenRestored: false, completion: nil)
    }

    func restoreNow() {
        guard !isBusy else { return }
        endLocalSession(revokeLease: true)
        isBusy = true
        errorMessage = nil

        Task.detached {
            do {
                try PrivilegedHelperManager.restoreSleepNow()
                let next = Self.waitForSnapshot(timeout: Self.restoreTimeout, ownedSessionID: nil) { candidate in
                    candidate.sleepDisabledVerified
                        && !candidate.sleepDisabled
                        && candidate.activationLease == nil
                        && !candidate.helperRecoveryRequired
                }
                await MainActor.run {
                    let restored = next.sleepDisabledVerified
                        && !next.sleepDisabled
                        && next.activationLease == nil
                        && !next.helperRecoveryRequired
                    self.snapshot = next
                    self.isBusy = false
                    if restored {
                        self.announce("System sleep has been restored.")
                    } else {
                        self.errorMessage = "LidSwitch could not verify that the macOS sleep override is off. Keep LidSwitch open and try Restore Sleep again."
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
        errorMessage = nil

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
                        self.errorMessage = "Removal completed, but the safe uninstalled state could not be verified."
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
            errorMessage = "LidSwitch is still finishing a safety operation. Wait for it to complete, then use Restore and Quit again."
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
        errorMessage = nil
        pendingStopCompletion = completion

        Task.detached {
            let next = Self.waitForSnapshot(timeout: Self.restoreTimeout, ownedSessionID: nil) { candidate in
                candidate.sleepDisabledVerified
                    && !candidate.sleepDisabled
                    && candidate.activationLease == nil
                    && !candidate.helperRecoveryRequired
            }
            await MainActor.run {
                let restored = next.sleepDisabledVerified
                    && !next.sleepDisabled
                    && next.activationLease == nil
                    && !next.helperRecoveryRequired
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
                    self.errorMessage = "LidSwitch stopped renewing the session, but macOS still reports an active sleep override. Use Restore Sleep before quitting."
                    self.announce(self.errorMessage ?? "Restore required before quitting.")
                    completion?(false)
                }
            }
        }
    }

    private func scheduleHeartbeat(for sessionID: UUID) {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: Self.heartbeatInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.renewLease(for: sessionID)
            }
        }
    }

    private func renewLease(for sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        let live = PowerInspector.snapshot(ownedSessionID: sessionID)
        guard live.sessionActive,
              live.activationLease?.sessionID == sessionID
        else {
            snapshot = live
            endLocalSession(
                revokeLease: true,
                announcement: "The plugged-in session ended and will not restart automatically."
            )
            return
        }

        do {
            _ = try ActivationLeaseStore.issue(sessionID: sessionID)
        } catch {
            endLocalSession(revokeLease: true)
            errorMessage = errorMessage(for: error, fallback: "The safety heartbeat failed. Protection is ending now.")
            snapshot = PowerInspector.snapshot(ownedSessionID: activeSessionID)
            announce(errorMessage ?? "The safety heartbeat failed.")
        }
    }

    private func endLocalSession(revokeLease: Bool, announcement: String? = nil) {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        activeSessionID = nil
        sessionWasAcknowledged = false
        if revokeLease {
            try? ActivationLeaseStore.revoke()
        }
        endActivity()
        if let announcement {
            announce(announcement)
        }
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
        let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let controller = Unmanaged<PowerController>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                controller.refresh()
            }
        }, context).takeRetainedValue()
        powerSourceRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private func finishFailure(_ error: Error, fallback: String) {
        snapshot = PowerInspector.snapshot(ownedSessionID: activeSessionID)
        isBusy = false
        errorMessage = errorMessage(for: error, fallback: fallback)
        announce(errorMessage ?? fallback)
    }

    private func errorMessage(for error: Error, fallback: String) -> String {
        let description = (error as NSError).localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? fallback : description
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
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
