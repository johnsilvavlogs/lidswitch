import Darwin
import Foundation
import IOKit
import LidSwitchCore

enum PowerInspector {
    private static let bundleValidation = validateBundle()
    private static let powerManagementDomain = "com.apple.PowerManagement"

    static func snapshot(ownedSessionID: UUID? = nil) -> PowerSnapshot {
        let source = nativePowerSource()
        let parsedSleepDisabled = nativeSleepDisabled()
        let helperLoaded = helperInstalled()
        let helperArtifactsPresent = artifactsPresent()
        let systemBuild = SystemBuild.current()
        let lease = validActivationLease(systemBuild: systemBuild)

        return PowerSnapshot(
            source: source,
            sleepDisabled: parsedSleepDisabled ?? false,
            sleepDisabledVerified: parsedSleepDisabled != nil,
            acIdleSleepMinutes: nativeACIdleSleep(),
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
            || manager.fileExists(atPath: AppPaths.rootTerminalGenerationsPath)
            || manager.fileExists(atPath: AppPaths.rootOriginalACSleepPath)
            || manager.fileExists(atPath: AppPaths.rootOriginalBatterySleepPath)
    }

    static func helperNeedsUpdate(helperArtifactsPresent: Bool, helperLoaded: Bool) -> Bool {
        guard helperArtifactsPresent else { return false }
        guard helperLoaded,
              readFile(AppPaths.rootHelperVersionPath)?.trimmingCharacters(in: .whitespacesAndNewlines) == AppPaths.helperVersion,
              artifact(readFile(AppPaths.launchDaemonPath), matches: PrivilegedHelperManager.diagnosticLaunchDaemonPlist()),
              filesMatch(AppPaths.rootHelperPath, AppPaths.bundledHelperFile.path),
              terminalGenerationsValid(),
              !FileManager.default.fileExists(atPath: AppPaths.legacyRootHelperPath)
        else {
            return true
        }
        return false
    }

    static func terminalGenerationsValid(
        path: String = AppPaths.rootTerminalGenerationsPath,
        expectedOwnerUID: uid_t = 0
    ) -> Bool {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_uid == expectedOwnerUID,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_mode & (S_IWGRP | S_IWOTH) == 0,
              status.st_size >= 0,
              status.st_size <= TerminalGenerationLedger.maximumBytes
        else { return false }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while data.count <= TerminalGenerationLedger.maximumBytes {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 { data.append(buffer, count: count); continue }
            if count == 0 { break }
            if errno == EINTR { continue }
            return false
        }
        guard data.count <= TerminalGenerationLedger.maximumBytes,
              let raw = String(data: data, encoding: .utf8)
        else { return false }
        return TerminalGenerationLedger.parse(raw) != nil
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

    private static func nativePowerSource() -> PowerSource {
        guard let unmanagedInfo = IOPSCopyPowerSourcesInfo() else {
            return .unknown("IOKit power source unavailable")
        }
        let info = unmanagedInfo.takeRetainedValue()
        guard let unmanagedSource = IOPSGetProvidingPowerSourceType(info) else {
            return .unknown("IOKit power source unavailable")
        }
        let source = unmanagedSource.takeUnretainedValue() as String
        if source == kIOPMACPowerKey { return .ac }
        guard source == kIOPMBatteryPowerKey else {
            return .unknown(source)
        }

        guard let unmanagedSources = IOPSCopyPowerSourcesList(info) else {
            return .battery(percent: nil)
        }
        let sources = unmanagedSources.takeRetainedValue() as NSArray
        var descriptions: [[String: Any]] = []
        for source in sources {
            guard let unmanagedDescription = IOPSGetPowerSourceDescription(info, source as CFTypeRef) else {
                continue
            }
            guard let description = unmanagedDescription.takeUnretainedValue() as? [String: Any] else { continue }
            descriptions.append(description)
        }
        return .battery(percent: internalBatteryPercent(from: descriptions))
    }

    static func internalBatteryPercent(from descriptions: [[String: Any]]) -> Int? {
        var currentTotal = 0.0
        var maximumTotal = 0.0
        for description in descriptions {
            guard (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? NSNumber,
                  let maximum = description[kIOPSMaxCapacityKey] as? NSNumber,
                  let currentValue = strictNonnegativeNumber(current),
                  let maximumValue = strictPositiveNumber(maximum),
                  currentValue <= maximumValue
            else { continue }
            currentTotal += currentValue
            maximumTotal += maximumValue
        }
        guard currentTotal.isFinite,
              maximumTotal.isFinite,
              maximumTotal > 0
        else { return nil }
        let percent = (currentTotal / maximumTotal) * 100
        guard percent.isFinite, percent >= 0, percent <= 100 else { return nil }
        return Int(percent.rounded())
    }

    private static func nativeSleepDisabled() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        let raw = IORegistryEntryCreateCFProperty(
            service,
            "SleepDisabled" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
        return strictBool(raw)
    }

    private static func nativeACIdleSleep() -> Int? {
        guard let settings = currentPowerPreference("AC Power") as? [String: Any] else { return nil }
        return strictInt(settings["System Sleep Timer"])
    }

    private static func currentPowerPreference(_ key: String) -> Any? {
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

    private static func strictNonnegativeNumber(_ number: NSNumber) -> Double? {
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite && value >= 0 ? value : nil
    }

    private static func strictPositiveNumber(_ number: NSNumber) -> Double? {
        guard let value = strictNonnegativeNumber(number), value > 0 else { return nil }
        return value
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

    static func helperStatus() -> HelperStatusRecord? {
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

    static func sessionHeartbeatObservation(sessionID: UUID) -> SessionHeartbeatObservation {
        let power: SessionHeartbeatObservation.Power
        if let unmanagedInfo = IOPSCopyPowerSourcesInfo() {
            let powerInfo = unmanagedInfo.takeRetainedValue()
            if let unmanagedSource = IOPSGetProvidingPowerSourceType(powerInfo) {
                let source = unmanagedSource.takeUnretainedValue() as String
                if source == kIOPMACPowerKey {
                    power = .ac
                } else if source == kIOPMBatteryPowerKey {
                    power = .disconnected
                } else {
                    power = .unknown
                }
            } else {
                power = .unknown
            }
        } else {
            power = .unknown
        }

        let leaseIsValid: Bool
        if let lease = ActivationLeaseStore.read(),
           lease.sessionID == sessionID,
           let bootID = BootIdentity.current(),
           let systemBuild = SystemBuild.current(),
           lease.validationFailure(
               now: Date(),
               nowMonotonic: MonotonicClock.seconds(),
               currentBootID: bootID,
               expectedOwnerUID: getuid(),
               currentSystemBuild: systemBuild
           ) == nil
        {
            leaseIsValid = true
        } else {
            leaseIsValid = false
        }

        return SessionHeartbeatObservation(
            power: power,
            leaseIsValid: leaseIsValid,
            helperStatus: helperStatus()
        )
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
