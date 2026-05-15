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
    var desiredEnabled: Bool
    var helperInstalled: Bool
    var checkedAt: Date

    static let empty = PowerSnapshot(
        source: .unknown("Not checked"),
        sleepDisabled: false,
        acIdleSleepMinutes: nil,
        desiredEnabled: false,
        helperInstalled: false,
        checkedAt: Date()
    )

    var statusTitle: String {
        if desiredEnabled && source.isAC && sleepDisabled {
            return "Keeping awake on power"
        }

        if desiredEnabled && source.isAC {
            return helperInstalled ? "Turning on" : "Helper needed"
        }

        if desiredEnabled {
            return "Armed for power"
        }

        return "Normal sleep"
    }

    var statusDetail: String {
        if desiredEnabled && source.isAC && sleepDisabled {
            return "Lid-close sleep is blocked while charging."
        }

        if desiredEnabled && source.isAC {
            return "Waiting for the helper to apply the AC profile."
        }

        if desiredEnabled {
            return "Battery sleep remains allowed."
        }

        if sleepDisabled {
            return "SleepDisabled is still on. Restore now."
        }

        return "No lid-awake override is active."
    }
}
