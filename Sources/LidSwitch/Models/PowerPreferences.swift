import Foundation
import LidSwitchCore

struct PowerPreferences: Equatable, Sendable {
    var keepAwakeEnabled: Bool
    /// Battery intent from the legacy format requires explicit remediation;
    /// only schema 2 can persist a new, independent battery preference.
    var legacyBatteryResidueDetected: Bool
    /// A malformed or contradictory record is never permission to enable the
    /// feature. This lets the UI distinguish an intentionally-disabled record
    /// from a fail-safe disabled one without preserving activation authority.
    var invalidPersistenceDetected: Bool
    var allowBatteryKeepAwake: Bool
    var allowPluggedInKeepAwake: Bool

    init(
        keepAwakeEnabled: Bool,
        allowBatteryKeepAwake: Bool,
        invalidPersistenceDetected: Bool = false,
        allowPluggedInKeepAwake: Bool = true,
        legacyBatteryResidueDetected: Bool = false
    ) {
        self.keepAwakeEnabled = keepAwakeEnabled
        self.allowBatteryKeepAwake = allowBatteryKeepAwake
        self.allowPluggedInKeepAwake = allowPluggedInKeepAwake
        self.legacyBatteryResidueDetected = legacyBatteryResidueDetected
        self.invalidPersistenceDetected = invalidPersistenceDetected
    }

    static let disabled = PowerPreferences(keepAwakeEnabled: false, allowBatteryKeepAwake: false)
    static let acOnlyEnabled = PowerPreferences(keepAwakeEnabled: true, allowBatteryKeepAwake: false)

    var storagePayload: String {
        // Activation belongs to this app process, never to a saved record.
        return "schema=2\nmode=disabled\nplugged_in=\(allowPluggedInKeepAwake ? "enabled" : "disabled")\nbattery=\(allowBatteryKeepAwake ? "enabled" : "disabled")\n"
    }

    func withKeepAwakeEnabled(_ enabled: Bool) -> PowerPreferences {
        PowerPreferences(
            keepAwakeEnabled: enabled,
            allowBatteryKeepAwake: allowBatteryKeepAwake,
            allowPluggedInKeepAwake: allowPluggedInKeepAwake
        )
    }

    var sessionPowerPolicy: SessionPowerPolicy? {
        SessionPowerPolicy(pluggedIn: allowPluggedInKeepAwake, onBattery: allowBatteryKeepAwake)
    }

    func allows(_ source: PowerSource) -> Bool {
        switch source {
        case .ac: allowPluggedInKeepAwake
        case .battery: allowBatteryKeepAwake
        case .unknown: false
        }
    }

    static func parse(_ raw: String) -> PowerPreferences {
        let compact = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.hasPrefix("schema=") { return parseCurrent(raw) }
        switch compact {
        case "enabled":
            return .acOnlyEnabled
        case "disabled":
            return .disabled
        case "":
            return PowerPreferences(
                keepAwakeEnabled: false,
                allowBatteryKeepAwake: false,
                invalidPersistenceDetected: true
            )
        default:
            break
        }

        var mode: Bool?
        var battery: Bool?
        var invalid = false

        for line in raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            // Comments were accepted by the legacy key/value format and carry
            // no state. Everything else must be an exact recognized record.
            if trimmed.hasPrefix("#") { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { invalid = true; continue }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { invalid = true; continue }

            switch key {
            case "mode", "enabled", "keepawake", "keep-awake":
                guard mode == nil, let parsed = parseBoolean(value) else {
                    invalid = true
                    continue
                }
                mode = parsed
            case "battery", "allowbattery", "allow-battery", "batterykeepawake", "battery-keep-awake":
                guard battery == nil, let parsed = parseBoolean(value) else {
                    invalid = true
                    continue
                }
                battery = parsed
            default:
                invalid = true
            }
        }

        // A structured record is never authorization unless it carries one
        // unambiguous mode. Empty and comment-only records are also explicit
        // fail-safe residue rather than silently-disabled valid intent.
        if mode == nil { invalid = true }

        return PowerPreferences(
            keepAwakeEnabled: invalid || battery == true ? false : mode ?? false,
            allowBatteryKeepAwake: false,
            invalidPersistenceDetected: invalid || battery == true,
            legacyBatteryResidueDetected: battery == true
        )
    }

    private static func parseCurrent(_ raw: String) -> PowerPreferences {
        var values: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, values[String(parts[0])] == nil else {
                return PowerPreferences(keepAwakeEnabled: false, allowBatteryKeepAwake: false, invalidPersistenceDetected: true)
            }
            values[String(parts[0])] = String(parts[1])
        }
        guard Set(values.keys) == ["schema", "mode", "plugged_in", "battery"],
              values["schema"] == "2",
              let mode = values["mode"], ["enabled", "disabled"].contains(mode),
              let pluggedIn = values["plugged_in"], ["enabled", "disabled"].contains(pluggedIn),
              let battery = values["battery"], ["enabled", "disabled"].contains(battery)
        else {
            return PowerPreferences(keepAwakeEnabled: false, allowBatteryKeepAwake: false, invalidPersistenceDetected: true)
        }
        return PowerPreferences(
            keepAwakeEnabled: mode == "enabled",
            allowBatteryKeepAwake: battery == "enabled",
            allowPluggedInKeepAwake: pluggedIn == "enabled"
        )
    }

    private static func parseBoolean(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "enabled", "enable", "true", "1", "yes", "on":
            return true
        case "disabled", "disable", "false", "0", "no", "off":
            return false
        default:
            return nil
        }
    }
}
