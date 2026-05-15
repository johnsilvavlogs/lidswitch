import Darwin
import Foundation

enum DebugCommands {
    static func handleIfNeeded() {
        guard let command = CommandLine.arguments.dropFirst().first else {
            return
        }

        switch command {
        case "--print-helper":
            print(PrivilegedHelperManager.diagnosticHelperScript())
            exit(0)
        case "--print-plist":
            print(PrivilegedHelperManager.diagnosticLaunchDaemonPlist())
            exit(0)
        case "--print-install-script":
            print(PrivilegedHelperManager.diagnosticInstallScript(initiallyEnabled: true))
            exit(0)
        case "--print-uninstall-script":
            print(PrivilegedHelperManager.diagnosticUninstallScript())
            exit(0)
        default:
            return
        }
    }
}
