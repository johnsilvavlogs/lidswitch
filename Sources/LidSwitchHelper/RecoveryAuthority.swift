import Darwin
import Foundation
import LidSwitchCore

/// Durable recovery conclusions. `legacyRestoreOnly` never authorizes a
/// reconnect; it exists solely to make the legacy rollback boundary explicit.
enum RecoveryAssessment: Equatable {
    case pristineIdle
    case migratedIdle(String)
    case terminalIdle(UUID, String)
    case recoveryRequired(String)
    case legacyRestoreOnly(AppliedState)
    case reconnectCandidate(AppliedState)
}

struct RecoveryProof: Equatable {
    enum Kind: String {
        case pristine
        case migrated
        case terminal
        case recoveryRequired = "recovery-required"
    }

    let kind: Kind
    let sessionID: UUID?
    let reason: String

    var payload: String {
        [
            "schema=1",
            "kind=\(kind.rawValue)",
            "session=\(sessionID?.uuidString.lowercased() ?? "none")",
            "reason=\(reason)",
            "",
        ].joined(separator: "\n")
    }

    static func parse(_ raw: String) -> RecoveryProof? {
        var values: [String: String] = [:]
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, !pair[0].isEmpty, values[String(pair[0])] == nil else { return nil }
            values[String(pair[0])] = String(pair[1])
        }
        guard values.count == 4,
              values["schema"] == "1",
              let kind = values["kind"].flatMap(Kind.init(rawValue:)),
              let session = values["session"],
              let reason = values["reason"],
              reason.range(of: "^[a-z0-9-]{1,96}$", options: .regularExpression) != nil
        else { return nil }

        let proof: RecoveryProof
        switch kind {
        case .pristine:
            guard session == "none", reason == "bootstrap" else { return nil }
            proof = .init(kind: kind, sessionID: nil, reason: reason)
        case .terminal:
            guard let id = UUID(uuidString: session) else { return nil }
            proof = .init(kind: kind, sessionID: id, reason: reason)
        case .migrated:
            guard session == "none", reason.hasPrefix("legacy-") else { return nil }
            proof = .init(kind: kind, sessionID: nil, reason: reason)
        case .recoveryRequired:
            guard session == "none" else { return nil }
            proof = .init(kind: kind, sessionID: nil, reason: reason)
        }
        // Authority files have one canonical byte representation. This rejects
        // appended blank lines and non-canonical UUID casing rather than
        // accepting multiple byte strings as the same proof.
        return proof.payload == raw ? proof : nil
    }
}

/// The reservation ledger records history; this root-private record stores
/// the one mutable phase for the exact active generation. A `reserved` record
/// is never proof that the privileged setter completed.
struct RecoveryBudgetState: Equatable {
    enum Phase: String { case reserved, spent }

    static let basename = "recovery-budget-state"
    static let maximumBytes = 192
    let sessionID: UUID
    let phase: Phase

    var payload: String {
        [
            "schema=1",
            "session=\(sessionID.uuidString.lowercased())",
            "phase=\(phase.rawValue)",
            "",
        ].joined(separator: "\n")
    }

    static func parse(_ raw: String) -> RecoveryBudgetState? {
        guard raw.utf8.count <= maximumBytes else { return nil }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count == 3 else { return nil }
        var values: [String: String] = [:]
        for line in lines {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2,
                  values.updateValue(String(pair[1]), forKey: String(pair[0])) == nil
            else { return nil }
        }
        guard values["schema"] == "1",
              let rawSession = values["session"],
              let session = UUID(uuidString: rawSession),
              session.uuidString.lowercased() == rawSession,
              let phase = values["phase"].flatMap(Phase.init(rawValue:))
        else { return nil }
        let state = RecoveryBudgetState(sessionID: session, phase: phase)
        return state.payload == raw ? state : nil
    }
}

/// Root-private, sessionless crash journal for releases that persisted only
/// original timer values. It is published and verified before the first native
/// setter. Every later step is recoverable from the journal plus a fresh native
/// read, so a crash can never require a guessed UUID or rearm protection.
struct LegacyRecoveryJournal: Equatable {
    enum Phase: String { case prepared, nativeSafe = "native-safe", proofPublished = "proof-published" }
    enum TimerDisposition: Equatable {
        case notRequired
        case pending
        case satisfied
        case restored
        case superseded(Int)

        var token: String {
            switch self {
            case .notRequired: return "not-required"
            case .pending: return "pending"
            case .satisfied: return "satisfied"
            case .restored: return "restored"
            case let .superseded(value): return "superseded-\(value)"
            }
        }

        static func parse(_ raw: String) -> TimerDisposition? {
            switch raw {
            case "not-required": return .notRequired
            case "pending": return .pending
            case "satisfied": return .satisfied
            case "restored": return .restored
            default:
                let prefix = "superseded-"
                guard raw.hasPrefix(prefix),
                      let value = Int(raw.dropFirst(prefix.count)),
                      value > 0, value <= 1_440,
                      raw == prefix + String(value)
                else { return nil }
                return .superseded(value)
            }
        }
    }

    static let basename = "legacy-recovery-journal"
    static let maximumBytes = 512

    let phase: Phase
    let ownsSleepDisabled: Bool
    let acTarget: Int?
    let batteryTarget: Int?
    let acDisposition: TimerDisposition
    let batteryDisposition: TimerDisposition

    var hasSupersededTimer: Bool {
        if case .superseded = acDisposition { return true }
        if case .superseded = batteryDisposition { return true }
        return false
    }

    var proofReason: String {
        hasSupersededTimer ? "legacy-migration-superseded" : "legacy-migration"
    }

    var payload: String {
        [
            "schema=1",
            "kind=legacy-no-session",
            "phase=\(phase.rawValue)",
            "owns_sleep_disabled=\(ownsSleepDisabled ? 1 : 0)",
            "ac_target=\(acTarget.map(String.init) ?? "none")",
            "battery_target=\(batteryTarget.map(String.init) ?? "none")",
            "ac_disposition=\(acDisposition.token)",
            "battery_disposition=\(batteryDisposition.token)",
            "",
        ].joined(separator: "\n")
    }

    static func parse(_ raw: String) -> LegacyRecoveryJournal? {
        guard raw.utf8.count <= maximumBytes else { return nil }
        var values: [String: String] = [:]
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, !pair[0].isEmpty,
                  values.updateValue(String(pair[1]), forKey: String(pair[0])) == nil
            else { return nil }
        }
        guard values.count == 8,
              values["schema"] == "1",
              values["kind"] == "legacy-no-session",
              let phase = values["phase"].flatMap(Phase.init(rawValue:)),
              let owns = values["owns_sleep_disabled"].flatMap(parseFlag),
              let ac = values["ac_target"].flatMap(parseTarget),
              let battery = values["battery_target"].flatMap(parseTarget),
              let acDisposition = values["ac_disposition"].flatMap(TimerDisposition.parse),
              let batteryDisposition = values["battery_disposition"].flatMap(TimerDisposition.parse)
        else { return nil }

        let journal = LegacyRecoveryJournal(
            phase: phase,
            ownsSleepDisabled: owns,
            acTarget: ac.value,
            batteryTarget: battery.value,
            acDisposition: acDisposition,
            batteryDisposition: batteryDisposition
        )
        guard owns == (ac.value != nil || battery.value != nil),
              validDisposition(acDisposition, target: ac.value, phase: phase),
              validDisposition(batteryDisposition, target: battery.value, phase: phase)
        else { return nil }
        return journal.payload == raw ? journal : nil
    }

    /// Rejects phase/disposition combinations that the recovery state machine
    /// cannot publish. A prepared target is still pending. A durable safe
    /// phase records an exact observed conclusion, and `restored` is possible
    /// only for a positive target that could have replaced legacy zero.
    private static func validDisposition(
        _ disposition: TimerDisposition,
        target: Int?,
        phase: Phase
    ) -> Bool {
        guard let target else { return disposition == .notRequired }
        switch phase {
        case .prepared:
            return disposition == .pending
        case .nativeSafe, .proofPublished:
            switch disposition {
            case .satisfied:
                return true
            case .restored:
                return target > 0
            case let .superseded(value):
                return value > 0 && value <= 1_440 && value != target
            case .notRequired, .pending:
                return false
            }
        }
    }

    private struct ParsedTarget { let value: Int? }

    private static func parseTarget(_ raw: String) -> ParsedTarget? {
        if raw == "none" { return .init(value: nil) }
        guard let value = Int(raw), value >= 0, value <= 1_440, raw == String(value) else { return nil }
        return .init(value: value)
    }

    private static func parseFlag(_ raw: String) -> Bool? {
        raw == "1" ? true : raw == "0" ? false : nil
    }
}

enum RecoveryPublicationOutcome: Equatable {
    case alreadyVerified
    case published
    case notPublished(VerifiedRootStateDirectory.PublicationFailure)
    case publishedButUnverified(VerifiedRootStateDirectory.PublicationFailure)

    var isVerified: Bool {
        switch self {
        case .alreadyVerified, .published: return true
        case .notPublished, .publishedButUnverified: return false
        }
    }
}

