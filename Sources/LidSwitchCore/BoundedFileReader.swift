import Darwin
import Foundation

public enum BoundedFileAncestorPolicy: Equatable, Sendable {
    /// Compatibility mode for callers that have not yet migrated to a held
    /// absolute chain. This is deliberately not used by new root-state APIs.
    case legacySafeParentDepth
    /// Every absolute ancestor is opened from `/` and retained through the
    /// leaf operation. Every ancestor must have the expected owner and may not
    /// be group- or world-writable.
    case fullAbsolute
    /// Explicit fixture-only exception for `/private/tmp/<owned-fixture>/...`.
    /// `/private/tmp` must be root-owned sticky 01777; the remaining chain is
    /// owned by `expectedOwnerUID` and has no group/world write bit.
    case testTemporaryDirectory
}

public struct BoundedFileReadPolicy: Sendable {
    public let maximumBytes: Int
    public let expectedOwnerUID: uid_t
    public let requireSingleLink: Bool
    public let rejectGroupOrWorldWritable: Bool
    public let requireNonEmpty: Bool
    /// Retained solely for source compatibility. It is ignored by the two
    /// descriptor-chain policies above.
    public let safeParentDepth: Int
    public let ancestorPolicy: BoundedFileAncestorPolicy

    public init(
        maximumBytes: Int,
        expectedOwnerUID: uid_t,
        requireSingleLink: Bool,
        rejectGroupOrWorldWritable: Bool,
        requireNonEmpty: Bool,
        safeParentDepth: Int,
        ancestorPolicy: BoundedFileAncestorPolicy = .legacySafeParentDepth
    ) {
        self.maximumBytes = maximumBytes
        self.expectedOwnerUID = expectedOwnerUID
        self.requireSingleLink = requireSingleLink
        self.rejectGroupOrWorldWritable = rejectGroupOrWorldWritable
        self.requireNonEmpty = requireNonEmpty
        self.safeParentDepth = safeParentDepth
        self.ancestorPolicy = ancestorPolicy
    }
}

public enum BoundedFileReadFailure: Error, Equatable, Sendable {
    case missing
    case unsafeParent
    case unsafeFile
    case tooLarge
    case changedDuringRead
    case io
    case invalidUTF8
}

/// Test-only timing controls. Production callers leave this absent, which
/// records no telemetry and does not alter the file-operation sequence.
public enum BoundedFileReadPhase: Equatable, Sendable { case body, eofProof }
public enum BoundedFileReadDirective: Equatable, Sendable { case system, interrupted, endOfFile }

public struct BoundedFileReadControls: Sendable {
    public let beforeLeafOpen: @Sendable () -> Void
    public let beforeFinalMetadata: @Sendable () -> Void
    public let readDirective: @Sendable (BoundedFileReadPhase) -> BoundedFileReadDirective

    public init(
        beforeLeafOpen: @escaping @Sendable () -> Void = {},
        beforeFinalMetadata: @escaping @Sendable () -> Void = {},
        readDirective: @escaping @Sendable (BoundedFileReadPhase) -> BoundedFileReadDirective = { _ in .system }
    ) {
        self.beforeLeafOpen = beforeLeafOpen
        self.beforeFinalMetadata = beforeFinalMetadata
        self.readDirective = readDirective
    }

    public static let none = BoundedFileReadControls()
}

