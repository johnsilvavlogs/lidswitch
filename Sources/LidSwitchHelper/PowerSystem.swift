import Darwin
import Foundation
import IOKit
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
    private static let powerManagementDomain = "com.apple.PowerManagement"

    private let liveSleepDisabledValue: () -> Any?
    private let preferenceValue: (String) -> Any?

    init(
        liveSleepDisabledValue: @escaping () -> Any? = SystemPowerSystem.currentLiveSleepDisabledValue,
        preferenceValue: @escaping (String) -> Any? = SystemPowerSystem.currentPreferenceValue
    ) {
        self.liveSleepDisabledValue = liveSleepDisabledValue
        self.preferenceValue = preferenceValue
    }

    func powerSource() -> HelperPowerSource {
        guard let unmanagedSnapshot = IOPSCopyPowerSourcesInfo() else { return .unknown }
        let snapshot = unmanagedSnapshot.takeRetainedValue()
        guard let unmanagedSource = IOPSGetProvidingPowerSourceType(snapshot) else { return .unknown }
        let source = unmanagedSource.takeUnretainedValue() as String
        if source == kIOPMACPowerKey { return .ac }
        if source == kIOPMBatteryPowerKey { return .battery }
        return .unknown
    }

    func sleepDisabled() -> Bool? {
        Self.strictBool(liveSleepDisabledValue())
    }

    func acSleepMinutes() -> Int? {
        guard let settings = preferenceValue("AC Power") as? [String: Any] else { return nil }
        return Self.strictInt(settings["System Sleep Timer"])
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

    private static func currentPreferenceValue(_ key: String) -> Any? {
        // Configured AC sleep is persisted here. SleepDisabled is deliberately
        // not read from preferences: it is live override state and must come
        // from IOPMrootDomain so external/powerd drift is observed immediately.
        _ = CFPreferencesSynchronize(
            powerManagementDomain as CFString,
            kCFPreferencesAnyUser,
            kCFPreferencesCurrentHost
        )
        return CFPreferencesCopyValue(
            key as CFString,
            powerManagementDomain as CFString,
            kCFPreferencesAnyUser,
            kCFPreferencesCurrentHost
        )
    }

    private static func currentLiveSleepDisabledValue() -> Any? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(
            service,
            "SleepDisabled" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
    }

    static func strictBool(_ raw: Any?) -> Bool? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    static func strictInt(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let value = number.doubleValue
        guard value.isFinite,
              value.rounded(.towardZero) == value,
              value >= 0,
              value <= Double(Int32.max)
        else { return nil }
        return Int(value)
    }

    // Only mutations use pmset. TERM/KILL are issued on a short deadline, but
    // ownership is never discarded while a mutation could still land later.
    // After SIGKILL we therefore wait for authoritative child termination;
    // active-session reads never enter this path and remain subprocess-free.
    private func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 1) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            let terminated = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in terminated.signal() }
            try process.run()
            if terminated.wait(timeout: .now() + timeout) == .timedOut {
                process.terminate()
                if terminated.wait(timeout: .now() + 0.1) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    if terminated.wait(timeout: .now() + 0.25) == .timedOut {
                        // A return here could let a delayed privileged mutation
                        // outlive applied-state ownership. Waiting is safer than
                        // falsely publishing inactive/safe state.
                        process.waitUntilExit()
                    }
                }
            }
        } catch {
            return ProcessResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }
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
