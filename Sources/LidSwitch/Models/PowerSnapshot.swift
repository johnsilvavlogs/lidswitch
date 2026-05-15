import Foundation

enum PowerSource: Equatable {
    case ac
    case battery(percent: Int?)
    case unknown(String)

    var title: String {
        switch self {
        case .ac:
            return "Power adapter"
        case .battery(let percent):
            if let percent {
                return "Battery \(percent)%"
            }
            return "Battery"
        case .unknown:
            return "Unknown"
        }
    }

    var isAC: Bool {
        if case .ac = self {
            return true
        }
        return false
    }
}

struct PowerSnapshot: Equatable {
    var source: PowerSource
    var sleepDisabled: Bool
    var acIdleSleepMinutes: Int?
    var batteryIdleSleepMinutes: Int?
    var preferences: PowerPreferences
    var helperInstalled: Bool
    var helperNeedsUpdate: Bool
    var checkedAt: Date

    static let empty = PowerSnapshot(
        source: .unknown("Not checked"),
        sleepDisabled: false,
        acIdleSleepMinutes: nil,
        batteryIdleSleepMinutes: nil,
        preferences: .disabled,
        helperInstalled: false,
        helperNeedsUpdate: false,
        checkedAt: Date()
    )

    var desiredEnabled: Bool {
        preferences.keepAwakeEnabled
    }

    var batteryKeepAwakeEnabled: Bool {
        preferences.allowBatteryKeepAwake
    }

    var statusTitle: String {
        if helperInstalled && helperNeedsUpdate {
            return "Helper update needed"
        }

        if desiredEnabled && source.isAC && sleepDisabled {
            return "Keeping awake on power"
        }

        if desiredEnabled && batteryKeepAwakeEnabled && isOnBattery && sleepDisabled {
            return "Keeping awake on battery"
        }

        if desiredEnabled && source.isAC {
            return helperInstalled ? "Turning on" : "Helper needed"
        }

        if desiredEnabled && batteryKeepAwakeEnabled && isOnBattery {
            return helperInstalled ? "Turning on battery" : "Helper needed"
        }

        if desiredEnabled && batteryKeepAwakeEnabled {
            return "Battery mode armed"
        }

        if desiredEnabled {
            return "Armed for power"
        }

        return "Normal sleep"
    }

    var statusDetail: String {
        if helperInstalled && helperNeedsUpdate {
            return "Update the helper so it can honor battery settings."
        }

        if desiredEnabled && source.isAC && sleepDisabled {
            if batteryKeepAwakeEnabled {
                return "Lid-close sleep is blocked while charging. Battery mode is also allowed."
            }

            return "Lid-close sleep is blocked while charging. Battery sleep stays normal."
        }

        if desiredEnabled && batteryKeepAwakeEnabled && isOnBattery && sleepDisabled {
            return "Lid-close sleep is blocked on battery. Watch remaining charge."
        }

        if desiredEnabled && source.isAC {
            return "Waiting for the helper to apply the AC profile."
        }

        if desiredEnabled && batteryKeepAwakeEnabled && isOnBattery {
            return "Waiting for the helper to apply the battery profile."
        }

        if desiredEnabled && batteryKeepAwakeEnabled {
            return "Battery keep-awake will run only while the main switch stays on."
        }

        if desiredEnabled {
            return "Battery sleep remains allowed."
        }

        if sleepDisabled {
            return "SleepDisabled is still on. Restore now."
        }

        return "No lid-awake override is active."
    }

    private var isOnBattery: Bool {
        if case .battery = source {
            return true
        }
        return false
    }
}