/// Reads one explicitly-policy-bound local text artifact without following
/// links or allocating beyond its declared cap. New security-sensitive callers
/// opt into a held complete descriptor chain; the legacy depth setting remains
/// only until existing callers are migrated.
public enum BoundedFileReader {
    public static func readUTF8(
        path: String,
        policy: BoundedFileReadPolicy,
        controls: BoundedFileReadControls? = nil
    ) -> Result<String, BoundedFileReadFailure> {
        guard policy.maximumBytes >= 0, policy.safeParentDepth >= 0 else {
            return .failure(.unsafeParent)
        }

        let leafDescriptor: Int32
        switch policy.ancestorPolicy {
        case .legacySafeParentDepth:
            if policy.safeParentDepth == 0 {
                leafDescriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            } else {
                guard let directoryDescriptor = legacySafeParentDescriptor(path: path, policy: policy) else {
                    return .failure(.unsafeParent)
                }
                defer { close(directoryDescriptor) }
                controls?.beforeLeafOpen()
                guard let leaf = lexicalLeaf(path) else { return .failure(.unsafeParent) }
                leafDescriptor = openat(directoryDescriptor, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            }
        case .fullAbsolute, .testTemporaryDirectory:
            guard let chain = HeldDescriptorChain(path: path, policy: policy) else {
                return .failure(.unsafeParent)
            }
            controls?.beforeLeafOpen()
            guard let descriptor = chain.openLeaf() else {
                return .failure(errno == ENOENT ? .missing : .unsafeFile)
            }
            leafDescriptor = descriptor
        }
        guard leafDescriptor >= 0 else { return .failure(errno == ENOENT ? .missing : .unsafeFile) }
        defer { close(leafDescriptor) }

        var initial = stat()
        guard fstat(leafDescriptor, &initial) == 0 else { return .failure(.io) }
        guard validFile(initial, policy: policy) else { return .failure(.unsafeFile) }
        guard initial.st_size <= off_t(policy.maximumBytes) else { return .failure(.tooLarge) }

        var bytes = [UInt8](repeating: 0, count: Int(initial.st_size))
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let directive = controls?.readDirective(.body) ?? .system
            let count: Int
            switch directive {
            case .interrupted: count = -1; errno = EINTR
            case .endOfFile: count = 0
            case .system: count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(leafDescriptor, buffer.baseAddress!.advanced(by: offset), remaining)
            }
            }
            if count > 0 { offset += count; continue }
            if count < 0, errno == EINTR { continue }
            return .failure(.changedDuringRead)
        }
        var trailing: UInt8 = 0
        while true {
            let directive = controls?.readDirective(.eofProof) ?? .system
            let count: Int
            switch directive {
            case .interrupted: count = -1; errno = EINTR
            case .endOfFile: count = 0
            case .system: count = Darwin.read(leafDescriptor, &trailing, 1)
            }
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            return .failure(.changedDuringRead)
        }
        controls?.beforeFinalMetadata()
        var final = stat()
        guard fstat(leafDescriptor, &final) == 0 else { return .failure(.io) }
        guard unchanged(initial, final) else { return .failure(.changedDuringRead) }
        guard let raw = String(bytes: bytes, encoding: .utf8) else { return .failure(.invalidUTF8) }
        return .success(raw)
    }

    private static func legacySafeParentDescriptor(path: String, policy: BoundedFileReadPolicy) -> Int32? {
        guard let parts = lexicalPath(path) else { return nil }
        var inspectedParents: [[String]] = []
        var parent = Array(parts.dropLast())
        for _ in 0..<policy.safeParentDepth {
            guard !parent.isEmpty else { return nil }
            inspectedParents.append(parent)
            parent.removeLast()
        }
        guard let topmost = inspectedParents.last else { return nil }
        let topPath = "/" + topmost.joined(separator: "/")
        var descriptor = open(topPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0, validDirectory(descriptor, policy: policy) else {
            if descriptor >= 0 { close(descriptor) }
            return nil
        }
        for childPath in inspectedParents.reversed().dropFirst() {
            guard let child = childPath.last else { close(descriptor); return nil }
            let next = openat(descriptor, child, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0, validDirectory(next, policy: policy) else {
                if next >= 0 { close(next) }
                close(descriptor)
                return nil
            }
            close(descriptor)
            descriptor = next
        }
        return descriptor
    }

    private static func lexicalLeaf(_ path: String) -> String? {
        lexicalPath(path)?.last
    }

    /// Rejects URL-style normalization before any descriptor is opened. The
    /// single production alias is converted lexically, never resolved through
    /// the filesystem.
    fileprivate static func lexicalPath(_ source: String) -> [String]? {
        guard source.precomposedStringWithCanonicalMapping == source,
              !source.utf8.contains(0),
              source.hasPrefix("/"),
              source != "/",
              !source.hasSuffix("/"),
              !source.contains("//")
        else { return nil }
        let path: String
        if source == "/var" {
            path = "/private/var"
        } else if source.hasPrefix("/var/") {
            path = "/private/var/" + String(source.dropFirst("/var/".count))
        } else {
            path = source
        }
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ VerifiedRootStateDirectory.isSafeBasename($0) })
        else { return nil }
        return components
    }

    fileprivate static func validDirectory(_ descriptor: Int32, policy: BoundedFileReadPolicy) -> Bool {
        var status = stat()
        return fstat(descriptor, &status) == 0 && directoryMetadataIsSafe(
            mode: status.st_mode,
            ownerUID: status.st_uid,
            policy: policy
        )
    }

    private static func validFile(_ status: stat, policy: BoundedFileReadPolicy) -> Bool {
        fileMetadataIsSafe(
            mode: status.st_mode,
            ownerUID: status.st_uid,
            linkCount: status.st_nlink,
            size: status.st_size,
            policy: policy
        )
    }

    static func directoryMetadataIsSafe(
        mode: mode_t,
        ownerUID: uid_t,
        policy: BoundedFileReadPolicy
    ) -> Bool {
        (mode & S_IFMT) == S_IFDIR
            && ownerUID == policy.expectedOwnerUID
            && mode & 0o7000 == 0
            && (!policy.rejectGroupOrWorldWritable || mode & (S_IWGRP | S_IWOTH) == 0)
    }

    static func fileMetadataIsSafe(
        mode: mode_t,
        ownerUID: uid_t,
        linkCount: nlink_t,
        size: off_t,
        policy: BoundedFileReadPolicy
    ) -> Bool {
        (mode & S_IFMT) == S_IFREG
            && ownerUID == policy.expectedOwnerUID
            && (!policy.requireSingleLink || linkCount == 1)
            && mode & 0o7000 == 0
            && (!policy.rejectGroupOrWorldWritable || mode & (S_IWGRP | S_IWOTH) == 0)
            && size >= 0
            && (!policy.requireNonEmpty || size > 0)
    }

    private static func unchanged(_ initial: stat, _ final: stat) -> Bool {
        initial.st_dev == final.st_dev
            && initial.st_ino == final.st_ino
            && initial.st_size == final.st_size
            && initial.st_uid == final.st_uid
            && initial.st_mode == final.st_mode
            && initial.st_nlink == final.st_nlink
            && initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec
            && initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec
            && initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec
            && initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec
    }
}

