import Darwin
import Foundation
import IOKit.ps

enum HelperPowerSource: Equatable {
    case ac
    case battery
    case unknown
}

protocol HelperPowerSystem {
    func powerSource() -> HelperPowerSource
    func sleepDisabled() -> Bool?
    func acSleepMinutes() -> Int?
    func setSleepDisabled(_ enabled: Bool) throws
    func setACSleepMinutes(_ minutes: Int) throws
}

struct SystemPowerSystem: HelperPowerSystem {
    func powerSource() -> HelperPowerSource {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let source = IOPSGetProvidingPowerSourceType(snapshot).takeUnretainedValue() as String
        if source == kIOPMACPowerKey { return .ac }
        if source == kIOPMBatteryPowerKey { return .battery }
        return .unknown
    }

    func sleepDisabled() -> Bool? {
        let result = run("/usr/bin/pmset", ["-g", "live"])
        guard result.exitCode == 0 else { return nil }
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.first == "SleepDisabled", parts.count >= 2 {
                if parts[1] == "1" { return true }
                if parts[1] == "0" { return false }
                return nil
            }
        }
        return nil
    }

    func acSleepMinutes() -> Int? {
        let result = run("/usr/bin/pmset", ["-g", "custom"])
        guard result.exitCode == 0 else { return nil }
        var inAC = false
        for line in result.stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "AC Power:" { inAC = true; continue }
            if trimmed == "Battery Power:" { inAC = false; continue }
            let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if inAC, parts.first == "sleep", parts.count >= 2 {
                return Int(parts[1])
            }
        }
        return nil
    }

    func setSleepDisabled(_ enabled: Bool) throws {
        try requireSuccess(run("/usr/bin/pmset", ["-a", "disablesleep", enabled ? "1" : "0"]))
    }

    func setACSleepMinutes(_ minutes: Int) throws {
        try requireSuccess(run("/usr/bin/pmset", ["-c", "sleep", String(minutes)]))
    }

    private func requireSuccess(_ result: ProcessResult) throws {
        guard result.exitCode == 0 else {
            throw NSError(
                domain: "LidSwitchHelper.PowerSystem",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: result.stderr]
            )
        }
    }

    // Reconciliation may need several pmset reads plus one write. A one-second
    // bound keeps the owned-drift recovery transaction below its ten-second
    // session safety deadline even when pmset is unhealthy.
    private func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 1) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return ProcessResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            usleep(100_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}

private struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}
