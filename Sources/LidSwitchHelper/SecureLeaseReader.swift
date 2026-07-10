import Darwin
import Foundation
import LidSwitchCore

enum SecureLeaseReader {
    static let maximumBytes: off_t = 4_096

    static func load(path: String, expectedOwnerUID: uid_t) -> Result<ActivationLease, LeaseValidationFailure> {
        guard safeParentDirectories(path: path, expectedOwnerUID: expectedOwnerUID) else {
            return .failure(.unsafeFile)
        }

        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            return .failure(errno == ENOENT ? .malformed : .unsafeFile)
        }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == expectedOwnerUID,
              status.st_nlink == 1,
              status.st_size > 0,
              status.st_size <= maximumBytes,
              status.st_mode & (S_IWGRP | S_IWOTH) == 0
        else {
            return .failure(.unsafeFile)
        }

        var data = Data(count: Int(status.st_size))
        let bytesRead = data.withUnsafeMutableBytes { buffer in
            read(descriptor, buffer.baseAddress, buffer.count)
        }
        guard bytesRead == data.count,
              let raw = String(data: data, encoding: .utf8),
              let lease = ActivationLease.parse(raw)
        else {
            return .failure(.malformed)
        }
        return .success(lease)
    }

    private static func safeParentDirectories(path: String, expectedOwnerUID: uid_t) -> Bool {
        let file = URL(fileURLWithPath: path)
        let directories = [file.deletingLastPathComponent(), file.deletingLastPathComponent().deletingLastPathComponent()]
        for directory in directories {
            var status = stat()
            guard lstat(directory.path, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFDIR,
                  status.st_uid == expectedOwnerUID
            else {
                return false
            }
        }
        return true
    }
}