/// Keeps every opened directory descriptor alive until the leaf has been
/// opened. It intentionally exposes no pathname reopen path.
fileprivate final class HeldDescriptorChain {
    private var directories: [Int32] = []
    private let leaf: String

    init?(path: String, policy: BoundedFileReadPolicy) {
        guard let components = BoundedFileReader.lexicalPath(path), let leaf = components.last else { return nil }
        self.leaf = leaf
        let rootFlags: Int32 = policy.ancestorPolicy == .testTemporaryDirectory
            ? O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            : O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let root = open("/", rootFlags)
        guard root >= 0 else { return nil }
        directories.append(root)
        guard validAncestor(root, componentIndex: 0, components: components, policy: policy) else { return nil }
        for (offset, component) in components.dropLast().enumerated() {
            guard let parent = directories.last else { return nil }
            let componentIndex = offset + 1
            let childFlags: Int32
            if policy.ancestorPolicy == .testTemporaryDirectory, componentIndex <= 2 {
                childFlags = O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            } else {
                childFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            }
            let child = openat(parent, component, childFlags)
            guard child >= 0 else { return nil }
            directories.append(child)
            guard validAncestor(child, componentIndex: componentIndex, components: components, policy: policy) else { return nil }
        }
    }

    deinit { directories.forEach { close($0) } }

    func openLeaf() -> Int32? {
        guard let parent = directories.last else { return nil }
        let descriptor = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        return descriptor >= 0 ? descriptor : nil
    }

    private func validAncestor(
        _ descriptor: Int32,
        componentIndex: Int,
        components: [String],
        policy: BoundedFileReadPolicy
    ) -> Bool {
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR else { return false }
        switch policy.ancestorPolicy {
        case .fullAbsolute:
            return status.st_uid == policy.expectedOwnerUID
                && status.st_mode & 0o7000 == 0
                && status.st_mode & (S_IWGRP | S_IWOTH) == 0
        case .testTemporaryDirectory:
            // Index zero is `/`; subsequent indexes name the path components.
            if componentIndex == 0 {
                return status.st_uid == 0 && status.st_mode & 0o7000 == 0 && status.st_mode & (S_IWGRP | S_IWOTH) == 0
            }
            guard components.starts(with: ["private", "tmp"]) else { return false }
            if componentIndex == 1 {
                return status.st_uid == 0 && status.st_mode & (S_IWGRP | S_IWOTH) == 0
            }
            if componentIndex == 2 {
                return status.st_uid == 0 && status.st_mode & 0o7777 == 0o1777
            }
            return status.st_uid == policy.expectedOwnerUID
                && status.st_mode & 0o7000 == 0
                && status.st_mode & (S_IWGRP | S_IWOTH) == 0
        case .legacySafeParentDepth:
            return BoundedFileReader.validDirectory(descriptor, policy: policy)
        }
    }
}
