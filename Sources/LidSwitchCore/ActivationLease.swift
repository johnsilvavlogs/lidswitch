import Darwin
import Foundation

/// Caches the first successful value of a process-lifetime invariant while
/// preserving fail-closed retries when the underlying kernel read is
/// temporarily unavailable. The loader runs under the lock, so concurrent
/// first readers cannot duplicate the expensive lookup or publish different
/// values.
final class ProcessInvariantCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedValue: Value?

    func value(load: () -> Value?) -> Value? {
        lock.lock()
        defer { lock.unlock() }

        if let cachedValue {
            return cachedValue
        }
        guard let loaded = load() else {
            return nil
        }
        cachedValue = loaded
        return loaded
    }
}

public struct ActivationLease: Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maximumLifetime: TimeInterval = 30

    public let sessionID: UUID
    public let bootID: String
    public let expiresAt: Date
    public let issuedMonotonic: TimeInterval
    public let expiresMonotonic: TimeInterval
    public let ownerUID: uid_t
    public let systemBuild: String

    public init(
        sessionID: UUID,
        bootID: String,
        expiresAt: Date,
        issuedMonotonic: TimeInterval,
        expiresMonotonic: TimeInterval,
        ownerUID: uid_t,
        systemBuild: String
    ) {
        self.sessionID = sessionID
        self.bootID = bootID
        self.expiresAt = expiresAt
        self.issuedMonotonic = issuedMonotonic
        self.expiresMonotonic = expiresMonotonic
        self.ownerUID = ownerUID
        self.systemBuild = systemBuild
    }

    public var storagePayload: String {
        [
            "schema=\(Self.schemaVersion)",
            "mode=active",
            "session=\(sessionID.uuidString.lowercased())",
            "boot=\(bootID)",
            "expires=\(Int(expiresAt.timeIntervalSince1970))",
            "issued_mono=\(issuedMonotonic)",
            "expires_mono=\(expiresMonotonic)",
            "uid=\(ownerUID)",
            "build=\(systemBuild)",
            "",
        ].joined(separator: "\n")
    }

    public func validationFailure(
        now _: Date,
        nowMonotonic: TimeInterval,
        currentBootID: String,
        expectedOwnerUID: uid_t,
        currentSystemBuild: String,
        maximumLifetime: TimeInterval = Self.maximumLifetime
    ) -> LeaseValidationFailure? {
        guard bootID == currentBootID else {
            return .bootMismatch
        }
        guard ownerUID == expectedOwnerUID else {
            return .ownerMismatch
        }
        guard systemBuild == currentSystemBuild else {
            return .buildMismatch
        }
        guard issuedMonotonic <= nowMonotonic,
              expiresMonotonic > nowMonotonic
        else {
            return .expired
        }
        guard expiresMonotonic - issuedMonotonic <= maximumLifetime,
              expiresMonotonic - nowMonotonic <= maximumLifetime
        else {
            return .excessiveLifetime
        }
        return nil
    }

    public static func parse(_ raw: String) -> ActivationLease? {
        var values: [String: String] = [:]
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                return nil
            }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, values[key] == nil else {
                return nil
            }
            values[key] = value
        }

        guard values.count == 9,
              values["schema"] == String(schemaVersion),
              values["mode"] == "active",
              let sessionRaw = values["session"],
              let sessionID = UUID(uuidString: sessionRaw),
              let bootID = values["boot"], !bootID.isEmpty,
              let expiresRaw = values["expires"],
              let expires = TimeInterval(expiresRaw),
              let issuedMonotonicRaw = values["issued_mono"],
              let issuedMonotonic = TimeInterval(issuedMonotonicRaw),
              let expiresMonotonicRaw = values["expires_mono"],
              let expiresMonotonic = TimeInterval(expiresMonotonicRaw),
              let ownerRaw = values["uid"],
              let ownerUID = uid_t(ownerRaw),
              let systemBuild = values["build"], !systemBuild.isEmpty
        else {
            return nil
        }

        return ActivationLease(
            sessionID: sessionID,
            bootID: bootID,
            expiresAt: Date(timeIntervalSince1970: expires),
            issuedMonotonic: issuedMonotonic,
            expiresMonotonic: expiresMonotonic,
            ownerUID: ownerUID,
            systemBuild: systemBuild
        )
    }
}

public enum MonotonicClock {
    /// The Mach timebase is immutable for a running kernel. Resolve it once per
    /// process so heartbeat, lease, and recovery paths pay only for the
    /// continuous-clock read on subsequent calls.
    private static let timebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (info.numer, info.denom)
    }()

    public static func seconds() -> TimeInterval {
        let ticks = mach_continuous_time()
        return TimeInterval(ticks) * TimeInterval(timebase.numer) / TimeInterval(timebase.denom) / 1_000_000_000
    }
}

public enum LeaseValidationFailure: String, Error, Equatable, Sendable {
    case malformed
    case unsafeFile
    case bootMismatch
    case ownerMismatch
    case buildMismatch
    case expired
    case excessiveLifetime
}

public enum BootIdentity {
    private static let cache = ProcessInvariantCache<String>()

    public static func current() -> String? {
        cache.value(load: readCurrent)
    }

    private static func readCurrent() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0,
              size > 1
        else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        if let terminator = buffer.firstIndex(of: 0) {
            buffer.removeSubrange(terminator...)
        }
        return normalizeBootSessionUUID(
            String(decoding: buffer.map(UInt8.init(bitPattern:)), as: UTF8.self)
        )
    }

    public static func normalizeBootSessionUUID(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard let uuid = UUID(uuidString: value) else { return nil }
        return uuid.uuidString.lowercased()
    }
}

public enum SystemBuild {
    private static let cache = ProcessInvariantCache<String>()

    public static func current() -> String? {
        cache.value(load: readCurrent)
    }

    private static func readCurrent() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0,
              size > 1
        else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        if let terminator = buffer.firstIndex(of: 0) {
            buffer.removeSubrange(terminator...)
        }
        let value = String(decoding: buffer.map(UInt8.init(bitPattern:)), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

public enum CompatibilityPolicy {
    public static let qualifiedBuilds: Set<String> = [ReleaseIdentity.qualifiedSystemBuild]

    public static func isQualified(systemBuild: String) -> Bool {
        qualifiedBuilds.contains(systemBuild)
    }
}
