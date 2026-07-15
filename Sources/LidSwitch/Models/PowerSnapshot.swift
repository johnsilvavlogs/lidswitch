import Foundation
import LidSwitchCore

enum PowerSource: Equatable, Sendable {
    case ac
    case battery(percent: Int?)
    case unknown(String)

    var title: String {
        switch self {
        case .ac:
            return "Plugged in"
        case let .battery(percent):
            return percent.map { "Battery · \($0)%" } ?? "Battery"
        case .unknown:
            return "Power source unavailable"
        }
    }

    var isAC: Bool {
        if case .ac = self { return true }
        return false
    }
}

/// Non-authoritative user-local persistence truth. The presentation fields
/// retain compatibility values, while this evidence prevents an unsafe or
/// interrupted read from being mistaken for a deliberate disabled/absent one.
enum UserStatePersistenceTruth: Equatable, Sendable {
    case valid
    case missing
    case invalid
    case retainedResidue
    case unsafe
    case io
    case indeterminate
}

struct HelperStatusRecord: Equatable, Sendable {
    let state: String
    let reason: String
    let sessionID: UUID?
    let updatedAt: Date
    let bootID: String?
    let updatedMonotonic: TimeInterval?

    init(state: String, reason: String, sessionID: UUID?, updatedAt: Date,
         bootID: String? = nil, updatedMonotonic: TimeInterval? = nil) {
        self.state = state
        self.reason = reason
        self.sessionID = sessionID
        self.updatedAt = updatedAt
        self.bootID = bootID
        self.updatedMonotonic = updatedMonotonic
    }

    static func parse(_ raw: String) -> HelperStatusRecord? {
        var values: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let key = String(parts[0])
            guard values[key] == nil else { return nil }
            values[key] = String(parts[1])
        }
        guard let state = values["state"],
              let reason = values["reason"],
              let sessionRaw = values["session"],
              let updatedRaw = values["updated"],
              let updatedSeconds = TimeInterval(updatedRaw)
        else {
            return nil
        }
        let sessionID: UUID?
        if sessionRaw == "none" {
            sessionID = nil
        } else if let parsed = UUID(uuidString: sessionRaw) {
            sessionID = parsed
        } else {
            return nil
        }
        return HelperStatusRecord(
            state: state,
            reason: reason,
            sessionID: sessionID,
            updatedAt: Date(timeIntervalSince1970: updatedSeconds),
            bootID: values["boot_id"],
            updatedMonotonic: values["updated_monotonic"].flatMap { TimeInterval($0) }
        )
    }

    func isFresh(at date: Date) -> Bool {
        if let bootID, let updatedMonotonic, bootID == BootIdentity.current() {
            let age = MonotonicClock.seconds() - updatedMonotonic
            return age >= 0 && age <= 12
        }
        let age = date.timeIntervalSince(updatedAt)
        return age >= -2 && age <= 12
    }
}

struct PowerSnapshot: Equatable, Sendable {
    let source: PowerSource
    let sleepDisabled: Bool
    let sleepDisabledVerified: Bool
    let acIdleSleepMinutes: Int?
    let preferences: PowerPreferences
    let desiredStateTruth: UserStatePersistenceTruth
    let helperArtifactsPresent: Bool
    let helperLoaded: Bool
    let helperNeedsUpdate: Bool
    let legacyLoginItemPresent: Bool
    let legacyLoginItemLoaded: Bool
    let activationLease: ActivationLease?
    let activationLeaseTruth: UserStatePersistenceTruth
    /// Descriptor-bound audit evidence of one reconciled installed legacy
    /// lease. It is intentionally separate from active lease truth.
    let activationLeaseRecoveredLegacyEvidence: Bool
    /// Exact canonical legacy plaintext was parsed but is expired or otherwise
    /// inactive. It routes to safe preparation, never session authority.
    let staleCanonicalLegacyLeasePresent: Bool
    let ownedSessionID: UUID?
    let helperStatus: HelperStatusRecord?
    let systemBuild: String?
    let systemBuildQualified: Bool
    let bundleIntegrityValid: Bool
    let bundleVersionValid: Bool
    let checkedAt: Date
    let installationInventoryState: PowerInspector.InstallationInventoryState
    let helperLaunchdState: PowerInspector.LaunchdPresence
    let legacyLaunchdState: PowerInspector.LaunchdPresence