enum RecoveryProvisionOutcome: Equatable {
    case ready
    case recoveryRequired(String)
}

enum RecoveryLedgerRecord: Equatable {
    case absent
    case privateAuthority(entries: [UUID], bytes: String)
    case legacyReadable(entries: [UUID], bytes: String)
    case invalid

    var entries: [UUID]? {
        switch self {
        case let .privateAuthority(entries, _), let .legacyReadable(entries, _): return entries
        case .absent, .invalid: return nil
        }
    }
}

enum RecoveryAppliedRecord: Equatable {
    case missing
    case privateAuthority(AppliedState)
    case legacyRestoreOnly(AppliedState)
    /// A crash after the public->quarantine rename is a cleanup continuation,
    /// never active authority. It can only be consumed by exact terminal replay.
    case quarantinedApplied(AppliedState)
    case invalid
}

enum RecoveryEvidenceState: Equatable { case absent, present, uncertain }

struct RecoveryAuthorityFileOperations: @unchecked Sendable {
    let openLeaf: (Int32, String) -> Int32
    let afterOpen: (Int32, String) -> Void

    static let system = RecoveryAuthorityFileOperations(
        openLeaf: { directory, basename in
            Darwin.openat(directory, basename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        },
        afterOpen: { _, _ in }
    )
}

/// Root-only authority stores. All mutations share the one fixed root-state
/// lock and the held support-directory capability. Historical root-owned
/// 0600/0640/0644 entries are accepted only by strict migration/legacy-rollback
/// readers; their bytes can never authorize a reconnect.
final class RecoveryAuthorityStore {
    static let appliedBasename = "applied-state"
    static let terminalBasename = "terminal-generations"
    static let reservationBasename = "recovery-reservations"
    static let proofBasename = "recovery-proof"
    static let containmentReceiptBasename = "contained-process-receipt"
    static let statusProjectionBasename = "status-projection-task"
    static let statusProjectionGenerationBasename = "status-projection-generation"
    static let recoveryBudgetBasename = RecoveryBudgetState.basename
    static let journalBasename = LegacyRecoveryJournal.basename
    static let legacyACBasename = "original-ac-sleep"
    static let legacyBatteryBasename = "original-battery-sleep"
    static let legacyHistoryBasenames = [
        "helper-status",
        legacyACBasename,
        legacyBatteryBasename,
        "lidswitch-helper",
        "LidSwitchHelper",
        "helper-version",
        "Current",
        "Previous",
    ]

    private let directory: VerifiedRootStateDirectory
    private let expectedOwnerUID: uid_t
    private let expectedGroupID: gid_t
    private let lockTimeout: TimeInterval
    private let lockNow: () -> TimeInterval
    private let fileOperations: RecoveryAuthorityFileOperations

    init?(
        supportDirectory: String,
        expectations: VerifiedRootStateDirectory.Expectations = .production,
        ancestorPolicy: RootStateDirectoryAncestorPolicy = .production,
        lockTimeout: TimeInterval = 1,
        lockNow: @escaping () -> TimeInterval = MonotonicClock.seconds,
        fileOperations: RecoveryAuthorityFileOperations = .system
    ) {
        guard let directory = VerifiedRootStateDirectory(
            directoryPath: supportDirectory,
            expectations: expectations,
            ancestorPolicy: ancestorPolicy
        ) else { return nil }
        self.directory = directory
        expectedOwnerUID = expectations.ownerUID
        expectedGroupID = expectations.groupID
        self.lockTimeout = lockTimeout
        self.lockNow = lockNow
        self.fileOperations = fileOperations
    }

    init(
        directory: VerifiedRootStateDirectory,
        expectedOwnerUID: uid_t = 0,
        expectedGroupID: gid_t = 0,
        lockTimeout: TimeInterval = 1,
        lockNow: @escaping () -> TimeInterval = MonotonicClock.seconds,
        fileOperations: RecoveryAuthorityFileOperations = .system
    ) {
        self.directory = directory
        self.expectedOwnerUID = expectedOwnerUID
        self.expectedGroupID = expectedGroupID
        self.lockTimeout = lockTimeout
        self.lockNow = lockNow
        self.fileOperations = fileOperations
    }

    /// Creates or verifies only the fixed lock inode. This operation does not
    /// bootstrap proof, migrate history, inspect power, or delete anything; it
    /// is therefore safe before the administrator has proved old writers are
    /// stopped.
    func provisionLock() -> RecoveryProvisionOutcome {
        switch directory.provisionLockLeaf(RootStateLock.authorizationBasename) {
        case .provisioned, .alreadyPresent: return .ready
        case .provisionedButUnverified: return .recoveryRequired("lock-provision-unverified")
        case .failure: return .recoveryRequired("lock-provision-failed")
        }
    }

    /// Compatibility helper for deterministic fixtures. Production performs
    /// `provisionLock()` first, proves legacy writers stopped, and only then
    /// invokes `prepareAuthorityAfterWriterQuiescence()`.
    func provision() -> RecoveryProvisionOutcome {
        let lock = provisionLock()
        guard lock == .ready else { return lock }
        return prepareAuthorityAfterWriterQuiescence()
    }

    func prepareAuthorityAfterWriterQuiescence() -> RecoveryProvisionOutcome {
        return RootStateLock.withExclusive(
            directory: directory,
            timeout: lockTimeout,
            now: lockNow
        ) { transaction in
            self.prepareAuthorityLocked(transaction)
        } ?? .recoveryRequired("root-state-lock-unavailable")
    }

