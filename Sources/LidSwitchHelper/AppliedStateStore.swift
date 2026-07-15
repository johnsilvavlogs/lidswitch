import Darwin
import Foundation
import LidSwitchCore

struct AppliedState: Equatable, Sendable {
    /// The byte shape is durable evidence, not a presentation detail. In
    /// particular, a historical six/fourteen-key record may explicitly carry
    /// battery keys whose values are both no-ops; dropping them would rewrite
    /// otherwise canonical evidence into a different record.
    enum PayloadShape: Equatable, Sendable {
        case legacyFour
        case legacySix
        case schemaTwelve
        case schemaFourteen

        fileprivate var includesBattery: Bool {
            self == .legacySix || self == .schemaFourteen
        }

        fileprivate var includesSchema: Bool {
            self == .schemaTwelve || self == .schemaFourteen
        }
    }
    /// Schema is provenance, not a property inferred from inode metadata.
    /// Schema-2 records are permanently restore-only, even at 0600.
    enum Provenance: Equatable, Sendable {
        case legacy
        case current

        fileprivate var schema: String? {
            switch self {
            // An owner/lease-bearing legacy record remains canonical schema 2
            // for exact parsing and restore. The ownerless legacy projection
            // never reaches this property because it has no owner/lease.
            case .legacy: return "2"
            case .current: return "3"
            }
        }
    }
    struct Owner: Equatable, Sendable {
        let pid: Int32
        let startSeconds: UInt64
        let startMicroseconds: UInt64
        let asid: UInt32
        let euid: UInt32
        let bootID: String

        var isWellFormed: Bool {
            pid > 0 && startSeconds > 0 && startMicroseconds < 1_000_000 && !bootID.isEmpty
        }
    }

    let sessionID: UUID
    let changedSleepDisabled: Bool
    let changedACSleep: Bool
    let originalACSleep: Int?
    /// Legacy releases could also persist a battery sleep baseline. Current
    /// sessions never mutate it, but native recovery must absorb and restore
    /// that exact evidence before the shell fallback can be retired.
    let changedBatterySleep: Bool
    let originalBatterySleep: Int?
    /// Present only for schema-2 authority records. Legacy four-key records
    /// remain parseable solely so recovery can restore their owned mutation.
    let owner: Owner?
    let leaseExpiryMonotonic: TimeInterval?
    let provenance: Provenance
    let payloadShape: PayloadShape

    init(
        sessionID: UUID,
        changedSleepDisabled: Bool,
        changedACSleep: Bool,
        originalACSleep: Int?,
        changedBatterySleep: Bool = false,
        originalBatterySleep: Int? = nil,
        owner: Owner? = nil,
        leaseExpiryMonotonic: TimeInterval? = nil,
        provenance: Provenance = .legacy,
        payloadShape: PayloadShape? = nil
    ) {
        self.sessionID = sessionID
        self.changedSleepDisabled = changedSleepDisabled
        self.changedACSleep = changedACSleep
        self.originalACSleep = originalACSleep
        self.changedBatterySleep = changedBatterySleep
        self.originalBatterySleep = originalBatterySleep
        self.owner = owner
        self.leaseExpiryMonotonic = leaseExpiryMonotonic
        self.provenance = provenance
        self.payloadShape = payloadShape ?? {
            let battery = changedBatterySleep || originalBatterySleep != nil
            if owner != nil || leaseExpiryMonotonic != nil {
                return battery ? .schemaFourteen : .schemaTwelve
            }
            return battery ? .legacySix : .legacyFour
        }()
    }

    var isReconnectable: Bool {
        provenance == .current && owner?.isWellFormed == true && leaseExpiryMonotonic?.isFinite == true && leaseExpiryMonotonic! > 0
    }

