import Darwin
import Foundation

/// The ownership rule used while opening the complete support-directory chain.
/// Production state follows the one canonical macOS support path: `/` and
/// `/Library` are root:wheel, `/Library/Application Support` is root:admin,
/// and the final LidSwitch directory returns to root:wheel.
/// Test fixtures must explicitly opt into the narrowly-scoped sticky-temp rule.
public enum RootStateDirectoryAncestorPolicy: Equatable, Sendable {
    case production
    case testTemporaryDirectory
}

/// A held, descriptor-anchored capability for one exact root-state directory.
/// No later operation resolves its pathname again.
public final class VerifiedRootStateDirectory {
    public struct Expectations: Equatable, Sendable {
        public let ownerUID: uid_t
        public let groupID: gid_t
        public let mode: mode_t

        public init(ownerUID: uid_t, groupID: gid_t, mode: mode_t = 0o755) {
            self.ownerUID = ownerUID
            self.groupID = groupID
            self.mode = mode
        }

        public static let production = Expectations(ownerUID: 0, groupID: 0, mode: 0o755)
    }

    public enum EntryState: Equatable, Sendable { case absent, present, unknown }
    public enum PublicationFailure: Equatable, Sendable {
        case unsafeName, temporaryCreate, temporaryMetadata, write, temporaryBarrier, rename
        case directoryBarrier, reopen, finalIdentity, finalMetadata, finalBytes, parser, finalBarrier
        case recoveryRequired, transactionInactive, reentrant
    }
    public enum PublicationResult: Equatable, Sendable {
        /// No rename occurred; retry/cleanup policy remains with the caller.
        case notPublished(PublicationFailure)
        /// Rename occurred; the exact final state could not be proven. Never
        /// retry this as though nothing was published.
        case publishedButUnverified(PublicationFailure)
        case published
    }
    public enum RemovalResult: Equatable, Sendable {
        case alreadyAbsent
        case removed
        /// The entry may have been unlinked but durability or absence could not
        /// be proven, so callers must preserve recovery ownership.
        case removalUnverified
        case unsafeEntry
        case recoveryRequired
        case transactionInactive
        case reentrant
    }
    public enum LockProvisionFailure: Equatable, Sendable {
        case unsafeName, create, metadata, existingInvalid, fileBarrier, directoryBarrier
    }
    public enum LockProvisionResult: Equatable, Sendable {
        case provisioned
        case alreadyPresent
        /// The exclusive create succeeded, but durability of the entry is not
        /// proven. It must never be treated as a clean absence/retry.
        case provisionedButUnverified(LockProvisionFailure)
        case failure(LockProvisionFailure)
    }

    /// Controlled fault seams for deterministic source tests. Production uses
    /// a full data-file barrier and the separate documented directory-entry
    /// synchronization path.
    struct Operations {
        let fileBarrier: (Int32) -> Bool
        let directoryEntryBarrier: (Int32) -> Bool
        let rename: (Int32, String, Int32, String) -> Int32
        let renameExclusive: (Int32, String, Int32, String) -> Int32
        let unlink: (Int32, String) -> Int32
        let beforeFinalBinding: (Int32, String) -> Void
        let beforeQuarantineVerify: (Int32, String) -> Void
        let beforeQuarantineUnlink: (Int32, String) -> Void

        init(
            fileBarrier: @escaping (Int32) -> Bool,
            directoryEntryBarrier: @escaping (Int32) -> Bool,
            rename: @escaping (Int32, String, Int32, String) -> Int32,
            unlink: @escaping (Int32, String) -> Int32,
            beforeFinalBinding: @escaping (Int32, String) -> Void = { _, _ in },
            beforeQuarantineVerify: @escaping (Int32, String) -> Void = { _, _ in },
            beforeQuarantineUnlink: @escaping (Int32, String) -> Void = { _, _ in },
            renameExclusive: @escaping (Int32, String, Int32, String) -> Int32 = { oldFD, oldName, newFD, newName in
                Darwin.renameatx_np(oldFD, oldName, newFD, newName, UInt32(RENAME_EXCL))
            }
        ) {
            self.fileBarrier = fileBarrier
            self.directoryEntryBarrier = directoryEntryBarrier
            self.rename = rename
            self.renameExclusive = renameExclusive
            self.unlink = unlink
            self.beforeFinalBinding = beforeFinalBinding
            self.beforeQuarantineVerify = beforeQuarantineVerify
            self.beforeQuarantineUnlink = beforeQuarantineUnlink
        }