    func prepareAuthorityLocked(
        _ transaction: VerifiedRootStateDirectory.Transaction,
        allowRecoveryRequiredLegacyRetry: Bool = false
    ) -> RecoveryProvisionOutcome {
        guard let inventory = classifiedDirectoryInventory() else {
            // Unknown, unsafe, over-bounded, or concurrently changing leaves
            // are evidence. Preserve the directory byte-for-byte and perform
            // no authority publication here.
            return .recoveryRequired("unsafe-authority-root-inventory")
        }
        var terminal = ledger(Self.terminalBasename)
        var reservation = ledger(Self.reservationBasename)
        let initialApplied = appliedRecordSnapshot()
        var applied = initialApplied.record
        let proof = proofRecord()
        let journal = journalRecord()

        // Public/legacy-mode applied bytes are never compatible with an
        // already completed pristine, migrated, or terminal conclusion. Check
        // that relationship before publishing even an empty ledger. An exact
        // recovery-required retry is admitted only by the explicit operator
        // recovery path, which passes the narrow retry capability below.
        if initialApplied.storage == .legacyMode {
            guard journal == .absent else {
                return .recoveryRequired("legacy-applied-journal-conflict")
            }
            switch proof {
            case .absent:
                break
            case let .valid(existing) where existing.kind == .recoveryRequired:
                guard allowRecoveryRequiredLegacyRetry else {
                    return .recoveryRequired(existing.reason)
                }
            case .valid:
                return .recoveryRequired("legacy-applied-proof-conflict")
            case .invalid:
                return .recoveryRequired("invalid-recovery-proof")
            }
        }

        // A private ownerless record is a durable sanitized crash boundary,
        // not reconnect authority. Only proof absence, an explicit exact retry,
        // or the matching terminal proof created after restoration may resume.
        if initialApplied.storage == .privateMode,
           case let .legacyRestoreOnly(state) = applied {
            switch proof {
            case .absent:
                break
            case let .valid(existing) where existing.kind == .recoveryRequired:
                guard allowRecoveryRequiredLegacyRetry else {
                    return .recoveryRequired(existing.reason)
                }
            case let .valid(existing) where existing.kind == .terminal:
                guard existing.sessionID == state.sessionID,
                      terminal.entries?.last == state.sessionID
                else { return .recoveryRequired("legacy-applied-proof-conflict") }
            case .valid:
                return .recoveryRequired("legacy-applied-proof-conflict")
            case .invalid:
                return .recoveryRequired("invalid-recovery-proof")
            }
        }

        // Freeze the canonical downgrade before any compatible preparation
        // mutation. This is intentionally computed from the descriptor-checked
        // public state and exact legacy timer evidence, and contains no owner
        // tuple or lease that a later private inode could reclassify.
        let publicRestoreProjection: AppliedState?
        if initialApplied.storage == .legacyMode,
           case let .legacyRestoreOnly(state) = applied {
            guard let sanitized = migratedLegacyState(state),
                  sanitized.owner == nil,
                  sanitized.leaseExpiryMonotonic == nil,
                  !sanitized.isProcessBound
            else { return .recoveryRequired("legacy-authority-sanitization-failed") }
            publicRestoreProjection = sanitized
        } else {
            publicRestoreProjection = nil
        }

        guard journal != .invalid else {
            return provisionFailure("invalid-legacy-recovery-journal", transaction)
        }

        // A verified journal means migration crossed its durable prepare
        // boundary. Re-entry may migrate exact legacy ledger bytes, but it must
        // not rewrite the journal or manufacture a pristine proof.
        if case .valid = journal {
            guard prepareLedgers(
                terminal: terminal,
                reservation: reservation,
                allowBothMissing: true,
                allowInterruptedEmptyPair: true,
                transaction: transaction
            ) else { return provisionFailure("journal-ledger-migration-failed", transaction) }
            guard proof != .invalid else {
                return provisionFailure("invalid-recovery-proof", transaction)
            }
            return .ready
        }

        // Existing current authority is already prepared. Legacy-mode ledgers
        // may be migrated byte-for-byte, but no missing history is guessed. A
        // recovery-required proof may continue only an exact legacy applied
        // record that still owns restoration; current private process authority
        // keeps its exact retry path and ordinary idle recovery-required state
        // is never relabelled.
        var mayResumeLegacyPreparation = false
        if case let .valid(existingProof) = proof {
            let hasLegacyApplied: Bool
            if case .legacyRestoreOnly = applied { hasLegacyApplied = true }
            else { hasLegacyApplied = false }
            let canResumeEmptyPair = existingProof.kind == .pristine
                || (existingProof.kind == .recoveryRequired
                    && hasLegacyApplied
                    && allowRecoveryRequiredLegacyRetry)
            guard prepareLedgers(
                terminal: terminal,
                reservation: reservation,
                allowBothMissing: canResumeEmptyPair,
                allowInterruptedEmptyPair: canResumeEmptyPair,
                transaction: transaction
            ) else { return provisionFailure("ledger-migration-or-history-ambiguous", transaction) }
            guard applied != .invalid else {
                return provisionFailure("invalid-applied-state", transaction)
            }
            if existingProof.kind == .recoveryRequired {
                switch applied {
                case .legacyRestoreOnly:
                    guard allowRecoveryRequiredLegacyRetry else { return .ready }
                    mayResumeLegacyPreparation = true
                case .missing, .privateAuthority, .quarantinedApplied, .invalid:
                    return .ready
                }
            } else {
                return .ready
            }
            if mayResumeLegacyPreparation {
                terminal = ledger(Self.terminalBasename)
                reservation = ledger(Self.reservationBasename)
                applied = appliedRecord()
            }
        }
        guard proof == .absent || mayResumeLegacyPreparation else {
            return provisionFailure("invalid-recovery-proof", transaction)
        }

        let fresh = terminal == .absent
            && reservation == .absent
            && applied == .missing
            && journal == .absent
            && inventory == .fresh
        if fresh {
            let bootstrap = RecoveryProof(kind: .pristine, sessionID: nil, reason: "bootstrap")
            guard publishProof(bootstrap, transaction).isVerified else {
                // A rename may already have published exact bootstrap bytes.
                // Never overwrite that indeterminate boundary with a second
                // conclusion; re-entry can classify it exactly.
                return .recoveryRequired("bootstrap-proof-unverified")
            }
            guard prepareLedgers(
                terminal: .absent,
                reservation: .absent,
                allowBothMissing: true,
                allowInterruptedEmptyPair: true,
                transaction: transaction
            ) else {
                // The verified pristine proof is the resume marker if only one
                // empty ledger crossed its rename boundary before a crash.
                return .recoveryRequired("bootstrap-ledger-unverified")
            }
            return .ready
        }

        if inventory == .fresh, applied == .missing,
           terminal != .absent, reservation != .absent {
            guard prepareLedgers(
                terminal: terminal,
                reservation: reservation,
                allowBothMissing: false,
                allowInterruptedEmptyPair: false,
                transaction: transaction
            ) else { return provisionFailure("legacy-ledger-migration-failed", transaction) }
            let terminalEntries = privateLedger(Self.terminalBasename) ?? []
            let reservationEntries = privateLedger(Self.reservationBasename) ?? []
            guard reservationEntries.isEmpty else {
                return provisionFailure("legacy-reservation-unresolved", transaction)
            }
            if let latest = terminalEntries.last {
                guard publishProof(
                    .init(kind: .terminal, sessionID: latest, reason: "legacy-migration"),
                    transaction
                ).isVerified else {
                    return provisionFailure("legacy-proof-migration-failed", transaction)
                }
            } else {
                let legacy = LegacyRecoveryJournal(
                    phase: .prepared,
                    ownsSleepDisabled: false,
                    acTarget: nil,
                    batteryTarget: nil,
                    acDisposition: .notRequired,
                    batteryDisposition: .notRequired
                )
                guard publishJournal(legacy, transaction).isVerified else {
                    return .recoveryRequired("legacy-journal-publication-failed")
                }
            }
            return .ready
        }

        // Any proof-absent or explicitly retried legacy applied record is
        // restore-only. Publish only an owner/lease-free canonical projection;
        // never copy public schema-2 process identity into private authority.
        // Both missing ledgers are legitimate historical state; a one-sided
        // gap is conflicting evidence and is preserved.
        switch applied {
        case let .legacyRestoreOnly(legacyState), let .privateAuthority(legacyState):
            guard let migrated = publicRestoreProjection ?? migratedLegacyState(legacyState),
                  migrated.owner == nil,
                  migrated.leaseExpiryMonotonic == nil,
                  !migrated.isProcessBound,
                  prepareLedgers(
                terminal: terminal,
                reservation: reservation,
                allowBothMissing: true,
                allowInterruptedEmptyPair: true,
                transaction: transaction
            ), migrateLegacyPowerEvidence(transaction),
               publishApplied(migrated, transaction).isVerified,
               appliedRecord() == .legacyRestoreOnly(migrated)
            else {
                // The applied record itself is the exact resume marker. Do not
                // publish a competing proof that would hide a one-ledger or
                // timer-migration crash boundary on the next invocation.
                return .recoveryRequired("legacy-authority-migration-failed")
            }
            return .ready
        case .quarantinedApplied:
            // Only RecoveryCoordinator's terminal replay may consume a
            // quarantined applied leaf; preparation must never relabel it.
            return .recoveryRequired("quarantined-applied-replay-required")
        case .invalid:
            return provisionFailure("invalid-applied-state", transaction)
        case .missing:
            break
        }

        // A shipped v0.1 installation can have no applied record and no UUID.
        // Strict root-owned timer/history evidence authorizes a sessionless
        // journal, never a synthetic terminal generation or pristine proof.
        let ac = legacyInteger(Self.legacyACBasename)
        let battery = legacyInteger(Self.legacyBatteryBasename)
        guard ac != .invalid, battery != .invalid else {
            return .recoveryRequired("invalid-legacy-power-evidence")
        }
        let recognizedHistory = inventory == .recognizedHistory
        if recognizedHistory {
            guard historicalArtifactsAreStrict else {
                return .recoveryRequired("unsafe-legacy-history")
            }
            guard terminal == .absent || reservation != .absent,
                  reservation == .absent || terminal != .absent
            else { return .recoveryRequired("legacy-history-ledger-conflict") }

            // When both ledgers are absent, publish the no-session journal as
            // the durable resume marker before creating either empty ledger.
            // That makes a crash after only one ledger rename distinguishable
            // from a pre-existing one-sided historical gap.
            if terminal == .absent, reservation == .absent {
                guard historicalStatusAllowsSessionlessMigration else {
                    return .recoveryRequired("legacy-status-lineage-conflict")
                }
                guard migrateLegacyPowerEvidence(transaction) else {
                    return .recoveryRequired("legacy-power-evidence-migration-failed")
                }
                let prepared = LegacyRecoveryJournal(
                    phase: .prepared,
                    ownsSleepDisabled: ac.value != nil || battery.value != nil,
                    acTarget: ac.value,
                    batteryTarget: battery.value,
                    acDisposition: ac.value == nil ? .notRequired : .pending,
                    batteryDisposition: battery.value == nil ? .notRequired : .pending
                )
                guard publishJournal(prepared, transaction).isVerified else {
                    return .recoveryRequired("legacy-journal-publication-failed")
                }
                guard prepareLedgers(
                    terminal: .absent,
                    reservation: .absent,
                    allowBothMissing: true,
                    allowInterruptedEmptyPair: true,
                    transaction: transaction
                ) else { return .recoveryRequired("legacy-ledger-publication-failed") }
                return .ready
            }

            guard prepareLedgers(
                terminal: terminal,
                reservation: reservation,
                allowBothMissing: false,
                allowInterruptedEmptyPair: false,
                transaction: transaction
            ), let terminalEntries = privateLedger(Self.terminalBasename),
               let reservationEntries = privateLedger(Self.reservationBasename),
               reservationEntries.isEmpty
            else { return .recoveryRequired("legacy-history-ledger-conflict") }

            let acTarget = ac.value
            let batteryTarget = battery.value
            if !terminalEntries.isEmpty {
                guard acTarget == nil, batteryTarget == nil,
                      let latest = terminalEntries.last,
                      historicalStatusAllowsTerminalMigration(latest),
                      publishProof(
                        .init(kind: .terminal, sessionID: latest, reason: "legacy-migration"),
                        transaction
                      ).isVerified
                else { return .recoveryRequired("legacy-sessionless-history-conflict") }
                return .ready
            }

            guard historicalStatusAllowsSessionlessMigration else {
                return .recoveryRequired("legacy-status-lineage-conflict")
            }

            guard migrateLegacyPowerEvidence(transaction) else {
                return .recoveryRequired("legacy-power-evidence-migration-failed")
            }
            let journal = LegacyRecoveryJournal(
                phase: .prepared,
                ownsSleepDisabled: acTarget != nil || batteryTarget != nil,
                acTarget: acTarget,
                batteryTarget: batteryTarget,
                acDisposition: acTarget == nil ? .notRequired : .pending,
                batteryDisposition: batteryTarget == nil ? .notRequired : .pending
            )
            guard publishJournal(journal, transaction).isVerified else {
                return .recoveryRequired("legacy-journal-publication-failed")
            }
            return .ready
        }

        return provisionFailure("ledger-migration-or-history-ambiguous", transaction)
    }