    init(
        source: PowerSource,
        sleepDisabled: Bool,
        sleepDisabledVerified: Bool,
        acIdleSleepMinutes: Int?,
        preferences: PowerPreferences,
        desiredStateTruth: UserStatePersistenceTruth = .valid,
        helperArtifactsPresent: Bool,
        helperLoaded: Bool,
        helperNeedsUpdate: Bool,
        legacyLoginItemPresent: Bool,
        legacyLoginItemLoaded: Bool,
        activationLease: ActivationLease?,
        activationLeaseTruth: UserStatePersistenceTruth? = nil,
        activationLeaseRecoveredLegacyEvidence: Bool = false,
        staleCanonicalLegacyLeasePresent: Bool = false,
        ownedSessionID: UUID?,
        helperStatus: HelperStatusRecord?,
        systemBuild: String?,
        systemBuildQualified: Bool,
        bundleIntegrityValid: Bool,
        bundleVersionValid: Bool,
        checkedAt: Date,
        installationInventoryState: PowerInspector.InstallationInventoryState? = nil,
        helperLaunchdState: PowerInspector.LaunchdPresence? = nil,
        legacyLaunchdState: PowerInspector.LaunchdPresence? = nil
    ) {
        self.source = source
        self.sleepDisabled = sleepDisabled
        self.sleepDisabledVerified = sleepDisabledVerified
        self.acIdleSleepMinutes = acIdleSleepMinutes
        self.preferences = preferences
        self.desiredStateTruth = desiredStateTruth
        self.helperArtifactsPresent = helperArtifactsPresent
        self.helperLoaded = helperLoaded
        self.helperNeedsUpdate = helperNeedsUpdate
        self.legacyLoginItemPresent = legacyLoginItemPresent
        self.legacyLoginItemLoaded = legacyLoginItemLoaded
        self.activationLease = activationLease
        self.activationLeaseTruth = activationLeaseTruth ?? (activationLease == nil ? .missing : .valid)
        self.activationLeaseRecoveredLegacyEvidence = activationLeaseRecoveredLegacyEvidence
        self.staleCanonicalLegacyLeasePresent = staleCanonicalLegacyLeasePresent
        self.ownedSessionID = ownedSessionID
        self.helperStatus = helperStatus
        self.systemBuild = systemBuild
        self.systemBuildQualified = systemBuildQualified
        self.bundleIntegrityValid = bundleIntegrityValid
        self.bundleVersionValid = bundleVersionValid
        self.checkedAt = checkedAt
        self.installationInventoryState = installationInventoryState
            ?? (helperLoaded && !helperNeedsUpdate ? .valid : .invalid("Fixture installation is not ready."))
        self.helperLaunchdState = helperLaunchdState ?? (helperLoaded ? .present : .absent)
        self.legacyLaunchdState = legacyLaunchdState ?? (legacyLoginItemLoaded ? .present : .absent)
    }

    static let empty = PowerSnapshot(
        source: .unknown(""),
        sleepDisabled: false,
        sleepDisabledVerified: false,
        acIdleSleepMinutes: nil,
        preferences: .disabled,
        desiredStateTruth: .missing,
        helperArtifactsPresent: false,
        helperLoaded: false,
        helperNeedsUpdate: false,
        legacyLoginItemPresent: false,
        legacyLoginItemLoaded: false,
        activationLease: nil,
        activationLeaseTruth: .missing,
        activationLeaseRecoveredLegacyEvidence: false,
        staleCanonicalLegacyLeasePresent: false,
        ownedSessionID: nil,
        helperStatus: nil,
        systemBuild: nil,
        systemBuildQualified: false,
        bundleIntegrityValid: false,
        bundleVersionValid: false,
        checkedAt: .distantPast,
        installationInventoryState: .pending,
        helperLaunchdState: .indeterminate,
        legacyLaunchdState: .indeterminate
    )

