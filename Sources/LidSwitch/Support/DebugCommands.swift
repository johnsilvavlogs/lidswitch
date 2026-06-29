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
            print(PrivilegedHelperManager.diagnosticInstallScript(initialPreferences: .acOnlyEnabled))
            exit(0)
        case "--print-uninstall-script":
            print(PrivilegedHelperManager.diagnosticUninstallScript())
            exit(0)
        case "--print-helper-status":
            let helperInstalled = PowerInspector.helperInstalled()
            let installedVersion = Shell.run("/bin/cat", [AppPaths.rootHelperVersionPath]).stdout
            let installedHelperScript = fileContents(at: AppPaths.rootHelperPath)
            let installedLaunchDaemonPlist = fileContents(at: AppPaths.launchDaemonPath)
            let helperArtifactsNeedUpdate = PowerInspector.helperNeedsUpdate(
                helperInstalled: helperInstalled,
                installedVersion: installedVersion,
                installedHelperScript: installedHelperScript,
                installedLaunchDaemonPlist: installedLaunchDaemonPlist
            )
            print("helperInstalled=\(helperInstalled)")
            print("helperNeedsUpdate=\(PowerInspector.helperNeedsUpdate(helperInstalled: helperInstalled))")
            print("helperVersionMatch=\(helperVersionMatches())")
            print("helperArtifactsNeedUpdate=\(helperArtifactsNeedUpdate)")
            exit(0)
        default:
            return
        }
    }

    private static func helperVersionMatches() -> Bool {
        let version = Shell.run("/bin/cat", [AppPaths.rootHelperVersionPath]).stdout
        return version.trimmingCharacters(in: .whitespacesAndNewlines) == AppPaths.helperVersion
    }

    private static func fileContents(at path: String) -> String? {
        let result = Shell.run("/bin/cat", [path])
        guard result.exitCode == 0 else {
            return nil
        }

        return result.stdout
    }
}
