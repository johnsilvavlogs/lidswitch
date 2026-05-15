import Foundation

enum DesiredStateStore {
    static func read() -> Bool {
        guard let raw = try? String(contentsOf: AppPaths.desiredStateFile, encoding: .utf8) else {
            return false
        }

        return raw.trimmingCharacters(in: .whitespacesAndNewlines) == "enabled"
    }

    static func write(_ enabled: Bool) throws {
        try FileManager.default.createDirectory(
            at: AppPaths.userSupportDirectory,
            withIntermediateDirectories: true
        )

        let value = enabled ? "enabled\n" : "disabled\n"
        try value.write(to: AppPaths.desiredStateFile, atomically: true, encoding: .utf8)
    }
}