    /// Only the complete process-bound schema can ever become reconnect
    /// authority. Four/six-key historical records remain restore-only even
    /// after their exact bytes are migrated to a private 0600 inode.
    var isProcessBound: Bool {
        provenance == .current && owner?.isWellFormed == true && leaseExpiryMonotonic != nil
    }

    var storagePayload: String {
        canonicalPayload(shape: payloadShape)
    }

    /// The live helper is the only writer allowed to originate a reconnectable
    /// generation.  Keeping construction here makes schema-3 and the
    /// battery-free schema-12 contract impossible to accidentally omit at a
    /// BEGIN call site.
    static func currentAuthority(
        sessionID: UUID,
        changedSleepDisabled: Bool,
        changedACSleep: Bool,
        originalACSleep: Int?,
        owner: Owner,
        leaseExpiryMonotonic: TimeInterval
    ) -> AppliedState {
        AppliedState(
            sessionID: sessionID,
            changedSleepDisabled: changedSleepDisabled,
            changedACSleep: changedACSleep,
            originalACSleep: originalACSleep,
            owner: owner,
            leaseExpiryMonotonic: leaseExpiryMonotonic,
            provenance: .current,
            payloadShape: .schemaTwelve
        )
    }

    /// Renewal is an exact replacement of the lease field.  It deliberately
    /// preserves parsed 12/14-key shape, provenance, and every power field so
    /// a future supported battery-bearing current authority cannot be silently
    /// downgraded while it is active.
    func replacingLeaseExpiry(_ renewedExpiry: TimeInterval) -> AppliedState? {
        guard renewedExpiry.isFinite,
              renewedExpiry > 0,
              provenance == .current,
              owner?.isWellFormed == true,
              payloadShape == .schemaTwelve || payloadShape == .schemaFourteen
        else { return nil }
        return AppliedState(
            sessionID: sessionID,
            changedSleepDisabled: changedSleepDisabled,
            changedACSleep: changedACSleep,
            originalACSleep: originalACSleep,
            changedBatterySleep: changedBatterySleep,
            originalBatterySleep: originalBatterySleep,
            owner: owner,
            leaseExpiryMonotonic: renewedExpiry,
            provenance: provenance,
            payloadShape: payloadShape
        )
    }

    /// Returns the exact historical 4/6-key or schema-2 12/14-key byte shape.
    /// Parsing supplies the observed shape so a valid legacy six-key no-op
    /// record remains readable without weakening canonical byte equality.
    private func canonicalPayload(shape: PayloadShape) -> String {
        var legacy = [
            "session=\(sessionID.uuidString.lowercased())",
            "changed_sleep_disabled=\(changedSleepDisabled ? 1 : 0)",
            "changed_ac_sleep=\(changedACSleep ? 1 : 0)",
            "original_ac_sleep=\(originalACSleep.map(String.init) ?? "unknown")",
        ]
        if shape.includesBattery {
            legacy += [
                "changed_battery_sleep=\(changedBatterySleep ? 1 : 0)",
                "original_battery_sleep=\(originalBatterySleep.map(String.init) ?? "unknown")",
            ]
        }
        guard shape.includesSchema,
              let owner, let leaseExpiryMonotonic, let schema = provenance.schema else {
            return (legacy + [""]).joined(separator: "\n")
        }
        return ([
            "schema=\(schema)",
        ] + legacy + [
            "pid=\(owner.pid)",
            "start_sec=\(owner.startSeconds)",
            "start_usec=\(owner.startMicroseconds)",
            "asid=\(owner.asid)",
            "euid=\(owner.euid)",
            "boot=\(owner.bootID)",
            "lease_expiry_mono=\(leaseExpiryMonotonic)",
            "",
        ]).joined(separator: "\n")
    }

