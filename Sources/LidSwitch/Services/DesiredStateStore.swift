import Foundation
import Darwin

enum DesiredStateStore {
    enum StoreError: Error {
        case unsafePath(String)
        case openFailed(String, Int32)
        case writeFailed(String, Int32)
    }

    static func readPreferences() -> PowerPreferences {
        guard let raw = try? String(contentsOf: AppPaths.desiredStateFile, encoding: .utf8) else {
            return .disabled
        }

        return PowerPreferences.parse(raw)
    }

    static func read() -> Bool {
        readPreferences().keepAwakeEnabled
    }

    static func write(_ enabled: Bool) throws {
        try write(
            PowerPreferences(
                keepAwakeEnabled: enabled,
                allowBatteryKeepAwake: false
            )
        )
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
        stateFile: URL
    ) throws {
        try prepareSupportDirectory(supportDirectory)
        try assertSafeStateFile(stateFile)
        try writeNoFollow(preferences.storagePayload, to: stateFile)
    }

    private static func prepareSupportDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.path) {
            try assertDirectoryIsSafe(directory)
            return
        }

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try assertDirectoryIsSafe(directory)
    }

    private static func assertDirectoryIsSafe(_ directory: URL) throws {
        let status = try lstatStatus(directory)
        if isSymlink(status) || !isDirectory(status) {
            throw StoreError.unsafePath(directory.path)
        }
    }

    private static func assertSafeStateFile(_ file: URL) throws {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return
        }

        let status = try lstatStatus(file)
        if isSymlink(status) || !isRegularFile(status) {
            throw StoreError.unsafePath(file.path)
        }
    }

    private static func lstatStatus(_ url: URL) throws -> stat {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw StoreError.openFailed(url.path, errno)
        }
        return status
    }

    private static func isSymlink(_ status: stat) -> Bool {
        (status.st_mode & S_IFMT) == S_IFLNK
    }

    private static func isDirectory(_ status: stat) -> Bool {
        (status.st_mode & S_IFMT) == S_IFDIR
    }

    private static func isRegularFile(_ status: stat) -> Bool {
        (status.st_mode & S_IFMT) == S_IFREG
    }

    private static func writeNoFollow(_ payload: String, to file: URL) throws {
        let flags = O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_NONBLOCK
        let fd = open(file.path, flags, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard fd >= 0 else {
            throw StoreError.openFailed(file.path, errno)
        }

        defer {
            close(fd)
        }

        var status = stat()
        guard fstat(fd, &status) == 0, isRegularFile(status) else {
            throw StoreError.unsafePath(file.path)
        }

        let bytes = Array(payload.utf8)
        try bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(
                    fd,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                if result < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw StoreError.writeFailed(file.path, errno)
                }
                written += result
            }
        }

        if fsync(fd) != 0 {
            throw StoreError.writeFailed(file.path, errno)
        }
    }
}
