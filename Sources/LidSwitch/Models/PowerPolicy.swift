import Foundation

struct PowerPolicyDecision: Equatable {
    var sleepDisabledShouldBeOn: Bool
    var acSleepShouldBeNever: Bool
    var batterySleepShouldBeNever: Bool
    var restoreACSleep: Bool
    var restoreBatterySleep: Bool
}

enum PowerPolicy {
    static func decision(
        preferences: PowerPreferences,
        source: PowerSource
    ) -> PowerPolicyDecision {
        guard preferences.keepAwakeEnabled else {
            return PowerPolicyDecision(
                sleepDisabledShouldBeOn: false,
                acSleepShouldBeNever: false,
                batterySleepShouldBeNever: false,
                restoreACSleep: true,
                restoreBatterySleep: true
            )
        }

        switch source {
        case .ac:
            return PowerPolicyDecision(
                sleepDisabledShouldBeOn: true,
                acSleepShouldBeNever: true,
                batterySleepShouldBeNever: preferences.allowBatteryKeepAwake,
                restoreACSleep: false,
                restoreBatterySleep: !preferences.allowBatteryKeepAwake
            )
        case .battery:
            return PowerPolicyDecision(
                sleepDisabledShouldBeOn: preferences.allowBatteryKeepAwake,
                acSleepShouldBeNever: false,
                batterySleepShouldBeNever: preferences.allowBatteryKeepAwake,
                restoreACSleep: false,
                restoreBatterySleep: !preferences.allowBatteryKeepAwake
            )
        case .unknown:
            return PowerPolicyDecision(
                sleepDisabledShouldBeOn: false,
                acSleepShouldBeNever: false,
                batterySleepShouldBeNever: false,
                restoreACSleep: false,
                restoreBatterySleep: !preferences.allowBatteryKeepAwake
            )
        }
    }
}
