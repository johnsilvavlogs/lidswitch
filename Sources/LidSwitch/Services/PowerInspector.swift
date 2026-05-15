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
        if launchd.exitCode == 0 {
            return true
        }

        return FileManager.default.fileExists(atPath: AppPaths.launchDaemonPath)
    }

    static func helperNeedsUpdate(helperInstalled: Bool) -> Bool {
        guard helperInstalled else {
            return false
        }

        let result = Shell.run("/bin/cat", [AppPaths.rootHelperVersionPath])
        let installedVersion = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return installedVersion != AppPaths.helperVersion
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