        /// A computed value avoids publishing a shared non-Sendable closure
        /// aggregate under Swift 6 strict concurrency. The production seams
        /// are capture-free and each directory receives its own immutable set.
        static var system: Operations {
            Operations(
                fileBarrier: { fd in Darwin.fsync(fd) == 0 && Darwin.fcntl(fd, F_FULLFSYNC) == 0 },
                // macOS documents fsync for synchronizing directory entries;
                // F_FULLFSYNC is a data-file barrier and is intentionally not
                // requested for a directory descriptor.
                directoryEntryBarrier: { fd in Darwin.fsync(fd) == 0 },
                rename: { oldFD, oldName, newFD, newName in Darwin.renameat(oldFD, oldName, newFD, newName) },
                unlink: { fd, name in Darwin.unlinkat(fd, name, 0) },
                beforeFinalBinding: { _, _ in },
                beforeQuarantineVerify: { _, _ in },
                beforeQuarantineUnlink: { _, _ in },
                renameExclusive: { oldFD, oldName, newFD, newName in
                    Darwin.renameatx_np(oldFD, oldName, newFD, newName, UInt32(RENAME_EXCL))
                }
            )
        }
    }

    private var descriptors: [Int32]
    private let expectations: Expectations
    private let operations: Operations

    public var directoryDescriptor: Int32? { descriptors.last }

    private enum QuarantineInventory: Equatable { case clean, orphan, bothPresent, unknown }
    private static let quarantineSuffix = ".lidswitch-delete"

    /// A non-forgeable-to-clients capability whose mutation surface remains
    /// active only while `RootStateLock` owns the verified lock descriptor.
    /// Every LidSwitch/helper/admin root-state writer must use this fixed lock.
    /// An arbitrary malicious root process that bypasses that cooperation lies
    /// outside this capability guarantee. It supports multi-file transitions.
    public final class Transaction {
        private let directory: VerifiedRootStateDirectory
        private let lockDescriptor: Int32
        private let activityCondition = NSCondition()
        private var active = true
        private var operationInProgress = false
        private var afterUnlockActions: [() -> Void] = []

        fileprivate init(directory: VerifiedRootStateDirectory, lockDescriptor: Int32) {
            self.directory = directory
            self.lockDescriptor = lockDescriptor
        }

        fileprivate func invalidate() {
            activityCondition.lock()
            active = false
            while operationInProgress { activityCondition.wait() }
            activityCondition.unlock()
        }

        /// Registers non-authoritative work that must start only after this
        /// transaction's root lock is released.  The action receives no
        /// transaction/capability and therefore cannot extend the mutation
        /// boundary; it is suitable for status and containment dispatch only.
        @discardableResult
        public func afterUnlock(_ action: @escaping () -> Void) -> Bool {
            withOperation(inactive: false, reentrant: false) {
                afterUnlockActions.append(action)
                return true
            }
        }

        fileprivate func runAfterUnlockActions() {
            activityCondition.lock()
            let actions = afterUnlockActions
            afterUnlockActions.removeAll()
            activityCondition.unlock()
            actions.forEach { $0() }
        }

        private func withOperation<T>(inactive: T, reentrant: T, _ body: () -> T) -> T {
            activityCondition.lock()
            guard active else {
                activityCondition.unlock()
                return inactive
            }
            // Admission is intentionally short-held. Both same-thread parser
            // reentry and synchronous cross-thread reentry observe this flag
            // and return a typed rejection without blocking on a held mutex.
            guard !operationInProgress else {
                activityCondition.unlock()
                return reentrant
            }
            operationInProgress = true
            activityCondition.unlock()

            let result = body()

            activityCondition.lock()
            operationInProgress = false
            activityCondition.broadcast()
            activityCondition.unlock()
            return result
        }

        /// Publishes exactly one byte payload through an exclusive no-follow
        /// temp while the held root-state lock is active.
        public func publish(
            _ bytes: Data,
            to basename: String,
            parser: (Data) -> Bool = { _ in true }
        ) -> PublicationResult {
            withOperation(
                inactive: .notPublished(.transactionInactive),
                reentrant: .notPublished(.reentrant)
            ) { publishLocked(bytes, to: basename, parser: parser) }
        }

