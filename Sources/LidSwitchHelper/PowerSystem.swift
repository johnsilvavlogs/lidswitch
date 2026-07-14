import Darwin
import Foundation
import IOKit
import IOKit.ps
import LidSwitchCore

enum HelperPowerSource: Equatable {
    case ac
    case battery
    case unknown
}

/// Preserves the only runner failure that changes mutation authority.  Generic
/// command failure may be reconciled from native truth; containment-pending
/// may not be retried, restored, or treated as proof that pmset did nothing.
enum HelperPowerMutationError: Error {
    case containmentPending(ContainedProcessReceipt)
    case commandFailed(Int32, String)
}

protocol HelperPowerSystem {
    func powerSource() -> HelperPowerSource
    func sleepDisabled() -> Bool?
    func acSleepMinutes() -> Int?
    func batterySleepMinutes() -> Int?
    func setSleepDisabled(_ enabled: Bool) throws
    func setACSleepMinutes(_ minutes: Int) throws
    func setBatterySleepMinutes(_ minutes: Int) throws
}

extension HelperPowerSystem {
    // Current sessions do not touch battery sleep. Defaults preserve existing
    // test/adapter conformers while legacy recovery explicitly requires a real
    // value only when old battery evidence is present.
    func batterySleepMinutes() -> Int? { nil }
    func setBatterySleepMinutes(_ minutes: Int) throws {
        throw NSError(
            domain: "LidSwitchHelper.PowerSystem",
            code: 78,
            userInfo: [NSLocalizedDescriptionKey: "Battery sleep recovery is unavailable."]
        )
    }
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

    func batterySleepMinutes() -> Int? {
        guard let settings = preferenceValue("Battery Power") as? [String: Any] else { return nil }
        return Self.strictInt(settings["System Sleep Timer"])
    }

    func setSleepDisabled(_ enabled: Bool) throws {
        try requireSuccess(ContainedProcessRunner.run(.pmsetSleepDisabled(enabled)))
    }

    func setACSleepMinutes(_ minutes: Int) throws {
        try requireValidMinutes(minutes)
        try requireSuccess(ContainedProcessRunner.run(.pmsetACSleep(minutes)))
    }

    func setBatterySleepMinutes(_ minutes: Int) throws {
        try requireValidMinutes(minutes)
        try requireSuccess(ContainedProcessRunner.run(.pmsetBatterySleep(minutes)))
    }

    private func requireSuccess(_ result: ContainedProcessResult) throws {
        if case .containmentPending = result.outcome,
           let receipt = result.containmentReceipt {
            throw HelperPowerMutationError.containmentPending(receipt)
        }
        guard result.outcome == .completed, result.exitCode == 0 else {
            throw HelperPowerMutationError.commandFailed(result.exitCode, result.stderr)
        }
    }

    private func requireValidMinutes(_ minutes: Int) throws {
        guard (0...1_440).contains(minutes) else {
            throw NSError(
                domain: "LidSwitchHelper.PowerSystem",
                code: 64,
                userInfo: [NSLocalizedDescriptionKey: "Sleep minutes are outside the fixed safe range."]
            )
        }
    }

    private static func currentPreferenceValue(_ key: String) -> Any? {
        // Configured AC sleep is persisted here. SleepDisabled is deliberately
        // not read from preferences: it is live override state and must come
        // from IOPMrootDomain so external/powerd drift is observed immediately.
        guard CFPreferencesSynchronize(
            powerManagementDomain as CFString,
            kCFPreferencesAnyUser,
            kCFPreferencesCurrentHost
        ) else { return nil }
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

}
