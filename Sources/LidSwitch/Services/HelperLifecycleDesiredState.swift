import Foundation

enum HelperLifecycleDesiredState {
    static func writeBestEffort(
        _ preferences: PowerPreferences,
        supportDirectory: URL = AppPaths.userSupportDirectory,
        stateFile: URL = AppPaths.desiredStateFile
    ) throws {
        do {
            try DesiredStateStore.write(
                preferences,
                supportDirectory: supportDirectory,
                stateFile: stateFile
            )
        } catch let error as DesiredStateStore.StoreError {
            switch error {
            case .unsafePath:
                return
            default:
                throw error
            }
        }
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
