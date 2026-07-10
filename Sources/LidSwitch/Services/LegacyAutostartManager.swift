import Darwin
import Foundation

enum LegacyAutostartManager {
    enum RemovalError: LocalizedError {
        case disableFailed(String)
        case stillLoaded
        case fileStillPresent

        var errorDescription: String? {
            switch self {
            case let .disableFailed(message):
                return "The old login item could not be disabled. \(message)"
            case .stillLoaded:
                return "The old login item is still running."
            case .fileStillPresent:
                return "The old login item file could not be removed."
            }
        }
    }

    static func isLoaded() -> Bool {
        let uid = getuid()
        return Shell.run("/bin/launchctl", ["print", "gui/\(uid)/\(AppPaths.legacyLoginLabel)"]).exitCode == 0
    }

    static func isDisabled() -> Bool {
        let uid = getuid()
        let result = Shell.run("/bin/launchctl", ["print-disabled", "gui/\(uid)"])
        guard result.exitCode == 0 else { return false }
        return result.stdout.contains("\"\(AppPaths.legacyLoginLabel)\" => disabled")
    }

    static func remove() throws {
        let uid = getuid()
        let disable = Shell.run("/bin/launchctl", ["disable", "gui/\(uid)/\(AppPaths.legacyLoginLabel)"])
        guard disable.exitCode == 0 else {
            throw RemovalError.disableFailed(disable.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(AppPaths.legacyLoginLabel)"])
        _ = Shell.run(
            "/bin/launchctl",
            ["bootout", "gui/\(uid)", AppPaths.legacyLoginAgentFile.path]
        )
        if unlink(AppPaths.legacyLoginAgentFile.path) != 0, errno != ENOENT {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard !FileManager.default.fileExists(atPath: AppPaths.legacyLoginAgentFile.path) else {
            throw RemovalError.fileStillPresent
        }
        guard !isLoaded() else {
            throw RemovalError.stillLoaded
        }
        guard isDisabled() else {
            throw RemovalError.disableFailed("launchd did not retain the disabled state.")
        }
    }
}