    /// Read-only classification used by normal daemon startup. It deliberately
    /// exposes no inventory details: callers may only distinguish a fully
    /// recognized authority root from an unsafe or ambiguous one.
    var authorityRootInventoryIsSafe: Bool {
        classifiedDirectoryInventory() != nil
    }

    private func prepareLedgers(
        terminal: RecoveryLedgerRecord,
        reservation: RecoveryLedgerRecord,
        allowBothMissing: Bool,
        allowInterruptedEmptyPair: Bool,
        transaction: VerifiedRootStateDirectory.Transaction
    ) -> Bool {
        if terminal == .absent || reservation == .absent {
            if terminal == .absent, reservation == .absent {
                guard allowBothMissing else { return false }
                return publishLedger(bytes: "", basename: Self.terminalBasename, transaction: transaction).isVerified
                    && publishLedger(bytes: "", basename: Self.reservationBasename, transaction: transaction).isVerified
            }
            guard allowInterruptedEmptyPair else { return false }
            if terminal == .absent,
               case let .privateAuthority(entries, bytes) = reservation,
               entries.isEmpty, bytes.isEmpty {
                return publishLedger(bytes: "", basename: Self.terminalBasename, transaction: transaction).isVerified
            }
            if reservation == .absent,
               case let .privateAuthority(entries, bytes) = terminal,
               entries.isEmpty, bytes.isEmpty {
                return publishLedger(bytes: "", basename: Self.reservationBasename, transaction: transaction).isVerified
            }
            return false
        }
        return migrateLedgerIfNeeded(terminal, basename: Self.terminalBasename, transaction: transaction)
            && migrateLedgerIfNeeded(reservation, basename: Self.reservationBasename, transaction: transaction)
    }

    private func migrateLegacyPowerEvidence(
        _ transaction: VerifiedRootStateDirectory.Transaction
    ) -> Bool {
        for basename in [Self.legacyACBasename, Self.legacyBatteryBasename] {
            switch legacyInteger(basename) {
            case .absent:
                continue
            case let .value(value):
                let canonical = "\(value)\n"
                guard publish(canonical, basename, transaction, parser: {
                    Self.parseLegacyTimer($0) == value
                }).isVerified else { return false }
            case .invalid:
                return false
            }
        }
        return true
    }

    private enum LegacyIntegerRecord: Equatable {
        case absent, value(Int), invalid
        var value: Int? { if case let .value(value) = self { return value }; return nil }
    }

    private func migratedLegacyState(_ state: AppliedState) -> AppliedState? {
        let ac = legacyInteger(Self.legacyACBasename)
        let battery = legacyInteger(Self.legacyBatteryBasename)
        guard ac != .invalid, battery != .invalid else { return nil }

        var changedAC = state.changedACSleep
        var originalAC = state.originalACSleep
        if case let .value(value) = ac {
            if changedAC, originalAC != value { return nil }
            changedAC = value != 0
            originalAC = value == 0 ? nil : value
        }
        var changedBattery = state.changedBatterySleep
        var originalBattery = state.originalBatterySleep
        if case let .value(value) = battery {
            if changedBattery, originalBattery != value { return nil }
            changedBattery = value != 0
            originalBattery = value == 0 ? nil : value
        }
        // Sanitization removes process identity, so schema-bearing shapes can
        // never survive. It must still retain the explicit battery dimension:
        // a six/fourteen-key no-op record is distinct canonical evidence from
        // its four-key projection.
        // Timer evidence can add an owned battery baseline to an older
        // four-key record.  The serialized projection must then carry the
        // battery fields as well; retaining the old four-key shape would drop
        // the migrated baseline on parse and make the just-published private
        // authority fail its own exact round trip.
        let retainedBatteryDimension = state.payloadShape == .legacySix
            || state.payloadShape == .schemaFourteen
        let sanitizedShape: AppliedState.PayloadShape = (retainedBatteryDimension || changedBattery || originalBattery != nil)
            ? .legacySix
            : .legacyFour
        return AppliedState(
            sessionID: state.sessionID,
            changedSleepDisabled: state.changedSleepDisabled || ac != .absent || battery != .absent,
            changedACSleep: changedAC,
            originalACSleep: originalAC,
            changedBatterySleep: changedBattery,
            originalBatterySleep: originalBattery,
            payloadShape: sanitizedShape
        )
    }

    private func legacyInteger(_ basename: String) -> LegacyIntegerRecord {
        switch recoverableLeafName(basename) {
        case .absent: return .absent
        case .invalid: return .invalid
        case let .bound(name):
            let raw: String
            switch classifiedText(name, maximumBytes: 128) {
            case let .privateMode(value), let .legacyMode(value): raw = value
            case .invalid: return .invalid
            }
            guard let value = Self.parseLegacyTimer(raw) else { return .invalid }
            return .value(value)
        }
    }

    private static func parseLegacyTimer(_ raw: String) -> Int? {
        let canonical = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
        guard !canonical.isEmpty,
              canonical.utf8.count <= 4,
              canonical.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(canonical), value >= 0, value <= 1_440,
              canonical == String(value),
              raw == canonical || raw == canonical + "\n"
        else { return nil }
        return value
    }

    private struct HistoricalHelperStatus: Equatable {
        let state: String
        let sessionID: UUID?
    }

    private enum HistoricalHelperStatusRecord: Equatable {
        case absent
        case valid(HistoricalHelperStatus)
        case invalid
    }

    private var historicalStatusRecord: HistoricalHelperStatusRecord {
        switch directory.entryState("helper-status") {
        case .absent:
            return evidenceState(for: "helper-status") == .absent ? .absent : .invalid
        case .unknown:
            return .invalid
        case .present:
            let raw: String
            switch classifiedText("helper-status", maximumBytes: 4_096) {
            case let .privateMode(value), let .legacyMode(value): raw = value
            case .invalid: return .invalid
            }
            guard let parsed = Self.parseHistoricalHelperStatus(raw) else { return .invalid }
            return .valid(parsed)
        }
    }

    private var historicalStatusAllowsSessionlessMigration: Bool {
        switch historicalStatusRecord {
        case .absent:
            return true
        case let .valid(status):
            return status.state == "inactive" && status.sessionID == nil
        case .invalid:
            return false
        }
    }

    private func historicalStatusAllowsTerminalMigration(_ terminal: UUID) -> Bool {
        switch historicalStatusRecord {
        case .absent:
            return true
        case let .valid(status):
            return status.state == "terminal" && status.sessionID == terminal
        case .invalid:
            return false
        }
    }

