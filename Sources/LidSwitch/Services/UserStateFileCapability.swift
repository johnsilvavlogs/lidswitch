import Darwin
import CryptoKit
import Foundation
import LidSwitchCore

/// Canonical, descriptor-bound storage for the current user's non-authoritative
/// desired-state records. A held descriptor is insufficient on its own: the
/// complete root-to-support chain remains open and is reasserted before and
/// after every namespace mutation.
enum UserStateFileCapability: Sendable {
    static let maximumPayloadBytes = 4_096
    static let maximumNameBytes = Int(NAME_MAX)
    /// Bounds lexical work before a hostile pathname is split or materialized.
    static let maximumPathBytes = 4_096
    static let maximumPathComponents = 32
    static let maximumRetainedQuarantines = 8
    static let privateDirectoryMode: mode_t = 0o700
    static let privateFileMode: mode_t = 0o600

    /// Fixed-size dual-slot state journal. Once a legacy plaintext record is
    /// migrated, changing state writes update one inactive slot in the same
    /// validated inode; they do not create namespace residue.
    private enum Journal {
        static let magic = Array("LSUSJ001".utf8)
        static let headerBytes = 16
        static let slotBytes = 8 + 4 + 4 + 32 + maximumPayloadBytes
        static let totalBytes = headerBytes + slotBytes * 2

        struct Slot: Equatable {
            let generation: UInt64
            let payload: [UInt8]
        }

        static func decode(_ bytes: [UInt8]) -> Slot? {
            guard bytes.count == totalBytes, Array(bytes[0..<magic.count]) == magic else { return nil }
            let valid = (0..<2).compactMap { slot(at: $0, bytes: bytes) }
            guard Set(valid.map(\.generation)).count == valid.count,
                  let newest = valid.max(by: { $0.generation < $1.generation })
            else { return nil }
            return newest
        }

