import Foundation

enum HelperLifecycleDesiredState {
    static func writeBestEffort(
        _ preferences: PowerPreferences,
        supportDirectory: URL = AppPaths.userSupportDirectory,
        stateFile: URL = AppPaths.desiredStateFile
    ) throws {
        // A malformed or substituted user-state path is not best-effort:
        // swallowing it could let a later lifecycle action proceed without
        // the intended fail-closed record.
        try DesiredStateStore.write(
            preferences,
            supportDirectory: supportDirectory,
            stateFile: stateFile
        )
    }

    static func performAfterBestEffortWrite(
        _ preferences: PowerPreferences,
        supportDirectory: URL = AppPaths.userSupportDirectory,
        stateFile: URL = AppPaths.desiredStateFile,
        operation: () throws -> Void
    ) throws {
        try writeBestEffort(
            preferences,
            supportDirectory: supportDirectory,
            stateFile: stateFile
        )
        try operation()
    }
}