    static func parse(_ raw: String) -> AppliedState? {
        var values: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let key = String(parts[0])
            guard values[key] == nil else { return nil }
            values[key] = String(parts[1])
        }
        guard [4, 6, 12, 14].contains(values.count),
              let sessionRaw = values["session"],
              let sessionID = UUID(uuidString: sessionRaw),
              let changedSleepRaw = values["changed_sleep_disabled"],
              let changedSleep = parseFlag(changedSleepRaw),
              let changedACRaw = values["changed_ac_sleep"],
              let changedAC = parseFlag(changedACRaw),
              let originalRaw = values["original_ac_sleep"]
        else {
            return nil
        }
        let original = originalRaw == "unknown" ? nil : Int(originalRaw)
        if originalRaw != "unknown", original == nil {
            return nil
        }
        if changedAC {
            guard let original, original > 0, original <= 1_440 else { return nil }
        } else if original != nil {
            return nil
        }
        let changedBattery: Bool
        let originalBattery: Int?
        if values.count == 6 || values.count == 14 {
            guard let changedRaw = values["changed_battery_sleep"],
                  let changed = parseFlag(changedRaw),
                  let originalRaw = values["original_battery_sleep"]
            else { return nil }
            let parsedOriginal = originalRaw == "unknown" ? nil : Int(originalRaw)
            guard originalRaw == "unknown" || parsedOriginal != nil else { return nil }
            if changed {
                guard let parsedOriginal, parsedOriginal > 0, parsedOriginal <= 1_440 else { return nil }
            } else if parsedOriginal != nil {
                return nil
            }
            changedBattery = changed
            originalBattery = parsedOriginal
        } else {
            changedBattery = false
            originalBattery = nil
        }
        let shape: PayloadShape
        switch values.count {
        case 4: shape = .legacyFour
        case 6: shape = .legacySix
        case 12: shape = .schemaTwelve
        case 14: shape = .schemaFourteen
        default: return nil
        }
        let base = AppliedState(
            sessionID: sessionID,
            changedSleepDisabled: changedSleep,
            changedACSleep: changedAC,
            originalACSleep: original,
            changedBatterySleep: changedBattery,
            originalBatterySleep: originalBattery,
            payloadShape: shape
        )
        guard values.count == 12 || values.count == 14 else {
            return base.canonicalPayload(shape: shape) == raw ? base : nil
        }
        guard let schema = values["schema"], ["2", "3"].contains(schema),
              let pid = values["pid"].flatMap(Int32.init), pid > 0,
              let seconds = values["start_sec"].flatMap(UInt64.init), seconds > 0,
              let microseconds = values["start_usec"].flatMap(UInt64.init), microseconds < 1_000_000,
              let asid = values["asid"].flatMap(UInt32.init),
              let euid = values["euid"].flatMap(UInt32.init),
              let boot = values["boot"], BootIdentity.normalizeBootSessionUUID(boot) == boot,
              let expiry = values["lease_expiry_mono"].flatMap(TimeInterval.init), expiry.isFinite, expiry > 0
        else { return nil }
        let state = AppliedState(
            sessionID: base.sessionID,
            changedSleepDisabled: base.changedSleepDisabled,
            changedACSleep: base.changedACSleep,
            originalACSleep: base.originalACSleep,
            changedBatterySleep: base.changedBatterySleep,
            originalBatterySleep: base.originalBatterySleep,
            owner: Owner(
                pid: pid,
                startSeconds: seconds,
                startMicroseconds: microseconds,
                asid: asid,
                euid: euid,
                bootID: boot
            ),
            leaseExpiryMonotonic: expiry,
            provenance: schema == "3" ? .current : .legacy,
            payloadShape: shape
        )
        return state.canonicalPayload(shape: shape) == raw ? state : nil
    }

    private static func parseFlag(_ raw: String) -> Bool? {
        if raw == "1" { return true }
        if raw == "0" { return false }
        return nil
    }
}

enum AppliedStateLoadResult: Equatable {
    case missing
    case invalid
    case success(AppliedState)
}

enum AppliedStateStore {
    private static let maximumSize: off_t = 4_096

