import Foundation
import Darwin
import LidSwitchCore

enum DesiredStateStore {
    enum UnsafePathKind: Equatable, Sendable {
        case supportDirectory
        case stateFile
    }

    enum StoreError: Error, Sendable {
        case unsafePath(String, UnsafePathKind)
        case openFailed(String, Int32)
        case writeFailed(String, Int32)
        case retainedResidue(String)
        /// Rename may have reached the namespace; callers must reconcile from
        /// disk instead of assuming the prior desired state survived.
        case committedIndeterminate(String, Int32)
    }

    enum ReadResult: Equatable, Sendable {
        case value(PowerPreferences)
        case missing(String)
        case unsafePath(String, UnsafePathKind)
        case invalid(String)
        case retainedResidue(String)
        case io(String, Int32)
        case indeterminate(String, Int32)
    }

    static func readPreferences(
        from file: URL = AppPaths.desiredStateFile,
        ancestorPolicy: BoundedFileAncestorPolicy = .fullAbsolute,
        capabilityPolicy: UserStateFileCapability.AncestryPolicy = .production
    ) -> ReadResult {
        _ = ancestorPolicy // retained source compatibility; no generic reader is used.
        do {
            switch try UserStateFileCapability.readPayload(
                finalFile: file, supportDirectory: file.deletingLastPathComponent(), ancestryPolicy: capabilityPolicy
            ) {
        case let .value(raw):
            let parsed = PowerPreferences.parse(raw)
            return parsed.invalidPersistenceDetected ? .invalid(file.path) : .value(parsed)
        case .missing: return .missing(file.path)
        case .missingWithRecognizedArchive, .recognizedLegacyPlaintext:
            // Desired-state never opts into the lease-only archive protocol.
            return .invalid(file.path)
        case let .retainedResidue(path): return .retainedResidue(path)
            }
        } catch let failure as UserStateFileCapability.Failure {
            switch failure {
            case let .unsafePath(path, kind):
                return .unsafePath(path, kind == .supportDirectory ? .supportDirectory : .stateFile)
            case let .operationFailed(_, code): return .io(file.path, code)
            case .retainedResidue: return .retainedResidue(file.path)
            case .invalidPersistence: return .invalid(file.path)
            case let .committedIndeterminate(_, code), let .revokedIndeterminate(_, code): return .indeterminate(file.path, code)
            case .commitRejected: return .indeterminate(file.path, EIO)
            }
        } catch {
            return .io(file.path, EIO)
        }
    }

    /// The compatibility convenience is intentionally explicit about all
    /// non-value outcomes. Unsafe bytes never become an implicit preference.
    static func read() -> ReadResult { readPreferences() }

    static func write(_ enabled: Bool) throws {
        try write(PowerPreferences(keepAwakeEnabled: enabled, allowBatteryKeepAwake: false))
    }

    static func write(_ preferences: PowerPreferences) throws {
        try write(
            preferences,
            supportDirectory: AppPaths.userSupportDirectory,
            stateFile: AppPaths.desiredStateFile
        )
    }

    static func write(
        _ preferences: PowerPreferences,
        supportDirectory: URL,
        stateFile: URL,
        ancestryPolicy: UserStateFileCapability.AncestryPolicy = .production
    ) throws {
        do {
            try UserStateFileCapability.writePayload(
                preferences.storagePayload,
                finalFile: stateFile,
                supportDirectory: supportDirectory,
                temporaryPrefix: ".desired-state.",
                ancestryPolicy: ancestryPolicy
            )
        } catch let failure as UserStateFileCapability.Failure {
            throw map(failure, supportDirectory: supportDirectory, stateFile: stateFile)
        }
    }

    /// Retained as a focused source-level seam for callers that need the
    /// historical typed failure shape. The capability itself retries EINTR.
    static func acceptedWriteCount(_ result: ssize_t, path: String, errorCode: Int32) throws -> Int {
        switch UserStateFileCapability.writeDecision(result: result, errorCode: errorCode) {
        case let .accept(count): return count
        case .retry: throw StoreError.writeFailed(path, EINTR)
        case let .fail(code): throw StoreError.writeFailed(path, code)
        }
    }

    private static func map(
        _ failure: UserStateFileCapability.Failure,
        supportDirectory: URL,
        stateFile: URL
    ) -> StoreError {
        switch failure {
        case let .unsafePath(path, kind):
            return .unsafePath(path, kind == .supportDirectory ? .supportDirectory : .stateFile)
        case let .operationFailed(_, code):
            return .writeFailed(stateFile.path, code)
        case .commitRejected:
            return .writeFailed(stateFile.path, EIO)
        case .retainedResidue:
            return .retainedResidue(stateFile.path)
        case .invalidPersistence:
            return .writeFailed(stateFile.path, EINVAL)
        case let .committedIndeterminate(_, code), let .revokedIndeterminate(_, code):
            return .committedIndeterminate(stateFile.path, code)
        }
    }

    static func mapCapabilityFailureForFixture(
        _ failure: UserStateFileCapability.Failure,
        supportDirectory: URL,
        stateFile: URL
    ) -> StoreError {
        map(failure, supportDirectory: supportDirectory, stateFile: stateFile)
    }
}