        private func publishLocked(
            _ bytes: Data,
            to basename: String,
            parser: (Data) -> Bool
        ) -> PublicationResult {
            guard lockDescriptor >= 0,
                  VerifiedRootStateDirectory.isSafeBasename(basename), let directoryFD = directory.directoryDescriptor
            else { return .notPublished(.unsafeName) }
            guard VerifiedRootStateDirectory.hasBoundedStateNames(basename) else {
                return .notPublished(.unsafeName)
            }
            guard directory.quarantineInventory(for: basename) == .clean else {
                return .notPublished(.recoveryRequired)
            }
            let temporary = ".\(basename).new.\(UUID().uuidString.lowercased())"
            let fd = openat(directoryFD, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { return .notPublished(.temporaryCreate) }
            var renamed = false
            defer {
                Darwin.close(fd)
                if !renamed { _ = Darwin.unlinkat(directoryFD, temporary, 0) }
            }
            guard Darwin.fchmod(fd, S_IRUSR | S_IWUSR) == 0 else { return .notPublished(.temporaryMetadata) }
            var temporaryMetadata = stat()
            guard fstat(fd, &temporaryMetadata) == 0,
                  VerifiedRootStateDirectory.validPrivateFile(temporaryMetadata, expectations: directory.expectations)
            else { return .notPublished(.temporaryMetadata) }
            guard VerifiedRootStateDirectory.writeExactly(bytes, to: fd) else { return .notPublished(.write) }
            guard directory.operations.fileBarrier(fd) else { return .notPublished(.temporaryBarrier) }
            guard directory.operations.rename(directoryFD, temporary, directoryFD, basename) == 0 else { return .notPublished(.rename) }
            renamed = true
            guard directory.operations.directoryEntryBarrier(directoryFD) else { return .publishedButUnverified(.directoryBarrier) }
            guard let final = directory.openForRead(basename) else { return .publishedButUnverified(.reopen) }
            defer { Darwin.close(final) }
            var initial = stat()
            guard fstat(final, &initial) == 0,
                  initial.st_dev == temporaryMetadata.st_dev,
                  initial.st_ino == temporaryMetadata.st_ino
            else { return .publishedButUnverified(.finalIdentity) }
            guard VerifiedRootStateDirectory.validPrivateFile(initial, expectations: directory.expectations), initial.st_size == off_t(bytes.count) else {
                return .publishedButUnverified(.finalMetadata)
            }
            guard let actual = VerifiedRootStateDirectory.readExactly(final, count: bytes.count), actual == bytes else {
                return .publishedButUnverified(.finalBytes)
            }
            guard parser(actual) else { return .publishedButUnverified(.parser) }
            var finalMetadata = stat()
            guard fstat(final, &finalMetadata) == 0, VerifiedRootStateDirectory.sameMetadata(initial, finalMetadata) else {
                return .publishedButUnverified(.finalMetadata)
            }
            guard directory.operations.fileBarrier(final) else { return .publishedButUnverified(.finalBarrier) }
            directory.operations.beforeFinalBinding(directoryFD, basename)
            var bound = stat()
            guard fstatat(directoryFD, basename, &bound, AT_SYMLINK_NOFOLLOW) == 0,
                  VerifiedRootStateDirectory.sameIdentity(initial, bound),
                  VerifiedRootStateDirectory.validPrivateFile(bound, expectations: directory.expectations)
            else { return .publishedButUnverified(.finalIdentity) }
            return .published
        }

        /// For cooperative fixed-lock writers, moves the public leaf to an
        /// exclusive quarantine and unlinks only the revalidated quarantine
        /// name. The last seam may substitute it; that produces uncertainty and
        /// preserves the deterministic quarantine for recovery rather than an
        /// impossible inode-unlink claim against a bypassing root process.
        public func remove(_ basename: String) -> RemovalResult {
            withOperation(
                inactive: .transactionInactive,
                reentrant: .reentrant
            ) { removeLocked(basename, expected: nil) }
        }

        /// Completes either the ordinary public->quarantine removal or an
        /// interrupted orphan-quarantine removal, but only when exact bounded
        /// bytes satisfy the caller's parser. This is used by crash-journal
        /// cleanup after a durable safe proof; arbitrary orphan leaves remain a
        /// hard recovery boundary.
        public func removeOrResume(
            _ basename: String,
            maximumBytes: Int,
            parser: @escaping (Data) -> Bool
        ) -> RemovalResult {
            guard maximumBytes >= 0, maximumBytes <= 64 * 1_024 else { return .unsafeEntry }
            return withOperation(
                inactive: .transactionInactive,
                reentrant: .reentrant
            ) { removeLocked(basename, expected: (maximumBytes, parser)) }
        }

        private func removeLocked(
            _ basename: String,
            expected: (maximumBytes: Int, parser: (Data) -> Bool)?
        ) -> RemovalResult {
            guard lockDescriptor >= 0,
                  VerifiedRootStateDirectory.isSafeBasename(basename), let directoryFD = directory.directoryDescriptor
            else { return .unsafeEntry }
            guard VerifiedRootStateDirectory.hasBoundedStateNames(basename) else { return .unsafeEntry }
            guard let quarantine = VerifiedRootStateDirectory.quarantineBasename(for: basename) else { return .unsafeEntry }
            switch directory.quarantineInventory(for: basename) {
            case .clean:
                break
            case .orphan:
                guard let expected else { return .recoveryRequired }
                return removeVerifiedOrphanLocked(
                    basename: basename,
                    quarantine: quarantine,
                    maximumBytes: expected.maximumBytes,
                    parser: expected.parser,
                    directoryFD: directoryFD
                )
            case .bothPresent, .unknown:
                return .recoveryRequired
            }
            var initial = stat()
            guard fstatat(directoryFD, basename, &initial, AT_SYMLINK_NOFOLLOW) == 0 else {
                guard errno == ENOENT else { return .unsafeEntry }
                guard directory.operations.directoryEntryBarrier(directoryFD),
                      directory.provesAbsence(basename: basename, quarantine: quarantine)
                else { return .removalUnverified }
                return .alreadyAbsent
            }
            guard VerifiedRootStateDirectory.validPrivateFile(initial, expectations: directory.expectations) else { return .unsafeEntry }
            if let expected {
                guard let held = directory.openForRead(basename) else { return .unsafeEntry }
                defer { Darwin.close(held) }
                var heldMetadata = stat()
                guard fstat(held, &heldMetadata) == 0,
                      VerifiedRootStateDirectory.sameMetadata(initial, heldMetadata),
                      heldMetadata.st_size <= off_t(expected.maximumBytes),
                      let bytes = VerifiedRootStateDirectory.readExactly(held, count: Int(heldMetadata.st_size)),
                      expected.parser(bytes),
                      fstat(held, &heldMetadata) == 0,
                      VerifiedRootStateDirectory.sameMetadata(initial, heldMetadata)
                else { return .unsafeEntry }
            }
            guard directory.operations.renameExclusive(directoryFD, basename, directoryFD, quarantine) == 0 else {
                return .removalUnverified
            }
            guard directory.operations.directoryEntryBarrier(directoryFD) else { return .removalUnverified }
            directory.operations.beforeQuarantineVerify(directoryFD, quarantine)
            var quarantined = stat()
            guard fstatat(directoryFD, quarantine, &quarantined, AT_SYMLINK_NOFOLLOW) == 0,
                  VerifiedRootStateDirectory.sameIdentity(initial, quarantined),
                  VerifiedRootStateDirectory.validPrivateFile(quarantined, expectations: directory.expectations)
            else {
                _ = directory.operations.directoryEntryBarrier(directoryFD)
                return .removalUnverified
            }
            directory.operations.beforeQuarantineUnlink(directoryFD, quarantine)
            var destructiveBoundary = stat()
            guard fstatat(directoryFD, quarantine, &destructiveBoundary, AT_SYMLINK_NOFOLLOW) == 0,
                  VerifiedRootStateDirectory.sameIdentity(initial, destructiveBoundary),
                  VerifiedRootStateDirectory.validPrivateFile(destructiveBoundary, expectations: directory.expectations)
            else {
                _ = directory.operations.directoryEntryBarrier(directoryFD)
                return .removalUnverified
            }
            if let expected {
                // Re-open and re-parse the quarantined inode at the destructive
                // boundary. The earlier public-name parse authorizes the
                // rename; it does not authorize unlinking bytes that changed
                // after the rename or through a fault seam.
                guard exactQuarantineMatchesLocked(
                    quarantine,
                    originalIdentity: initial,
                    maximumBytes: expected.maximumBytes,
                    parser: expected.parser,
                    directoryFD: directoryFD
                ) else { return .removalUnverified }
            }
            guard directory.operations.unlink(directoryFD, quarantine) == 0 else { return .removalUnverified }
            guard directory.operations.directoryEntryBarrier(directoryFD) else { return .removalUnverified }
            return directory.provesAbsence(basename: basename, quarantine: quarantine)
                ? .removed
                : .removalUnverified
        }

        private func removeVerifiedOrphanLocked(
            basename: String,
            quarantine: String,
            maximumBytes: Int,
            parser: (Data) -> Bool,
            directoryFD: Int32
        ) -> RemovalResult {
            guard let held = directory.openForRead(quarantine) else { return .unsafeEntry }
            defer { Darwin.close(held) }
            var initial = stat()
            guard fstat(held, &initial) == 0,
                  initial.st_size <= off_t(maximumBytes),
                  let bytes = VerifiedRootStateDirectory.readExactly(held, count: Int(initial.st_size)),
                  parser(bytes),
                  directory.operations.fileBarrier(held)
            else { return .unsafeEntry }
            var stable = stat()
            var bound = stat()
            guard fstat(held, &stable) == 0,
                  VerifiedRootStateDirectory.sameMetadata(initial, stable),
                  fstatat(directoryFD, quarantine, &bound, AT_SYMLINK_NOFOLLOW) == 0,
                  VerifiedRootStateDirectory.sameMetadata(initial, bound)
            else { return .removalUnverified }
            directory.operations.beforeQuarantineUnlink(directoryFD, quarantine)
            var destructiveBoundary = stat()
            guard fstatat(directoryFD, quarantine, &destructiveBoundary, AT_SYMLINK_NOFOLLOW) == 0,
                  VerifiedRootStateDirectory.sameMetadata(initial, destructiveBoundary)
            else { return .removalUnverified }
            guard directory.operations.unlink(directoryFD, quarantine) == 0 else { return .removalUnverified }
            guard directory.operations.directoryEntryBarrier(directoryFD) else { return .removalUnverified }
            return directory.provesAbsence(basename: basename, quarantine: quarantine)
                ? .removed
                : .removalUnverified
        }

        private func exactQuarantineMatchesLocked(
            _ quarantine: String,
            originalIdentity: stat,
            maximumBytes: Int,
            parser: (Data) -> Bool,
            directoryFD: Int32
        ) -> Bool {
            guard let held = directory.openForRead(quarantine) else { return false }
            defer { Darwin.close(held) }
            var initial = stat()
            guard fstat(held, &initial) == 0,
                  VerifiedRootStateDirectory.sameIdentity(originalIdentity, initial),
                  initial.st_size <= off_t(maximumBytes),
                  let bytes = VerifiedRootStateDirectory.readExactly(held, count: Int(initial.st_size)),
                  parser(bytes),
                  directory.operations.fileBarrier(held)
            else { return false }
            var stable = stat()
            var bound = stat()
            return fstat(held, &stable) == 0
                && VerifiedRootStateDirectory.sameMetadata(initial, stable)
                && fstatat(directoryFD, quarantine, &bound, AT_SYMLINK_NOFOLLOW) == 0
                && VerifiedRootStateDirectory.sameMetadata(initial, bound)
        }
    }

