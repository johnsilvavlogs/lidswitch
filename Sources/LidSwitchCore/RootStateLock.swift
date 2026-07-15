import Foundation

/// A bounded advisory lock rooted in a held `VerifiedRootStateDirectory`.
/// Failure and timeout return before invoking `body`, so cooperative
/// LidSwitch/helper/admin root-state writers make no protected mutation without
/// this lock. A malicious root process that bypasses the fixed lock is outside
/// this capability guarantee.
public enum RootStateLock {
    public static let authorizationBasename = "session-authorization.lock"

    public static func withExclusive<T>(
        directory: VerifiedRootStateDirectory,
        lockBasename: String = authorizationBasename,
        timeout: TimeInterval = 1,
        now: () -> TimeInterval = MonotonicClock.seconds,
        body: (VerifiedRootStateDirectory.Transaction) -> T
    ) -> T? {
        directory.withExclusiveTransaction(
            lockBasename: lockBasename,
            timeout: timeout,
            now: now,
            body: body
        )
    }

    /// Compatibility convenience for later migrations. The directory chain is
    /// established once and held through the lock/body lifetime; the lock leaf
    /// itself is still opened only through that retained capability.
    public static func withExclusive<T>(
        directoryPath: String,
        expectations: VerifiedRootStateDirectory.Expectations,
        ancestorPolicy: RootStateDirectoryAncestorPolicy = .production,
        lockBasename: String = authorizationBasename,
        timeout: TimeInterval = 1,
        now: () -> TimeInterval = MonotonicClock.seconds,
        body: (VerifiedRootStateDirectory.Transaction) -> T
    ) -> T? {
        guard let directory = VerifiedRootStateDirectory(
            directoryPath: directoryPath,
            expectations: expectations,
            ancestorPolicy: ancestorPolicy
        ) else { return nil }
        return withExclusive(
            directory: directory,
            lockBasename: lockBasename,
            timeout: timeout,
            now: now,
            body: body
        )
    }
}
