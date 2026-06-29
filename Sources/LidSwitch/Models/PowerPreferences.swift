import Foundation

struct PowerPreferences: Equatable {
    var keepAwakeEnabled: Bool
    var allowBatteryKeepAwake: Bool

    init(keepAwakeEnabled: Bool, allowBatteryKeepAwake: Bool) {
        self.keepAwakeEnabled = keepAwakeEnabled
        self.allowBatteryKeepAwake = keepAwakeEnabled && allowBatteryKeepAwake
    }

    static let disabled = PowerPreferences(keepAwakeEnabled: false, allowBatteryKeepAwake: false)
    static let acOnlyEnabled = PowerPreferences(keepAwakeEnabled: true, allowBatteryKeepAwake: false)

    var storagePayload: String {
        let mode = keepAwakeEnabled ? "enabled" : "disabled"
        let battery = allowBatteryKeepAwake ? "enabled" : "disabled"
        return "mode=\(mode)\nbattery=\(battery)\n"
    }

    func withKeepAwakeEnabled(_ enabled: Bool) -> PowerPreferences {
        PowerPreferences(
            keepAwakeEnabled: enabled,
            allowBatteryKeepAwake: enabled ? allowBatteryKeepAwake : false
        )
    }

    func withBatteryKeepAwakeAllowed(_ allowed: Bool) -> PowerPreferences {
        PowerPreferences(
            keepAwakeEnabled: keepAwakeEnabled,
            allowBatteryKeepAwake: allowed
        )
    }

    static func parse(_ raw: String) -> PowerPreferences {
        let compact = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch compact {
        case "enabled":
            return .acOnlyEnabled
        case "disabled", "":
            return .disabled
        default:
            break
        }

        var mode: Bool?
        var battery: Bool?

        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                continue
            }

            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                continue
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

            switch key {
            case "mode", "enabled", "keepawake", "keep-awake":
                mode = parseBoolean(value)
            case "battery", "allowbattery", "allow-battery", "batterykeepawake", "battery-keep-awake":
                battery = parseBoolean(value)
            default:
                continue
            }
        }

        return PowerPreferences(
            keepAwakeEnabled: mode ?? false,
            allowBatteryKeepAwake: battery ?? false
        )
    }

    private static func parseBoolean(_ value: String) -> Bool {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "enabled", "enable", "true", "1", "yes", "on":
            return true
        default:
            return false
        }
    }
}
