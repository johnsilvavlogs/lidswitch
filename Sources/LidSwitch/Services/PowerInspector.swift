import Foundation

enum PowerInspector {
    static func snapshot() -> PowerSnapshot {
        let battery = Shell.run("/usr/bin/pmset", ["-g", "batt"]).stdout
        let live = Shell.run("/usr/bin/pmset", ["-g", "live"]).stdout
        let custom = Shell.run("/usr/bin/pmset", ["-g", "custom"]).stdout
        let helperInstalled = helperInstalled()

        return PowerSnapshot(
            source: parsePowerSource(from: battery),
            sleepDisabled: parseSleepDisabled(from: live),
            acIdleSleepMinutes: parseACIdleSleep(from: custom),
            batteryIdleSleepMinutes: parseBatteryIdleSleep(from: custom),
            preferences: DesiredStateStore.readPreferences(),
            helperInstalled: helperInstalled,
            helperNeedsUpdate: helperNeedsUpdate(helperInstalled: helperInstalled),
            checkedAt: Date()
        )
    }

    static func helperInstalled() -> Bool {
        let launchd = Shell.run("/bin/launchctl", ["print", "system/\(AppPaths.helperLabel)"])
        return launchd.exitCode == 0
    }

    static func helperNeedsUpdate(helperInstalled: Bool) -> Bool {
        guard helperInstalled else {
            return false
        }

        let result = Shell.run("/bin/cat", [AppPaths.rootHelperVersionPath])
        return helperNeedsUpdate(
            helperInstalled: helperInstalled,
            installedVersion: result.stdout,
            installedHelperScript: readFile(AppPaths.rootHelperPath),
            installedLaunchDaemonPlist: readFile(AppPaths.launchDaemonPath)
        )
    }

    static func helperNeedsUpdate(
        helperInstalled: Bool,
        installedVersion: String?,
        installedHelperScript: String?,
        installedLaunchDaemonPlist: String?
    ) -> Bool {
        guard helperInstalled else {
            return false
        }

        guard installedVersion?.trimmingCharacters(in: .whitespacesAndNewlines) == AppPaths.helperVersion else {
            return true
        }

        guard artifact(installedHelperScript, matches: PrivilegedHelperManager.diagnosticHelperScript()) else {
            return true
        }

        guard artifact(installedLaunchDaemonPlist, matches: PrivilegedHelperManager.diagnosticLaunchDaemonPlist()) else {
            return true
        }

        return false
    }

    private static func readFile(_ path: String) -> String? {
        let result = Shell.run("/bin/cat", [path])
        guard result.exitCode == 0 else {
            return nil
        }

        return result.stdout
    }

    private static func artifact(_ installed: String?, matches expected: String) -> Bool {
        installed?.trimmingCharacters(in: .newlines) == expected.trimmingCharacters(in: .newlines)
    }

    static func parsePowerSource(from output: String) -> PowerSource {
        if output.contains("Now drawing from 'AC Power'") {
            return .ac
        }

        if output.contains("Now drawing from 'Battery Power'") {
            return .battery(percent: parseBatteryPercent(from: output))
        }

        return .unknown(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func parseBatteryPercent(from output: String) -> Int? {
        guard let percentRange = output.range(of: #"(\d+)%"#, options: .regularExpression) else {
            return nil
        }

        let raw = output[percentRange].dropLast()
        return Int(raw)
    }

    static func parseSleepDisabled(from output: String) -> Bool {
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.first == "SleepDisabled", parts.count >= 2 else {
                continue
            }

            return parts[1] == "1"
        }

        return false
    }

    static func parseACIdleSleep(from output: String) -> Int? {
        var inACSection = false

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "AC Power:" {
                inACSection = true
                continue
            }

            if trimmed == "Battery Power:" {
                inACSection = false
                continue
            }

            guard inACSection else {
                continue
            }

            let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.first == "sleep", parts.count >= 2 else {
                continue
            }

            return Int(parts[1])
        }

        return nil
    }

    static func parseBatteryIdleSleep(from output: String) -> Int? {
        var inBatterySection = false

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "Battery Power:" {
                inBatterySection = true
                continue
            }

            if trimmed == "AC Power:" {
                inBatterySection = false
                continue
            }

            guard inBatterySection else {
                continue
            }

            let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.first == "sleep", parts.count >= 2 else {
                continue
            }

            return Int(parts[1])
        }

        return nil
    }
}
