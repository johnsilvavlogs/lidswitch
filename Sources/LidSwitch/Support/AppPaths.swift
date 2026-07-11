import Foundation

enum AppPaths {
    static let appName = "LidSwitch"
    static let appVersion = "0.2.8"
    static let appBuild = "1"
    static let bundleIdentifier = "com.johnsilva.LidSwitch"
    static let helperLabel = "com.johnsilva.lidswitch.helper"
    static let helperVersion = "3"
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

    static let rootSupportDirectory = "/Library/Application Support/LidSwitch"
    static let rootHelperPath = "/Library/Application Support/LidSwitch/LidSwitchHelper"
    static let legacyRootHelperPath = "/Library/Application Support/LidSwitch/lidswitch-helper"
    static let rootHelperVersionPath = "/Library/Application Support/LidSwitch/helper-version"
    static let rootOriginalACSleepPath = "/Library/Application Support/LidSwitch/original-ac-sleep"
    static let rootOriginalBatterySleepPath = "/Library/Application Support/LidSwitch/original-battery-sleep"
    static let rootAppliedStatePath = "/Library/Application Support/LidSwitch/applied-state"
    static let rootHelperStatusPath = "/Library/Application Support/LidSwitch/helper-status"
    static let rootTerminalGenerationsPath = "/Library/Application Support/LidSwitch/terminal-generations"
    static let launchDaemonPath = "/Library/LaunchDaemons/com.johnsilva.lidswitch.helper.plist"
}
