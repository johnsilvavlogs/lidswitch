import Foundation
import LidSwitchCore

enum AppPaths {
    static let appName = "LidSwitch"
    static let appVersion = ReleaseIdentity.appVersion
    static let appBuild = ReleaseIdentity.appBuild
    static let bundleIdentifier = ReleaseIdentity.appBundleIdentifier
    static let helperLabel = ReleaseIdentity.helperLabel
    static let helperVersion = ReleaseIdentity.helperVersion
    static let legacyLoginLabel = "com.johnsilva.LidSwitch.login"

    static var userSupportDirectory: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LidSwitch", isDirectory: true)
    }

    static var desiredStateFile: URL {
        userSupportDirectory.appendingPathComponent("desired-state", isDirectory: false)
    }

    static var activationLeaseFile: URL {
        userSupportDirectory.appendingPathComponent("activation-lease", isDirectory: false)
    }

    static var sessionHistoryFile: URL {
        userSupportDirectory.appendingPathComponent("session-history.json", isDirectory: false)
    }

    static var legacyLoginAgentFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.johnsilva.LidSwitch.login.plist", isDirectory: false)
    }

    static var bundledHelperFile: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchServices/LidSwitchHelper", isDirectory: false)
    }

    static let rootSupportDirectory = ReleaseIdentity.rootSupportDirectory
    static let rootCurrentDirectory = "/Library/Application Support/LidSwitch/Current"
    static let rootPreviousDirectory = "/Library/Application Support/LidSwitch/Previous"
    static let rootHelperPath = ReleaseIdentity.rootHelperPath
    static let legacyV4RootHelperPath = "/Library/Application Support/LidSwitch/LidSwitchHelper"
    static let legacyRootHelperPath = "/Library/Application Support/LidSwitch/lidswitch-helper"
    static let legacyV4RootHelperVersionPath = "/Library/Application Support/LidSwitch/helper-version"
    static let rootHelperVersionPath = "/Library/Application Support/LidSwitch/Current/helper-version"
    static let rootEnrollmentPolicyPath = ReleaseIdentity.rootEnrollmentPolicyPath
    static let rootOriginalACSleepPath = "/Library/Application Support/LidSwitch/original-ac-sleep"
    static let rootOriginalBatterySleepPath = "/Library/Application Support/LidSwitch/original-battery-sleep"
    static let rootAppliedStatePath = ReleaseIdentity.rootAppliedStatePath
    static let rootHelperStatusPath = ReleaseIdentity.rootStatusPath
    static let rootTerminalGenerationsPath = "/Library/Application Support/LidSwitch/terminal-generations"
    static let rootRecoveryReservationsPath = "/Library/Application Support/LidSwitch/recovery-reservations"
    static let rootRecoveryProofPath = "/Library/Application Support/LidSwitch/recovery-proof"
    static let rootStateLockPath = "/Library/Application Support/LidSwitch/root-state.lock"
    static let administratorReceiptPrefix = "administrator-transaction-"
    static let launchDaemonPath = "/Library/LaunchDaemons/com.johnsilva.lidswitch.helper.plist"
    static let helperMachService = ReleaseIdentity.machService

    static func administratorReceiptPath(transactionID: UUID) -> String {
        rootSupportDirectory + "/" + administratorReceiptPrefix
            + transactionID.uuidString.lowercased() + ".receipt"
    }
}