    enum DurabilityStage: Equatable { case fileBarrier, rename, directoryBarrier, finalVerification }
    enum StoreError: Error, Equatable { case durability(DurabilityStage), io }

    struct DurabilityOperations: Sendable {
        let fileBarrier: @Sendable (Int32) -> Bool
        let rename: @Sendable (String, String) -> Bool
        let directoryBarrier: @Sendable (String) -> Bool
        let verify: @Sendable (String, String, AppliedState, uid_t) -> Bool

        static let system = DurabilityOperations(
            fileBarrier: { descriptor in
                fsync(descriptor) == 0 && fcntl(descriptor, F_FULLFSYNC) == 0
            },
            rename: { source, destination in Darwin.rename(source, destination) == 0 },
            directoryBarrier: { directory in
                let descriptor = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard descriptor >= 0 else { return false }
                defer { close(descriptor) }
                return fsync(descriptor) == 0
            },
            verify: { path, expectedPayload, expected, owner in
                let policy = BoundedFileReadPolicy(
                    maximumBytes: Int(maximumSize), expectedOwnerUID: owner,
                    requireSingleLink: true, rejectGroupOrWorldWritable: true,
                    requireNonEmpty: true, safeParentDepth: 1
                )
                guard case let .success(raw) = BoundedFileReader.readUTF8(path: path, policy: policy) else {
                    return false
                }
                return raw == expectedPayload && AppliedState.parse(raw) == expected
            }
        )
    }

    static func load(path: String, expectedOwnerUID: uid_t = getuid()) -> AppliedStateLoadResult {
        let policy = BoundedFileReadPolicy(
            maximumBytes: Int(maximumSize), expectedOwnerUID: expectedOwnerUID,
            requireSingleLink: true, rejectGroupOrWorldWritable: true,
            requireNonEmpty: true, safeParentDepth: 1
        )
        switch BoundedFileReader.readUTF8(path: path, policy: policy) {
        case .failure(.missing): return .missing
        case .failure: return .invalid
        case let .success(raw):
            BenchmarkProbe.record("file_read")
            BenchmarkProbe.record("decoded_bytes", count: raw.utf8.count)
            return AppliedState.parse(raw).map(AppliedStateLoadResult.success) ?? .invalid
        }
    }

    static func read(path: String) -> AppliedState? {
        guard case let .success(state) = load(path: path) else { return nil }
        return state
    }

    static func write(
        _ state: AppliedState,
        path: String,
        operations: DurabilityOperations = .system
    ) throws {
        let destination = URL(fileURLWithPath: path)
        let directory = destination.deletingLastPathComponent()
        let temp = path + ".tmp.\(UUID().uuidString)"
        let descriptor = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        BenchmarkProbe.record("file_open")
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        var removeTemp = true
        var published = false
        defer {
            close(descriptor)
            if removeTemp && !published { unlink(temp) }
        }
        let bytes = Array(state.storagePayload.utf8)
        BenchmarkProbe.record("decoded_bytes", count: bytes.count)
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), remaining)
            }
            if count > 0 { BenchmarkProbe.record("file_write") }
            guard count > 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            offset += count
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH) == 0 else { throw StoreError.io }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_mode & 0o7777 == 0o644
        else { throw StoreError.io }
        BenchmarkProbe.record("file_fsync")
        guard operations.fileBarrier(descriptor) else { throw StoreError.durability(.fileBarrier) }
        BenchmarkProbe.record("file_rename")
        guard operations.rename(temp, path) else { throw StoreError.durability(.rename) }
        published = true
        removeTemp = false
        guard operations.directoryBarrier(directory.path) else { throw StoreError.durability(.directoryBarrier) }
        guard operations.verify(path, state.storagePayload, state, getuid()) else {
            throw StoreError.durability(.finalVerification)
        }
    }

    static func remove(path: String) -> Bool {
        unlink(path) == 0 || errno == ENOENT
    }
}