    private static func parseHistoricalHelperStatus(_ raw: String) -> HistoricalHelperStatus? {
        guard raw.utf8.count <= 4_096,
              raw.hasSuffix("\n"), !raw.hasSuffix("\n\n")
        else { return nil }
        let body = raw.dropLast()
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 4, lines.count <= 12 else { return nil }

        var values: [String: String] = [:]
        var orderedKeys: [String] = []
        for line in lines {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, !pair[0].isEmpty else { return nil }
            let key = String(pair[0])
            let value = String(pair[1])
            guard values.updateValue(value, forKey: key) == nil else { return nil }
            orderedKeys.append(key)
        }
        guard Array(orderedKeys.prefix(4)) == ["state", "reason", "session", "updated"],
              let state = values["state"],
              state.range(of: "^[a-z0-9-]{1,32}$", options: .regularExpression) != nil,
              let reason = values["reason"],
              reason.range(of: "^[a-z0-9-]{1,96}$", options: .regularExpression) != nil,
              let sessionRaw = values["session"],
              let updatedRaw = values["updated"],
              let updated = UInt64(updatedRaw), updatedRaw == String(updated)
        else { return nil }

        let sessionID: UUID?
        if sessionRaw == "none" {
            sessionID = nil
        } else {
            guard let session = UUID(uuidString: sessionRaw),
                  session.uuidString.lowercased() == sessionRaw
            else { return nil }
            sessionID = session
        }

        let evidenceKeys = Array(orderedKeys.dropFirst(4))
        guard evidenceKeys == evidenceKeys.sorted(),
              Set(evidenceKeys).count == evidenceKeys.count
        else { return nil }
        for key in evidenceKeys {
            guard key.range(of: "^[a-z_]{1,48}$", options: .regularExpression) != nil,
                  !["state", "reason", "session", "updated"].contains(key),
                  let value = values[key], value.utf8.count <= 96,
                  value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7e })
            else { return nil }
        }
        if let boot = values["boot_id"] {
            guard boot == "unknown" || BootIdentity.normalizeBootSessionUUID(boot) == boot else { return nil }
        }
        if let monotonicRaw = values["updated_monotonic"] {
            guard let monotonic = TimeInterval(monotonicRaw), monotonic.isFinite, monotonic >= 0 else { return nil }
        }
        return HistoricalHelperStatus(state: state, sessionID: sessionID)
    }

    private static func parseHistoricalHelperVersion(_ raw: String) -> Int? {
        let canonical = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
        guard !canonical.isEmpty, canonical.utf8.count <= 7,
              canonical.allSatisfy({ $0.isASCII && $0.isNumber }),
              let version = Int(canonical), version > 0, version <= 1_000_000,
              canonical == String(version),
              raw == canonical || raw == canonical + "\n"
        else { return nil }
        return version
    }

    private var historicalArtifactsAreStrict: Bool {
        for basename in Self.legacyHistoryBasenames {
            switch directory.entryState(basename) {
            case .absent:
                if basename == Self.legacyACBasename || basename == Self.legacyBatteryBasename {
                    guard legacyInteger(basename) != .invalid else { return false }
                } else {
                    guard evidenceState(for: basename) == .absent else { return false }
                }
            case .unknown:
                return false
            case .present:
                switch basename {
                case Self.legacyACBasename, Self.legacyBatteryBasename:
                    guard legacyInteger(basename) != .invalid else { return false }
                case "helper-status":
                    guard historicalStatusRecord != .invalid else { return false }
                case "helper-version":
                    let raw: String
                    switch classifiedText(basename, maximumBytes: 128) {
                    case let .privateMode(value), let .legacyMode(value): raw = value
                    case .invalid: return false
                    }
                    guard Self.parseHistoricalHelperVersion(raw) != nil else { return false }
                case "lidswitch-helper", "LidSwitchHelper":
                    guard historicalRegularIsValid(basename, expectedMode: 0o755, maximumBytes: 16 * 1_024 * 1_024) else {
                        return false
                    }
                case "Current", "Previous":
                    guard historicalDirectoryIsValid(basename) else { return false }
                default:
                    return false
                }
            }
        }
        return true
    }

    private enum DirectoryInventory: Equatable { case fresh, recognizedHistory }

    private func classifiedDirectoryInventory() -> DirectoryInventory? {
        guard let names = directory.boundedEntryNames() else { return nil }
        let authorityNames: Set<String> = [
            RootStateLock.authorizationBasename,
            Self.appliedBasename,
            Self.terminalBasename,
            Self.reservationBasename,
            Self.proofBasename,
            Self.containmentReceiptBasename,
            Self.statusProjectionBasename,
            Self.statusProjectionGenerationBasename,
            // Exact, descriptor-bound public projection artifacts. Their
            // lifecycle is recovered by HelperStatusStore; no prefix or
            // caller-selected temporary name is accepted here.
            "helper-status.projection.lock",
            "helper-status.projection-temp",
            Self.recoveryBudgetBasename,
            Self.journalBasename,
        ]
        var recognizedHistory = false
        for name in names {
            if authorityNames.contains(name) {
                // The public projection capability has exactly two durable
                // transaction artifacts.  They are not a broad prefix: each
                // is descriptor-opened/no-follow and metadata-bound here;
                // HelperStatusStore then either completes the canonical temp
                // recovery under its lock or returns typed unsafe evidence.
                if name == "helper-status.projection.lock",
                   !strictProjectionArtifactIsValid(name, expectedMode: 0o600, maximumBytes: 0) { return nil }
                if name == "helper-status.projection-temp",
                   !strictProjectionArtifactIsValid(name, expectedMode: 0o644, maximumBytes: 4_096) { return nil }
                continue
            }
            let recoverableQuarantines = [
                Self.appliedBasename,
                Self.legacyACBasename,
                Self.legacyBatteryBasename,
                Self.journalBasename,
                Self.recoveryBudgetBasename,
            ].compactMap { VerifiedRootStateDirectory.quarantineBasename(for: $0) }
            if recoverableQuarantines.contains(name) {
                if name != VerifiedRootStateDirectory.quarantineBasename(for: Self.journalBasename) {
                    recognizedHistory = true
                }
                continue
            }
            if Self.legacyHistoryBasenames.contains(name) {
                recognizedHistory = true
                continue
            }
            if let transaction = canonicalTransactionID(
                name,
                prefix: ".administrator-",
                suffix: ""
            ) {
                _ = transaction
                // The candidate stage is mutable installer work, not authority
                // and not historical evidence. Its mere presence makes a fresh
                // or migration classification impossible; staging belongs
                // outside this root before authority preparation begins.
                return nil
            }
            if canonicalTransactionID(
                name,
                prefix: "administrator-transaction-",
                suffix: ".receipt"
            ) != nil {
                guard case let .legacyMode(raw) = classifiedText(name, maximumBytes: 1_024),
                      AdministratorTransactionReceipt.parse(raw) != nil
                else { return nil }
                continue
            }
            // Quarantines, abandoned publication temps, user state, and every
            // other unrecognized leaf block both pristine bootstrap and legacy
            // migration. They are never silently ignored.
            return nil
        }
        guard !recognizedHistory || historicalArtifactsAreStrict else { return nil }
        return recognizedHistory ? .recognizedHistory : .fresh
    }

    private func canonicalTransactionID(
        _ name: String,
        prefix: String,
        suffix: String
    ) -> UUID? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix),
              name.utf8.count > prefix.utf8.count + suffix.utf8.count
        else { return nil }
        let end = suffix.isEmpty ? name.endIndex : name.index(name.endIndex, offsetBy: -suffix.count)
        let raw = String(name[name.index(name.startIndex, offsetBy: prefix.count)..<end])
        guard let value = UUID(uuidString: raw), value.uuidString.lowercased() == raw else { return nil }
        return value
    }

    private func historicalRegularIsValid(
        _ basename: String,
        expectedMode: mode_t,
        maximumBytes: off_t
    ) -> Bool {
        guard let parent = directory.directoryDescriptor else { return false }
        let fd = Darwin.openat(parent, basename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0,
              Self.historicalRegularMetadataIsAccepted(
                before,
                expectedOwnerUID: expectedOwnerUID,
                expectedGroupID: expectedGroupID,
                expectedMode: expectedMode,
                maximumBytes: maximumBytes
              ),
              readExactly(fd, count: Int(before.st_size)) != nil
        else { return false }
        var after = stat()
        var bound = stat()
        return fstat(fd, &after) == 0
            && sameMetadata(before, after)
            && fstatat(parent, basename, &bound, AT_SYMLINK_NOFOLLOW) == 0
            && sameMetadata(before, bound)
    }

    static func historicalRegularMetadataIsAccepted(
        _ status: stat,
        expectedOwnerUID: uid_t,
        expectedGroupID: gid_t,
        expectedMode: mode_t,
        maximumBytes: off_t
    ) -> Bool {
        (status.st_mode & S_IFMT) == S_IFREG
            && status.st_uid == expectedOwnerUID
            && historicalGroupIsAccepted(
                ownerUID: expectedOwnerUID,
                expectedGroupID: expectedGroupID,
                actualGroupID: status.st_gid
            )
            && status.st_nlink == 1
            && status.st_mode & 0o7777 == expectedMode
            && status.st_size >= 0
            && status.st_size <= maximumBytes
    }

    private func strictProjectionArtifactIsValid(
        _ basename: String,
        expectedMode: mode_t,
        maximumBytes: off_t
    ) -> Bool {
        guard let parent = directory.directoryDescriptor else { return false }
        let fd = Darwin.openat(parent, basename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == expectedOwnerUID, before.st_gid == expectedGroupID,
              before.st_nlink == 1, before.st_mode & 0o7777 == expectedMode,
              before.st_size >= 0, before.st_size <= maximumBytes,
              readExactly(fd, count: Int(before.st_size)) != nil
        else { return false }
        var after = stat(); var bound = stat()
        return fstat(fd, &after) == 0 && sameMetadata(before, after)
            && fstatat(parent, basename, &bound, AT_SYMLINK_NOFOLLOW) == 0
            && sameMetadata(before, bound)
    }

    private func historicalDirectoryIsValid(_ basename: String) -> Bool {
        exactDirectoryIsValid(basename, expectedMode: 0o755, allowHistoricalGroup: true)
    }

    private func exactDirectoryIsValid(
        _ basename: String,
        expectedMode: mode_t,
        allowHistoricalGroup: Bool = false
    ) -> Bool {
        guard let parent = directory.directoryDescriptor else { return false }
        let fd = Darwin.openat(parent, basename, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFDIR,
              before.st_uid == expectedOwnerUID,
              (allowHistoricalGroup ? historicalGroupIsAccepted(before.st_gid) : before.st_gid == expectedGroupID),
              before.st_nlink >= 2,
              before.st_mode & 0o7777 == expectedMode
        else { return false }
        var bound = stat()
        return fstatat(parent, basename, &bound, AT_SYMLINK_NOFOLLOW) == 0
            && sameMetadata(before, bound)
    }

    private func historicalGroupIsAccepted(_ gid: gid_t) -> Bool {
        Self.historicalGroupIsAccepted(
            ownerUID: expectedOwnerUID,
            expectedGroupID: expectedGroupID,
            actualGroupID: gid
        )
    }

    static func historicalGroupIsAccepted(
        ownerUID: uid_t,
        expectedGroupID: gid_t,
        actualGroupID: gid_t
    ) -> Bool {
        actualGroupID == expectedGroupID || (ownerUID == 0 && actualGroupID == 80)
    }

    private func provisionFailure(
        _ reason: String,
        _ transaction: VerifiedRootStateDirectory.Transaction
    ) -> RecoveryProvisionOutcome {
        // Malformed proof bytes are evidence. Never destroy them in order to
        // publish a cleaner-looking failure conclusion. Preserve the first
        // durable recovery-required reason as well, avoiding retry churn that
        // could obscure the original boundary.
        switch proofRecord() {
        case .invalid:
            break
        case let .valid(proof) where proof.kind == .recoveryRequired:
            break
        case .absent, .valid:
            _ = markRecoveryRequired(reason, transaction)
        }
        return .recoveryRequired(reason)
    }

    private func migrateLedgerIfNeeded(
        _ record: RecoveryLedgerRecord,
        basename: String,
        transaction: VerifiedRootStateDirectory.Transaction
    ) -> Bool {
        switch record {
        case .privateAuthority: return true
        case let .legacyReadable(_, bytes):
            // The legacy descriptor was held, metadata-stable, exact-EOF read,
            // and parsed before this atomic replacement. No invalid bytes are
            // ever overwritten.
            return publishLedger(bytes: bytes, basename: basename, transaction: transaction).isVerified
        case .absent, .invalid: return false
        }
    }

    func withTransaction<T>(_ body: (VerifiedRootStateDirectory.Transaction) -> T) -> T? {
        RootStateLock.withExclusive(
            directory: directory,
            timeout: lockTimeout,
            now: lockNow,
            body: body
        )
    }

    func ledger(_ basename: String) -> RecoveryLedgerRecord {
        guard basename == Self.terminalBasename || basename == Self.reservationBasename else { return .invalid }
        switch directory.entryState(basename) {
        case .absent: return evidenceState(for: basename) == .absent ? .absent : .invalid
        case .unknown: return .invalid
        case .present:
            switch classifiedText(basename, maximumBytes: TerminalGenerationLedger.maximumBytes) {
            case let .privateMode(raw):
                guard let entries = TerminalGenerationLedger.parse(raw) else { return .invalid }
                return .privateAuthority(entries: entries, bytes: raw)
            case let .legacyMode(raw):
                guard let entries = TerminalGenerationLedger.parse(raw) else { return .invalid }
                return .legacyReadable(entries: entries, bytes: raw)
            case .invalid:
                return .invalid
            }
        }
    }

    func privateLedger(_ basename: String) -> [UUID]? {
        guard case let .privateAuthority(entries, _) = ledger(basename) else { return nil }
        return entries
    }

    func proof() -> RecoveryProof? {
        guard case let .valid(proof) = proofRecord() else { return nil }
        return proof
    }

    enum JournalRecord: Equatable {
        case absent
        case valid(LegacyRecoveryJournal)
        case invalid
    }

    enum BudgetRecord: Equatable {
        case absent
        case valid(RecoveryBudgetState)
        case invalid
    }

    func recoveryBudgetRecord() -> BudgetRecord {
        switch recoverableLeafName(Self.recoveryBudgetBasename) {
        case .absent: return .absent
        case .invalid: return .invalid
        case let .bound(name):
            guard case let .privateMode(raw) = classifiedText(
                name,
                maximumBytes: RecoveryBudgetState.maximumBytes
            ), let budget = RecoveryBudgetState.parse(raw) else { return .invalid }
            return .valid(budget)
        }
    }

    func publishRecoveryBudget(
        _ budget: RecoveryBudgetState,
        _ transaction: VerifiedRootStateDirectory.Transaction
    ) -> RecoveryPublicationOutcome {
        if recoveryBudgetRecord() == .valid(budget) { return .alreadyVerified }
        return publish(budget.payload, Self.recoveryBudgetBasename, transaction) {
            RecoveryBudgetState.parse($0) == budget
        }
    }

    func removeRecoveryBudget(
        expected: RecoveryBudgetState,
        _ transaction: VerifiedRootStateDirectory.Transaction
    ) -> VerifiedRootStateDirectory.RemovalResult {
        transaction.removeOrResume(
            Self.recoveryBudgetBasename,
            maximumBytes: RecoveryBudgetState.maximumBytes
        ) { data in
            guard let raw = String(data: data, encoding: .utf8) else { return false }
            return raw == expected.payload && RecoveryBudgetState.parse(raw) == expected
        }
    }

    func journalRecord() -> JournalRecord {
        switch recoverableLeafName(Self.journalBasename) {
        case .absent: return .absent
        case .invalid: return .invalid
        case let .bound(name):
            guard case let .privateMode(raw) = classifiedText(
                name,
                maximumBytes: LegacyRecoveryJournal.maximumBytes
            ), let journal = LegacyRecoveryJournal.parse(raw) else { return .invalid }
            return .valid(journal)
        }
    }

    func publishJournal(
        _ journal: LegacyRecoveryJournal,
        _ transaction: VerifiedRootStateDirectory.Transaction
    ) -> RecoveryPublicationOutcome {
        if journalRecord() == .valid(journal) { return .alreadyVerified }
        return publish(journal.payload, Self.journalBasename, transaction, parser: {
            LegacyRecoveryJournal.parse($0) == journal
        })
    }

    func removeJournal(
        expected: LegacyRecoveryJournal,
        _ transaction: VerifiedRootStateDirectory.Transaction
    ) -> VerifiedRootStateDirectory.RemovalResult {
        transaction.removeOrResume(
            Self.journalBasename,
            maximumBytes: LegacyRecoveryJournal.maximumBytes
        ) { data in
            guard let raw = String(data: data, encoding: .utf8) else { return false }
            return raw == expected.payload && LegacyRecoveryJournal.parse(raw) == expected
        }
    }

    private enum AppliedRecordStorage: Equatable {
        case absent
        case privateMode
        case legacyMode
        case invalid
    }

    private struct AppliedRecordSnapshot {
        let record: RecoveryAppliedRecord
        let storage: AppliedRecordStorage
    }

    private func appliedRecordSnapshot() -> AppliedRecordSnapshot {
        switch recoverableLeafName(Self.appliedBasename) {
        case .absent:
            return .init(record: .missing, storage: .absent)
        case .invalid:
            return .init(record: .invalid, storage: .invalid)
        case let .bound(name):
            switch classifiedText(name, maximumBytes: 4_096) {
            case let .privateMode(raw):
                guard let state = AppliedState.parse(raw) else {
                    return .init(record: .invalid, storage: .invalid)
                }
                if name != Self.appliedBasename {
                    return .init(record: .quarantinedApplied(state), storage: .privateMode)
                }
                return .init(
                    record: state.isProcessBound ? .privateAuthority(state) : .legacyRestoreOnly(state),
                    storage: .privateMode
                )
            case let .legacyMode(raw):
                guard let state = AppliedState.parse(raw) else {
                    return .init(record: .invalid, storage: .invalid)
                }
                return .init(record: .legacyRestoreOnly(state), storage: .legacyMode)
            case .invalid:
                return .init(record: .invalid, storage: .invalid)
            }
        }
    }

    func appliedRecord() -> RecoveryAppliedRecord {
        appliedRecordSnapshot().record
    }

    /// Compatibility projection for the session authority. Callers that need
    /// reconnect authority must use `appliedRecord()` and require its private
    /// case explicitly.
    func applied() -> AppliedStateLoadResult {
        switch appliedRecord() {
        case .missing: return .missing
        case .invalid: return .invalid
        case let .privateAuthority(state), let .legacyRestoreOnly(state): return .success(state)
        case .quarantinedApplied: return .invalid
        }
    }

    func recordTerminal(
        _ session: UUID,
        into basename: String,
        transaction: VerifiedRootStateDirectory.Transaction
    ) -> RecoveryPublicationOutcome {
        guard basename == Self.terminalBasename || basename == Self.reservationBasename,
              case let .privateAuthority(entries, _) = ledger(basename) else {
            return .notPublished(.finalMetadata)
        }
        switch basename {
        case Self.reservationBasename:
            // Reservation is a membership history: one entry per session.
            if entries.contains(session) { return .alreadyVerified }
        case Self.terminalBasename:
            // Terminal history is ordered. An older receipt cannot authorize a
            // fresh terminal proof or cleanup for a different latest receipt.
            if entries.last == session { return .alreadyVerified }
            if entries.contains(session) { return .notPublished(.parser) }
        default:
            return .notPublished(.finalMetadata)
        }
        let updated = Array((entries + [session]).suffix(TerminalGenerationLedger.maximumEntries))
        let bytes = updated.map { $0.uuidString.lowercased() }.joined(separator: "\n") + "\n"
        return publishLedger(bytes: bytes, basename: basename, transaction: transaction)
    }

    func publishProof(
        _ proof: RecoveryProof,
        _ transaction: VerifiedRootStateDirectory.Transaction
    ) -> RecoveryPublicationOutcome {
        let existing = proofRecord()
        if existing == .valid(proof) { return .alreadyVerified }
        // A migrated proof is a completed, sessionless safety conclusion. It
        // is immutable: crash replay may verify it but may never replace or
        // reclassify it, including as recovery-required.
        if case let .valid(current) = existing, current.kind == .migrated {
            return .notPublished(.parser)
        }
        return publish(proof.payload, Self.proofBasename, transaction, parser: { RecoveryProof.parse($0) == proof })
    }

    /// The only admissible successor to a completed migration. It is bound to
    /// the exact private schema-3 applied record and the latest terminal ledger
    /// receipt, so a migrated proof remains immutable for every legacy shape.
    func publishCurrentTerminalProof(
        state: AppliedState,
        reason: String,
        _ transaction: VerifiedRootStateDirectory.Transaction
    ) -> RecoveryPublicationOutcome {
        guard state.provenance == .current,
              state.isReconnectable,
              appliedRecord() == .privateAuthority(state),
              case let .privateAuthority(entries, _) = ledger(Self.terminalBasename),
              entries.last == state.sessionID,
              case let .valid(prior) = proofRecord(), prior.kind == .migrated
        else { return .notPublished(.parser) }
        let proof = RecoveryProof(kind: .terminal, sessionID: state.sessionID, reason: reason)
        return publish(proof.payload, Self.proofBasename, transaction) { RecoveryProof.parse($0) == proof }
    }

    func publishCurrentRecoveryRequired(
        state: AppliedState,
        reason: String,
        _ transaction: VerifiedRootStateDirectory.Transaction
    ) -> RecoveryPublicationOutcome {
        guard state.provenance == .current,
              state.isReconnectable,
              appliedRecord() == .privateAuthority(state),
              case let .privateAuthority(entries, _) = ledger(Self.terminalBasename),
              entries.last == state.sessionID,
              case let .valid(prior) = proofRecord(), prior.kind == .migrated
        else { return .notPublished(.parser) }
        let proof = RecoveryProof(kind: .recoveryRequired, sessionID: nil, reason: reason)
        return publish(proof.payload, Self.proofBasename, transaction) { RecoveryProof.parse($0) == proof }
    }

    func markRecoveryRequired(
        _ reason: String,
        _ transaction: VerifiedRootStateDirectory.Transaction
    ) -> RecoveryPublicationOutcome {
        publishProof(.init(kind: .recoveryRequired, sessionID: nil, reason: reason), transaction)
    }

    func publishApplied(
        _ state: AppliedState,
        _ transaction: VerifiedRootStateDirectory.Transaction
    ) -> RecoveryPublicationOutcome {
        publish(state.storagePayload, Self.appliedBasename, transaction) { AppliedState.parse($0) == state }
    }

    func removeApplied(
        expected state: AppliedState,
        _ transaction: VerifiedRootStateDirectory.Transaction
    ) -> VerifiedRootStateDirectory.RemovalResult {
        transaction.removeOrResume(Self.appliedBasename, maximumBytes: 4_096) { data in
            guard let raw = String(data: data, encoding: .utf8) else { return false }
            return raw == state.storagePayload && AppliedState.parse(raw) == state
        }
    }

    /// Legacy power baselines are restore-only evidence. They may be removed
    /// only by the native helper after a terminal proof has been published;
    /// administrator shell wrappers never parse or delete them.
    func removeLegacyPowerEvidence(
        _ transaction: VerifiedRootStateDirectory.Transaction
    ) -> Bool {
        for basename in [Self.legacyACBasename, Self.legacyBatteryBasename] {
            switch transaction.removeOrResume(basename, maximumBytes: 128) { data in
                guard let raw = String(data: data, encoding: .utf8) else { return false }
                return Self.parseLegacyTimer(raw) != nil
            } {
            case .removed, .alreadyAbsent:
                continue
            case .removalUnverified, .unsafeEntry, .recoveryRequired,
                 .transactionInactive, .reentrant:
                return false
            }
        }
        return true
    }

    func removeLegacyPowerEvidence(
        expectedAC: Int?,
        expectedBattery: Int?,
        _ transaction: VerifiedRootStateDirectory.Transaction
    ) -> Bool {
        for (basename, target) in [
            (Self.legacyACBasename, expectedAC),
            (Self.legacyBatteryBasename, expectedBattery),
        ] {
            guard let target else {
                guard evidenceState(for: basename) == .absent else { return false }
                continue
            }
            switch transaction.removeOrResume(basename, maximumBytes: 128, parser: { data in
                guard let raw = String(data: data, encoding: .utf8) else { return false }
                return Self.parseLegacyTimer(raw) == target
            }) {
            case .removed, .alreadyAbsent:
                continue
            case .removalUnverified, .unsafeEntry, .recoveryRequired,
                 .transactionInactive, .reentrant:
                return false
            }
        }
        return true
    }

    func evidenceState(for basename: String) -> RecoveryEvidenceState {
        let publicState = directory.entryState(basename)
        guard let quarantine = VerifiedRootStateDirectory.quarantineBasename(for: basename) else { return .uncertain }
        let quarantineState = directory.entryState(quarantine)
        switch (publicState, quarantineState) {
        case (.absent, .absent): return .absent
        case (.unknown, _), (_, .unknown): return .uncertain
        default: return .present
        }
    }

    private enum RecoverableLeafName { case absent, bound(String), invalid }

    private func recoverableLeafName(_ basename: String) -> RecoverableLeafName {
        guard let quarantine = VerifiedRootStateDirectory.quarantineBasename(for: basename) else { return .invalid }
        let publicState = directory.entryState(basename)
        let quarantineState = directory.entryState(quarantine)
        switch (publicState, quarantineState) {
        case (.absent, .absent): return .absent
        case (.present, .absent): return .bound(basename)
        case (.absent, .present): return .bound(quarantine)
        case (.unknown, _), (_, .unknown), (.present, .present): return .invalid
        }
    }

    enum ProofRecord: Equatable { case absent, valid(RecoveryProof), invalid }

    /// A containment receipt is root-private authority, never a status
    /// projection. Invalid or quarantined receipts remain fail-closed.
    enum ContainmentReceiptRecord: Equatable { case absent, valid(ContainedProcessReceipt), invalid }
    enum StatusProjectionTaskRecord: Equatable { case absent, valid(StatusProjectionTask), invalid }

    func statusProjectionTaskRecord() -> StatusProjectionTaskRecord {
        switch directory.entryState(Self.statusProjectionBasename) {
        case .absent:
            return evidenceState(for: Self.statusProjectionBasename) == .absent ? .absent : .invalid
        case .unknown: return .invalid
        case .present:
            guard case let .privateMode(raw) = classifiedText(Self.statusProjectionBasename, maximumBytes: StatusProjectionTask.maximumBytes),
                  let task = StatusProjectionTask.parse(raw) else { return .invalid }
            return .valid(task)
        }
    }

    /// The dirty intent is written in the same authority transaction as the
    /// state change. Matching targets coalesce; different targets obtain a
    /// newer generation so an old worker cannot clear newer intent.
    func enqueueStatusProjection(
        state: String,
        reason: String,
        sessionID: UUID?,
        _ transaction: VerifiedRootStateDirectory.Transaction,
        generationFloor: UInt64 = 0
    ) -> StatusProjectionTask? {
        let prior: StatusProjectionTask?
        switch statusProjectionTaskRecord() {
        case .absent: prior = nil
        case let .valid(task):
            if task.state == state, task.reason == reason, task.sessionID == sessionID,
               generationFloor == 0 { return task }
            prior = task
        case .invalid: return nil
        }
        let watermark: UInt64
        switch directory.entryState(Self.statusProjectionGenerationBasename) {
        case .absent: watermark = 0
        case .unknown: return nil
        case .present:
            guard case let .privateMode(raw) = classifiedText(Self.statusProjectionGenerationBasename, maximumBytes: 32),
                  let parsed = UInt64(raw.trimmingCharacters(in: .newlines)),
                  raw == "\(parsed)\n" else { return nil }
            watermark = parsed
        }
        let highestGeneration = max(watermark, max(prior?.generation ?? 0, generationFloor))
        guard highestGeneration < UInt64.max else { return nil }
        let nextGeneration = highestGeneration + 1
        let now = UInt64(max(0, MonotonicClock.seconds()) * 1_000_000_000)
        guard let next = StatusProjectionTask(generation: nextGeneration, state: state,
                                              reason: reason, sessionID: sessionID,
                                              deadlineNanoseconds: now &+ 300_000_000_000),
              publish("\(nextGeneration)\n", Self.statusProjectionGenerationBasename, transaction, parser: { $0 == "\(nextGeneration)\n" }).isVerified,
              publish(next.payload, Self.statusProjectionBasename, transaction, parser: { StatusProjectionTask.parse($0) == next }).isVerified
        else { return nil }
        return next
    }

    func advanceStatusProjectionTask(
        expected: StatusProjectionTask,
        next: StatusProjectionTask,
        _ transaction: VerifiedRootStateDirectory.Transaction
    ) -> Bool {
        guard next.token == expected.token, next.generation == expected.generation,
              case let .valid(current) = statusProjectionTaskRecord(), current == expected
        else { return false }
        return publish(next.payload, Self.statusProjectionBasename, transaction, parser: { StatusProjectionTask.parse($0) == next }).isVerified
    }

    func removeStatusProjectionTask(
        expected task: StatusProjectionTask,
        _ transaction: VerifiedRootStateDirectory.Transaction
    ) -> Bool {
        switch transaction.removeOrResume(Self.statusProjectionBasename, maximumBytes: StatusProjectionTask.maximumBytes) { data in
            guard let raw = String(data: data, encoding: .utf8) else { return false }
            return raw == task.payload && StatusProjectionTask.parse(raw) == task
        } {
        case .removed, .alreadyAbsent: return true
        case .removalUnverified, .unsafeEntry, .recoveryRequired, .transactionInactive, .reentrant: return false
        }
    }

    func containmentReceiptRecord() -> ContainmentReceiptRecord {
        switch directory.entryState(Self.containmentReceiptBasename) {
        case .absent:
            return evidenceState(for: Self.containmentReceiptBasename) == .absent ? .absent : .invalid
        case .unknown: return .invalid
        case .present:
            guard case let .privateMode(raw) = classifiedText(Self.containmentReceiptBasename, maximumBytes: 4_096),
                  let receipt = ContainedProcessReceipt.parse(raw) else { return .invalid }
            return .valid(receipt)
        }
    }

    /// Initial publication is an exact insert/idempotence boundary. A second
    /// live token never overwrites an unextinguished command group.
    func publishInitialContainmentReceipt(
        _ receipt: ContainedProcessReceipt,
        _ transaction: VerifiedRootStateDirectory.Transaction
    ) -> Bool {
        switch containmentReceiptRecord() {
        case .absent:
            return publish(receipt.storagePayload, Self.containmentReceiptBasename, transaction) {
                ContainedProcessReceipt.parse($0) == receipt
            }.isVerified
        case let .valid(existing): return existing == receipt
        case .invalid: return false
        }
    }

    func removeContainmentReceipt(
        expected receipt: ContainedProcessReceipt,
        _ transaction: VerifiedRootStateDirectory.Transaction
    ) -> VerifiedRootStateDirectory.RemovalResult {
        transaction.removeOrResume(Self.containmentReceiptBasename, maximumBytes: 4_096) { data in
            guard let raw = String(data: data, encoding: .utf8) else { return false }
            return raw == receipt.storagePayload && ContainedProcessReceipt.parse(raw) == receipt
        }
    }

    /// Token-bound compare-and-swap transitions. The held root transaction
    /// makes the pre-read/publish sequence atomic with other helper authority
    /// decisions; a stale cleanup owner can never replace another receipt.
    func claimContainmentReceipt(
        token: UUID,
        owner: UUID,
        now: UInt64,
        until deadline: UInt64,
        _ transaction: VerifiedRootStateDirectory.Transaction
    ) -> ContainedProcessReceipt? {
        guard case let .valid(current) = containmentReceiptRecord(), current.token == token,
              let claimed = (current.cleanupOwnerToken == owner && current.ownerDeadlineNanoseconds > now) ? current
                : (current.claimed(by: owner, until: deadline) ?? current.reclaimed(by: owner, now: now, until: deadline)),
              publish(claimed.storagePayload, Self.containmentReceiptBasename, transaction, parser: {
                  ContainedProcessReceipt.parse($0) == claimed
              }).isVerified
        else { return nil }
        return claimed
    }

    func advanceContainmentReceipt(
        expected current: ContainedProcessReceipt,
        next: ContainedProcessReceipt,
        _ transaction: VerifiedRootStateDirectory.Transaction
    ) -> Bool {
        guard case let .valid(actual) = containmentReceiptRecord(), actual == current,
              actual.token == next.token, actual.cleanupOwnerToken == next.cleanupOwnerToken,
              next.noSecondMutation,
              publish(next.storagePayload, Self.containmentReceiptBasename, transaction, parser: {
                  ContainedProcessReceipt.parse($0) == next
              }).isVerified
        else { return false }
        return true
    }

    func proofRecord() -> ProofRecord {
        switch directory.entryState(Self.proofBasename) {
        case .absent:
            return evidenceState(for: Self.proofBasename) == .absent ? .absent : .invalid
        case .unknown: return .invalid
        case .present:
            guard case let .privateMode(raw) = classifiedText(Self.proofBasename, maximumBytes: 512),
                  let proof = RecoveryProof.parse(raw) else { return .invalid }
            return .valid(proof)
        }
    }

    private func publishLedger(
        bytes: String,
        basename: String,
        transaction: VerifiedRootStateDirectory.Transaction
    ) -> RecoveryPublicationOutcome {
        if case let .privateAuthority(_, existing) = ledger(basename), existing == bytes {
            return .alreadyVerified
        }
        return publish(bytes, basename, transaction, parser: { TerminalGenerationLedger.parse($0) != nil })
    }

    private func publish(
        _ raw: String,
        _ basename: String,
        _ transaction: VerifiedRootStateDirectory.Transaction,
        parser: @escaping (String) -> Bool
    ) -> RecoveryPublicationOutcome {
        let result = transaction.publish(Data(raw.utf8), to: basename) { data in
            guard let candidate = String(data: data, encoding: .utf8) else { return false }
            return parser(candidate)
        }
        switch result {
        case .published: return .published
        case let .notPublished(failure): return .notPublished(failure)
        case let .publishedButUnverified(failure): return .publishedButUnverified(failure)
        }
    }

    private enum ClassifiedText: Equatable { case privateMode(String), legacyMode(String), invalid }

    /// Opens a leaf exactly once, classifies its mode from that held descriptor,
    /// reads exact EOF, revalidates descriptor metadata, then proves the public
    /// basename still binds the same inode. A legacy fallback can never reopen
    /// a different leaf.
    private func classifiedText(_ basename: String, maximumBytes: Int) -> ClassifiedText {
        guard let parent = directory.directoryDescriptor else { return .invalid }
        let fd = fileOperations.openLeaf(parent, basename)
        guard fd >= 0 else { return .invalid }
        defer { Darwin.close(fd) }
        fileOperations.afterOpen(parent, basename)

        var before = stat()
        guard fstat(fd, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == expectedOwnerUID,
              before.st_nlink == 1,
              before.st_size >= 0,
              before.st_size <= off_t(maximumBytes)
        else { return .invalid }
        let mode = before.st_mode & 0o7777
        // Current private authority is exact root:wheel 0600. Historical
        // installers also emitted root:admin 0640 and root-owned 0644 restore
        // evidence. Group identity is not an authority boundary when neither
        // group nor world can write; accept those bytes only as migration
        // input, never as reconnect authority.
        let isPrivate = mode == 0o600 && before.st_gid == expectedGroupID
        let isLegacy = [mode_t(0o600), mode_t(0o640), mode_t(0o644)].contains(mode)
            && mode & (S_IWGRP | S_IWOTH) == 0
            && historicalGroupIsAccepted(before.st_gid)
        guard isPrivate || isLegacy else { return .invalid }

        guard let bytes = readExactly(fd, count: Int(before.st_size)) else { return .invalid }
        var after = stat()
        guard fstat(fd, &after) == 0, sameMetadata(before, after) else { return .invalid }
        var bound = stat()
        guard fstatat(parent, basename, &bound, AT_SYMLINK_NOFOLLOW) == 0,
              bound.st_dev == before.st_dev,
              bound.st_ino == before.st_ino,
              sameMetadata(before, bound),
              let raw = String(data: bytes, encoding: .utf8)
        else { return .invalid }
        return isPrivate ? .privateMode(raw) : .legacyMode(raw)
    }

    private func readExactly(_ fd: Int32, count: Int) -> Data? {
        var bytes = Data(count: count)
        let complete = bytes.withUnsafeMutableBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if result > 0 { offset += result; continue }
                if result < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
        guard complete else { return nil }
        var trailing: UInt8 = 0
        while true {
            let result = Darwin.read(fd, &trailing, 1)
            if result == 0 { return bytes }
            if result < 0, errno == EINTR { continue }
            return nil
        }
    }

    private func sameMetadata(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev
            && first.st_ino == second.st_ino
            && first.st_uid == second.st_uid
            && first.st_gid == second.st_gid
            && first.st_mode == second.st_mode
            && first.st_nlink == second.st_nlink
            && first.st_size == second.st_size
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
            && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
            && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }
}
