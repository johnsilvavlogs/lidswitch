import Darwin
import Foundation
import IOKit.ps
import LidSwitchCore

final class HelperRuntime: @unchecked Sendable {
    private enum StartupRecovery {
        case recovered
        case needsActivation
        case failed
    }

    private static let restoreRetryDelays: [useconds_t] = [100_000, 300_000]
    // A native preference read can transiently race powerd publication. Retry
    // only values that were unreadable; explicit drift is never delayed or
    // masked, and no reconciliation read launches a pmset subprocess.
    private static let unreadableProbeRetryDelays: [useconds_t] = [100_000, 300_000]

    private let configuration: HelperConfiguration
    private let power: HelperPowerSystem
    private let currentBootID: () -> String?
    private let currentSystemBuild: () -> String?
    private let reconciliationInterval: TimeInterval
    private let terminalGenerationAllows: (UUID, String) -> Bool
    private let terminalGenerationRecord: (UUID, String) -> Bool
    private var activeSessionID: UUID?
    // A session gets one bounded repair for an owned SleepDisabled-only loss.
    // A second loss is terminal so we never fight another power-policy actor.
    private var successfulOverrideRecoveries = 0
    private var shouldExit = false
    private var exitCode: Int32 = 0
    private var leaseTimer: Timer?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var signalSources: [DispatchSourceSignal] = []

    private var terminalGenerationsPath: String {
        configuration.supportDirectory + "/terminal-generations"
    }

    init(
        configuration: HelperConfiguration,
        power: HelperPowerSystem = SystemPowerSystem(),
        currentBootID: @escaping () -> String? = BootIdentity.current,
        currentSystemBuild: @escaping () -> String? = SystemBuild.current,
        reconciliationInterval: TimeInterval = 2,
        terminalGenerationAllows: @escaping (UUID, String) -> Bool = { sessionID, path in
            TerminalGenerationStore.allowsActivation(sessionID: sessionID, path: path)
        },
        terminalGenerationRecord: @escaping (UUID, String) -> Bool = { sessionID, path in
            TerminalGenerationStore.record(sessionID: sessionID, path: path)
        }
    ) {
        self.configuration = configuration
        self.power = power
        self.currentBootID = currentBootID
        self.currentSystemBuild = currentSystemBuild
        self.reconciliationInterval = reconciliationInterval
        self.terminalGenerationAllows = terminalGenerationAllows
        self.terminalGenerationRecord = terminalGenerationRecord
    }

