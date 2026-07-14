import Darwin
import Foundation

enum LegacyAutostartManager {
    enum LoadedState: Equatable { case present, absent, indeterminate }
    enum RemovalError: LocalizedError {
        case disableFailed(String)
        case bootoutFailed(String)
        case stillLoaded
        case fileStillPresent

        var errorDescription: String? {
            switch self {
            case let .disableFailed(message):
                return "The old login item could not be disabled. \(message)"
            case .stillLoaded:
                return "The old login item is still running."
            case let .bootoutFailed(message):
                return "The old login item could not be unloaded. \(message)"
            case .fileStillPresent:
                return "The old login item file could not be removed."
            }
        }
    }

    static func loadedState() -> LoadedState {
        let target = "gui/\(getuid())/\(AppPaths.legacyLoginLabel)"
        let result = Shell.run(.launchctlPrint(target))
        guard result.outcome == .completed else { return .indeterminate }
        if result.exitCode == 0 { return .present }
        // launchctl's documented missing-service response is the sole absent
        // result. Permission, parse, runner, and all other errors stay unsafe.
        let prefix = "Could not find service \"\(target)\""
        return result.stdout.isEmpty && result.stderr.hasPrefix(prefix) ? .absent : .indeterminate
    }

    static func isLoaded() -> Bool {
        loadedState() == .present
    }

    static func isDisabled() -> Bool {
        let uid = getuid()
        let result = Shell.run(.launchctlPrintDisabled("gui/\(uid)"))
        guard result.outcome == .completed, result.exitCode == 0 else { return false }
        return result.stdout.contains("\"\(AppPaths.legacyLoginLabel)\" => disabled")
    }

    static func remove() throws {
        let uid = getuid()
        let target = "gui/\(uid)/\(AppPaths.legacyLoginLabel)"
        let reconcileAbsent: @Sendable () -> Bool = { loadedState() == .absent }
        let reconcileDisabled: @Sendable () -> Bool = { isDisabled() }
        let disable = Shell.run(.launchctlMutation(.disable(target), reconcileAfterTimeout: reconcileDisabled))
        guard (disable.outcome == .completed && disable.exitCode == 0) || disable.reconciliation == .passed else {
            throw RemovalError.disableFailed(disable.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let directBootout = Shell.run(.launchctlMutation(.bootoutService(target), reconcileAfterTimeout: reconcileAbsent))
        let pathBootout = Shell.run(.launchctlMutation(.bootoutPath(domain: "gui/\(uid)", path: AppPaths.legacyLoginAgentFile.path), reconcileAfterTimeout: reconcileAbsent))
        // launchctl bootout is naturally idempotent: one representation may
        // already be absent, but failing both forms leaves an unreconciled
        // mutation and must not be presented as success.
        let absent = loadedState()
        guard (directBootout.outcome == .completed && directBootout.exitCode == 0)
            || (pathBootout.outcome == .completed && pathBootout.exitCode == 0)
            || directBootout.reconciliation == .passed
            || pathBootout.reconciliation == .passed
            || absent == .absent else {
            throw RemovalError.bootoutFailed((directBootout.stderr + " " + pathBootout.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if unlink(AppPaths.legacyLoginAgentFile.path) != 0, errno != ENOENT {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard !FileManager.default.fileExists(atPath: AppPaths.legacyLoginAgentFile.path) else {
            throw RemovalError.fileStillPresent
        }
        guard loadedState() == .absent else {
            throw RemovalError.stillLoaded
        }
        guard isDisabled() else {
            throw RemovalError.disableFailed("launchd did not retain the disabled state.")
        }
    }
}
