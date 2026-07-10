import Darwin
import Foundation
import LidSwitchCore

enum ActivationLeaseStore {
    enum StoreError: Error {
        case unsafePath(String)
        case openFailed(String, Int32)
        case writeFailed(String, Int32)
        case renameFailed(String, Int32)
        case commitRejected(String)
    }

    static func issue(
        sessionID: UUID,
        lifetime: TimeInterval = ActivationLease.maximumLifetime,
        commitGuard: (@Sendable () -> Bool)? = nil
    ) throws -> ActivationLease {
        guard let bootID = BootIdentity.current(),
              let systemBuild = SystemBuild.current()
        else {
            throw StoreError.unsafePath("Unable to read the current boot or macOS build.")
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
        commitGuard: (@Sendable () -> Bool)? = nil
    ) throws {
        try prepareSupportDirectory(file.deletingLastPathComponent())
        let temp = file.deletingLastPathComponent()
            .appendingPathComponent(".activation-lease.\(UUID().uuidString)", isDirectory: false)
        let descriptor = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw StoreError.openFailed(temp.path, errno)
        }

        var shouldRemoveTemp = true
        defer {
            close(descriptor)
            if shouldRemoveTemp {
                unlink(temp.path)
            }
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1
        else {
            throw StoreError.unsafePath(temp.path)
        }
        _ = fchmod(descriptor, S_IRUSR | S_IWUSR)

        let data = Array(lease.storagePayload.utf8)
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset)
            }
            guard written > 0 else {
                throw StoreError.writeFailed(temp.path, errno)
            }
            offset += written
        }
        guard fsync(descriptor) == 0 else {
            throw StoreError.writeFailed(temp.path, errno)
        }
        guard commitGuard?() ?? true else {
            throw StoreError.commitRejected(file.path)
        }
        guard rename(temp.path, file.path) == 0 else {
            throw StoreError.renameFailed(file.path, errno)
        }
        shouldRemoveTemp = false
    }

    static func read(from file: URL = AppPaths.activationLeaseFile) -> ActivationLease? {
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else {
            return nil
        }
        return ActivationLease.parse(raw)
    }

    static func revoke(file: URL = AppPaths.activationLeaseFile) throws {
        if unlink(file.path) != 0, errno != ENOENT {
            throw StoreError.writeFailed(file.path, errno)
        }
    }

    private static func prepareSupportDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var status = stat()
        guard lstat(directory.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == getuid(),
              status.st_mode & (S_IWGRP | S_IWOTH) == 0
        else {
            throw StoreError.unsafePath(directory.path)
        }
    }
}