    func withIndeterminateInstallationInventory(reason: String) -> PowerSnapshot {
        PowerSnapshot(
            source: source,
            sleepDisabled: sleepDisabled,
            sleepDisabledVerified: sleepDisabledVerified,
            acIdleSleepMinutes: acIdleSleepMinutes,
            preferences: preferences,
            desiredStateTruth: desiredStateTruth,
            helperArtifactsPresent: helperArtifactsPresent,
            helperLoaded: false,
            helperNeedsUpdate: helperArtifactsPresent,
            legacyLoginItemPresent: legacyLoginItemPresent,
            legacyLoginItemLoaded: false,
            activationLease: activationLease,
            activationLeaseTruth: activationLeaseTruth,
            activationLeaseRecoveredLegacyEvidence: activationLeaseRecoveredLegacyEvidence,
            staleCanonicalLegacyLeasePresent: staleCanonicalLegacyLeasePresent,
            ownedSessionID: ownedSessionID,
            helperStatus: helperStatus,
            systemBuild: systemBuild,
            systemBuildQualified: systemBuildQualified,
            bundleIntegrityValid: false,
            bundleVersionValid: false,
            checkedAt: checkedAt,
            installationInventoryState: .indeterminate(reason),
            helperLaunchdState: .indeterminate,
            legacyLaunchdState: .indeterminate
        )
    }

    var helperReady: Bool {
        installationInventoryState.isValid
            && helperArtifactsPresent
            && helperLaunchdState == .present
            && !helperNeedsUpdate
    }

    var legacyResiduePresent: Bool {
        legacyLoginItemPresent
            || legacyLoginItemLoaded
            || preferences.keepAwakeEnabled
            || preferences.legacyBatteryResidueDetected
            || desiredStateTruth != .valid
            || activationLeaseTruth == .valid
            || staleCanonicalLegacyLeasePresent
    }

    var sessionActive: Bool {
        guard let ownedSessionID else { return false }
        return source.isAC
            && sleepDisabledVerified
            && sleepDisabled
            && helperStatus?.state == "active"
            && helperStatus?.sessionID == ownedSessionID
            && helperStatus?.isFresh(at: checkedAt) == true
    }

    var sessionPending: Bool {
        ownedSessionID != nil && !sessionActive
    }

    var helperRecoveryRequired: Bool {
        helperStatus?.state == "recovery-required"
    }

    /// A terminal projection is informational only after the app has lost its
    /// in-memory generation. The helper keeps one latest projection, so its
    /// current-boot identity—not short liveness—is the boundary that prevents
    /// a pre-reboot generation from resurfacing after a later launch.
    var previousPeerProcessEndedSafely: Bool {
        Self.isCurrentBootPeerProcessSafeIdle(
            helperStatus: helperStatus,
            ownedSessionID: ownedSessionID,
            sleepDisabledVerified: sleepDisabledVerified,
            sleepDisabled: sleepDisabled,
            acIdleSleepMinutes: acIdleSleepMinutes,
            helperRecoveryRequired: helperRecoveryRequired,
            currentBootID: BootIdentity.current(),
            currentMonotonic: MonotonicClock.seconds()
        )
    }

    static func isCurrentBootPeerProcessSafeIdle(
        helperStatus: HelperStatusRecord?,
        ownedSessionID: UUID?,
        sleepDisabledVerified: Bool,
        sleepDisabled: Bool,
        acIdleSleepMinutes: Int?,
        helperRecoveryRequired: Bool,
        currentBootID: String?,
        currentMonotonic: TimeInterval
    ) -> Bool {
        guard ownedSessionID == nil,
              let helperStatus,
              helperStatus.state == "terminal",
              helperStatus.reason == "peer-process-invalid",
              helperStatus.sessionID != nil,
              let currentBootID,
              helperStatus.bootID == currentBootID,
              currentMonotonic.isFinite,
              currentMonotonic >= 0,
              sleepDisabledVerified,
              !sleepDisabled,
              acIdleSleepMinutes != nil,
              !helperRecoveryRequired
        else { return false }
        if let updatedMonotonic = helperStatus.updatedMonotonic {
            guard updatedMonotonic.isFinite,
                  updatedMonotonic >= 0,
                  updatedMonotonic <= currentMonotonic
            else { return false }
        }
        return true
    }