    func run() -> Int32 {
        guard prepareSupportDirectory() else {
            // A persistent filesystem/configuration failure is handled, not a crash.
            // Exit successfully so launchd's crash-only KeepAlive does not loop forever.
            return 0
        }
        guard let lease = validatedLease() else {
            let preservedSessionID = HelperStatusTombstone.read(path: configuration.statusPath)
                .flatMap(\.sessionID)
            _ = restoreOwnedStateThenRecordTerminal(
                reason: "no-valid-lease",
                sessionID: preservedSessionID
            )
            return 0
        }
        let terminalGeneration = !terminalGenerationAllows(lease.sessionID, terminalGenerationsPath)
        let terminalStatus = HelperStatusTombstone.read(path: configuration.statusPath).map {
            $0.sessionID == lease.sessionID && $0.isTerminal
        } ?? false
        if terminalGeneration || terminalStatus {
            // Terminal status is the fail-closed fallback when the bounded
            // ledger could not be recorded. Neither terminal marker may suppress
            // rollback while a prior helper still owns applied power state.
            _ = restoreOwnedStateThenRecordTerminal(
                reason: "terminal-session-recovery",
                sessionID: lease.sessionID
            )
            return 0
        }
        switch recoverAppliedSession(lease: lease) {
        case .recovered:
            break
        case .needsActivation:
            guard activate(lease: lease) else {
                _ = restoreOwnedStateThenRecordTerminal(
                    reason: "activation-failed",
                    sessionID: lease.sessionID
                )
                return 0
            }
        case .failed:
            _ = restoreOwnedStateThenRecordTerminal(
                reason: "recovery-failed",
                sessionID: lease.sessionID
            )
            return 0
        }

        guard installPowerNotification() else {
            _ = restoreOwnedStateThenRecordTerminal(
                reason: "power-notification-unavailable",
                sessionID: lease.sessionID
            )
            return 0
        }
        installSignalHandlers()
        leaseTimer = Timer.scheduledTimer(withTimeInterval: reconciliationInterval, repeats: true) { [weak self] _ in
            self?.reconcile()
        }

        while !shouldExit {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1))
        }
        return exitCode
    }

    private func validatedLease() -> ActivationLease? {
        guard let bootID = currentBootID(),
              let systemBuild = currentSystemBuild(),
              systemBuild == configuration.qualifiedBuild,
              CompatibilityPolicy.isQualified(systemBuild: systemBuild)
        else {
            return nil
        }
        guard case let .success(lease) = SecureLeaseReader.load(
            path: configuration.leasePath,
            expectedOwnerUID: configuration.expectedOwnerUID
        ) else {
            return nil
        }
        guard lease.validationFailure(
            now: Date(),
            nowMonotonic: MonotonicClock.seconds(),
            currentBootID: bootID,
            expectedOwnerUID: configuration.expectedOwnerUID,
            currentSystemBuild: systemBuild
        ) == nil else {
            return nil
        }
        return lease
    }

    private func activate(lease: ActivationLease) -> Bool {
        guard power.powerSource() == .ac,
              power.sleepDisabled() == false,
              let currentACSleep = power.acSleepMinutes()
        else {
            HelperStatusStore.write(
                state: "blocked",
                reason: "preflight-failed",
                sessionID: lease.sessionID,
                path: configuration.statusPath
            )
            return false
        }

        let changedACSleep = currentACSleep != 0
        let appliedState = AppliedState(
            sessionID: lease.sessionID,
            changedSleepDisabled: true,
            changedACSleep: changedACSleep,
            originalACSleep: changedACSleep ? currentACSleep : nil
        )
        do {
            try AppliedStateStore.write(appliedState, path: configuration.appliedStatePath)
            if changedACSleep {
                try power.setACSleepMinutes(0)
                guard power.acSleepMinutes() == 0 else {
                    throw NSError(domain: "LidSwitchHelper", code: 2)
                }
            }
            guard power.powerSource() == .ac else {
                throw NSError(domain: "LidSwitchHelper", code: 3)
            }
            try power.setSleepDisabled(true)
            guard power.sleepDisabled() == true,
                  power.acSleepMinutes() == 0,
                  power.powerSource() == .ac
            else {
                throw NSError(domain: "LidSwitchHelper", code: 1)
            }
        } catch {
            return false
        }

        activeSessionID = lease.sessionID
        successfulOverrideRecoveries = 0
        HelperStatusStore.write(
            state: "active",
            reason: "verified",
            sessionID: lease.sessionID,
            path: configuration.statusPath
        )
        return true
    }

    private func recoverAppliedSession(lease: ActivationLease) -> StartupRecovery {
        let priorStatus = HelperStatusTombstone.read(path: configuration.statusPath)
        switch AppliedStateStore.load(
            path: configuration.appliedStatePath,
            expectedOwnerUID: getuid()
        ) {
        case .missing:
            return .needsActivation
        case .invalid:
            HelperStatusStore.write(
                state: "recovery-required",
                reason: "invalid-applied-state",
                sessionID: nil,
                path: configuration.statusPath
            )
            return .failed
        case let .success(applied):
            if applied.sessionID == lease.sessionID, priorStatus?.sessionID == lease.sessionID,
               priorStatus?.recoveryReserved == true
            {
                // A crash after recording the pre-mutation reservation is not
                // evidence of a successful repair. Roll back and tombstone it;
                // startup must never spend a fresh budget by reactivating here.
                _ = restoreOwnedState(reason: "startup-interrupted-override-recovery", statusSessionID: lease.sessionID)
                return .failed
            }
            if applied.sessionID == lease.sessionID,
               power.powerSource() == .ac,
               power.sleepDisabled() == true,
               power.acSleepMinutes() == 0
            {
                activeSessionID = lease.sessionID
                successfulOverrideRecoveries = priorStatus?.sessionID == lease.sessionID && priorStatus?.recoverySpent == true ? 1 : 0
                HelperStatusStore.write(
                    state: "active",
                    reason: "recovered-after-abnormal-exit",
                    sessionID: lease.sessionID,
                    path: configuration.statusPath,
                    evidence: successfulOverrideRecoveries == 1 ? ["recovery_budget": "spent"] : [:]
                )
                return .recovered
            }
            return restoreOwnedState(reason: "startup-state-mismatch") ? .needsActivation : .failed
        }
    }

    private func reconcile() {
        guard !shouldExit else { return }
        guard power.powerSource() == .ac else {
            stop(reason: "power-source-changed")
            return
        }
        guard let lease = validatedLease(), lease.sessionID == activeSessionID else {
            stop(reason: "lease-expired-or-invalid")
            return
        }
        let (sleepDisabled, acSleep) = readOverrideStateWithBoundedUnreadableRetry()
        guard sleepDisabled == true, acSleep == 0 else {
            let evidence = overrideEvidence(
                sessionID: lease.sessionID,
                sleepDisabled: sleepDisabled,
                acSleep: acSleep
            )
            // AC sleep drift is deliberately not repaired here: a nonzero value
            // may be newer third-party intent. Only our owned SleepDisabled=0
            // loss can be recovered, and only for this still-live generation.
            if sleepDisabled == false,
               acSleep == 0,
               recoverOwnedSleepDisabledOverride(lease: lease, evidence: evidence)
            {
                return
            }
            stop(reason: "override-lost", evidence: evidence)
            return
        }
        HelperStatusStore.write(
            state: "active",
            reason: successfulOverrideRecoveries == 1 ? "verified-after-override-recovery" : "verified",
            sessionID: activeSessionID,
            path: configuration.statusPath,
            evidence: successfulOverrideRecoveries == 1 ? ["recovery_budget": "spent"] : [:]
        )
    }

    private func readOverrideStateWithBoundedUnreadableRetry() -> (Bool?, Int?) {
        var sleepDisabled = power.sleepDisabled()
        var acSleep = power.acSleepMinutes()
        guard sleepDisabled == nil || acSleep == nil else {
            return (sleepDisabled, acSleep)
        }

        for delay in Self.unreadableProbeRetryDelays {
            usleep(delay)
            // A known value is evidence, including explicit drift. Only repeat
            // the command whose previous result could not be parsed.
            if sleepDisabled == nil {
                sleepDisabled = power.sleepDisabled()
            }
            if acSleep == nil {
                acSleep = power.acSleepMinutes()
            }
            if sleepDisabled != nil && acSleep != nil {
                break
            }
        }
        return (sleepDisabled, acSleep)
    }

    private func recoverOwnedSleepDisabledOverride(
        lease: ActivationLease,
        evidence: [String: String]
    ) -> Bool {
        let status = HelperStatusTombstone.read(path: configuration.statusPath)
        guard activeSessionID == lease.sessionID,
              successfulOverrideRecoveries == 0,
              terminalGenerationAllows(lease.sessionID, terminalGenerationsPath),
              !(status?.sessionID == lease.sessionID && status?.isTerminal == true),
              case let .success(applied) = AppliedStateStore.load(
                path: configuration.appliedStatePath,
                expectedOwnerUID: getuid()
              ),
              applied.sessionID == lease.sessionID,
              applied.changedSleepDisabled,
              power.powerSource() == .ac,
              power.sleepDisabled() == false,
              power.acSleepMinutes() == 0
        else { return false }

        // Persist causal evidence before mutation; a terminal status below keeps
        // it if the reapply fails. It is bounded, root-owned, and non-sensitive.
        HelperStatusStore.write(
            state: "active",
            reason: "override-drift-observed",
            sessionID: lease.sessionID,
            path: configuration.statusPath,
            evidence: evidence.merging(["recovery_budget": "reserved"]) { _, new in new }
        )
        guard terminalGenerationAllows(lease.sessionID, terminalGenerationsPath),
              power.powerSource() == .ac,
              power.sleepDisabled() == false,
              power.acSleepMinutes() == 0,
              let currentLease = validatedLease(), currentLease.sessionID == lease.sessionID
        else { return false }
        do {
            try power.setSleepDisabled(true)
        } catch {
            return false
        }
        guard power.powerSource() == .ac,
              power.sleepDisabled() == true,
              power.acSleepMinutes() == 0,
              let currentLease = validatedLease(), currentLease.sessionID == lease.sessionID,
              terminalGenerationAllows(lease.sessionID, terminalGenerationsPath)
        else { return false }
        HelperStatusStore.write(
            state: "active",
            reason: "override-recovered",
            sessionID: lease.sessionID,
            path: configuration.statusPath,
            evidence: evidence.merging([
                "recovered_at": String(Int(Date().timeIntervalSince1970)),
                "recovery_budget": "spent",
            ]) { _, new in new }
        )
        successfulOverrideRecoveries = 1
        return true
    }

    private func overrideEvidence(sessionID: UUID, sleepDisabled: Bool?, acSleep: Int?) -> [String: String] {
        [
            "event": "override-drift",
            "observed_sleep_disabled": sleepDisabled.map { $0 ? "1" : "0" } ?? "unreadable",
            "observed_ac_sleep": acSleep.map(String.init) ?? "unreadable",
            "observed_power": "ac",
            "observed_session": sessionID.uuidString.lowercased(),
            "observed_at": String(Int(Date().timeIntervalSince1970)),
        ]
    }

    private func stop(reason: String, evidence: [String: String] = [:]) {
        guard !shouldExit else { return }
        _ = restoreOwnedStateThenRecordTerminal(reason: reason, sessionID: activeSessionID, evidence: evidence)
        // Recovery-required is a durable handled state. A nonzero exit here would
        // make launchd retry the same pmset failure forever through KeepAlive.
        exitCode = 0
        shouldExit = true
        leaseTimer?.invalidate()
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .defaultMode)
        }
        CFRunLoopStop(CFRunLoopGetCurrent())
    }

    @discardableResult
    private func restoreOwnedStateThenRecordTerminal(
        reason: String,
        sessionID: UUID?,
        evidence: [String: String] = [:]
    ) -> Bool {
        // Publish a durable retry marker before mutating power state. If the helper
        // is interrupted anywhere in rollback, startup will retry restoration
        // instead of reactivating or treating the session as already cleaned up.
        HelperStatusStore.write(
            state: "recovery-required",
            reason: "\(reason)-restore-pending",
            sessionID: sessionID,
            path: configuration.statusPath,
            evidence: evidence
        )
        guard restoreOwnedState(reason: reason, statusSessionID: sessionID, evidence: evidence) else {
            return false
        }
        if let sessionID {
            _ = terminalGenerationRecord(sessionID, terminalGenerationsPath)
        }
        return true
    }

    @discardableResult
    private func restoreOwnedState(
        reason: String,
        statusSessionID: UUID? = nil,
        evidence: [String: String] = [:]
    ) -> Bool {
        let applied: AppliedState
        switch AppliedStateStore.load(
            path: configuration.appliedStatePath,
            expectedOwnerUID: getuid()
        ) {
        case .missing:
            removeLegacyPreferenceResidue()
            HelperStatusStore.write(
                state: "inactive",
                reason: reason,
                sessionID: activeSessionID ?? statusSessionID,
                path: configuration.statusPath,
                evidence: evidence
            )
            return true
        case .invalid:
            HelperStatusStore.write(
                state: "recovery-required",
                reason: "\(reason)-invalid-applied-state",
                sessionID: activeSessionID ?? statusSessionID,
                path: configuration.statusPath
            )
            return false
        case let .success(storedState):
            applied = storedState
        }

        for attempt in 0...Self.restoreRetryDelays.count {
            if attempt > 0 {
                usleep(Self.restoreRetryDelays[attempt - 1])
            }
            if restoreOwnedChanges(applied) {
                guard AppliedStateStore.remove(path: configuration.appliedStatePath) else {
                    HelperStatusStore.write(
                        state: "recovery-required",
                        reason: "\(reason)-applied-state-remove-failed",
                        sessionID: applied.sessionID,
                        path: configuration.statusPath,
                        evidence: evidence
                    )
                    return false
                }
                removeLegacyPreferenceResidue()
                HelperStatusStore.write(
                    state: "inactive",
                    reason: reason,
                    sessionID: applied.sessionID,
                    path: configuration.statusPath,
                    evidence: evidence
                )
                return true
            }
        }

        HelperStatusStore.write(
            state: "recovery-required",
            reason: "\(reason)-restore-unverified",
            sessionID: applied.sessionID,
            path: configuration.statusPath,
            evidence: evidence
        )
        return false
    }

    private func restoreOwnedChanges(_ applied: AppliedState) -> Bool {
        var sleepRestored = true
        if applied.changedSleepDisabled {
            if let sleepDisabled = power.sleepDisabled() {
                if sleepDisabled {
                    do {
                        try power.setSleepDisabled(false)
                        sleepRestored = power.sleepDisabled() == false
                    } catch {
                        sleepRestored = false
                    }
                }
            } else {
                sleepRestored = false
            }
        }

        var acSleepRestored = true
        if applied.changedACSleep {
            guard let original = applied.originalACSleep, original > 0 else { return false }
            switch power.acSleepMinutes() {
            case original:
                break
            case 0:
                do {
                    try power.setACSleepMinutes(original)
                    acSleepRestored = power.acSleepMinutes() == original
                } catch {
                    acSleepRestored = false
                }
            case .some(_):
                // Another actor changed the AC sleep value after LidSwitch applied 0.
                // Relinquish ownership without overwriting that newer value.
                break
            case nil:
                acSleepRestored = false
            }
        }

        return sleepRestored && acSleepRestored
    }

    private func installPowerNotification() -> Bool {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let unmanagedSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let runtime = Unmanaged<HelperRuntime>.fromOpaque(context).takeUnretainedValue()
            runtime.reconcile()
        }, context) else { return false }
        let source = unmanagedSource.takeRetainedValue()
        powerSourceRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
        return true
    }

    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                self?.stop(reason: "signal")
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func prepareSupportDirectory() -> Bool {
        let effectiveUID = getuid()
        let effectiveGID = getgid()
        var metadata = stat()
        if lstat(configuration.supportDirectory, &metadata) != 0 {
            guard errno == ENOENT,
                  mkdir(configuration.supportDirectory, 0o755) == 0,
                  chown(configuration.supportDirectory, effectiveUID, effectiveGID) == 0,
                  chmod(configuration.supportDirectory, 0o755) == 0,
                  lstat(configuration.supportDirectory, &metadata) == 0
            else {
                return false
            }
        }

        let permissions = metadata.st_mode & 0o7777
        guard metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == effectiveUID,
              metadata.st_gid == effectiveGID,
              permissions & 0o700 == 0o700,
              permissions & 0o022 == 0,
              permissions & 0o7000 == 0
        else {
            return false
        }
        return true
    }

    private func removeLegacyPreferenceResidue() {
        for name in ["original-ac-sleep", "original-battery-sleep"] {
            _ = unlink((configuration.supportDirectory as NSString).appendingPathComponent(name))
        }
    }
}
