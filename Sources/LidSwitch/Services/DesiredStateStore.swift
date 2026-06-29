import Foundation

enum DesiredStateStore {
    static func readPreferences() -> PowerPreferences {
        guard let raw = try? String(contentsOf: AppPaths.desiredStateFile, encoding: .utf8) else {
            return .disabled
        }

        return PowerPreferences.parse(raw)
    }

    static func read() -> Bool {
        readPreferences().keepAwakeEnabled
    }

    static func write(_ enabled: Bool) throws {
        try write(
            PowerPreferences(
                keepAwakeEnabled: enabled,
                allowBatteryKeepAwake: false
            )
        )
    }

    static func write(_ preferences: PowerPreferences) throws {
        try FileManager.default.createDirectory(
            at: AppPaths.userSupportDirectory,
            withIntermediateDirectories: true
        )

        try preferences.storagePayload.write(
            to: AppPaths.desiredStateFile,
            atomically: true,
            encoding: .utf8
        )
    }
}
