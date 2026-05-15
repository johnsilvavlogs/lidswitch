import Foundation

enum AppPaths {
    static let appName = "LidSwitch"
    static let bundleIdentifier = "com.johnsilva.LidSwitch"
    static let helperLabel = "com.johnsilva.lidswitch.helper"

    static var userSupportDirectory: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LidSwitch", isDirectory: true)
    }

    static var desiredStateFile: URL {
        userSupportDirectory.appendingPathComponent("desired-state", isDirectory: false)
    }

    static let rootSupportDirectory = "/Library/Application Support/LidSwitch"
    static let rootHelperPath = "/Library/Application Support/LidSwitch/lidswitch-helper"
    static let rootOriginalACSleepPath = "/Library/Application Support/LidSwitch/original-ac-sleep"
    static let launchDaemonPath = "/Library/LaunchDaemons/com.johnsilva.lidswitch.helper.plist"
}
