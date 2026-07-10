import Darwin
import Foundation
import LidSwitchCore

enum PowerInspector {
    private static let bundleValidation = validateBundle()

    static func snapshot(ownedSessionID: UUID? = nil) -> PowerSnapshot {
        let battery = Shell.run("/usr/bin/pmset", ["-g", "batt"])
        let live = Shell.run("/usr/bin/pmset", ["-g", "live"])
        let custom = Shell.run("/usr/bin/pmset", ["-g", "custom"])
        let parsedSleepDisabled = live.exitCode == 0 ? parseSleepDisabled(from: live.stdout) : nil
        let helperLoaded = helperInstalled()
        let helperArtifactsPresent = artifactsPresent()
        let systemBuild = SystemBuild.current()
        let lease = validActivationLease(systemBuild: systemBuild)

        return PowerSnapshot(
            source: battery.exitCode == 0 ? parsePowerSource(from: battery.stdout) : .unknown("pmset failed"),
            sleepDisabled: parsedSleepDisabled ?? false,
            sleepDisabledVerified: parsedSleepDisabled != nil,
            acIdleSleepMinutes: custom.exitCode == 0 ? parseACIdleSleep(from: custom.stdout) : nil,
            preferences: DesiredStateStore.readPreferences(),
            helperArtifactsPresent: helperArtifactsPresent,
            helperLoaded: helperLoaded,
            helperNeedsUpdate: helperNeedsUpdate(
                helperArtifactsPresent: helperArtifactsPresent,
                helperLoaded: helperLoaded
            ),
            legacyLoginItemPresent: FileManager.default.fileExists(atPath: AppPaths.legacyLoginAgentFile.path),
            legacyLoginItemLoaded: LegacyAutostartManager.isLoaded(),
            activationLease: lease,
            ownedSessionID: ownedSessionID,
            helperStatus: helperStatus(),
            systemBuild: systemBuild,
            systemBuildQualified: systemBuild.map(CompatibilityPolicy.isQualified) ?? false,
            bundleIntegrityValid: bundleValidation.integrity,
            bundleVersionValid: bundleValidation.version,
            checkedAt: Date()
        )
    }

    static func helperInstalled() -> Bool {
        Shell.run("/bin/launchctl", ["print", "system/\(AppPaths.helperLabel)"]).exitCode == 0
    }

    static func artifactsPresent() -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: AppPaths.rootHelperPath)
            || manager.fileExists(atPath: AppPaths.legacyRootHelperPath)
            || manager.fileExists(atPath: AppPaths.launchDaemonPath)
            || manager.fileExists(atPath: AppPaths.rootHelperVersionPath)
            || manager.fileExists(atPath: AppPaths.rootAppliedStatePath)
            || manager.fileExists(atPath: AppPaths.rootHelperStatusPath)
            || manager.fileExists(atPath: AppPaths.rootOriginalACSleepPath)
            || manager.fileExists(atPath: AppPaths.rootOriginalBatterySleepPath)
    }

    static func helperNeedsUpdate(helperArtifactsPresent: Bool, helperLoaded: Bool) -> Bool {
        guard helperArtifactsPresent else { return false }
        guard helperLoaded,
              readFile(AppPaths.rootHelperVersionPath)?.trimmingCharacters(in: .whitespacesAndNewlines) == AppPaths.helperVersion,
              artifact(readFile(AppPaths.launchDaemonPath), matches: PrivilegedHelperManager.diagnosticLaunchDaemonPlist()),
              filesMatch(AppPaths.rootHelperPath, AppPaths.bundledHelperFile.path),
              !FileManager.default.fileExists(atPath: AppPaths.legacyRootHelperPath)
        else {
            return true
        }
        return false
    }

    static func parsePowerSource(from output: String) -> PowerSource {
        if output.contains("Now drawing from 'AC Power'") { return .ac }
        if output.contains("Now drawing from 'Battery Power'") {
            return .battery(percent: parseBatteryPercent(from: output))
        }
        return .unknown(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func parseSleepDisabled(from output: String) -> Bool? {
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.first == "SleepDisabled", parts.count >= 2 {
                if parts[1] == "1" { return true }
                if parts[1] == "0" { return false }
                return nil
            }
        }
        return nil
    }

    static func parseACIdleSleep(from output: String) -> Int? {
        var inAC = false
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "AC Power:" { inAC = true; continue }
            if trimmed == "Battery Power:" { inAC = false; continue }
            let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if inAC, parts.first == "sleep", parts.count >= 2 { return Int(parts[1]) }
        }
        return nil
    }

    private static func parseBatteryPercent(from output: String) -> Int? {
        guard let range = output.range(of: #"(\d+)%"#, options: .regularExpression) else { return nil }
        return Int(output[range].dropLast())
    }

    private static func validActivationLease(systemBuild: String?) -> ActivationLease? {
        guard let lease = ActivationLeaseStore.read(),
              let bootID = BootIdentity.current(),
              let systemBuild,
              lease.validationFailure(
                now: Date(),
                nowMonotonic: MonotonicClock.seconds(),
                currentBootID: bootID,
                expectedOwnerUID: getuid(),
                currentSystemBuild: systemBuild
              ) == nil
        else {
            return nil
        }
        return lease
    }

    private static func helperStatus() -> HelperStatusRecord? {
        var status = stat()
        guard lstat(AppPaths.rootHelperStatusPath, &status) == 0,
              status.st_uid == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_size >= 0,
              status.st_size <= 4_096,
              let raw = readFile(AppPaths.rootHelperStatusPath)
        else { return nil }
        return HelperStatusRecord.parse(raw)
    }

    private static func readFile(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    private static func artifact(_ installed: String?, matches expected: String) -> Bool {
        installed?.trimmingCharacters(in: .newlines) == expected.trimmingCharacters(in: .newlines)
    }

    private static func filesMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = FileManager.default.contents(atPath: lhs),
              let right = FileManager.default.contents(atPath: rhs)
        else {
            return false
        }
        return left == right
    }

    private static func validateBundle() -> (integrity: Bool, version: Bool) {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app" else {
            return (false, false)
        }
        let signature = Shell.run(
            "/usr/bin/codesign",
            ["--verify", "--deep", "--strict", "--verbose=2", bundle.bundleURL.path]
        )
        let versionMatches = bundle.bundleIdentifier == AppPaths.bundleIdentifier
            && bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == AppPaths.appVersion
            && bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == AppPaths.appBuild
        return (signature.exitCode == 0, versionMatches)
    }
}