    public convenience init?(
        directoryPath: String,
        expectations: Expectations,
        ancestorPolicy: RootStateDirectoryAncestorPolicy = .production
    ) {
        self.init(
            directoryPath: directoryPath,
            expectations: expectations,
            ancestorPolicy: ancestorPolicy,
            operations: .system
        )
    }

    /// Duplicates an already identity-checked directory capability without
    /// reopening any ancestor by pathname. This is intentionally limited to
    /// the system operations used by production; fault-injecting operations
    /// remain internal to the core test surface.
    public convenience init?(
        heldDirectoryDescriptor: Int32,
        expectations: Expectations
    ) {
        self.init(
            heldDirectoryDescriptor: heldDirectoryDescriptor,
            expectations: expectations,
            operations: .system
        )
    }

    init?(
        directoryPath: String,
        expectations: Expectations,
        ancestorPolicy: RootStateDirectoryAncestorPolicy,
        operations: Operations
    ) {
        guard let components = Self.absoluteComponents(directoryPath) else { return nil }
        let rootFlags: Int32 = ancestorPolicy == .testTemporaryDirectory
            ? O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            : O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let root = open("/", rootFlags)
        guard root >= 0 else { return nil }
        var held = [root]
        guard Self.validAncestor(root, index: 0, components: components, expectations: expectations, policy: ancestorPolicy) else {
            held.forEach { Darwin.close($0) }
            return nil
        }
        for (offset, component) in components.enumerated() {
            guard let parent = held.last else {
                held.forEach { Darwin.close($0) }
                return nil
            }
            let componentIndex = offset + 1
            let flags: Int32
            if ancestorPolicy == .testTemporaryDirectory, componentIndex <= 2 {
                flags = O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            } else {
                flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            }
            let next = openat(parent, component, flags)
            guard next >= 0 else { held.forEach { Darwin.close($0) }; return nil }
            held.append(next)
            guard Self.validAncestor(next, index: componentIndex, components: components, expectations: expectations, policy: ancestorPolicy) else {
                held.forEach { Darwin.close($0) }
                return nil
            }
        }
        guard let directory = held.last, Self.validSupportDirectory(directory, expectations: expectations) else {
            held.forEach { Darwin.close($0) }
            return nil
        }
        self.descriptors = held
        self.expectations = expectations
        self.operations = operations
    }