    var orphanedLeasePresent: Bool {
        // Legacy file leases are diagnostic residue only. They never authorize
        // helper activity after the raw-XPC migration.
        activationLease != nil
    }

    var restoreRequired: Bool {
        helperRecoveryRequired
            || (sleepDisabledVerified && sleepDisabled && !sessionActive)
    }

    var hasCriticalSafetyIssue: Bool {
        restoreRequired
            || !sleepDisabledVerified
            || (!installationInventoryState.isPending && !bundleVersionValid)
            || (!installationInventoryState.isPending && !bundleIntegrityValid)
            || !systemBuildQualified
            || installationInventoryIndeterminate
            || desiredStateTruth == .unsafe
            || desiredStateTruth == .io
            || desiredStateTruth == .indeterminate
            || desiredStateTruth == .retainedResidue
            || activationLeaseTruth == .unsafe
            || activationLeaseTruth == .io
            || activationLeaseTruth == .indeterminate
            || activationLeaseTruth == .retainedResidue
            || (!installationInventoryState.isPending && helperNeedsUpdate)
            || legacyResiduePresent
    }

    var canPrepareHelper: Bool {
        !installationInventoryState.isPending
            && systemBuildQualified
            && bundleIntegrityValid
            && bundleVersionValid
    }

    var canStartSession: Bool {
        source.isAC
            && helperReady
            && !legacyResiduePresent
            && systemBuildQualified
            && bundleIntegrityValid
            && bundleVersionValid
            && sleepDisabledVerified
            && !sleepDisabled
            && !helperRecoveryRequired
            && installationInventoryState.isValid
            && Self.userStateAllowsSessionStart(
                desiredStateTruth: desiredStateTruth,
                activationLeaseTruth: activationLeaseTruth,
                activationLeasePresent: activationLease != nil
            )
    }

    static func userStateAllowsSessionStart(
        desiredStateTruth: UserStatePersistenceTruth,
        activationLeaseTruth: UserStatePersistenceTruth,
        activationLeasePresent: Bool
    ) -> Bool {
        guard desiredStateTruth == .valid, !activationLeasePresent else { return false }
        // Only canonical absence is active-lease absence. Generic retained
        // evidence always blocks; the separately recorded archive audit fact
        // never enters this authority decision.
        return activationLeaseTruth == .missing
    }

    var installationInventoryPending: Bool {
        installationInventoryState.isPending
    }

    var installationInventoryIndeterminate: Bool {
        guard !installationInventoryPending else { return false }
        if case .indeterminate = installationInventoryState { return true }
        return helperLaunchdState == .indeterminate || legacyLaunchdState == .indeterminate
    }

    var statusTitle: String {
        if staleCanonicalLegacyLeasePresent {
            return "Legacy lease needs reconciliation"
        }
        if desiredStateTruth != .valid || activationLeaseTruth == .unsafe || activationLeaseTruth == .invalid || activationLeaseTruth == .io || activationLeaseTruth == .indeterminate {
            return "User-state verification required"
        }
        if activationLeaseRecoveredLegacyEvidence {
            return "Legacy lease archived"
        }
        if helperRecoveryRequired {
            return "Recovery required"
        }
        if restoreRequired {
            return "Restore required"
        }
        if previousPeerProcessEndedSafely {
            return "Previous session ended safely"
        }
        if !sleepDisabledVerified {
            return "Power status unavailable"
        }
        if sessionActive {
            return "Protection active — plugged in"
        }
        if installationInventoryPending {
            return "Checking installation"
        }
        if installationInventoryIndeterminate {
            return "Installation status unavailable"
        }
        if !bundleVersionValid || !bundleIntegrityValid {
            return "Build verification failed"
        }
        if !systemBuildQualified {
            return "Compatibility not confirmed"
        }
        if helperNeedsUpdate {
            return "Helper update required"
        }
        if legacyResiduePresent {
            return "Old startup files found"
        }
        if sessionPending {
            return "Starting monitored session"
        }
        if helperReady {
            switch source {
            case .ac:
                return "Ready for monitored session"
            case .battery:
                return "Connect power to start"
            case .unknown:
                return "Power source unavailable"
            }
        }
        return "Protection off"
    }

