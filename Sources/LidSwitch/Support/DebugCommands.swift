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
            let helperLoaded = PowerInspector.helperInstalled()
            let helperArtifactsPresent = PowerInspector.artifactsPresent()
            let helperArtifactsNeedUpdate = PowerInspector.helperNeedsUpdate(
                helperArtifactsPresent: helperArtifactsPresent,
                helperLoaded: helperLoaded
            )
            let snapshot = PowerInspector.snapshot()
            print("helperArtifactsPresent=\(helperArtifactsPresent)")
            print("helperLoaded=\(helperLoaded)")
            print("helperReady=\(snapshot.helperReady)")
            print("helperNeedsUpdate=\(helperArtifactsNeedUpdate)")
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
        let version = Shell.run("/bin/cat", [AppPaths.rootHelperVersionPath]).stdout
        return version.trimmingCharacters(in: .whitespacesAndNewlines) == AppPaths.helperVersion
    }
}
