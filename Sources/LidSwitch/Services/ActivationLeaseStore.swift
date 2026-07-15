import Darwin
import Foundation
import LidSwitchCore

enum ActivationLeaseStore {
    enum UnsafePathKind: Equatable, Sendable { case supportDirectory, leaseFile }

    enum StoreError: Error, Sendable {
        case unsafePath(String, UnsafePathKind)
        case openFailed(String, Int32)
        case writeFailed(String, Int32)
        case retainedResidue(String)
        case renameFailed(String, Int32)
        case commitRejected(String)
        /// Publication or revocation crossed its namespace mutation point but
        /// canonical durability/postcondition proof was interrupted.
        case committedIndeterminate(String, Int32)
        /// Canonical lease absence was reached, but post-revocation proof or
        /// tombstone cleanup could not establish a terminal namespace state.
        case revokedIndeterminate(String, Int32)
    }

    enum ReadResult: Equatable, Sendable {
        case value(ActivationLease)
        /// Exact descriptor-validated legacy plaintext at the canonical lease
        /// name. This provenance is intentionally retained until the inspector
        /// classifies active versus stale; journals never produce this case.
        case legacyPlaintext(ActivationLease)
        /// A parse-valid canonical legacy plaintext lease failed liveness
        /// validation. It is recoverable product residue, never authority.
        case staleLegacyCanonical(ActivationLease)
        case missing(String)
        /// A descriptor-bound archive of an exact installed legacy lease is
        /// present. The active canonical name was freshly proved absent; this
        /// is audit evidence, not a lease or generic retained residue.
        case missingWithRecognizedLegacyArchive(String)
        case unsafePath(String, UnsafePathKind)
        case invalid(String)
        case retainedResidue(String)
        case io(String, Int32)
        case indeterminate(String, Int32)
    }

    private static let legacyArchivePrefix = ".lidswitch-legacy-lease-"

    static func issue(
        sessionID: UUID,
        lifetime: TimeInterval = ActivationLease.maximumLifetime,
        commitGuard: (@Sendable () -> Bool)? = nil
    ) throws -> ActivationLease {
        guard let bootID = BootIdentity.current(),
              let systemBuild = SystemBuild.current()
        else {
            throw StoreError.unsafePath("Unable to read the current boot or macOS build.", .leaseFile)
        }
        let issuedMonotonic = MonotonicClock.seconds()
        let boundedLifetime = min(max(lifetime, 1), ActivationLease.maximumLifetime)
        let lease = ActivationLease(
            sessionID: sessionID,
            bootID: bootID,
            expiresAt: Date().addingTimeInterval(boundedLifetime),
            issuedMonotonic: issuedMonotonic,
            expiresMonotonic: issuedMonotonic + boundedLifetime,
            ownerUID: getuid(),
            systemBuild: systemBuild
        )
        try write(lease, commitGuard: commitGuard)
        return lease
    }

    static func write(
        _ lease: ActivationLease,
        to file: URL = AppPaths.activationLeaseFile,
        commitGuard: (@Sendable () -> Bool)? = nil,
        ancestryPolicy: UserStateFileCapability.AncestryPolicy = .production
    ) throws {
        do {
            try UserStateFileCapability.writePayload(
                lease.storagePayload,
                finalFile: file,
                supportDirectory: file.deletingLastPathComponent(),
                temporaryPrefix: ".activation-lease.",
                commitGuard: commitGuard,
                ancestryPolicy: ancestryPolicy
            )
        } catch let failure as UserStateFileCapability.Failure {
            throw mapCapabilityFailure(failure, file: file)
        } catch {
            throw error
        }
    }