    /// Test-only capability intake. The fixture boundary opens and identity-
    /// verifies the directory relative to the wrapper-sealed execution root;
    /// this initializer duplicates that held descriptor without reopening any
    /// shared `/private/tmp` ancestor.
    init?(
        heldDirectoryDescriptor: Int32,
        expectations: Expectations,
        operations: Operations
    ) {
        let descriptor = fcntl(heldDirectoryDescriptor, F_DUPFD_CLOEXEC, 3)
        guard descriptor >= 0,
              Self.validSupportDirectory(descriptor, expectations: expectations)
        else {
            if descriptor >= 0 { Darwin.close(descriptor) }
            return nil
        }
        self.descriptors = [descriptor]
        self.expectations = expectations
        self.operations = operations
    }

    deinit { descriptors.forEach { Darwin.close($0) } }

    /// Internal capability-owning lock path. It is the only constructor for a
    /// transaction and accepts no caller-provided descriptor, so public clients
    /// can only receive a transaction through `RootStateLock`.
    internal func withExclusiveTransaction<T>(
        lockBasename: String,
        timeout: TimeInterval,
        now: () -> TimeInterval,
        body: (Transaction) -> T
    ) -> T? {
        guard timeout >= 0, let descriptor = openExistingLock(lockBasename) else { return nil }
        defer { Darwin.close(descriptor) }
        let deadline = now() + timeout
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN, now() < deadline else { return nil }
            var interval = timespec(tv_sec: 0, tv_nsec: 5_000_000)
            _ = nanosleep(&interval, nil)
        }
        let transaction = Transaction(directory: self, lockDescriptor: descriptor)
        let result = body(transaction)
        transaction.invalidate()
        _ = flock(descriptor, LOCK_UN)
        transaction.runAfterUnlockActions()
        return result
    }

