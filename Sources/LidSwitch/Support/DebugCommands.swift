import Darwin
import Foundation

enum DebugCommands {
    static func handleIfNeeded() {
        guard let command = CommandLine.arguments.dropFirst().first else {
            return
        }

        switch command {
        case "--print-helper":
            print(AppPaths.bundledHelperFile.path)
            exit(0)
        case "--print-plist":
            print(PrivilegedHelperManager.diagnosticLaunchDaemonPlist())
            exit(0)
        case "--print-install-script":
            print(PrivilegedHelperManager.diagnosticInstallScript())
            exit(0)
        case "--print-uninstall-script":
            print(PrivilegedHelperManager.diagnosticUninstallScript())
            exit(0)
        case "--print-restore-script":
            print(PrivilegedHelperManager.diagnosticRestoreScript())
            exit(0)
        case "--print-helper-status":
            let snapshot = PowerInspector.snapshot(inspectionPolicy: .forceFresh)
            print("helperArtifactsPresent=\(snapshot.helperArtifactsPresent)")
            print("helperLoaded=\(snapshot.helperLoaded)")
            print("helperReady=\(snapshot.helperReady)")
            print("helperNeedsUpdate=\(snapshot.helperNeedsUpdate)")
            print("helperVersionMatch=\(helperVersionMatches())")
            print("legacyResiduePresent=\(snapshot.legacyResiduePresent)")
            print("sessionActive=\(snapshot.sessionActive)")
            print("sessionPending=\(snapshot.sessionPending)")
            print("sleepDisabled=\(snapshot.sleepDisabled)")
            print("sleepDisabledVerified=\(snapshot.sleepDisabledVerified)")
            exit(0)
        default:
            return
        }
    }

    private static func helperVersionMatches() -> Bool {
        let result = Shell.run(.rootFileContents(AppPaths.rootHelperVersionPath, maximumOutputBytes: 256))
        guard result.outcome == .completed, result.exitCode == 0,
              !result.stdout.contains("[output truncated]") else { return false }
        let version = result.stdout
        return version.trimmingCharacters(in: .whitespacesAndNewlines) == AppPaths.helperVersion
    }
}