    var statusDetail: String {
        if staleCanonicalLegacyLeasePresent {
            return "A prior installed activation lease is no longer active. Prepare Safe Helper archives the exact record and verifies its canonical absence before a new session can start."
        }
        if desiredStateTruth != .valid || activationLeaseTruth == .unsafe || activationLeaseTruth == .invalid || activationLeaseTruth == .io || activationLeaseTruth == .indeterminate || activationLeaseTruth == .valid {
            return "LidSwitch could not establish the exact user-state record. Protection remains off; refresh after resolving the local record."
        }
        if activationLeaseRecoveredLegacyEvidence {
            return "An installed legacy activation lease was archived after its canonical name was verified absent. The archive is diagnostic evidence only."
        }
        if helperRecoveryRequired {
            return "The helper could not verify a complete rollback. Use Restore Sleep before starting another session or quitting."
        }
        if restoreRequired {
            return "LidSwitch is inactive, but macOS still reports an active system sleep override. Restore it before doing anything else."
        }
        if previousPeerProcessEndedSafely {
            return "LidSwitch stopped running, and the helper restored system sleep. Protection remains off until you explicitly start a new session."
        }
        if !sleepDisabledVerified {
            return "LidSwitch could not verify the live macOS sleep override. Starting a session is blocked."
        }
        if sessionActive {
            return "Lid-close sleep is blocked for this session. Quit, unplug, restart, or a missed safety check ends it."
        }
        if installationInventoryPending {
            return "Checking the installed helper and app bundle. Protection stays off until this exact check finishes."
        }
        if installationInventoryIndeterminate {
            if case let .indeterminate(reason) = installationInventoryState {
                return "\(reason) Protection remains off; refresh to try the bounded check again."
            }
            return "LidSwitch could not determine the launchd installation state. Protection remains off; refresh to try the bounded check again."
        }
        if !bundleVersionValid || !bundleIntegrityValid {
            return "This copy of LidSwitch cannot safely control power settings. Protection remains off."
        }
        if !systemBuildQualified {
            return "This macOS build has not passed LidSwitch safety checks. Protection remains off."
        }
        if helperNeedsUpdate {
            return "A newer crash-safe helper is available. Prepare Safe Helper before starting a new session."
        }
        if legacyResiduePresent {
            return "Disabled legacy components remain on this Mac. Replace them before starting a new session."
        }
        if sessionPending {
            return "Waiting for the helper to verify the live system override."
        }
        if helperReady {
            if source.isAC {
                return "Protection is off. LidSwitch starts only when you explicitly begin a plugged-in session."
            }
            if case .battery = source {
                return "Protection remains off on battery. Reconnecting power never starts it automatically."
            }
            return "LidSwitch could not verify AC power. Starting a session is blocked."
        }
        return "Prepare the crash-safe helper. Protection remains off until you explicitly start a session."
    }

    var systemSummary: String {
        let override: String
        if sleepDisabledVerified {
            override = sleepDisabled ? "System sleep override on" : "System sleep override off"
        } else {
            override = "System sleep override unavailable"
        }
        let ac = acIdleSleepMinutes.map { $0 == 0 ? "AC idle sleep: Never" : "AC idle sleep: \($0)m" } ?? "AC idle sleep unavailable"
        return "\(override) · \(ac)"
    }

    var accessibilityState: String {
        "LidSwitch, \(statusTitle). \(statusDetail)"
    }
}