    static func read(
        from file: URL = AppPaths.activationLeaseFile,
        ancestorPolicy: BoundedFileAncestorPolicy = .fullAbsolute,
        operations: UserStateFileCapability.Operations = .system,
        capabilityPolicy: UserStateFileCapability.AncestryPolicy = .production
    ) -> ReadResult {
        _ = ancestorPolicy // test compatibility only; the capability binds production ancestry.
        do {
            switch try UserStateFileCapability.readPayload(
                finalFile: file,
                supportDirectory: file.deletingLastPathComponent(),
                operations: operations,
                recognizedArchive: .init(prefix: legacyArchivePrefix, payloadIsAccepted: { ActivationLease.parse($0) != nil }),
                ancestryPolicy: capabilityPolicy
            ) {
        case let .recognizedLegacyPlaintext(raw):
            guard let lease = ActivationLease.parse(raw) else { return .invalid(file.path) }
            return .legacyPlaintext(lease)
        case let .value(raw):
            guard let lease = ActivationLease.parse(raw) else { return .invalid(file.path) }
            return .value(lease)
        case .missing: return .missing(file.path)
        case let .missingWithRecognizedArchive(path): return .missingWithRecognizedLegacyArchive(path)
        case let .retainedResidue(path): return .retainedResidue(path)
            }
        } catch let failure as UserStateFileCapability.Failure {
            switch failure {
            case let .unsafePath(path, kind): return .unsafePath(path, kind == .supportDirectory ? .supportDirectory : .leaseFile)
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

    static func revoke(
        file: URL = AppPaths.activationLeaseFile,
        ancestryPolicy: UserStateFileCapability.AncestryPolicy = .production
    ) throws {
        do {
            try UserStateFileCapability.revoke(
                finalFile: file,
                supportDirectory: file.deletingLastPathComponent(),
                ancestryPolicy: ancestryPolicy
            )
        } catch let failure as UserStateFileCapability.Failure {
            throw mapCapabilityFailure(failure, file: file)
        }
    }

    /// One-time recovery for the installed, exact recognized legacy lease.
    /// It cannot authorize power behavior and never removes retained evidence;
    /// success is a fresh descriptor-bound proof that the canonical lease name
    /// is absent after the revoke boundary.
    static func reconcileRecognizedLegacyLease(
        file: URL = AppPaths.activationLeaseFile,
        operations: UserStateFileCapability.Operations = .system,
        ancestryPolicy: UserStateFileCapability.AncestryPolicy = .production
    ) throws {
        do {
        switch read(from: file, operations: operations, capabilityPolicy: ancestryPolicy) {
        case .missing:
            return
        case .missingWithRecognizedLegacyArchive:
            guard try UserStateFileCapability.canonicalFinalIsAbsent(
                finalFile: file, supportDirectory: file.deletingLastPathComponent(), operations: operations, ancestryPolicy: ancestryPolicy
            ) else { throw StoreError.revokedIndeterminate(file.path, EIO) }
            return
        case let .legacyPlaintext(lease):
            // Re-read the descriptor-bound legacy plaintext before moving it;
            // journal-backed or generic values cannot enter this branch.
            guard case let .recognizedLegacyPlaintext(raw) = try UserStateFileCapability.readPayload(
                finalFile: file,
                supportDirectory: file.deletingLastPathComponent(),
                operations: operations,
                recognizedArchive: .init(prefix: legacyArchivePrefix, payloadIsAccepted: { ActivationLease.parse($0) != nil }),
                ancestryPolicy: ancestryPolicy
            ), raw == lease.storagePayload else {
                throw StoreError.retainedResidue(file.path)
            }
            do {
                try UserStateFileCapability.archiveRecognizedLegacyPayload(
                    raw, finalFile: file, supportDirectory: file.deletingLastPathComponent(),
                    archivePrefix: legacyArchivePrefix, operations: operations, ancestryPolicy: ancestryPolicy
                )
            } catch let failure as UserStateFileCapability.Failure {
                throw mapCapabilityFailure(failure, file: file)
            }
            guard case .missingWithRecognizedLegacyArchive = read(
                from: file, operations: operations, capabilityPolicy: ancestryPolicy
            ), try UserStateFileCapability.canonicalFinalIsAbsent(
                finalFile: file, supportDirectory: file.deletingLastPathComponent(), operations: operations, ancestryPolicy: ancestryPolicy
            ) else { throw StoreError.revokedIndeterminate(file.path, EIO) }
        case .value, .staleLegacyCanonical:
            throw StoreError.retainedResidue(file.path)
        case .retainedResidue:
            throw StoreError.retainedResidue(file.path)
        case let .unsafePath(path, kind):
            throw StoreError.unsafePath(path, kind)
        case .invalid:
            throw StoreError.writeFailed(file.path, EINVAL)
        case .io:
            throw StoreError.writeFailed(file.path, EIO)
        case .indeterminate:
            throw StoreError.revokedIndeterminate(file.path, EIO)
        }
        } catch let failure as UserStateFileCapability.Failure {
            throw mapCapabilityFailure(failure, file: file)
        }
    }

    static func mapCapabilityFailure(_ failure: UserStateFileCapability.Failure, file: URL) -> StoreError {
        switch failure {
        case let .unsafePath(path, kind):
            return .unsafePath(path, kind == .supportDirectory ? .supportDirectory : .leaseFile)
        case let .operationFailed(operation, code):
            return operation.hasPrefix("renameat")
                ? .renameFailed(file.path, code)
                : .writeFailed(file.path, code)
        case .commitRejected:
            return .commitRejected(file.path)
        case .retainedResidue:
            return .retainedResidue(file.path)
        case .invalidPersistence:
            return .writeFailed(file.path, EINVAL)
        case let .committedIndeterminate(_, code):
            return .committedIndeterminate(file.path, code)
        case let .revokedIndeterminate(_, code):
            return .revokedIndeterminate(file.path, code)
        }
    }
}
