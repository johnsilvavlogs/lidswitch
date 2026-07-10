import Foundation
import LidSwitchCore

enum PowerSource: Equatable {
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

struct HelperStatusRecord: Equatable, Sendable {
    let state: String
    let reason: String
    let sessionID: UUID?
    let updatedAt: Date

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
            updatedAt: Date(timeIntervalSince1970: updatedSeconds)
        )
    }

    func isFresh(at date: Date) -> Bool {
        let age = date.timeIntervalSince(updatedAt)
        return age >= -2 && age <= 12
    }
}

struct PowerSnapshot: Equatable {
    let source: PowerSource
    let sleepDisabled: Bool
    let sleepDisabledVerified: Bool
    let acIdleSleepMinutes: Int?
    let preferences: PowerPreferences
    let helperArtifactsPresent: Bool
    let helperLoaded: Bool
    let helperNeedsUpdate: Bool
    let legacyLoginItemPresent: Bool
    let legacyLoginItemLoaded: Bool
    let activationLease: ActivationLease?
    let ownedSessionID: UUID?
    let helperStatus: HelperStatusRecord?
    let systemBuild: String?
    let systemBuildQualified: Bool
    let bundleIntegrityValid: Bool
    let bundleVersionValid: Bool
    let checkedAt: Date

    static let empty = PowerSnapshot(
        source: .unknown(""),
        sleepDisabled: false,
        sleepDisabledVerified: false,
        acIdleSleepMinutes: nil,
        preferences: .disabled,
        helperArtifactsPresent: false,
        helperLoaded: false,
        helperNeedsUpdate: false,
        legacyLoginItemPresent: false,
        legacyLoginItemLoaded: false,
        activationLease: nil,
        ownedSessionID: nil,
        helperStatus: nil,
        systemBuild: nil,
        systemBuildQualified: false,
        bundleIntegrityValid: false,
        bundleVersionValid: false,
        checkedAt: .distantPast
    )

    var helperReady: Bool {
        helperArtifactsPresent && helperLoaded && !helperNeedsUpdate
    }

    var legacyResiduePresent: Bool {
        legacyLoginItemPresent
            || legacyLoginItemLoaded
            || (helperArtifactsPresent && helperNeedsUpdate)
            || preferences.keepAwakeEnabled
            || preferences.allowBatteryKeepAwake
    }

    var sessionActive: Bool {
        guard let lease = activationLease,
              let ownedSessionID,
              lease.sessionID == ownedSessionID
        else { return false }
        return source.isAC
            && sleepDisabledVerified
            && sleepDisabled
            && helperStatus?.state == "active"
            && helperStatus?.sessionID == lease.sessionID
            && helperStatus?.isFresh(at: checkedAt) == true
    }

    var sessionPending: Bool {
        guard let lease = activationLease, lease.sessionID == ownedSessionID else { return false }
        return !sessionActive
    }

    var helperRecoveryRequired: Bool {
        helperStatus?.state == "recovery-required"
    }

    var orphanedLeasePresent: Bool {
        guard let lease = activationLease else { return false }
        return lease.sessionID != ownedSessionID
    }

    var restoreRequired: Bool {
        helperRecoveryRequired
            || orphanedLeasePresent
            || (sleepDisabledVerified && sleepDisabled && !sessionActive)
    }

    var hasCriticalSafetyIssue: Bool {
        restoreRequired
            || !sleepDisabledVerified
            || !bundleVersionValid
            || !bundleIntegrityValid
            || !systemBuildQualified
            || legacyResiduePresent
    }

    var canPrepareHelper: Bool {
        systemBuildQualified && bundleIntegrityValid && bundleVersionValid
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
            && activationLease == nil
            && !helperRecoveryRequired
    }

    var statusTitle: String {
        if helperRecoveryRequired {
            return "Recovery required"
        }
        if restoreRequired {
            return "Restore required"
        }
        if !sleepDisabledVerified {
            return "Power status unavailable"
        }
        if !bundleVersionValid || !bundleIntegrityValid {
            return "Build verification failed"
        }
        if !systemBuildQualified {
            return "Compatibility not confirmed"
        }
        if legacyResiduePresent {
            return "Old startup files found"
        }
        if sessionActive {
            return "Protection active — plugged in"
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
        if helperArtifactsPresent || helperLoaded {
            return "Helper update required"
        }
        return "Protection off"
    }

    var statusDetail: String {
        if helperRecoveryRequired {
            return "The helper could not verify a complete rollback. Use Restore Sleep before starting another session or quitting."
        }
        if restoreRequired {
            return "LidSwitch is inactive, but macOS still reports an active system sleep override. Restore it before doing anything else."
        }
        if !sleepDisabledVerified {
            return "LidSwitch could not verify the live macOS sleep override. Starting a session is blocked."
        }
        if !bundleVersionValid || !bundleIntegrityValid {
            return "This copy of LidSwitch cannot safely control power settings. Protection remains off."
        }
        if !systemBuildQualified {
            return "This macOS build has not passed LidSwitch safety checks. Protection remains off."
        }
        if legacyResiduePresent {
            return "Disabled legacy components remain on this Mac. Replace them before starting a new session."
        }
        if sessionActive {
            return "Lid-close sleep is blocked for this session. Quit, unplug, restart, or a missed safety check ends it."
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
