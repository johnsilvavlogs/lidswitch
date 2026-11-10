import Darwin
import Foundation

/// One GUI owner per user, including launches from different app copies.
/// Keep the descriptor open for the app's lifetime. Never unlink the lock:
/// replacing its inode would let a second process lock a different file.
final class AppInstanceLock {
    static let directoryName = ".lidswitch-instance"
    static let fileName = "gui.lock"

    enum Failure: Swift.Error {
        case unsafeLocation
        case systemCall(String, Int32)
    }

    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        // close also releases flock after an ordinary exit; the kernel does
        // the same on a crash or SIGKILL. There is no PID file to go stale.
        close(descriptor)
    }

    /// nil means another GUI already owns the lock. Other failures fail closed.
    static func acquireForCurrentUser() throws -> AppInstanceLock? {
        guard getuid() == geteuid(),
              let account = getpwuid(getuid()), let rawHome = account.pointee.pw_dir
        else { throw Failure.unsafeLocation }
        // Use the account database, never HOME, TMPDIR, or a bundle-relative
        // location: those could give different app copies different locks.
        let home = String(cString: rawHome)
        guard home.hasPrefix("/"), home != "/" else { throw Failure.unsafeLocation }
        let homeDescriptor = open(home, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard homeDescriptor >= 0 else { throw Failure.systemCall("open home", errno) }
        defer { close(homeDescriptor) }
        return try acquire(in: homeDescriptor)
    }

    /// Descriptor-based entry point also lets fixtures stay inside TestSandbox.
    static func acquire(in parentDirectory: Int32) throws -> AppInstanceLock? {
        var parent = stat()
        guard fstat(parentDirectory, &parent) == 0,
              parent.st_mode & S_IFMT == S_IFDIR,
              parent.st_uid == getuid(), parent.st_mode & 0o022 == 0
        else { throw Failure.unsafeLocation }

        if mkdirat(parentDirectory, directoryName, 0o700) != 0, errno != EEXIST {
            throw Failure.systemCall("mkdir instance directory", errno)
        }
        let directory = openat(parentDirectory, directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.systemCall("open instance directory", errno) }
        defer { close(directory) }
        var directoryStatus = stat()
        var directoryEntry = stat()
        guard fstat(directory, &directoryStatus) == 0,
              directoryStatus.st_mode == (S_IFDIR | 0o700),
              directoryStatus.st_uid == getuid(), directoryStatus.st_nlink >= 2,
              fstatat(parentDirectory, directoryName, &directoryEntry, AT_SYMLINK_NOFOLLOW) == 0,
              sameInode(directoryStatus, directoryEntry)
        else { throw Failure.unsafeLocation }

        // NONBLOCK prevents an unsafe pre-existing FIFO from hanging startup.
        // CLOEXEC prevents a subsequently launched helper retaining ownership.
        let file = openat(directory, fileName, O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw Failure.systemCall("open instance lock", errno) }
        var transferred = false
        defer { if !transferred { close(file) } }
        var status = stat()
        guard fstat(file, &status) == 0, isPrivateLockFile(status)
        else { throw Failure.unsafeLocation }

        guard flock(file, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN { return nil }
            throw Failure.systemCall("lock instance", code)
        }
        var boundFile = stat()
        var boundDirectory = stat()
        guard fstatat(directory, fileName, &boundFile, AT_SYMLINK_NOFOLLOW) == 0,
              sameInode(status, boundFile), isPrivateLockFile(boundFile),
              fstatat(parentDirectory, directoryName, &boundDirectory, AT_SYMLINK_NOFOLLOW) == 0,
              sameInode(directoryStatus, boundDirectory)
        else { throw Failure.unsafeLocation }
        transferred = true
        return AppInstanceLock(descriptor: file)
    }

    static func isPrivateLockFile(_ status: stat) -> Bool {
        status.st_mode == (S_IFREG | 0o600)
            && status.st_uid == getuid() && status.st_nlink == 1
    }

    private static func sameInode(_ opened: stat, _ entry: stat) -> Bool {
        // APFS directory link counts include entries, so creating gui.lock
        // changes that count without replacing or weakening the directory.
        // Regular-file link counts are checked by isPrivateLockFile instead.
        opened.st_dev == entry.st_dev && opened.st_ino == entry.st_ino
            && opened.st_uid == entry.st_uid && opened.st_mode == entry.st_mode
    }
}