    /// Opens one safe leaf relative to the held directory. The caller owns the
    /// returned descriptor; this method never follows a leaf symlink.
    public func openForRead(_ basename: String) -> Int32? {
        guard Self.isSafeBasename(basename), let directory = directoryDescriptor else { return nil }
        let fd = openat(directory, basename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, Self.validPrivateFile(metadata, expectations: expectations) else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    /// Opens an existing fixed lock leaf. It never creates a leaf, ensuring a
    /// lock acquisition timeout/failure has no state mutation.
    public func openExistingLock(_ basename: String) -> Int32? {
        guard Self.isSafeBasename(basename), let directory = directoryDescriptor else { return nil }
        let fd = openat(directory, basename, O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, Self.validPrivateFile(metadata, expectations: expectations) else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    public func entryState(_ basename: String) -> EntryState {
        guard Self.isSafeBasename(basename), let directory = directoryDescriptor else { return .unknown }
        var metadata = stat()
        if fstatat(directory, basename, &metadata, AT_SYMLINK_NOFOLLOW) == 0 { return .present }
        return errno == ENOENT ? .absent : .unknown
    }

    /// Enumerates one stable, bounded snapshot through a new `.` description
    /// opened relative to the held directory capability. A plain `dup` would
    /// share the directory offset and make later inventories silently appear
    /// empty. No external pathname is resolved, identity is revalidated, and a
    /// concurrent directory mutation invalidates the entire snapshot.
    public func boundedEntryNames(
        maximumEntries: Int = 256,
        maximumNameBytes: Int = 32 * 1_024
    ) -> [String]? {
        guard maximumEntries > 0, maximumEntries <= 1_024,
              maximumNameBytes > 0, maximumNameBytes <= 128 * 1_024,
              let directory = directoryDescriptor
        else { return nil }

        var before = stat()
        guard fstat(directory, &before) == 0 else { return nil }
        let inventory = Darwin.openat(
            directory,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard inventory >= 0 else { return nil }
        var inventoryMetadata = stat()
        guard fstat(inventory, &inventoryMetadata) == 0,
              Self.sameIdentity(before, inventoryMetadata),
              Self.validSupportDirectory(inventory, expectations: expectations)
        else {
            Darwin.close(inventory)
            return nil
        }
        guard let stream = fdopendir(inventory) else {
            Darwin.close(inventory)
            return nil
        }
        defer { closedir(stream) }

        var names: [String] = []
        var totalNameBytes = 0
        errno = 0
        while let pointer = readdir(stream) {
            var entry = pointer.pointee
            let length = Int(entry.d_namlen)
            guard length > 0, length <= Int(NAME_MAX) else { return nil }
            var storage = entry.d_name
            let name: String? = withUnsafeBytes(of: &storage) { raw in
                guard length <= raw.count else { return nil }
                return String(bytes: raw.prefix(length), encoding: .utf8)
            }
            guard let name else { return nil }
            if name == "." || name == ".." { continue }
            guard Self.isSafeBasename(name) else { return nil }
            totalNameBytes += length
            guard names.count < maximumEntries, totalNameBytes <= maximumNameBytes else { return nil }
            names.append(name)
        }
        guard errno == 0, Set(names).count == names.count else { return nil }
        var after = stat()
        guard fstat(directory, &after) == 0, Self.sameMetadata(before, after) else { return nil }
        return names.sorted()
    }

    /// Safely provisions the pre-existing lock leaf required by
    /// `RootStateLock`. This deliberately does not acquire the lock or wire an
    /// installer; a later privileged integration lane owns that transition.
    public func provisionLockLeaf(_ basename: String) -> LockProvisionResult {
        guard Self.isSafeBasename(basename), let directory = directoryDescriptor else { return .failure(.unsafeName) }
        let fd = openat(directory, basename, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        if fd < 0 {
            guard errno == EEXIST else { return .failure(.create) }
            guard let existing = openExistingLock(basename) else { return .failure(.existingInvalid) }
            defer { Darwin.close(existing) }
            guard operations.fileBarrier(existing) else { return .provisionedButUnverified(.fileBarrier) }
            guard operations.directoryEntryBarrier(directory) else { return .provisionedButUnverified(.directoryBarrier) }
            return .alreadyPresent
        }
        defer { Darwin.close(fd) }
        guard Darwin.fchmod(fd, S_IRUSR | S_IWUSR) == 0 else { return .provisionedButUnverified(.metadata) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, Self.validPrivateFile(metadata, expectations: expectations) else {
            return .provisionedButUnverified(.metadata)
        }
        guard operations.fileBarrier(fd) else { return .provisionedButUnverified(.fileBarrier) }
        guard operations.directoryEntryBarrier(directory) else { return .provisionedButUnverified(.directoryBarrier) }
        return .provisioned
    }

    public static func isSafeBasename(_ value: String) -> Bool {
        !value.isEmpty
            && value.precomposedStringWithCanonicalMapping == value
            && !value.utf8.contains(0)
            && value != "."
            && value != ".."
            && !value.contains("/")
    }

    /// Returns the one bounded recovery/quarantine name for a public state
    /// basename. A name that cannot coexist with this suffix under NAME_MAX is
    /// rejected before any root-state mutation begins.
    public static func quarantineBasename(for basename: String) -> String? {
        guard isSafeBasename(basename) else { return nil }
        let name = ".\(basename)\(quarantineSuffix)"
        return name.utf8.count <= Int(NAME_MAX) ? name : nil
    }

    private static func hasBoundedStateNames(_ basename: String) -> Bool {
        guard quarantineBasename(for: basename) != nil else { return false }
        // `publish` creates `.<basename>.new.<UUID>`; UUID's canonical text is
        // fixed-width ASCII. Validate it before opening any transaction leaf.
        return 1 + basename.utf8.count + ".new.".utf8.count + 36 <= Int(NAME_MAX)
    }

    private func quarantineInventory(for basename: String) -> QuarantineInventory {
        guard let quarantine = Self.quarantineBasename(for: basename), let directory = directoryDescriptor else { return .unknown }
        func presence(_ name: String) -> Bool? {
            var metadata = stat()
            if fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 { return true }
            return errno == ENOENT ? false : nil
        }
        guard let publicPresent = presence(basename), let quarantinePresent = presence(quarantine) else { return .unknown }
        switch (publicPresent, quarantinePresent) {
        case (false, false), (true, false): return .clean
        case (false, true): return .orphan
        case (true, true): return .bothPresent
        }
    }

    private func provesAbsence(basename: String, quarantine: String) -> Bool {
        guard let directory = directoryDescriptor else { return false }
        func absent(_ name: String) -> Bool {
            var metadata = stat()
            return fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT
        }
        return absent(basename) && absent(quarantine)
    }

    private static func absoluteComponents(_ source: String) -> [String]? {
        guard source.precomposedStringWithCanonicalMapping == source,
              !source.utf8.contains(0), source.hasPrefix("/"), source != "/",
              !source.hasSuffix("/"), !source.contains("//")
        else { return nil }
        let path: String
        if source == "/var" { path = "/private/var" }
        else if source.hasPrefix("/var/") { path = "/private/var/" + String(source.dropFirst("/var/".count)) }
        else { path = source }
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return !components.isEmpty && components.allSatisfy(isSafeBasename) ? components : nil
    }

    private static func validAncestor(
        _ descriptor: Int32,
        index: Int,
        components: [String],
        expectations: Expectations,
        policy: RootStateDirectoryAncestorPolicy
    ) -> Bool {
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR else { return false }
        switch policy {
        case .production:
            return productionAncestorIsValid(
                index: index,
                components: components,
                ownerUID: status.st_uid,
                groupID: status.st_gid,
                mode: status.st_mode,
                expectations: expectations
            )
        case .testTemporaryDirectory:
            if index == 0 || index == 1 {
                return status.st_uid == 0 && status.st_gid == 0 && status.st_mode & (S_IWGRP | S_IWOTH) == 0
            }
            guard components.starts(with: ["private", "tmp"]) else { return false }
            if index == 2 {
                return status.st_uid == 0 && status.st_gid == 0 && status.st_mode & S_ISVTX != 0 && status.st_mode & 0o777 == 0o777
            }
            return status.st_uid == expectations.ownerUID
                && status.st_gid == expectations.groupID
                && status.st_mode & (S_IWGRP | S_IWOTH) == 0
        }
    }

    /// Pure production-policy seam used by source fixtures. The admin group is
    /// accepted only for the canonical `Application Support` ancestor; it does
    /// not broaden ownership policy for caller-selected paths or the final
    /// root-private state directory.
    static func productionAncestorIsValid(
        index: Int,
        components: [String],
        ownerUID: uid_t,
        groupID: gid_t,
        mode: mode_t,
        expectations: Expectations
    ) -> Bool {
        let canonical = ["Library", "Application Support", "LidSwitch"]
        guard components == canonical,
              expectations == .production,
              index >= 0, index <= canonical.count,
              (mode & S_IFMT) == S_IFDIR,
              ownerUID == 0,
              mode & 0o7777 == 0o755
        else { return false }

        let expectedGroups: [gid_t] = [0, 0, 80, 0]
        return groupID == expectedGroups[index]
    }

    private static func validSupportDirectory(_ descriptor: Int32, expectations: Expectations) -> Bool {
        var status = stat()
        return fstat(descriptor, &status) == 0
            && (status.st_mode & S_IFMT) == S_IFDIR
            && status.st_uid == expectations.ownerUID
            && status.st_gid == expectations.groupID
            && status.st_nlink >= 2
            && status.st_mode & 0o7777 == expectations.mode
    }

    private static func validPrivateFile(_ status: stat, expectations: Expectations) -> Bool {
        (status.st_mode & S_IFMT) == S_IFREG
            && status.st_uid == expectations.ownerUID
            && status.st_gid == expectations.groupID
            && status.st_nlink == 1
            && status.st_mode & 0o7777 == 0o600
            && status.st_size >= 0
    }

    private static func writeExactly(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    private static func readExactly(_ descriptor: Int32, count: Int) -> Data? {
        var bytes = Data(count: count)
        let completed = bytes.withUnsafeMutableBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let readCount = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if readCount > 0 { offset += readCount; continue }
                if readCount < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
        guard completed else { return nil }
        var trailing: UInt8 = 0
        while true {
            let readCount = Darwin.read(descriptor, &trailing, 1)
            if readCount == 0 { return bytes }
            if readCount < 0, errno == EINTR { continue }
            return nil
        }
    }

    private static func sameMetadata(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
            && first.st_uid == second.st_uid && first.st_gid == second.st_gid
            && first.st_mode == second.st_mode && first.st_nlink == second.st_nlink
            && first.st_size == second.st_size
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
            && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
            && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }

    private static func sameIdentity(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }
}