        static func initial(_ payload: [UInt8]) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: totalBytes)
            bytes.replaceSubrange(0..<magic.count, with: magic)
            write(slot: Slot(generation: 1, payload: payload), at: 0, into: &bytes)
            return bytes
        }

        static func next(_ current: Slot, payload: [UInt8], bytes: [UInt8]) -> (slot: Int, record: [UInt8])? {
            guard bytes.count == totalBytes, payload.count > 0, payload.count <= maximumPayloadBytes,
                  current.generation < UInt64.max else { return nil }
            var record = bytes
            let active = (0..<2).first { slot(at: $0, bytes: bytes)?.generation == current.generation } ?? 0
            let inactive = active == 0 ? 1 : 0
            write(slot: Slot(generation: current.generation + 1, payload: payload), at: inactive, into: &record)
            return (inactive, record)
        }

        private static func slot(at index: Int, bytes: [UInt8]) -> Slot? {
            let offset = headerBytes + index * slotBytes
            let generation = littleEndian64(bytes, offset)
            let length = Int(littleEndian32(bytes, offset + 8))
            guard generation > 0, length > 0, length <= maximumPayloadBytes else { return nil }
            let digestStart = offset + 16
            let payloadStart = offset + 48
            let payload = Array(bytes[payloadStart..<(payloadStart + length)])
            guard Array(SHA256.hash(data: Data(payload))) == Array(bytes[digestStart..<(digestStart + 32)]) else { return nil }
            return Slot(generation: generation, payload: payload)
        }

        private static func write(slot: Slot, at index: Int, into bytes: inout [UInt8]) {
            let offset = headerBytes + index * slotBytes
            writeLittleEndian(slot.generation, into: &bytes, at: offset)
            writeLittleEndian(UInt32(slot.payload.count), into: &bytes, at: offset + 8)
            let digest = Array(SHA256.hash(data: Data(slot.payload)))
            bytes.replaceSubrange((offset + 16)..<(offset + 48), with: digest)
            bytes.replaceSubrange((offset + 48)..<(offset + 48 + slot.payload.count), with: slot.payload)
        }

        private static func littleEndian64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
            (0..<8).reduce(UInt64(0)) { $0 | (UInt64(bytes[offset + $1]) << UInt64($1 * 8)) }
        }

        private static func littleEndian32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | (UInt32(bytes[offset + $1]) << UInt32($1 * 8)) }
        }

        private static func writeLittleEndian(_ value: UInt64, into bytes: inout [UInt8], at offset: Int) {
            for index in 0..<8 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> UInt64(index * 8)) }
        }

        private static func writeLittleEndian(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
            for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(index * 8)) }
        }
    }

    enum UnsafePathKind: Equatable {
        case supportDirectory
        case finalFile
        case temporaryFile
        case quarantine
    }

    enum Failure: Error {
        case unsafePath(String, UnsafePathKind)
        case invalidPersistence(String)
        case operationFailed(String, Int32)
        /// Bounded private recovery evidence is present. Callers must
        /// reconcile manually; no additional namespace mutation is allowed.
        case retainedResidue(String)
        case commitRejected(String)
        case committedIndeterminate(String, Int32)
        case revokedIndeterminate(String, Int32)
    }

    enum DurabilityEvent: Equatable { case supportDirectoryCreation, publication, revocation }
    enum WriteDecision: Equatable { case accept(Int), retry, fail(Int32) }
    enum PublicationVerification: Equatable { case accepted, replacementOrMetadataChanged, contentChanged }
    enum ReadValue: Equatable {
        case missing
        /// A lease-only archive has passed descriptor, identity, digest and
        /// payload validation. It is audit evidence, never active authority.
        case missingWithRecognizedArchive(String)
        case recognizedLegacyPlaintext(String)
        case retainedResidue(String)
        case value(String)
    }
    struct RecognizedArchive {
        let prefix: String
        let payloadIsAccepted: @Sendable (String) -> Bool
    }
    private enum JournalUpdateResult { case notJournal, unchanged, updated }
    private struct ResidueInventory {
        let count: Int
        let names: [String]
    }

    struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        init(device: dev_t, inode: ino_t) { self.device = device; self.inode = inode }
        init(_ status: stat) { device = status.st_dev; inode = status.st_ino }
    }

    /// Production never grants a sticky-directory exception. Fixtures must
    /// explicitly bind the one TestSandbox root they created; this policy is
    /// retained in the descriptor chain and rechecked with that root identity.
    enum AncestryPolicy: Equatable {
        case production
        case testSandbox(rootPath: String, rootIdentity: FileIdentity)

        static func testSandbox(root: URL) throws -> AncestryPolicy {
            var status = stat()
            guard lstat(root.path, &status) == 0,
                  status.st_mode & S_IFMT == S_IFDIR,
                  status.st_uid == getuid(), status.st_gid == getgid(),
                  status.st_mode & (S_IWGRP | S_IWOTH) == 0
            else { throw Failure.unsafePath("unsafe TestSandbox root \(root.path)", .supportDirectory) }
            return .testSandbox(rootPath: root.path, rootIdentity: FileIdentity(status))
        }
    }

    struct Operations: Sendable {
        let fileFsync: @Sendable (Int32) -> (Int32, Int32)
        /// Regular journal/temp data uses F_FULLFSYNC after fsync because this
        /// product makes sudden-power-loss persistence claims. Directory
        /// metadata remains fsync-only on Darwin.
        let fileFullSync: @Sendable (Int32) -> (Int32, Int32)
        let directoryFsync: @Sendable (Int32) -> (Int32, Int32)
        let close: @Sendable (Int32) -> (Int32, Int32)
        let renameExclusive: @Sendable (Int32, String, Int32, String) -> (Int32, Int32)
        let write: @Sendable (Int32, [UInt8]) -> (ssize_t, Int32)
        let pwrite: @Sendable (Int32, [UInt8], off_t) -> (ssize_t, Int32)
        let pread: @Sendable (Int32, Int, off_t) -> (bytes: [UInt8], result: ssize_t, errorCode: Int32)
        /// Production read loops consume this seam directly so fixtures can
        /// exercise partial reads, EINTR, zero-byte reads, and EOF proof.
        let read: @Sendable (Int32, Int) -> (bytes: [UInt8], result: ssize_t, errorCode: Int32)

        init(
            fileFsync: @escaping @Sendable (Int32) -> (Int32, Int32),
            fileFullSync: @escaping @Sendable (Int32) -> (Int32, Int32) = { descriptor in
                let result = fcntl(descriptor, F_FULLFSYNC)
                return (result, errno)
            },
            directoryFsync: @escaping @Sendable (Int32) -> (Int32, Int32),
            close: @escaping @Sendable (Int32) -> (Int32, Int32),
            renameExclusive: @escaping @Sendable (Int32, String, Int32, String) -> (Int32, Int32) = { oldFD, oldName, newFD, newName in
                let result = Darwin.renameatx_np(oldFD, oldName, newFD, newName, UInt32(RENAME_EXCL))
                return (result, errno)
            },
            write: @escaping @Sendable (Int32, [UInt8]) -> (ssize_t, Int32) = { descriptor, bytes in
                let result = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, bytes.count) }
                return (result, errno)
            },
            pwrite: @escaping @Sendable (Int32, [UInt8], off_t) -> (ssize_t, Int32) = { descriptor, bytes, offset in
                let result = bytes.withUnsafeBytes { Darwin.pwrite(descriptor, $0.baseAddress, bytes.count, offset) }
                return (result, errno)
            },
            pread: @escaping @Sendable (Int32, Int, off_t) -> (bytes: [UInt8], result: ssize_t, errorCode: Int32) = { descriptor, count, offset in
                var bytes = [UInt8](repeating: 0, count: count)
                let result = bytes.withUnsafeMutableBytes { Darwin.pread(descriptor, $0.baseAddress, count, offset) }
                return (result > 0 ? Array(bytes.prefix(Int(result))) : [], result, errno)
            },
            read: @escaping @Sendable (Int32, Int) -> (bytes: [UInt8], result: ssize_t, errorCode: Int32) = { descriptor, count in
                var bytes = [UInt8](repeating: 0, count: count)
                let result = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, count) }
                return (result > 0 ? Array(bytes.prefix(Int(result))) : [], result, errno)
            }
        ) {
            self.fileFsync = fileFsync
            self.fileFullSync = fileFullSync
            self.directoryFsync = directoryFsync
            self.close = close
            self.renameExclusive = renameExclusive
            self.write = write
            self.pwrite = pwrite
            self.pread = pread
            self.read = read
        }

        static let system = Operations(
            fileFsync: { descriptor in let result = fsync(descriptor); return (result, errno) },
            directoryFsync: { descriptor in let result = fsync(descriptor); return (result, errno) },
            close: { descriptor in let result = Darwin.close(descriptor); return (result, errno) }
        )
    }

    struct Controls: Sendable {
        var beforeSupportCreate: @Sendable (String) -> Void = { _ in }
        var beforeCommit: @Sendable (String) -> Void = { _ in }
        var afterRename: @Sendable (String) -> Void = { _ in }
        var afterDescriptorVerification: @Sendable (String) -> Void = { _ in }
        var afterDirectoryFsync: @Sendable (String) -> Void = { _ in }
        var beforeRevoke: @Sendable (String) -> Void = { _ in }
        var afterFirstRevokeAbsence: @Sendable (String) -> Void = { _ in }
        var afterRevokeFsync: @Sendable (String) -> Void = { _ in }
        var afterMissingSupport: @Sendable (String) -> Void = { _ in }
        var afterTombstoneMove: @Sendable (String) -> Void = { _ in }
        var beforeExistingFinalQuarantine: @Sendable (String) -> Void = { _ in }
        var afterExistingFinalQuarantine: @Sendable (String) -> Void = { _ in }
        var afterFinalRead: @Sendable (String) -> Void = { _ in }
        var beforeTerminalChainClose: @Sendable (String) -> Void = { _ in }
        static let none = Controls()
    }

    static func requiresDirectoryFsync(after event: DurabilityEvent) -> Bool { true }

    static func writeDecision(result: ssize_t, errorCode: Int32) -> WriteDecision {
        if result > 0 { return .accept(Int(result)) }
        if result == 0 { return .fail(EIO) }
        return errorCode == EINTR ? .retry : .fail(errorCode)
    }

    static func publicationVerification(
        expectedIdentity: FileIdentity,
        observedIdentity: FileIdentity,
        metadataIsSafe: Bool,
        expectedBytes: [UInt8],
        observedBytes: [UInt8]
    ) -> PublicationVerification {
        guard expectedIdentity == observedIdentity, metadataIsSafe else { return .replacementOrMetadataChanged }
        return expectedBytes == observedBytes ? .accepted : .contentChanged
    }

    static func directoryMetadataIsSafe(mode: mode_t, uid: uid_t, gid: gid_t, isDirectory: Bool) -> Bool {
        isDirectory && uid == getuid() && gid == getgid() && mode & 0o7777 == privateDirectoryMode
    }

    static func privateRegularMetadataIsSafe(
        mode: mode_t, uid: uid_t, gid: gid_t, linkCount: nlink_t, isRegular: Bool
    ) -> Bool {
        isRegular && uid == getuid() && gid == getgid() && linkCount == 1 && mode & 0o7777 == privateFileMode
    }

    static func legacySupportMetadataIsSafe(mode: mode_t, uid: uid_t, gid: gid_t, isDirectory: Bool) -> Bool {
        isDirectory && uid == getuid() && gid == getgid() && mode & 0o7777 == 0o755
    }

    static func replaceEligibleFinalMetadataIsSafe(
        mode: mode_t, uid: uid_t, gid: gid_t, linkCount: nlink_t, isRegular: Bool
    ) -> Bool {
        isRegular && uid == getuid() && gid == getgid() && linkCount == 1
            && (mode & 0o7777 == privateFileMode || mode & 0o7777 == 0o644)
    }

    static func safeLeafComponent(_ value: String) -> Bool { isSafeComponent(value) }

    static func writePayload(
        _ payload: String,
        finalFile: URL,
        supportDirectory: URL,
        temporaryPrefix: String,
        commitGuard: (@Sendable () -> Bool)? = nil,
        operations: Operations = .system,
        controls: Controls = .none,
        ancestryPolicy: AncestryPolicy = .production
    ) throws {
        let payloadBytes = try payloadBytes(payload)
        let bytes = Journal.initial(payloadBytes)
        let finalName = try childName(finalFile, in: supportDirectory)
        let temporaryName = try temporaryLeaf(prefix: temporaryPrefix)
        let chain = try openSupportChain(supportDirectory, createIfMissing: true, operations: operations, controls: controls, ancestryPolicy: ancestryPolicy)
        var temporaryFD: Int32 = -1
        var temporaryIdentity: FileIdentity?
        var namespaceMutated = false
        var journalMutationCommitted = false
        defer {
            if temporaryFD >= 0 {
                let consumedFD = temporaryFD
                temporaryFD = -1
                _ = Darwin.close(consumedFD)
            }
            chain.closeIgnoringErrors()
        }

        do {
            try chain.reassert()
            try validateLeaf(finalName, in: chain.supportFD)
            try validateLeaf(temporaryName, in: chain.supportFD)
            switch try updateJournalIfPresent(
                payload: payloadBytes, named: finalName, in: chain.supportFD,
                chain: chain, temporaryPrefix: temporaryPrefix, commitGuard: commitGuard, operations: operations
            ) {
            case .updated:
                journalMutationCommitted = true
                try chain.closeAll(operations: operations)
                return
            case .unchanged:
                try chain.closeAll(operations: operations)
                return
            case .notJournal:
                break
            }
            // The fallback migration/publication can retain one private name
            // on an interrupted namespace operation. Reserve before creating
            // the temp so a ninth entry is never created.
            _ = try assertBoundedQuarantineResidue(in: chain.supportFD, reserving: 1)
            temporaryFD = openat(
                chain.supportFD, temporaryName,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                privateFileMode
            )
            BenchmarkProbe.record("file_open")
            guard temporaryFD >= 0 else { throw Failure.operationFailed("openat \(temporaryName)", errno) }
            temporaryIdentity = try validatePrivateRegularFile(temporaryFD, label: temporaryName)
            guard fchmod(temporaryFD, privateFileMode) == 0 else {
                throw Failure.operationFailed("fchmod \(temporaryName)", errno)
            }
            temporaryIdentity = try validatePrivateRegularFile(temporaryFD, label: temporaryName)
            try writeAll(bytes, to: temporaryFD, label: temporaryName, operations: operations)
            BenchmarkProbe.record("file_fsync")
            try requireSuccess(operations.fileFsync(temporaryFD), operation: "fsync \(temporaryName)")
            try requireSuccess(operations.fileFullSync(temporaryFD), operation: "F_FULLFSYNC \(temporaryName)")

            controls.beforeCommit(temporaryName)
            try chain.reassert()
            guard let expectedTemporary = temporaryIdentity else { throw Failure.operationFailed("temporary identity", EIO) }
            try assertNamedIdentity(temporaryName, in: chain.supportFD, expected: expectedTemporary)
            guard commitGuard?() ?? true else {
                // No unlink-by-fd primitive exists. Move only the exact private
                // temp to an exclusive retained quarantine; a substituted name
                // is never deleted and commit rejection stays fail-closed.
                _ = try quarantineNamedIdentity(
                    temporaryName, in: chain.supportFD, expected: expectedTemporary,
                    prefix: ".lidswitch-rejected-", operations: operations
                )
                let consumedTemporaryFD = temporaryFD
                temporaryFD = -1
                try closeChecked(consumedTemporaryFD, label: temporaryName, operations: operations)
                try chain.closeAll(operations: operations)
                throw Failure.commitRejected(finalFile.path)
            }

            let priorFinal = try existingFinalIdentityIfPresent(finalName, in: chain.supportFD)
            try chain.reassert()
            try assertNamedIdentity(temporaryName, in: chain.supportFD, expected: expectedTemporary)
            if let priorFinal {
                controls.beforeExistingFinalQuarantine(finalName)
                // The pre-rename assertion is evidence only. The exclusive
                // move is authoritative: if it moved a different inode the
                // mismatch is retained and this call never overwrites it.
                _ = try quarantineNamedIdentity(
                    finalName, in: chain.supportFD, expected: priorFinal,
                    prefix: ".lidswitch-prior-", operations: operations,
                    allowLegacyFinal: true
                )
                namespaceMutated = true
                controls.afterExistingFinalQuarantine(finalName)
                try chain.reassert()
                try assertAbsent(finalName, in: chain.supportFD)
            } else {
                try assertAbsent(finalName, in: chain.supportFD)
            }
            BenchmarkProbe.record("file_rename")
            try requireSuccess(
                operations.renameExclusive(chain.supportFD, temporaryName, chain.supportFD, finalName),
                operation: "renameatx_np publish \(finalName)"
            )
            namespaceMutated = true
            controls.afterRename(finalName)

            try chain.reassert()
            try assertNamedIdentity(finalName, in: chain.supportFD, expected: expectedTemporary)
            try verifyPublishedFile(named: finalName, in: chain.supportFD, expectedIdentity: expectedTemporary, expectedBytes: bytes, operations: operations, afterRead: { controls.afterFinalRead(finalName) })
            try assertNamedIdentity(finalName, in: chain.supportFD, expected: expectedTemporary)
            controls.afterDescriptorVerification(finalName)
            try chain.reassert()
            try assertNamedIdentity(finalName, in: chain.supportFD, expected: expectedTemporary)
            BenchmarkProbe.record("directory_fsync")
            try requireSuccess(operations.directoryFsync(chain.supportFD), operation: "fsync directory \(supportDirectory.path)")
            controls.afterDirectoryFsync(finalName)
            try chain.reassert()
            try assertNamedIdentity(finalName, in: chain.supportFD, expected: expectedTemporary)
            let consumedTemporaryFD = temporaryFD
            temporaryFD = -1
            try closeChecked(consumedTemporaryFD, label: temporaryName, operations: operations)
            try chain.reassert()
            controls.beforeTerminalChainClose(finalName)
            try chain.closeAll(operations: operations)
        } catch let failure as Failure {
            if !namespaceMutated, temporaryFD >= 0, let expectedTemporary = temporaryIdentity {
                _ = try quarantineNamedIdentity(
                    temporaryName, in: chain.supportFD, expected: expectedTemporary,
                    prefix: ".lidswitch-abandoned-", operations: operations
                )
            }
            if case .committedIndeterminate = failure { throw failure }
            if journalMutationCommitted {
                throw Failure.committedIndeterminate(finalFile.path, code(for: failure))
            }
            if namespaceMutated {
                switch failure {
                case .committedIndeterminate, .revokedIndeterminate: throw failure
                default: throw Failure.committedIndeterminate(finalFile.path, code(for: failure))
                }
            }
            throw failure
        }
    }

    static func revoke(
        finalFile: URL,
        supportDirectory: URL,
        operations: Operations = .system,
        controls: Controls = .none,
        ancestryPolicy: AncestryPolicy = .production
    ) throws {
        let finalName = try childName(finalFile, in: supportDirectory)
        guard let chain = try openExistingSupportChain(supportDirectory, operations: operations, controls: controls, ancestryPolicy: ancestryPolicy) else { return }
        var revoked = false
        defer { chain.closeIgnoringErrors() }
        do {
            try chain.reassert()
            try validateLeaf(finalName, in: chain.supportFD)
            // Successful revoke leaves its verified tombstone as bounded
            // evidence, so reserve that one name before the atomic move.
            _ = try assertBoundedQuarantineResidue(in: chain.supportFD, reserving: 1)
            guard let expected = try namedIdentityIfPresent(finalName, in: chain.supportFD) else {
                try chain.reassert()
                try chain.closeAll(operations: operations)
                return
            }
            controls.beforeRevoke(finalName)
            try chain.reassert()
            try assertNamedIdentity(finalName, in: chain.supportFD, expected: expected)
            let hidden = try tombstoneLeaf(for: finalName, identity: expected, in: chain.supportFD)
            try requireSuccess(
                operations.renameExclusive(chain.supportFD, finalName, chain.supportFD, hidden),
                operation: "renameatx_np revoke \(finalName)"
            )
            revoked = true
            BenchmarkProbe.record("file_rename")
            controls.afterTombstoneMove(hidden)
            try assertNamedIdentity(hidden, in: chain.supportFD, expected: expected)
            try chain.reassert()
            try assertAbsent(finalName, in: chain.supportFD)
            controls.afterFirstRevokeAbsence(finalName)
            try chain.reassert()
            try assertAbsent(finalName, in: chain.supportFD)
            try assertNamedIdentity(hidden, in: chain.supportFD, expected: expected)
            BenchmarkProbe.record("directory_fsync")
            try requireSuccess(operations.directoryFsync(chain.supportFD), operation: "fsync directory \(supportDirectory.path)")
            controls.afterRevokeFsync(finalName)
            try chain.reassert()
            try assertAbsent(finalName, in: chain.supportFD)
            try assertNamedIdentity(hidden, in: chain.supportFD, expected: expected)
            // There is no safe unlink-by-descriptor on Darwin. The verified
            // tombstone remains bounded evidence; a later operation refuses
            // to create more than the cap rather than risking a substituted
            // same-UID pathname.
            try chain.reassert()
            try assertAbsent(finalName, in: chain.supportFD)
            try assertNamedIdentity(hidden, in: chain.supportFD, expected: expected)
            controls.beforeTerminalChainClose(finalName)
            try chain.closeAll(operations: operations)
            // The original held chain is now closed. Rebind once more and
            // prove canonical absence at the terminal boundary; after return
            // same-UID recreation remains an unavoidable point-in-time race.
            guard let terminalChain = try openExistingSupportChain(
                supportDirectory, operations: operations, controls: controls, ancestryPolicy: ancestryPolicy
            ) else {
                throw Failure.revokedIndeterminate("support disappeared after revoke \(finalFile.path)", EIO)
            }
            defer { terminalChain.closeIgnoringErrors() }
            try terminalChain.reassert()
            try assertAbsent(finalName, in: terminalChain.supportFD)
            try terminalChain.closeAll(operations: operations)
        } catch let failure as Failure {
            if revoked {
                switch failure {
                case .revokedIndeterminate, .committedIndeterminate: throw failure
                default: throw Failure.revokedIndeterminate(finalFile.path, code(for: failure))
                }
            }
            throw failure
        }
    }

    /// Fresh descriptor-bound proof used by the legacy lease reconciliation
    /// action. It deliberately does not inventory or remove retained
    /// evidence: canonical absence, not tombstone deletion, is the recovery
    /// boundary.
    static func canonicalFinalIsAbsent(
        finalFile: URL,
        supportDirectory: URL,
        operations: Operations = .system,
        ancestryPolicy: AncestryPolicy = .production
    ) throws -> Bool {
        let finalName = try childName(finalFile, in: supportDirectory)
        guard let chain = try openExistingSupportChain(
            supportDirectory, operations: operations, controls: .none, ancestryPolicy: ancestryPolicy
        ) else { return true }
        defer { chain.closeIgnoringErrors() }
        try chain.reassert()
        let absent = try rawIdentityIfPresent(finalName, in: chain.supportFD) == nil
        try chain.reassert()
        try chain.closeAll(operations: operations)
        return absent
    }

    /// Atomically archives one exact legacy plaintext leaf.  This is narrowly
    /// for recovery of the old activation-lease record: it never overwrites a
    /// name, never unlinks evidence, and returns only after the old canonical
    /// name is durably absent while the held inode is bound to a digest-bearing
    /// archive leaf.
    static func archiveRecognizedLegacyPayload(
        _ payload: String,
        finalFile: URL,
        supportDirectory: URL,
        archivePrefix: String,
        operations: Operations = .system,
        ancestryPolicy: AncestryPolicy = .production
    ) throws {
        let expectedBytes = try payloadBytes(payload)
        let finalName = try childName(finalFile, in: supportDirectory)
        guard let chain = try openExistingSupportChain(
            supportDirectory, operations: operations, controls: .none, ancestryPolicy: ancestryPolicy
        ) else { throw Failure.operationFailed("missing legacy final \(finalName)", ENOENT) }
        var moved = false
        defer { chain.closeIgnoringErrors() }
        do {
            try chain.reassert()
            let inventory = try assertBoundedQuarantineResidue(in: chain.supportFD, reserving: 1)
            guard inventory.count == 0 else { throw Failure.retainedResidue("legacy recovery has retained evidence") }
            guard let expected = try namedIdentityIfPresent(finalName, in: chain.supportFD) else {
                throw Failure.operationFailed("missing legacy final \(finalName)", ENOENT)
            }
            let archive = try recognizedArchiveLeaf(
                prefix: archivePrefix, finalName: finalName, identity: expected, payload: expectedBytes, in: chain.supportFD
            )
            try assertNamedIdentity(finalName, in: chain.supportFD, expected: expected)
            try requireSuccess(
                operations.renameExclusive(chain.supportFD, finalName, chain.supportFD, archive),
                operation: "renameatx_np archive legacy \(finalName)"
            )
            moved = true
            try chain.reassert()
            try assertNamedIdentity(archive, in: chain.supportFD, expected: expected)
            try assertAbsent(finalName, in: chain.supportFD)
            try verifyPublishedFile(
                named: archive, in: chain.supportFD, expectedIdentity: expected,
                expectedBytes: expectedBytes, operations: operations, afterRead: {}
            )
            try chain.reassert()
            try assertNamedIdentity(archive, in: chain.supportFD, expected: expected)
            try assertAbsent(finalName, in: chain.supportFD)
            BenchmarkProbe.record("directory_fsync")
            try requireSuccess(operations.directoryFsync(chain.supportFD), operation: "fsync legacy archive directory \(supportDirectory.path)")
            try chain.reassert()
            try assertNamedIdentity(archive, in: chain.supportFD, expected: expected)
            try assertAbsent(finalName, in: chain.supportFD)
            try chain.closeAll(operations: operations)
        } catch let failure as Failure {
            if moved {
                switch failure {
                case .revokedIndeterminate, .committedIndeterminate: throw failure
                default: throw Failure.revokedIndeterminate(finalFile.path, code(for: failure))
                }
            }
            throw failure
        }
    }

    /// User-state reads use the same retained, canonical chain as mutation.
    /// Unlike the generic reader this admits only the exact user-state legacy
    /// metadata contract and reasserts the final entry before returning bytes.
    static func readPayload(
        finalFile: URL,
        supportDirectory: URL,
        maximumBytes: Int = maximumPayloadBytes,
        operations: Operations = .system,
        recognizedArchive: RecognizedArchive? = nil,
        ancestryPolicy: AncestryPolicy = .production
    ) throws -> ReadValue {
        guard maximumBytes > 0, maximumBytes <= maximumPayloadBytes else {
            throw Failure.unsafePath("invalid user-state read bound", .finalFile)
        }
        let finalName = try childName(finalFile, in: supportDirectory)
        guard let chain = try openExistingSupportChain(
            supportDirectory, operations: operations, controls: .none, ancestryPolicy: ancestryPolicy
        ) else { return .missing }
        var descriptor: Int32 = -1
        var descriptorConsumed = false
        defer {
            if descriptor >= 0 && !descriptorConsumed {
                descriptorConsumed = true
                let consumedDescriptor = descriptor
                descriptor = -1
                _ = Darwin.close(consumedDescriptor)
            }
            chain.closeIgnoringErrors()
        }
        try chain.reassert()
        let residue = try assertBoundedQuarantineResidue(in: chain.supportFD, reserving: 0)
        let recognizedArchiveName: String?
        if let recognizedArchive {
            recognizedArchiveName = try validatedRecognizedArchive(
                finalName: finalName, inventory: residue, in: chain.supportFD,
                archive: recognizedArchive, operations: operations
            )
        } else {
            recognizedArchiveName = nil
        }
        guard let expected = try existingFinalIdentityIfPresent(finalName, in: chain.supportFD) else {
            if let archive = recognizedArchiveName {
                try chain.reassert()
                try assertAbsent(finalName, in: chain.supportFD)
                try chain.closeAll(operations: operations)
                return .missingWithRecognizedArchive(archive)
            }
            if residue.count > 0 {
                try chain.reassert()
                try chain.closeAll(operations: operations)
                return .retainedResidue(supportDirectory.path)
            }
            try chain.reassert()
            try chain.closeAll(operations: operations)
            return .missing
        }
        if residue.count > 0,
           recognizedArchiveName == nil,
           !isSinglePriorMigrationResidue(inventory: residue, finalName: finalName) {
            try chain.reassert()
            try chain.closeAll(operations: operations)
            return .retainedResidue(supportDirectory.path)
        }
        descriptor = openat(chain.supportFD, finalName, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        BenchmarkProbe.record("file_open")
        guard descriptor >= 0 else { throw Failure.operationFailed("openat read \(finalName)", errno) }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0,
              FileIdentity(initial) == expected,
              isReplaceEligibleFinal(initial), initial.st_size > 0
        else { throw Failure.unsafePath("unsafe user-state final \(finalName)", .finalFile) }
        guard initial.st_size <= off_t(maximumBytes) || initial.st_size == off_t(Journal.totalBytes) else {
            throw Failure.invalidPersistence("oversized user-state final \(finalName)")
        }
        if initial.st_size == off_t(Journal.totalBytes), !isPrivateRegularFile(initial) {
            // 0644 is accepted only for installed plaintext migration input;
            // a journal is always private 0600.
            throw Failure.invalidPersistence("journal has legacy metadata \(finalName)")
        }
        let bytes = try readExact(
            descriptor, count: Int(initial.st_size), label: "user-state \(finalName)", operations: operations
        )
        var final = stat()
        guard fstat(descriptor, &final) == 0,
              unchangedFileMetadata(initial, final),
              FileIdentity(final) == expected,
              isReplaceEligibleFinal(final)
        else { throw Failure.committedIndeterminate("user-state changed during read \(finalName)", EIO) }
        try chain.reassert()
        try assertExistingFinalIdentity(finalName, in: chain.supportFD, expected: expected)
        let descriptorToClose = descriptor
        descriptorConsumed = true
        descriptor = -1
        do {
            try closeChecked(descriptorToClose, label: "read \(finalName)", operations: operations)
        } catch let failure as Failure {
            throw Failure.committedIndeterminate("read terminal close \(finalName)", code(for: failure))
        }
        try chain.reassert()
        try assertExistingFinalIdentity(finalName, in: chain.supportFD, expected: expected)
        try chain.closeAll(operations: operations)
        if let journal = Journal.decode(bytes) {
            guard let value = String(bytes: journal.payload, encoding: .utf8) else {
                throw Failure.unsafePath("invalid journal payload UTF-8 \(finalName)", .finalFile)
            }
            BenchmarkProbe.record("file_read")
            BenchmarkProbe.record("decoded_bytes", count: journal.payload.count)
            return .value(value)
        }
        if bytes.count == Journal.totalBytes {
            // Exact journal-sized records are never legacy plaintext. A torn
            // slot must be reconciled, not interpreted as a new preference.
            throw Failure.committedIndeterminate("torn or invalid journal \(finalName)", EIO)
        }
        guard let value = String(bytes: bytes, encoding: .utf8) else {
            throw Failure.unsafePath("invalid user-state UTF-8 \(finalName)", .finalFile)
        }
        BenchmarkProbe.record("file_read")
        BenchmarkProbe.record("decoded_bytes", count: bytes.count)
        if let recognizedArchive, recognizedArchive.payloadIsAccepted(value) {
            return .recognizedLegacyPlaintext(value)
        }
        return .value(value)
    }

    /// Validates the only archive that can be projected as canonical lease
    /// absence. A matching filename alone is deliberately insufficient: the
    /// held archive inode must be private, single-link, exact-size readable,
    /// digest-bound to its own structured name, and carry a parser-accepted
    /// legacy payload. Any extra or malformed residue remains fail-closed.
    private static func validatedRecognizedArchive(
        finalName: String,
        inventory: ResidueInventory,
        in directoryFD: Int32,
        archive: RecognizedArchive,
        operations: Operations
    ) throws -> String? {
        guard inventory.count > 0 else { return nil }
        guard inventory.count == 1, let name = inventory.names.first,
              name.hasPrefix(archive.prefix),
              let identity = try quarantineIdentityIfPresent(name, in: directoryFD)
        else { return nil }
        let expectedPrefix = "\(archive.prefix)\(finalName)--\(identity.device)-\(identity.inode)-"
        guard name.hasPrefix(expectedPrefix) else { throw Failure.retainedResidue("legacy archive targets another leaf") }
        let digest = String(name.dropFirst(expectedPrefix.count))
        guard digest.count == 64, digest.utf8.allSatisfy({ byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }) else { throw Failure.retainedResidue("malformed legacy archive digest") }

        let descriptor = openat(directoryFD, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        BenchmarkProbe.record("file_open")
        guard descriptor >= 0 else { throw Failure.operationFailed("openat legacy archive \(name)", errno) }
        var consumed = false
        defer {
            if !consumed {
                consumed = true
                _ = Darwin.close(descriptor)
            }
        }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0,
              FileIdentity(initial) == identity,
              isPrivateRegularFile(initial), initial.st_size > 0,
              initial.st_size <= off_t(maximumPayloadBytes)
        else { throw Failure.retainedResidue("unsafe legacy archive metadata") }
        let bytes = try readExact(descriptor, count: Int(initial.st_size), label: "legacy archive \(name)", operations: operations)
        guard SHA256.hash(data: Data(bytes)).map({ String(format: "%02x", $0) }).joined() == digest,
              let payload = String(bytes: bytes, encoding: .utf8), archive.payloadIsAccepted(payload)
        else { throw Failure.retainedResidue("legacy archive content mismatch") }
        var final = stat()
        guard fstat(descriptor, &final) == 0,
              unchangedFileMetadata(initial, final), FileIdentity(final) == identity,
              isPrivateRegularFile(final)
        else { throw Failure.retainedResidue("legacy archive changed during read") }
        guard try rawIdentityIfPresent(name, in: directoryFD) == identity else {
            throw Failure.retainedResidue("legacy archive name replaced")
        }
        consumed = true
        try closeChecked(descriptor, label: "legacy archive \(name)", operations: operations)
        return name
    }

    private final class DirectoryChain {
        struct Node {
            let fd: Int32
            let nameFromParent: String?
            let path: String
            let identity: FileIdentity
            let support: Bool
        }
        var nodes: [Node]
        let ancestryPolicy: AncestryPolicy
        var closed = false
        /// A close can report an error after consuming its numeric descriptor.
        /// Mark ownership consumed before every close attempt and never retry
        /// that integer from a defer/fallback path.
        var consumedFDs: Set<Int32> = []
        init(nodes: [Node], ancestryPolicy: AncestryPolicy) {
            self.nodes = nodes
            self.ancestryPolicy = ancestryPolicy
        }
        var supportFD: Int32 { nodes[nodes.count - 1].fd }

        func reassert() throws {
            guard !closed else { throw UserStateFileCapability.Failure.operationFailed("closed directory chain", EBADF) }
            for index in nodes.indices {
                var descriptorStatus = stat()
                guard fstat(nodes[index].fd, &descriptorStatus) == 0 else {
                    throw UserStateFileCapability.Failure.operationFailed("fstat \(nodes[index].path)", errno)
                }
                guard FileIdentity(descriptorStatus) == nodes[index].identity,
                      UserStateFileCapability.isAllowedDirectory(descriptorStatus, path: nodes[index].path, requirePrivate: nodes[index].support, ancestryPolicy: ancestryPolicy)
                else { throw UserStateFileCapability.Failure.unsafePath("detached directory \(nodes[index].path)", .supportDirectory) }
                if case let .testSandbox(rootPath, rootIdentity) = ancestryPolicy,
                   nodes[index].path == rootPath,
                   FileIdentity(descriptorStatus) != rootIdentity {
                    throw UserStateFileCapability.Failure.unsafePath("replaced TestSandbox root \(rootPath)", .supportDirectory)
                }
                guard index > 0, let name = nodes[index].nameFromParent else { continue }
                var entryStatus = stat()
                guard fstatat(nodes[index - 1].fd, name, &entryStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw UserStateFileCapability.Failure.unsafePath("missing or symlinked directory entry \(nodes[index].path)", .supportDirectory)
                }
                guard FileIdentity(entryStatus) == nodes[index].identity else {
                    throw UserStateFileCapability.Failure.unsafePath("replaced directory entry \(nodes[index].path)", .supportDirectory)
                }
            }
        }

        func closeAll(operations: Operations) throws {
            guard !closed else { return }
            for node in nodes.reversed() {
                guard consumedFDs.insert(node.fd).inserted else { continue }
                try UserStateFileCapability.requireSuccess(operations.close(node.fd), operation: "close \(node.path)")
            }
            closed = true
        }

        func closeIgnoringErrors() {
            guard !closed else { return }
            for node in nodes.reversed() where consumedFDs.insert(node.fd).inserted { _ = Darwin.close(node.fd) }
            closed = true
        }
    }

    private static func openSupportChain(
        _ directory: URL,
        createIfMissing: Bool,
        operations: Operations,
        controls: Controls,
        ancestryPolicy: AncestryPolicy
    ) throws -> DirectoryChain {
        if case let .testSandbox(rootPath, _) = ancestryPolicy,
           directory.path != rootPath, !directory.path.hasPrefix(rootPath + "/") {
            throw Failure.unsafePath("support path escapes declared TestSandbox root", .supportDirectory)
        }
        let parent = directory.deletingLastPathComponent()
        let name = try childName(directory, in: parent)
        let chain = try openCanonicalChain(to: parent, ancestryPolicy: ancestryPolicy)
        do {
            var existing = stat()
            if fstatat(chain.supportFD, name, &existing, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { throw Failure.operationFailed("fstatat \(directory.path)", errno) }
                guard createIfMissing else { throw Failure.unsafePath("missing support directory \(directory.path)", .supportDirectory) }
                controls.beforeSupportCreate(name)
                let created = mkdirat(chain.supportFD, name, privateDirectoryMode) == 0
                guard created || errno == EEXIST else { throw Failure.operationFailed("mkdirat \(directory.path)", errno) }
                // Both creator and loser bind the canonical entry and persist the
                // parent directory before a child record can report durability.
                try appendSupportDirectory(named: name, path: directory.path, to: chain, operations: operations)
                try chain.reassert()
                BenchmarkProbe.record(created ? "directory_create" : "directory_create_raced")
                BenchmarkProbe.record("directory_fsync")
                try requireSuccess(operations.directoryFsync(chain.nodes[chain.nodes.count - 2].fd), operation: "fsync parent directory \(parent.path)")
                return chain
            }
            try appendSupportDirectory(named: name, path: directory.path, to: chain, operations: operations)
            try chain.reassert()
            return chain
        } catch {
            chain.closeIgnoringErrors()
            throw error
        }
    }

    private static func openExistingSupportChain(_ directory: URL, operations: Operations, controls: Controls, ancestryPolicy: AncestryPolicy) throws -> DirectoryChain? {
        if case let .testSandbox(rootPath, _) = ancestryPolicy,
           directory.path != rootPath, !directory.path.hasPrefix(rootPath + "/") {
            throw Failure.unsafePath("support path escapes declared TestSandbox root", .supportDirectory)
        }
        let parent = directory.deletingLastPathComponent()
        let name = try childName(directory, in: parent)
        let chain = try openCanonicalChain(to: parent, ancestryPolicy: ancestryPolicy)
        do {
            var existing = stat()
            if fstatat(chain.supportFD, name, &existing, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { throw Failure.operationFailed("fstatat \(directory.path)", errno) }
                controls.afterMissingSupport(name)
                try chain.reassert()
                if fstatat(chain.supportFD, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
                    throw Failure.unsafePath("support recreated during idempotent revoke \(directory.path)", .supportDirectory)
                }
                guard errno == ENOENT else { throw Failure.operationFailed("fstatat recreated support \(directory.path)", errno) }
                try chain.closeAll(operations: operations)
                return nil
            }
            try appendSupportDirectory(named: name, path: directory.path, to: chain, operations: operations)
            try chain.reassert()
            return chain
        } catch {
            chain.closeIgnoringErrors()
            throw error
        }
    }

    private static func openCanonicalChain(to directory: URL, ancestryPolicy: AncestryPolicy) throws -> DirectoryChain {
        let path = directory.path
        let slashCount = path.utf8.reduce(into: 0) { if $1 == 47 { $0 += 1 } }
        guard directory.isFileURL, path.hasPrefix("/"), path.utf8.count <= maximumPathBytes,
              slashCount <= maximumPathComponents + 1
        else { throw Failure.unsafePath("directory must be bounded absolute", .supportDirectory) }
        if case .production = ancestryPolicy {
            let home = try productionHomePath()
            guard path == home || path.hasPrefix(home + "/") else {
                throw Failure.unsafePath("production user-state path escapes canonical home", .supportDirectory)
            }
        }
        if case let .testSandbox(rootPath, _) = ancestryPolicy,
           path != rootPath, !rootPath.hasPrefix(path + "/"), !path.hasPrefix(rootPath + "/") {
            throw Failure.unsafePath("fixture path escapes declared TestSandbox root", .supportDirectory)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count <= maximumPathComponents, components.allSatisfy(isSafeComponent) else {
            throw Failure.unsafePath("unsafe directory component", .supportDirectory)
        }
        // Fixture traversal needs search authority for the fixed system
        // ancestors, not readable descriptors that could enumerate shared
        // `/private` or `/private/tmp`. Production keeps its existing readable
        // directory descriptors for durability barriers.
        let rootFlags: Int32
        if case .testSandbox = ancestryPolicy {
            rootFlags = O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        } else {
            rootFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        }
        let rootFD = open("/", rootFlags)
        guard rootFD >= 0 else { throw Failure.operationFailed("open /", errno) }
        var rootStatus = stat()
        guard fstat(rootFD, &rootStatus) == 0,
              isAllowedDirectory(rootStatus, path: "/", requirePrivate: false, ancestryPolicy: ancestryPolicy)
        else { _ = Darwin.close(rootFD); throw Failure.unsafePath("unsafe root", .supportDirectory) }
        let chain = DirectoryChain(nodes: [
            .init(fd: rootFD, nameFromParent: nil, path: "/", identity: FileIdentity(rootStatus), support: false),
        ], ancestryPolicy: ancestryPolicy)
        do {
            var path = ""
            for component in components {
                path += "/\(component)"
                try appendDirectory(named: component, path: path, support: false, to: chain)
            }
            try chain.reassert()
            return chain
        } catch {
            chain.closeIgnoringErrors()
            throw error
        }
    }

    private static func appendDirectory(named name: String, path: String, support: Bool, to chain: DirectoryChain) throws {
        let flags: Int32
        if case let .testSandbox(rootPath, _) = chain.ancestryPolicy,
           path != rootPath, !path.hasPrefix(rootPath + "/") {
            flags = O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        } else {
            flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        }
        let fd = openat(chain.supportFD, name, flags)
        BenchmarkProbe.record("file_open")
        guard fd >= 0 else { throw Failure.unsafePath("unsafe directory \(path)", .supportDirectory) }
        var status = stat()
        guard fstat(fd, &status) == 0,
              isAllowedDirectory(status, path: path, requirePrivate: support, ancestryPolicy: chain.ancestryPolicy)
        else { _ = Darwin.close(fd); throw Failure.unsafePath("unsafe directory \(path)", .supportDirectory) }
        chain.nodes.append(.init(fd: fd, nameFromParent: name, path: path, identity: FileIdentity(status), support: support))
    }

    private static func appendSupportDirectory(
        named name: String,
        path: String,
        to chain: DirectoryChain,
        operations: Operations
    ) throws {
        try validateLeaf(name, in: chain.supportFD)
        let fd = openat(chain.supportFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        BenchmarkProbe.record("file_open")
        guard fd >= 0 else { throw Failure.unsafePath("unsafe support directory \(path)", .supportDirectory) }
        do {
            var status = stat()
            guard fstat(fd, &status) == 0 else { throw Failure.operationFailed("fstat \(path)", errno) }
            let legacy = isLegacySupportDirectory(status)
            guard legacy || directoryMetadataIsSafe(mode: status.st_mode, uid: status.st_uid, gid: status.st_gid, isDirectory: status.st_mode & S_IFMT == S_IFDIR) else {
                throw Failure.unsafePath("unsafe support directory \(path)", .supportDirectory)
            }
            if legacy {
                guard fchmod(fd, privateDirectoryMode) == 0 else { throw Failure.operationFailed("fchmod support \(path)", errno) }
                guard fstat(fd, &status) == 0,
                      directoryMetadataIsSafe(mode: status.st_mode, uid: status.st_uid, gid: status.st_gid, isDirectory: status.st_mode & S_IFMT == S_IFDIR)
                else { throw Failure.unsafePath("support migration verification \(path)", .supportDirectory) }
                var bound = stat()
                guard fstatat(chain.supportFD, name, &bound, AT_SYMLINK_NOFOLLOW) == 0,
                      FileIdentity(bound) == FileIdentity(status)
                else { throw Failure.unsafePath("support migration entry changed \(path)", .supportDirectory) }
                BenchmarkProbe.record("directory_fsync")
                try requireSuccess(operations.directoryFsync(fd), operation: "fsync migrated support \(path)")
                try requireSuccess(operations.directoryFsync(chain.supportFD), operation: "fsync support parent \(path)")
                try chain.reassert()
            }
            chain.nodes.append(.init(fd: fd, nameFromParent: name, path: path, identity: FileIdentity(status), support: true))
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
    }

    private static func payloadBytes(_ payload: String) throws -> [UInt8] {
        let count = payload.utf8.count
        guard count > 0, count <= maximumPayloadBytes else { throw Failure.unsafePath("payload size", .finalFile) }
        let bytes = Array(payload.utf8)
        BenchmarkProbe.record("decoded_bytes", count: bytes.count)
        return bytes
    }

    private static func temporaryLeaf(prefix: String) throws -> String {
        guard isSafeComponent(prefix), prefix.utf8.count + 36 <= maximumNameBytes else { throw Failure.unsafePath("unsafe temporary prefix", .temporaryFile) }
        return "\(prefix)\(UUID().uuidString.lowercased())"
    }

    private static func tombstoneLeaf(for finalName: String, identity: FileIdentity, in directoryFD: Int32) throws -> String {
        let value = ".lidswitch-revoke-\(finalName)--\(identity.device)-\(identity.inode)"
        try validateLeaf(value, in: directoryFD)
        return value
    }

    private static func recognizedArchiveLeaf(
        prefix: String, finalName: String, identity: FileIdentity, payload: [UInt8], in directoryFD: Int32
    ) throws -> String {
        guard prefix == ".lidswitch-legacy-lease-" else {
            throw Failure.unsafePath("unsupported recognized archive namespace", .quarantine)
        }
        let digest = SHA256.hash(data: Data(payload)).map { String(format: "%02x", $0) }.joined()
        let value = "\(prefix)\(finalName)--\(identity.device)-\(identity.inode)-\(digest)"
        try validateLeaf(value, in: directoryFD)
        return value
    }

    private static func quarantineLeaf(
        prefix: String, finalName: String, identity: FileIdentity, in directoryFD: Int32
    ) throws -> String {
        let value = "\(prefix)\(finalName)--\(identity.device)-\(identity.inode)-\(UUID().uuidString.lowercased())"
        try validateLeaf(value, in: directoryFD)
        return value
    }

    /// Counts retained, self-identifying quarantine entries. Darwin has no
    /// unlink-by-fd, so deleting a checked pathname could delete a same-UID
    /// replacement. Retention is deliberately bounded; operations fail closed
    /// once reconciliation is required instead of accumulating without limit.
    private static func assertBoundedQuarantineResidue(
        in directoryFD: Int32,
        reserving additionalEntries: Int
    ) throws -> ResidueInventory {
        guard additionalEntries >= 0, additionalEntries <= maximumRetainedQuarantines else {
            throw Failure.retainedResidue("invalid retained-residue reservation")
        }
        let inventory = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard inventory >= 0 else { throw Failure.operationFailed("openat tombstone inventory", errno) }
        guard let stream = fdopendir(inventory) else { _ = Darwin.close(inventory); throw Failure.operationFailed("fdopendir tombstone inventory", errno) }
        defer { _ = closedir(stream) }
        var names: [String] = []
        errno = 0
        while let pointer = readdir(stream) {
            var entry = pointer.pointee
            let length = Int(entry.d_namlen)
            guard length > 0, length <= maximumNameBytes else { throw Failure.retainedResidue("invalid retained directory entry") }
            var storage = entry.d_name
            let name: String? = withUnsafeBytes(of: &storage) { raw in
                guard length <= raw.count else { return nil }
                return String(bytes: raw.prefix(length), encoding: .utf8)
            }
            guard let name else { throw Failure.retainedResidue("non-UTF8 retained directory entry") }
            guard hasReservedUserStatePrefix(name) else { continue }
            guard isRetainedUserStateName(name) else {
                throw Failure.retainedResidue("malformed retained user-state name")
            }
            names.append(name)
            guard names.count + additionalEntries <= maximumRetainedQuarantines else {
                throw Failure.retainedResidue("retained-residue capacity exhausted")
            }
            if name.hasPrefix(".lidswitch-legacy-lease-") {
                guard let identity = try quarantineIdentityIfPresent(name, in: directoryFD),
                      hasStructuredLegacyArchiveIdentity(name, identity: identity)
                else { throw Failure.retainedResidue("ambiguous legacy archive residue") }
            } else if name.hasPrefix(".lidswitch-") {
                guard let identity = try quarantineIdentityIfPresent(name, in: directoryFD),
                      hasStructuredRetainedIdentity(name, identity: identity)
                else { throw Failure.retainedResidue("ambiguous quarantine residue") }
            } else if try namedIdentityIfPresent(name, in: directoryFD) == nil {
                throw Failure.retainedResidue("missing raw temporary residue")
            }
        }
        guard errno == 0 else { throw Failure.operationFailed("readdir tombstone inventory", errno) }
        return ResidueInventory(count: names.count, names: names)
    }

    private static func isRetainedUserStateName(_ name: String) -> Bool {
        if [".lidswitch-revoke-", ".lidswitch-prior-", ".lidswitch-rejected-", ".lidswitch-abandoned-", ".lidswitch-legacy-lease-"]
            .contains(where: { name.hasPrefix($0) }) { return true }
        for prefix in [".desired-state.", ".activation-lease."] {
            guard name.hasPrefix(prefix) else { continue }
            return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
        }
        return false
    }

    /// A successful one-time plaintext-to-journal migration necessarily
    /// retains the exact displaced inode because Darwin has no unlink-by-fd.
    /// That single identity-bound prior leaf is audit evidence, not authority,
    /// and must not make the newly verified canonical journal unreadable.
    private static func isSinglePriorMigrationResidue(
        inventory: ResidueInventory,
        finalName: String
    ) -> Bool {
        inventory.count == 1
            && inventory.names.first?.hasPrefix(".lidswitch-prior-\(finalName)--") == true
    }

    private static func hasReservedUserStatePrefix(_ name: String) -> Bool {
        name.hasPrefix(".lidswitch-")
            || name.hasPrefix(".desired-state.")
            || name.hasPrefix(".activation-lease.")
    }

    private static func hasStructuredRetainedIdentity(_ name: String, identity: FileIdentity) -> Bool {
        let marker = "--\(identity.device)-\(identity.inode)"
        guard let range = name.range(of: marker, options: .backwards) else { return false }
        let suffix = name[range.upperBound...]
        return suffix.isEmpty || (suffix.first == "-" && UUID(uuidString: String(suffix.dropFirst())) != nil)
    }

    private static func hasStructuredLegacyArchiveIdentity(_ name: String, identity: FileIdentity) -> Bool {
        let marker = "--\(identity.device)-\(identity.inode)-"
        guard let range = name.range(of: marker, options: .backwards) else { return false }
        let digest = name[range.upperBound...]
        return digest.count == 64 && digest.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func childName(_ child: URL, in parent: URL) throws -> String {
        let name = child.lastPathComponent
        guard child.isFileURL, child.deletingLastPathComponent().path == parent.path, isSafeComponent(name) else {
            throw Failure.unsafePath("not a direct child", .finalFile)
        }
        return name
    }

    private static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.utf8.count <= maximumNameBytes
            && !value.utf8.contains(0) && !value.contains("/")
    }

    private static func validateLeaf(_ value: String, in directoryFD: Int32) throws {
        guard isSafeComponent(value) else {
            throw Failure.unsafePath("leaf exceeds held-directory name limit", .finalFile)
        }
        let limit = try nameLimit(in: directoryFD)
        guard value.utf8.count <= limit else {
            throw Failure.unsafePath("leaf exceeds held-directory name limit", .finalFile)
        }
    }

    private static func nameLimit(in directoryFD: Int32) throws -> Int {
        errno = 0
        let result = fpathconf(directoryFD, _PC_NAME_MAX)
        if result == -1 {
            // POSIX permits -1 with errno==0 only for a platform-defined
            // unlimited value. The preliminary 255-byte cap remains binding.
            guard errno == 0 else { throw Failure.operationFailed("fpathconf _PC_NAME_MAX", errno) }
            return maximumNameBytes
        }
        guard result > 0 else { throw Failure.operationFailed("fpathconf _PC_NAME_MAX", EIO) }
        return min(maximumNameBytes, Int(result))
    }

    private static func writeAll(_ bytes: [UInt8], to descriptor: Int32, label: String, operations: Operations) throws {
        guard !bytes.isEmpty else { throw Failure.operationFailed("empty write \(label)", EIO) }
        var offset = 0
        while offset < bytes.count {
            let result = operations.write(descriptor, Array(bytes[offset...]))
            switch writeDecision(result: result.0, errorCode: result.1) {
            case let .accept(count):
                guard count <= bytes.count - offset else { throw Failure.operationFailed("write \(label)", EIO) }
                BenchmarkProbe.record("file_write")
                offset += count
            case .retry: continue
            case let .fail(code): throw Failure.operationFailed("write \(label)", code)
            }
        }
    }

    /// Returns true only when a current private final is a valid journal and
    /// the inactive slot has been durably advanced. Plaintext finals return
    /// false and take the one-time migration publication path.
    private static func updateJournalIfPresent(
        payload: [UInt8], named name: String, in directoryFD: Int32,
        chain: DirectoryChain, temporaryPrefix: String, commitGuard: (@Sendable () -> Bool)?, operations: Operations
    ) throws -> JournalUpdateResult {
        guard let expected = try existingFinalIdentityIfPresent(name, in: directoryFD) else { return .notJournal }
        let descriptor = openat(directoryFD, name, O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        BenchmarkProbe.record("file_open")
        guard descriptor >= 0 else { throw Failure.operationFailed("openat journal \(name)", errno) }
        var consumed = false
        defer {
            if !consumed {
                consumed = true
                _ = Darwin.close(descriptor)
            }
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              FileIdentity(status) == expected,
              isReplaceEligibleFinal(status)
        else { throw Failure.unsafePath("journal metadata changed \(name)", .finalFile) }
        guard status.st_size == off_t(Journal.totalBytes) else {
            guard status.st_size > 0, status.st_size <= off_t(maximumPayloadBytes) else {
                throw Failure.invalidPersistence("invalid legacy size \(name)")
            }
            let legacyBytes = try readExact(descriptor, count: Int(status.st_size), label: "legacy \(name)", operations: operations)
            guard let legacy = String(bytes: legacyBytes, encoding: .utf8), legacyPlaintextIsAccepted(legacy, temporaryPrefix: temporaryPrefix) else {
                throw Failure.invalidPersistence("invalid legacy payload \(name)")
            }
            var final = stat()
            guard fstat(descriptor, &final) == 0,
                  unchangedFileMetadata(status, final), FileIdentity(final) == expected,
                  isReplaceEligibleFinal(final)
            else { throw Failure.committedIndeterminate("legacy changed during validation \(name)", EIO) }
            try chain.reassert()
            try assertExistingFinalIdentity(name, in: directoryFD, expected: expected)
            return .notJournal
        }
        guard isPrivateRegularFile(status) else {
            throw Failure.invalidPersistence("legacy file has journal-sized bytes \(name)")
        }
        let record = try readExact(descriptor, count: Journal.totalBytes, label: "journal \(name)", operations: operations)
        guard let current = Journal.decode(record) else {
            throw Failure.committedIndeterminate("torn or invalid journal \(name)", EIO)
        }
        guard commitGuard?() ?? true else { throw Failure.commitRejected(name) }
        if current.payload == payload {
            try chain.reassert()
            try assertNamedIdentity(name, in: directoryFD, expected: expected)
            consumed = true
            try closeChecked(descriptor, label: "journal \(name)", operations: operations)
            return .unchanged
        }
        guard let next = Journal.next(current, payload: payload, bytes: record) else {
            throw Failure.committedIndeterminate("journal generation \(name)", EOVERFLOW)
        }
        let slotOffset = Journal.headerBytes + next.slot * Journal.slotBytes
        let slot = Array(next.record[slotOffset..<(slotOffset + Journal.slotBytes)])
        do {
            try pwriteAll(slot, to: descriptor, offset: off_t(slotOffset), label: "journal slot \(name)", operations: operations)
            BenchmarkProbe.record("file_fsync")
            try requireSuccess(operations.fileFsync(descriptor), operation: "fsync journal \(name)")
            try requireSuccess(operations.fileFullSync(descriptor), operation: "F_FULLFSYNC journal \(name)")
            let persisted = try preadExact(descriptor, count: Journal.totalBytes, offset: 0, label: "journal verify \(name)", operations: operations)
            guard let observed = Journal.decode(persisted),
                  observed.generation == current.generation + 1,
                  observed.payload == payload
            else { throw Failure.committedIndeterminate("journal reread \(name)", EIO) }
            var final = stat()
            guard fstat(descriptor, &final) == 0,
                  unchangedFileMetadata(status, final),
                  FileIdentity(final) == expected
            else { throw Failure.committedIndeterminate("journal final metadata \(name)", EIO) }
            try chain.reassert()
            try assertNamedIdentity(name, in: directoryFD, expected: expected)
            consumed = true
            try closeChecked(descriptor, label: "journal \(name)", operations: operations)
            return .updated
        } catch let failure as Failure {
            throw Failure.committedIndeterminate("journal update \(name)", code(for: failure))
        }
    }

    private static func readExact(_ descriptor: Int32, count: Int, label: String, operations: Operations) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let observed = operations.read(descriptor, count - offset)
            if observed.result > 0 {
                let observedCount = Int(observed.result)
                guard observed.bytes.count == observedCount, observedCount <= count - offset else {
                    throw Failure.operationFailed("read \(label)", EIO)
                }
                bytes.replaceSubrange(offset..<(offset + observedCount), with: observed.bytes)
                offset += observedCount
                continue
            }
            if observed.result < 0, observed.errorCode == EINTR { continue }
            throw Failure.operationFailed("read \(label)", observed.result == 0 ? EIO : observed.errorCode)
        }
        while true {
            let observed = operations.read(descriptor, 1)
            if observed.result == 0 { return bytes }
            if observed.result < 0, observed.errorCode == EINTR { continue }
            throw Failure.unsafePath("journal EOF proof \(label)", .finalFile)
        }
    }

    private static func preadExact(
        _ descriptor: Int32, count: Int, offset: off_t, label: String, operations: Operations
    ) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var consumed = 0
        while consumed < count {
            let observed = operations.pread(descriptor, count - consumed, offset + off_t(consumed))
            if observed.result > 0 {
                let observedCount = Int(observed.result)
                guard observed.bytes.count == observedCount, observedCount <= count - consumed else {
                    throw Failure.operationFailed("pread \(label)", EIO)
                }
                bytes.replaceSubrange(consumed..<(consumed + observedCount), with: observed.bytes)
                consumed += observedCount
                continue
            }
            if observed.result < 0, observed.errorCode == EINTR { continue }
            throw Failure.operationFailed("pread \(label)", observed.result == 0 ? EIO : observed.errorCode)
        }
        while true {
            let extra = operations.pread(descriptor, 1, offset + off_t(count))
            if extra.result == 0 { return bytes }
            if extra.result < 0, extra.errorCode == EINTR { continue }
            throw Failure.unsafePath("journal pread EOF proof \(label)", .finalFile)
        }
    }

    private static func legacyPlaintextIsAccepted(_ payload: String, temporaryPrefix: String) -> Bool {
        switch temporaryPrefix {
        case ".desired-state.":
            let preferences = PowerPreferences.parse(payload)
            // Battery activation is no longer an authorization state, but the
            // exact legacy two-key record is safe to migrate to the inert
            // journal.  Do not admit broader malformed input merely because
            // it also happens to contain a battery flag.
            return !preferences.invalidPersistenceDetected
                || isCanonicalLegacyBatteryResidue(payload)
        case ".activation-lease.":
            return ActivationLease.parse(payload) != nil
        default:
            return false
        }
    }

    private static func isCanonicalLegacyBatteryResidue(_ payload: String) -> Bool {
        let fields = payload.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        guard fields.count == 2 else { return false }
        var mode: Substring?
        var battery: Substring?
        for field in fields {
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return false }
            switch parts[0] {
            case "mode":
                guard mode == nil, parts[1] == "enabled" || parts[1] == "disabled" else { return false }
                mode = parts[1]
            case "battery":
                guard battery == nil, parts[1] == "enabled" else { return false }
                battery = parts[1]
            default:
                return false
            }
        }
        return mode != nil && battery == "enabled"
    }

    private static func pwriteAll(
        _ bytes: [UInt8], to descriptor: Int32, offset: off_t, label: String, operations: Operations
    ) throws {
        var written = 0
        while written < bytes.count {
            let part = Array(bytes[written...])
            let result = operations.pwrite(descriptor, part, offset + off_t(written))
            switch writeDecision(result: result.0, errorCode: result.1) {
            case let .accept(count):
                guard count <= bytes.count - written else { throw Failure.operationFailed("pwrite \(label)", EIO) }
                written += count
            case .retry: continue
            case let .fail(code): throw Failure.operationFailed("pwrite \(label)", code)
            }
        }
    }

    private static func verifyPublishedFile(
        named name: String, in directoryFD: Int32, expectedIdentity: FileIdentity,
        expectedBytes: [UInt8], operations: Operations,
        afterRead: @Sendable () -> Void
    ) throws {
        let fd = openat(directoryFD, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        BenchmarkProbe.record("file_open")
        guard fd >= 0 else { throw Failure.operationFailed("openat final \(name)", errno) }
        var consumed = false
        defer {
            if !consumed {
                consumed = true
                _ = Darwin.close(fd)
            }
        }
        var initial = stat()
            guard fstat(fd, &initial) == 0, isPrivateRegularFile(initial),
                  FileIdentity(initial) == expectedIdentity, initial.st_size == off_t(expectedBytes.count)
            else {
                throw Failure.unsafePath("unsafe final \(name)", .finalFile)
            }
            let actual = try readExact(fd, count: expectedBytes.count, label: "final \(name)", operations: operations)
            var final = stat()
            guard fstat(fd, &final) == 0,
                  unchangedFileMetadata(initial, final),
                  publicationVerification(expectedIdentity: expectedIdentity, observedIdentity: FileIdentity(final), metadataIsSafe: isPrivateRegularFile(final), expectedBytes: expectedBytes, observedBytes: actual) == .accepted
            else {
                throw Failure.unsafePath("final changed during publication \(name)", .finalFile)
            }
            afterRead()
            consumed = true
        try closeChecked(fd, label: name, operations: operations)
    }

    // Kept as a local seam-free metadata equality primitive so publication
    // verifies identity, type, ownership, mode, links and size after bytes.
    private static func unchangedFileMetadata(_ first: stat, _ second: stat) -> Bool {
        FileIdentity(first) == FileIdentity(second)
            && first.st_mode == second.st_mode
            && first.st_uid == second.st_uid
            && first.st_gid == second.st_gid
            && first.st_nlink == second.st_nlink
            && first.st_size == second.st_size
    }

    private static func namedIdentityIfPresent(_ name: String, in directoryFD: Int32) throws -> FileIdentity? {
        var status = stat()
        if fstatat(directoryFD, name, &status, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw Failure.operationFailed("fstatat \(name)", errno) }
            return nil
        }
        guard isPrivateRegularFile(status) else { throw Failure.unsafePath("unsafe final \(name)", .finalFile) }
        return FileIdentity(status)
    }

    private static func existingFinalIdentityIfPresent(_ name: String, in directoryFD: Int32) throws -> FileIdentity? {
        var status = stat()
        if fstatat(directoryFD, name, &status, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw Failure.operationFailed("fstatat \(name)", errno) }
            return nil
        }
        guard isReplaceEligibleFinal(status) else { throw Failure.unsafePath("unsafe existing final \(name)", .finalFile) }
        return FileIdentity(status)
    }

    private static func assertNamedIdentity(_ name: String, in directoryFD: Int32, expected: FileIdentity) throws {
        guard try namedIdentityIfPresent(name, in: directoryFD) == expected else { throw Failure.unsafePath("replaced final \(name)", .finalFile) }
    }

    private static func assertExistingFinalIdentity(_ name: String, in directoryFD: Int32, expected: FileIdentity) throws {
        guard try existingFinalIdentityIfPresent(name, in: directoryFD) == expected else { throw Failure.unsafePath("replaced existing final \(name)", .finalFile) }
    }

    private static func assertAbsent(_ name: String, in directoryFD: Int32) throws {
        guard try namedIdentityIfPresent(name, in: directoryFD) == nil else { throw Failure.unsafePath("recreated final \(name)", .finalFile) }
    }

    /// Atomically moves the live leaf into a unique name and proves that the
    /// moved inode is the held inode. It intentionally never unlinks a name:
    /// another same-UID process can replace any pathname after verification.
    @discardableResult
    private static func quarantineNamedIdentity(
        _ name: String,
        in directoryFD: Int32,
        expected: FileIdentity,
        prefix: String,
        operations: Operations,
        allowLegacyFinal: Bool = false
    ) throws -> String {
        if allowLegacyFinal {
            try assertExistingFinalIdentity(name, in: directoryFD, expected: expected)
        } else {
            try assertNamedIdentity(name, in: directoryFD, expected: expected)
        }
        let quarantine = try quarantineLeaf(prefix: prefix, finalName: name, identity: expected, in: directoryFD)
        try requireSuccess(
            operations.renameExclusive(directoryFD, name, directoryFD, quarantine),
            operation: "renameatx_np quarantine \(name)"
        )
        guard try rawIdentityIfPresent(quarantine, in: directoryFD) == expected else {
            // The exclusive rename succeeded, so the canonical name changed;
            // retain the moved evidence and force caller reconciliation.
            throw Failure.committedIndeterminate("quarantine replaced \(name)", EIO)
        }
        return quarantine
    }

    private static func rawIdentityIfPresent(_ name: String, in directoryFD: Int32) throws -> FileIdentity? {
        var status = stat()
        if fstatat(directoryFD, name, &status, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw Failure.operationFailed("fstatat \(name)", errno) }
            return nil
        }
        return FileIdentity(status)
    }

    private static func quarantineIdentityIfPresent(_ name: String, in directoryFD: Int32) throws -> FileIdentity? {
        var status = stat()
        if fstatat(directoryFD, name, &status, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw Failure.operationFailed("fstatat \(name)", errno) }
            return nil
        }
        guard isReplaceEligibleFinal(status) else {
            throw Failure.unsafePath("unsafe quarantine residue \(name)", .quarantine)
        }
        return FileIdentity(status)
    }

    private static func validatePrivateRegularFile(_ descriptor: Int32, label: String) throws -> FileIdentity {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw Failure.operationFailed("fstat \(label)", errno) }
        guard isPrivateRegularFile(status) else { throw Failure.unsafePath("unsafe private file \(label)", .temporaryFile) }
        return FileIdentity(status)
    }

    private static func closeChecked(_ descriptor: Int32, label: String, operations: Operations) throws {
        try requireSuccess(operations.close(descriptor), operation: "close \(label)")
    }

    private static func requireSuccess(_ result: (Int32, Int32), operation: String) throws {
        guard result.0 == 0 else { throw Failure.operationFailed(operation, result.1) }
    }

    private static func code(for failure: Failure) -> Int32 {
        switch failure {
        case let .operationFailed(_, code), let .committedIndeterminate(_, code), let .revokedIndeterminate(_, code): return code
        case .unsafePath, .invalidPersistence, .commitRejected, .retainedResidue: return EIO
        }
    }

    private static func isAllowedDirectory(
        _ status: stat, path: String, requirePrivate: Bool, ancestryPolicy: AncestryPolicy
    ) -> Bool {
        guard status.st_mode & S_IFMT == S_IFDIR else { return false }
        if requirePrivate { return directoryMetadataIsSafe(mode: status.st_mode, uid: status.st_uid, gid: status.st_gid, isDirectory: true) }
        if path == "/" {
            return status.st_uid == 0 && status.st_gid == 0
                && status.st_mode & 0o7777 == 0o755
        }
        if path == "/private/tmp" {
            guard case let .testSandbox(rootPath, _) = ancestryPolicy,
                  rootPath.hasPrefix("/private/tmp/")
            else { return false }
            return status.st_uid == 0 && status.st_gid == 0
                && status.st_mode == (S_IFDIR | S_ISVTX | 0o777)
        }
        if path == "/private" {
            guard case let .testSandbox(rootPath, _) = ancestryPolicy,
                  rootPath.hasPrefix("/private/tmp/")
            else { return false }
            return status.st_uid == 0 && status.st_gid == 0 && status.st_mode & 0o7777 == 0o755
        }
        guard case .production = ancestryPolicy else {
            // Fixture descendants remain exact current-user private nodes.
            return status.st_uid == getuid() && status.st_gid == getgid()
                && status.st_mode & 0o7777 == privateDirectoryMode
        }
        // Production recognizes only this Mac's fixed system chain, then the
        // passwd-bound current home and its private descendants. There is no
        // generic "foreign but non-writable" ancestor allowance.
        if path == "/" {
            return status.st_uid == 0 && status.st_gid == 0 && status.st_mode & 0o7777 == 0o755
        }
        if path == "/Users" {
            return status.st_uid == 0 && status.st_gid == 80 && status.st_mode & 0o7777 == 0o755
        }
        guard let home = productionHomePathOrNil(), path == home || path.hasPrefix(home + "/") else { return false }
        guard status.st_uid == getuid() && status.st_gid == getgid() else { return false }
        if path == home {
            return status.st_mode & 0o7777 == 0o700 || status.st_mode & 0o7777 == 0o750
        }
        return status.st_mode & 0o7777 == privateDirectoryMode
    }

    private static func productionHomePath() throws -> String {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
            throw Failure.operationFailed("getpwuid current user", errno == 0 ? EIO : errno)
        }
        let path = String(cString: directory)
        guard path.hasPrefix("/"), path.utf8.count <= maximumPathBytes else {
            throw Failure.unsafePath("invalid passwd home", .supportDirectory)
        }
        return path
    }

    private static func productionHomePathOrNil() -> String? {
        do { return try productionHomePath() }
        catch { return nil }
    }

    private static func isPrivateRegularFile(_ status: stat) -> Bool {
        privateRegularMetadataIsSafe(mode: status.st_mode, uid: status.st_uid, gid: status.st_gid, linkCount: status.st_nlink, isRegular: status.st_mode & S_IFMT == S_IFREG)
    }

    private static func isReplaceEligibleFinal(_ status: stat) -> Bool {
        replaceEligibleFinalMetadataIsSafe(
            mode: status.st_mode, uid: status.st_uid, gid: status.st_gid,
            linkCount: status.st_nlink, isRegular: status.st_mode & S_IFMT == S_IFREG
        )
    }

    private static func isLegacySupportDirectory(_ status: stat) -> Bool {
        legacySupportMetadataIsSafe(
            mode: status.st_mode, uid: status.st_uid, gid: status.st_gid,
            isDirectory: status.st_mode & S_IFMT == S_IFDIR
        )
            && status.st_mode & 0o777 == 0o755
    }
}
