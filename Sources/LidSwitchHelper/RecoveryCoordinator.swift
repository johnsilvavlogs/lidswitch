import Foundation
import LidSwitchCore

/// The single recovery state machine used by daemon startup and administrator
/// one-shots. It owns no listener or timer API, so an explicit recovery can
/// never accidentally start serving or rearm power policy.
final class RecoveryCoordinator {
    private static let containmentCleanupQueue = DispatchQueue(label: "com.johnsilva.lidswitch.containment-cleanup")
    private let configuration: HelperServiceConfiguration
    private let power: HelperPowerSystem
    private let bootIdentity: () -> String?
    private let storeFactory: (String) -> RecoveryAuthorityStore?
    private let quiescenceProbe: LegacyWriterQuiescenceProbe
    private let statusProjectionWriter: StatusProjectionDispatcher.Writer

    private enum RecoveryExecution {
        case daemonStartup
        case administratorOneShot
        case currentHelperTransaction

        var requiresLegacyWriterQuiescence: Bool {
            self == .administratorOneShot
        }
    }

    init(
        configuration: HelperServiceConfiguration,
        power: HelperPowerSystem,
        bootIdentity: @escaping () -> String? = BootIdentity.current,
        storeFactory: ((String) -> RecoveryAuthorityStore?)? = nil,
        quiescenceProbe: LegacyWriterQuiescenceProbe? = nil,
        statusProjectionWriter: StatusProjectionDispatcher.Writer? = nil
    ) {
        self.configuration = configuration
        self.power = power
        self.bootIdentity = bootIdentity
        self.storeFactory = storeFactory ?? { RecoveryAuthorityStore(supportDirectory: $0) }
        self.quiescenceProbe = quiescenceProbe ?? .system(
            ownerUID: configuration.expectedOwnerUID,
            qualifiedBuild: configuration.qualifiedBuild
        )
        self.statusProjectionWriter = statusProjectionWriter ?? { task, configuration in
            HelperStatusStore.writeOutcome(task: task, path: configuration.statusPath)
        }
    }

    func provision() -> RecoveryProvisionOutcome {
        guard let store = storeFactory(configuration.supportDirectory) else {
            return .recoveryRequired("unsafe-root-state-directory")
        }
        return store.provisionLock()
    }

    /// `allowReconnect` is true only for normal daemon startup. Explicit
    /// install/uninstall/user-restore one-shots always terminalize and restore.
    func recover(
        intent: RecoveryIntent,
        allowReconnect: Bool,
        terminalReason: String? = nil,
        hydrateStatusProjection: Bool = true
    ) -> RecoveryAssessment {
        guard let store = storeFactory(configuration.supportDirectory) else {
            return projectRequired("unsafe-root-state-directory")
        }
        guard let outcome = store.withTransaction({ transaction in
            self.withContainmentReceipt(store: store, transaction: transaction) {
                self.recoverLocked(
                    store,
                    transaction,
                    intent: intent,
                    allowReconnect: allowReconnect,
                    terminalReason: terminalReason,
                    permitRecoveryRequiredRetry: intent != .startup && !allowReconnect,
                    execution: intent == .startup && allowReconnect
                        ? .daemonStartup
                    : .administratorOneShot
                )
            }
        }) else {
            // Hydration is projection-only, but starting it before recovery
            // lets our own asynchronous status worker win the same root lock
            // and turn a safe helper restart into a transient startup stop.
            // Wake it only after this recovery attempt has released or failed
            // to acquire the lock; it cannot grant session or power authority.
            if hydrateStatusProjection {
                StatusProjectionDispatcher.hydrate(
                    configuration: configuration,
                    storeFactory: storeFactory,
                    writer: statusProjectionWriter
                )
            }
            return projectRequired("root-state-lock-unavailable")
        }
        if hydrateStatusProjection {
            StatusProjectionDispatcher.hydrate(
                configuration: configuration,
                storeFactory: storeFactory,
                writer: statusProjectionWriter
            )
        }
        Self.scheduleContainmentCleanup(configuration: configuration)
        return outcome
    }

    func recoverWithinTransaction(
        store: RecoveryAuthorityStore,
        transaction: VerifiedRootStateDirectory.Transaction,
        intent: RecoveryIntent,
        allowReconnect: Bool,
        terminalReason: String? = nil,
        permitRecoveryRequiredRetry: Bool = false
    ) -> RecoveryAssessment {
        guard !(permitRecoveryRequiredRetry && allowReconnect) else {
            return .recoveryRequired("invalid-recovery-retry-mode")
        }
        return withContainmentReceipt(store: store, transaction: transaction) {
            recoverLocked(
                store,
                transaction,
                intent: intent,
                allowReconnect: allowReconnect,
                terminalReason: terminalReason,
                permitRecoveryRequiredRetry: permitRecoveryRequiredRetry,
                execution: .currentHelperTransaction
            )
        }
    }

    private func withContainmentReceipt<T>(
        store: RecoveryAuthorityStore,
        transaction: VerifiedRootStateDirectory.Transaction,
        _ body: () -> T
    ) -> T {
        ContainedProcessRunner.withContainmentReceiptSink({ receipt in
            store.publishInitialContainmentReceipt(receipt, transaction)
        }, replace: { current, next in
            store.advanceContainmentReceipt(expected: current, next: next, transaction)
        }, release: { receipt in
            store.removeContainmentReceipt(expected: receipt, transaction) == .removed
        }, onAccepted: {
            transaction.afterUnlock {
                Self.scheduleContainmentCleanup(configuration: self.configuration)
            }
        }, body)
    }

    private func recoverLocked(
        _ store: RecoveryAuthorityStore,
        _ transaction: VerifiedRootStateDirectory.Transaction,
        intent: RecoveryIntent,
        allowReconnect: Bool,
        terminalReason: String?,
        permitRecoveryRequiredRetry: Bool = false,
        execution: RecoveryExecution
    ) -> RecoveryAssessment {
        switch store.containmentReceiptRecord() {
        case .absent: break
        case .valid, .invalid:
            // Do not open a second setter path while a command group is
            // unproved. This also fences proof/status mutations: the receipt
            // is the only durable authority until extinction is exact.
            Self.scheduleContainmentCleanup(configuration: configuration)
            return .recoveryRequired("containment-pending")
        }
        let legacyWritersStopped: Bool
        if execution.requiresLegacyWriterQuiescence {
            switch quiescenceProbe.verify() {
            case .quiesced:
                legacyWritersStopped = true
            case let .indeterminate(reason):
                return .recoveryRequired(reason)
            }
            switch store.prepareAuthorityLocked(
                transaction,
                allowRecoveryRequiredLegacyRetry: permitRecoveryRequiredRetry
            ) {
            case .ready:
                break
            case let .recoveryRequired(reason):
                return .recoveryRequired(reason)
            }
        } else {
            legacyWritersStopped = false
            // Normal daemon startup is observation-only until an administrator
            // transaction has stopped every historical writer. In particular,
            // it must not bootstrap ledgers, publish a failure proof, migrate a
            // legacy record, or rewrite status merely because old authority is
            // incomplete. A complete current authority shape is the only state
            // the daemon may inspect further.
            guard store.authorityRootInventoryIsSafe else {
                return .recoveryRequired("unsafe-authority-root-inventory")
            }
            let startupTerminal = store.ledger(RecoveryAuthorityStore.terminalBasename)
            let startupReservation = store.ledger(RecoveryAuthorityStore.reservationBasename)
            if startupTerminal == .invalid || startupReservation == .invalid {
                return .recoveryRequired("invalid-private-ledger")
            }
            guard case .privateAuthority = startupTerminal,
                  case .privateAuthority = startupReservation
            else { return .recoveryRequired("legacy-writers-not-quiesced") }
            switch store.journalRecord() {
            case .absent:
                break
            case .invalid:
                return .recoveryRequired("invalid-legacy-recovery-journal")
            case .valid:
                return .recoveryRequired("legacy-writers-not-quiesced")
            }
            switch store.proofRecord() {
            case .valid:
                break
            case .invalid:
                return .recoveryRequired("invalid-recovery-proof")
            case .absent:
                return .recoveryRequired("legacy-writers-not-quiesced")
            }
            switch store.appliedRecord() {
            case .missing, .privateAuthority, .quarantinedApplied:
                break
            case .invalid:
                return .recoveryRequired("invalid-applied-state")
            case .legacyRestoreOnly:
                return .recoveryRequired("legacy-writers-not-quiesced")
            }
        }
        guard case let .privateAuthority(terminalEntries, _) = store.ledger(RecoveryAuthorityStore.terminalBasename),
              case let .privateAuthority(reservationEntries, _) = store.ledger(RecoveryAuthorityStore.reservationBasename)
        else { return required(store, transaction, "invalid-private-ledger") }

        if case .invalid = store.recoveryBudgetRecord() {
            return required(store, transaction, "invalid-recovery-budget-state")
        }

        let priorProof = store.proofRecord()
        switch priorProof {
        case .invalid:
            return required(store, transaction, "invalid-recovery-proof")
        case let .valid(proof) where proof.kind == .recoveryRequired && !permitRecoveryRequiredRetry:
            return .recoveryRequired(proof.reason)
        case .absent, .valid:
            break
        }

        switch store.journalRecord() {
        case .invalid:
            return required(store, transaction, "invalid-legacy-recovery-journal")
        case let .valid(journal):
            guard legacyWritersStopped else {
                return required(store, transaction, "legacy-writers-not-quiesced")
            }
            return recoverLegacyJournal(journal, store, transaction)
        case .absent:
            break
        }

        switch store.appliedRecord() {
        case .missing:
            let idle = assessIdle(store, transaction)
            // An administrator one-shot is the only path allowed to quiesce
            // and migrate historical writers.  Once that transaction has
            // proven an exact terminal generation, publish the corresponding
            // canonical v5 diagnostic before returning safe idle.  Daemon
            // startup remains observation-only and merely hydrates a durable
            // task left by the administrator transaction.
            if legacyWritersStopped,
               case let .terminalIdle(session, reason) = idle {
                guard projectStatus(
                    state: "terminal",
                    reason: reason,
                    sessionID: session,
                    store: store,
                    transaction: transaction
                ) else { return .recoveryRequired("status-projection-enqueue-failed") }
            }
            return idle
        case .invalid:
            return required(store, transaction, "invalid-applied-state")
        case let .quarantinedApplied(state):
            return replayTerminalCleanup(
                state,
                store,
                transaction,
                terminalEntries: terminalEntries
            )
        case let .legacyRestoreOnly(state):
            // Legacy bytes are restore-only even on startup. They are never a
            // reconnect candidate and no explicit recovery can resume them.
            // The administrator transaction must first prove every historical
            // writer stopped; daemon startup cannot infer that from files.
            guard legacyWritersStopped else {
                return required(store, transaction, "legacy-writers-not-quiesced")
            }
            // Preparation must have replaced any public schema-2 bytes with a
            // canonical owner/lease-free projection. Recheck before the only
            // private publication in this branch so stale process identity can
            // never cross the authority boundary even if preparation regresses.
            guard state.owner == nil,
                  state.leaseExpiryMonotonic == nil,
                  !state.isProcessBound
            else { return .recoveryRequired("unsanitized-legacy-applied-state") }
            switch priorProof {
            case .absent:
                break
            case let .valid(proof) where proof.kind == .recoveryRequired && permitRecoveryRequiredRetry:
                break
            case let .valid(proof) where proof.kind == .terminal:
                guard proof.sessionID == state.sessionID,
                      terminalEntries.last == state.sessionID
                else { return .recoveryRequired("legacy-applied-proof-conflict") }
            case .invalid, .valid:
                return .recoveryRequired("legacy-applied-proof-conflict")
            }
            // Replace the exact descriptor-verified parsed payload with a
            // private 0600 authority inode before generic quarantine removal.
            _ = RecoveryAssessment.legacyRestoreOnly(state)
            let migration = store.publishApplied(state, transaction)
            guard migration.isVerified,
                  store.appliedRecord() == .legacyRestoreOnly(state)
            else { return required(store, transaction, publicationReason("legacy-applied-migration", migration)) }
            return terminalizeAndRestore(
                state,
                store,
                transaction,
                reason: "legacy-restore"
            )
        case let .privateAuthority(state):
            if case let .valid(proof) = priorProof,
               proof.kind == .terminal,
               proof.sessionID == state.sessionID,
               terminalEntries.last == state.sessionID {
                return replayTerminalCleanup(
                    state,
                    store,
                    transaction,
                    terminalEntries: terminalEntries
                )
            }
            if priorProof == .absent {
                // A private schema-2 record without matching proof is never a
                // reconnect authority. It is still exact restore-only evidence
                // after the administrator has quiesced historical writers.
                guard legacyWritersStopped else {
                    return required(store, transaction, "unproven-applied-state")
                }
                return terminalizeAndRestore(
                    state,
                    store,
                    transaction,
                    reason: "unproven-schema2-restore"
                )
            }
            // A durable recovery budget is a restart boundary, not merely a
            // reconnect hint. Reserved means one setter may have started but
            // did not durably finish; foreign/sessionless history is equally
            // ambiguous. Daemon startup must retain evidence for an explicit
            // administrator recovery, never restore/rearm on its own.
            if allowReconnect, intent == .startup {
                switch store.recoveryBudgetRecord() {
                case .absent:
                    guard !reservationEntries.contains(state.sessionID) else {
                        return required(store, transaction, "recovery-budget-reservation-without-phase")
                    }
                case let .valid(budget):
                    guard budget.sessionID == state.sessionID else {
                        return required(store, transaction, "recovery-budget-session-mismatch")
                    }
                    guard budget.phase == .spent,
                          reservationEntries.contains(state.sessionID)
                    else { return required(store, transaction, "recovery-budget-reserved") }
                case .invalid:
                    return required(store, transaction, "invalid-recovery-budget-state")
                }
            }
            let retryingRequired: Bool
            if permitRecoveryRequiredRetry,
               case let .valid(proof) = priorProof,
               proof.kind == .recoveryRequired {
                retryingRequired = true
            } else {
                retryingRequired = false
            }
            if retryingRequired,
               terminalEntries.contains(state.sessionID),
               terminalEntries.last != state.sessionID {
                return required(store, transaction, "active-proof-conflict")
            }
            guard priorProof != .absent,
                  retryingRequired || priorProofAllowsActiveState(
                      priorProof,
                      state: state,
                      terminalEntries: terminalEntries
                  )
            else { return required(store, transaction, "active-proof-conflict") }
            if allowReconnect,
               intent == .startup,
               !terminalEntries.contains(state.sessionID),
               recoveryBudgetAllowsReconnect(state, reservationEntries: reservationEntries, store: store),
               state.isReconnectable,
               state.owner?.bootID == bootIdentity(),
               strictOwnedSnapshot() {
                // The daemon integration must still prove the exact live
                // PID/start/EUID/ASID tuple, expiry, build, and boot before it
                // binds a connection. This result alone grants no authority.
                return .reconnectCandidate(state)
            }
            return terminalizeAndRestore(
                state,
                store,
                transaction,
                reason: terminalReason ?? "\(intent.rawValue)-recovery"
            )
        }
    }

    /// A reservation is normally a one-way reconnect veto. The sole exception
    /// is an exact durable `spent` record for this still-current authority;
    /// that represents a completed first repair, not permission to spend a
    /// second one. Reserved, foreign, malformed, or missing-phase history
    /// remains restore-only.
    private func recoveryBudgetAllowsReconnect(
        _ state: AppliedState,
        reservationEntries: [UUID],
        store: RecoveryAuthorityStore
    ) -> Bool {
        switch store.recoveryBudgetRecord() {
        case .absent:
            return !reservationEntries.contains(state.sessionID)
        case let .valid(budget):
            return budget.sessionID == state.sessionID
                && budget.phase == .spent
                && reservationEntries.contains(state.sessionID)
        case .invalid:
            return false
        }
    }

    private func recoverLegacyJournal(
        _ journal: LegacyRecoveryJournal,
        _ store: RecoveryAuthorityStore,
        _ transaction: VerifiedRootStateDirectory.Transaction
    ) -> RecoveryAssessment {
        let priorProof = store.proofRecord()
        let migratedProof: RecoveryProof?
        switch priorProof {
        case .invalid:
            return required(store, transaction, "invalid-recovery-proof")
        case let .valid(proof) where proof.kind != .recoveryRequired && proof.kind != .migrated:
            return required(store, transaction, "legacy-proof-conflict")
        case let .valid(proof) where proof.kind == .migrated:
            migratedProof = proof
        case .absent, .valid:
            migratedProof = nil
        }

        if let migratedProof {
            // Proof publication precedes the proof-published journal update.
            // Therefore only native-safe/proof-published lineage can replay an
            // existing migrated proof; prepared+proof is an impossible state.
            guard migratedProof.sessionID == nil,
                  migratedProof.reason == journal.proofReason,
                  journal.phase == .nativeSafe || journal.phase == .proofPublished
            else { return required(store, transaction, "legacy-proof-journal-mismatch") }
        } else if journal.phase == .proofPublished {
            // This phase is written only after an exact migrated proof has
            // already been verified. Absence cannot be repaired by guessing.
            return required(store, transaction, "legacy-proof-missing")
        }

        // Read every required native field before the first setter. A nil,
        // negative, or out-of-contract value preserves all evidence and makes
        // no mutation at all.
        guard let sleepDisabled = power.sleepDisabled() else {
            return required(store, transaction, "legacy-sleep-disabled-unknown")
        }
        let proofAlreadyPublished = migratedProof != nil
        let effectivePhase: LegacyRecoveryJournal.Phase = proofAlreadyPublished ? .proofPublished : journal.phase
        let acCurrent = journal.acTarget == nil ? nil : power.acSleepMinutes()
        let batteryCurrent = journal.batteryTarget == nil ? nil : power.batterySleepMinutes()

        if let migratedProof {
            // Crash-after-proof replay is observation-only. The proof and the
            // journal's dispositions are immutable; exact native drift fails
            // closed and retains both artifacts for administrator review.
            guard sleepDisabled == false,
                  publishedLegacyDispositionMatches(
                    target: journal.acTarget,
                    current: acCurrent,
                    disposition: journal.acDisposition
                  ),
                  publishedLegacyDispositionMatches(
                    target: journal.batteryTarget,
                    current: batteryCurrent,
                    disposition: journal.batteryDisposition
                  )
            else { return required(store, transaction, "legacy-post-proof-native-drift") }

            let cleanupJournal: LegacyRecoveryJournal
            if journal.phase == .nativeSafe {
                cleanupJournal = LegacyRecoveryJournal(
                    phase: .proofPublished,
                    ownsSleepDisabled: journal.ownsSleepDisabled,
                    acTarget: journal.acTarget,
                    batteryTarget: journal.batteryTarget,
                    acDisposition: journal.acDisposition,
                    batteryDisposition: journal.batteryDisposition
                )
                guard store.publishJournal(cleanupJournal, transaction).isVerified else {
                    return required(store, transaction, "legacy-proof-journal-unverified")
                }
            } else {
                cleanupJournal = journal
            }

            guard store.removeLegacyPowerEvidence(
                expectedAC: cleanupJournal.acTarget,
                expectedBattery: cleanupJournal.batteryTarget,
                transaction
            ) else {
                return required(store, transaction, "legacy-evidence-removal-unverified")
            }
            switch store.removeJournal(expected: cleanupJournal, transaction) {
            case .removed:
                projectStatus(state: "inactive", reason: migratedProof.reason, sessionID: nil,
                              store: store, transaction: transaction)
                return .migratedIdle(migratedProof.reason)
            case .alreadyAbsent:
                return required(store, transaction, "legacy-journal-disappeared")
            case .removalUnverified:
                return required(store, transaction, "legacy-journal-removal-unverified")
            case .unsafeEntry, .recoveryRequired, .transactionInactive, .reentrant:
                return required(store, transaction, "legacy-journal-removal-unsafe")
            }
        }

        guard let acPlan = legacyTimerPlan(
                target: journal.acTarget,
                current: acCurrent,
                prior: journal.acDisposition,
                phase: effectivePhase
              ),
              let batteryPlan = legacyTimerPlan(
                target: journal.batteryTarget,
                current: batteryCurrent,
                prior: journal.batteryDisposition,
                phase: effectivePhase
              )
        else { return required(store, transaction, "legacy-timer-state-unknown") }

        if sleepDisabled {
            guard journal.ownsSleepDisabled,
                  journal.phase == .prepared,
                  !proofAlreadyPublished
            else {
                // Helper/plist/history presence alone never owns a global
                // override, and completed migration never consumes ownership a
                // second time after another actor changes native state.
                return required(store, transaction, "legacy-sleep-override-ambiguous")
            }
            do {
                try power.setSleepDisabled(false)
            } catch HelperPowerMutationError.containmentPending {
                return required(store, transaction, "containment-pending")
            } catch {
                // A contained pmset error is completion-indeterminate. The
                // live property is the sole reconciliation evidence; never
                // retry this global setter.
                guard power.sleepDisabled() == false else {
                    return required(store, transaction, "legacy-sleep-restore-failed")
                }
            }
            guard power.sleepDisabled() == false else {
                return required(store, transaction, "legacy-sleep-postcondition-unknown")
            }
        }

        let preliminaryACDisposition: LegacyRecoveryJournal.TimerDisposition
        switch applyLegacyTimerPlan(acPlan, setter: power.setACSleepMinutes, reread: power.acSleepMinutes) {
        case let .success(disposition): preliminaryACDisposition = disposition
        case let .failure(reason): return required(store, transaction, reason)
        }
        guard store.containmentReceiptRecord() == .absent else {
            return required(store, transaction, "containment-pending")
        }
        let preliminaryBatteryDisposition: LegacyRecoveryJournal.TimerDisposition
        switch applyLegacyTimerPlan(
            batteryPlan,
            setter: power.setBatterySleepMinutes,
            reread: power.batterySleepMinutes
        ) {
        case let .success(disposition): preliminaryBatteryDisposition = disposition
        case let .failure(reason): return required(store, transaction, reason)
        }
        guard store.containmentReceiptRecord() == .absent else {
            return required(store, transaction, "containment-pending")
        }

        // Bind the journal to one final observation even for equal/satisfied
        // plans that needed no setter. This records a late positive value as
        // superseding evidence instead of incorrectly calling it satisfied.
        guard let acDisposition = verifiedLegacyTimerDisposition(
                target: journal.acTarget,
                current: journal.acTarget == nil ? nil : power.acSleepMinutes(),
                preliminary: preliminaryACDisposition
              ),
              let batteryDisposition = verifiedLegacyTimerDisposition(
                target: journal.batteryTarget,
                current: journal.batteryTarget == nil ? nil : power.batterySleepMinutes(),
                preliminary: preliminaryBatteryDisposition
              )
        else { return required(store, transaction, "legacy-timer-final-state-unknown") }

        guard power.sleepDisabled() == false else {
            return required(store, transaction, "legacy-native-idle-unverified")
        }
        let safe = LegacyRecoveryJournal(
            phase: .nativeSafe,
            ownsSleepDisabled: journal.ownsSleepDisabled,
            acTarget: journal.acTarget,
            batteryTarget: journal.batteryTarget,
            acDisposition: acDisposition,
            batteryDisposition: batteryDisposition
        )
        let cleanupJournal: LegacyRecoveryJournal
        if journal.phase == .proofPublished {
            guard safe.acDisposition == journal.acDisposition,
                  safe.batteryDisposition == journal.batteryDisposition
            else { return required(store, transaction, "legacy-post-proof-native-drift") }
            cleanupJournal = journal
        } else {
            guard store.publishJournal(safe, transaction).isVerified else {
                return required(store, transaction, "legacy-safe-journal-unverified")
            }
            cleanupJournal = LegacyRecoveryJournal(
                phase: .proofPublished,
                ownsSleepDisabled: safe.ownsSleepDisabled,
                acTarget: safe.acTarget,
                batteryTarget: safe.batteryTarget,
                acDisposition: safe.acDisposition,
                batteryDisposition: safe.batteryDisposition
            )
        }

        let proof = RecoveryProof(kind: .migrated, sessionID: nil, reason: cleanupJournal.proofReason)
        let proofOutcome = store.publishProof(proof, transaction)
        guard proofOutcome.isVerified else {
            return required(store, transaction, publicationReason("legacy-proof", proofOutcome))
        }
        if journal.phase != .proofPublished {
            guard store.publishJournal(cleanupJournal, transaction).isVerified else {
                return required(store, transaction, "legacy-proof-journal-unverified")
            }
        }
        guard store.removeLegacyPowerEvidence(
            expectedAC: cleanupJournal.acTarget,
            expectedBattery: cleanupJournal.batteryTarget,
            transaction
        ) else {
            return required(store, transaction, "legacy-evidence-removal-unverified")
        }
        switch store.removeJournal(expected: cleanupJournal, transaction) {
        case .removed:
            projectStatus(state: "inactive", reason: proof.reason, sessionID: nil,
                          store: store, transaction: transaction)
            return .migratedIdle(proof.reason)
        case .alreadyAbsent:
            return required(store, transaction, "legacy-journal-disappeared")
        case .removalUnverified:
            return required(store, transaction, "legacy-journal-removal-unverified")
        case .unsafeEntry, .recoveryRequired, .transactionInactive, .reentrant:
            return required(store, transaction, "legacy-journal-removal-unsafe")
        }
    }

    private enum LegacyTimerPlan {
        case notRequired
        case retain(LegacyRecoveryJournal.TimerDisposition)
        case restore(Int)
    }

    private enum LegacyTimerApplication {
        case success(LegacyRecoveryJournal.TimerDisposition)
        case failure(String)
    }

    private func legacyTimerPlan(
        target: Int?,
        current: Int?,
        prior: LegacyRecoveryJournal.TimerDisposition,
        phase: LegacyRecoveryJournal.Phase
    ) -> LegacyTimerPlan? {
        guard let target else { return prior == .notRequired ? .notRequired : nil }
        guard target >= 0, target <= 1_440,
              let current, current >= 0, current <= 1_440
        else { return nil }

        // Once a durable safe/proof phase or superseded disposition exists,
        // migration is observation-only forever. This is the no-rearm rule.
        if phase != .prepared || prior != .pending {
            if current == target { return .retain(prior == .restored ? .restored : .satisfied) }
            if current > 0 { return .retain(.superseded(current)) }
            return nil
        }
        if current == target { return .retain(.satisfied) }
        if current == 0, target > 0 { return .restore(target) }
        if current > 0 { return .retain(.superseded(current)) }
        // target == 0/current == 0 was handled by equality.
        return nil
    }

    private func applyLegacyTimerPlan(
        _ plan: LegacyTimerPlan,
        setter: (Int) throws -> Void,
        reread: () -> Int?
    ) -> LegacyTimerApplication {
        switch plan {
        case .notRequired:
            return .success(.notRequired)
        case let .retain(disposition):
            return .success(disposition)
        case let .restore(target):
            // Close the read/plan/set race. Another power-management actor may
            // have installed a positive timer after the initial all-fields
            // snapshot; preserve that value instead of overwriting it.
            guard let boundary = reread(), boundary >= 0, boundary <= 1_440 else {
                return .failure("legacy-timer-postcondition-unknown")
            }
            if boundary == target { return .success(.satisfied) }
            // A positive value that appeared between planning and mutation is
            // externally owned state. Preserve it and keep the recovery
            // record actionable; completing this migration would falsely
            // attest that our planned rollback reached a stable conclusion.
            if boundary > 0 { return .failure("legacy-timer-superseded") }
            guard boundary == 0, target > 0 else {
                return .failure("legacy-timer-restore-unverified")
            }
            do {
                try setter(target)
            } catch {
                // Contained pmset may have completed before reporting an
                // ambiguous result. Re-read below and accept only an exact
                // target or an externally superseding positive value.
            }
            guard let current = reread(), current >= 0, current <= 1_440 else {
                return .failure("legacy-timer-postcondition-unknown")
            }
            if current == target { return .success(.restored) }
            if current > 0 { return .failure("legacy-timer-superseded") }
            return .failure("legacy-timer-restore-unverified")
        }
    }

    private func verifiedLegacyTimerDisposition(
        target: Int?,
        current: Int?,
        preliminary: LegacyRecoveryJournal.TimerDisposition
    ) -> LegacyRecoveryJournal.TimerDisposition? {
        guard let target else { return preliminary == .notRequired ? .notRequired : nil }
        guard target >= 0, target <= 1_440,
              let current, current >= 0, current <= 1_440
        else { return nil }
        if current == target {
            return preliminary == .restored ? .restored : .satisfied
        }
        if current > 0 { return .superseded(current) }
        return nil
    }

    private func publishedLegacyDispositionMatches(
        target: Int?,
        current: Int?,
        disposition: LegacyRecoveryJournal.TimerDisposition
    ) -> Bool {
        guard let target else { return current == nil && disposition == .notRequired }
        guard target >= 0, target <= 1_440,
              let current, current >= 0, current <= 1_440
        else { return false }
        switch disposition {
        case .satisfied, .restored:
            return current == target
        case let .superseded(value):
            return value > 0 && current == value && value != target
        case .notRequired, .pending:
            return false
        }
    }

    private func terminalizeAndRestore(
        _ state: AppliedState,
        _ store: RecoveryAuthorityStore,
        _ transaction: VerifiedRootStateDirectory.Transaction,
        reason: String
    ) -> RecoveryAssessment {
        // Ordering is an authority invariant: terminal record first, then the
        // exact restore, a fresh postcondition, proof, applied removal, and only
        // then the non-authoritative status projection.
        // A terminal receipt is global safe-idle evidence, never merely a
        // statement about changes this record owned.  In particular a legacy
        // no-op/AC-only record must not erase itself while an unrelated actor
        // still owns the global SleepDisabled override.
        guard let before = strictSnapshot() else {
            return required(store, transaction, "power-precondition-unknown")
        }
        if !state.changedSleepDisabled && before.sleepDisabled {
            return required(store, transaction, "unowned-sleep-override-active")
        }
        let terminal = store.recordTerminal(
            state.sessionID,
            into: RecoveryAuthorityStore.terminalBasename,
            transaction: transaction
        )
        guard terminal.isVerified else {
            return required(store, transaction, publicationReason("terminal-publication", terminal))
        }

        if state.changedACSleep {
            guard let original = state.originalACSleep,
                  before.acSleepMinutes == 0 || before.acSleepMinutes == original
            else { return requiredAfterCurrentTerminal(state, store, transaction, "power-precondition-conflict") }
        }
        if state.changedBatterySleep {
            guard let original = state.originalBatterySleep,
                  let current = before.batterySleepMinutes,
                  current == 0 || current == original
            else { return requiredAfterCurrentTerminal(state, store, transaction, "battery-precondition-conflict") }
        }

        var mutationResultIndeterminate = false
        do {
            if state.changedSleepDisabled, before.sleepDisabled {
                try power.setSleepDisabled(false)
            }
            if state.changedACSleep, let original = state.originalACSleep {
                guard let boundary = power.acSleepMinutes() else {
                    return requiredAfterCurrentTerminal(state, store, transaction, "ac-setter-boundary-unknown")
                }
                if boundary == 0 {
                    try power.setACSleepMinutes(original)
                } else if boundary != original {
                    return requiredAfterCurrentTerminal(state, store, transaction, "ac-setter-boundary-conflict")
                }
            }
            if state.changedBatterySleep, let original = state.originalBatterySleep {
                guard let boundary = power.batterySleepMinutes() else {
                    return requiredAfterCurrentTerminal(state, store, transaction, "battery-setter-boundary-unknown")
                }
                if boundary == 0 {
                    try power.setBatterySleepMinutes(original)
                } else if boundary != original {
                    return requiredAfterCurrentTerminal(state, store, transaction, "battery-setter-boundary-conflict")
                }
            }
        } catch HelperPowerMutationError.containmentPending {
            return requiredAfterCurrentTerminal(state, store, transaction, "containment-pending")
        } catch {
            // The contained pmset runner can fail after the direct command has
            // committed. Do not retry a restore setter: the exact full native
            // snapshot below is the sole reconciliation authority.
            mutationResultIndeterminate = true
        }

        guard let after = strictSnapshot(),
              after.sleepDisabled == false,
              (!state.changedACSleep || after.acSleepMinutes == state.originalACSleep),
              (!state.changedBatterySleep || after.batterySleepMinutes == state.originalBatterySleep)
        else {
            return requiredAfterCurrentTerminal(
                state,
                store,
                transaction,
                mutationResultIndeterminate ? "owned-restore-indeterminate" : "restore-postcondition-unknown"
            )
        }

        let proof = RecoveryProof(kind: .terminal, sessionID: state.sessionID, reason: reason)
        let proofOutcome: RecoveryPublicationOutcome
        if case let .valid(prior) = store.proofRecord(), prior.kind == .migrated {
            proofOutcome = store.publishCurrentTerminalProof(state: state, reason: reason, transaction)
        } else {
            proofOutcome = store.publishProof(proof, transaction)
        }
        guard proofOutcome.isVerified else {
            return requiredAfterCurrentTerminal(state, store, transaction, publicationReason("recovery-proof", proofOutcome))
        }

        guard store.removeLegacyPowerEvidence(transaction) else {
            return terminalCleanupPending("legacy-evidence-removal-unverified")
        }
        guard removeRecoveryBudgetAtTerminal(state, store, transaction) else {
            return terminalCleanupPending("recovery-budget-removal-unverified")
        }

        switch store.removeApplied(expected: state, transaction) {
        case .removed:
            // Projection failure cannot change the already-durable authority
            // result. The next reader reconstructs state from proof + ledger.
            projectStatus(state: "terminal", reason: reason, sessionID: state.sessionID,
                          store: store, transaction: transaction)
            return .terminalIdle(state.sessionID, reason)
        case .alreadyAbsent:
            // We read this exact public leaf under the same cooperative lock;
            // disappearance is a bypass/uncertainty, not clean idempotence.
            return terminalCleanupPending("applied-disappeared-during-recovery")
        case .removalUnverified:
            return terminalCleanupPending("applied-removal-unverified")
        case .unsafeEntry, .recoveryRequired, .transactionInactive, .reentrant:
            return terminalCleanupPending("applied-removal-unsafe")
        }
    }

    /// A terminal proof can be durable before the applied leaf is removed. This
    /// replay path is intentionally mutation-free for power: exact terminal
    /// proof/latest-ledger/native-safe facts may resume only descriptor-checked
    /// cleanup, including an orphaned quarantine from a prior remove attempt.
    private func replayTerminalCleanup(
        _ state: AppliedState,
        _ store: RecoveryAuthorityStore,
        _ transaction: VerifiedRootStateDirectory.Transaction,
        terminalEntries: [UUID]
    ) -> RecoveryAssessment {
        guard case let .valid(proof) = store.proofRecord(),
              proof.kind == .terminal,
              proof.sessionID == state.sessionID,
              terminalEntries.last == state.sessionID,
              let snapshot = strictSnapshot(),
              snapshot.sleepDisabled == false,
              (!state.changedACSleep || snapshot.acSleepMinutes == state.originalACSleep),
              (!state.changedBatterySleep || snapshot.batterySleepMinutes == state.originalBatterySleep)
        else { return required(store, transaction, "terminal-replay-proof-or-native-mismatch") }
        guard store.removeLegacyPowerEvidence(transaction) else {
            return terminalCleanupPending("legacy-evidence-removal-unverified")
        }
        guard removeRecoveryBudgetAtTerminal(state, store, transaction) else {
            return terminalCleanupPending("recovery-budget-removal-unverified")
        }
        switch store.removeApplied(expected: state, transaction) {
        case .removed:
            projectStatus(state: "terminal", reason: proof.reason, sessionID: state.sessionID,
                          store: store, transaction: transaction)
            return .terminalIdle(state.sessionID, proof.reason)
        case .alreadyAbsent:
            return terminalCleanupPending("applied-disappeared-during-recovery")
        case .removalUnverified:
            return terminalCleanupPending("applied-removal-unverified")
        case .unsafeEntry, .recoveryRequired, .transactionInactive, .reentrant:
            return terminalCleanupPending("applied-removal-unsafe")
        }
    }

    /// Once terminal proof is verified, an uncertain cleanup boundary must not
    /// overwrite it with recovery-required: that would erase the sole exact
    /// authorization needed to resume no-power-mutation cleanup after a crash.
    private func terminalCleanupPending(_ reason: String) -> RecoveryAssessment {
        .recoveryRequired(reason)
    }

    @discardableResult
    private func projectStatus(
        state: String,
        reason: String,
        sessionID: UUID?,
        store: RecoveryAuthorityStore,
        transaction: VerifiedRootStateDirectory.Transaction
    ) -> Bool {
        guard StatusProjectionDispatcher.enqueue(state: state, reason: reason, sessionID: sessionID,
                                                 store: store, transaction: transaction, configuration: configuration,
                                                 storeFactory: storeFactory,
                                                 writer: statusProjectionWriter) else {
            _ = store.markRecoveryRequired("status-projection-enqueue-failed", transaction)
            return false
        }
        return true
    }

    /// Budget evidence is retained through terminal proof and the verified
    /// native-safe snapshot, then removed only as part of cleanup. This keeps
    /// a crash before proof fail-closed and lets post-proof cleanup replay
    /// safely tolerate an already-removed exact budget inode.
    private func removeRecoveryBudgetAtTerminal(
        _ state: AppliedState,
        _ store: RecoveryAuthorityStore,
        _ transaction: VerifiedRootStateDirectory.Transaction
    ) -> Bool {
        switch store.recoveryBudgetRecord() {
        case .absent:
            return true
        case let .valid(budget):
            // A prior generation's spent recovery budget is bounded audit
            // evidence.  It cannot authorize this state, but it also must
            // not prevent a later independently verified generation from
            // reaching terminal idle.  Only the current generation owns a
            // budget leaf that this cleanup may remove.
            guard budget.sessionID == state.sessionID else { return true }
            switch store.removeRecoveryBudget(expected: budget, transaction) {
            case .removed: return true
            case .alreadyAbsent, .removalUnverified, .unsafeEntry, .recoveryRequired,
                 .transactionInactive, .reentrant: return false
            }
        case .invalid:
            return false
        }
    }

    private func requiredAfterCurrentTerminal(
        _ state: AppliedState,
        _ store: RecoveryAuthorityStore,
        _ transaction: VerifiedRootStateDirectory.Transaction,
        _ reason: String
    ) -> RecoveryAssessment {
        // This is deliberately narrower than `required`: only an exact current
        // schema-3 applied record with its newly recorded latest terminal can
        // replace a migrated proof. Legacy migration itself remains immutable.
        _ = store.publishCurrentRecoveryRequired(state: state, reason: reason, transaction)
        return required(store, transaction, reason)
    }

    private func assessIdle(
        _ store: RecoveryAuthorityStore,
        _ transaction: VerifiedRootStateDirectory.Transaction
    ) -> RecoveryAssessment {
        guard case let .privateAuthority(terminalEntries, _) = store.ledger(RecoveryAuthorityStore.terminalBasename),
              case let .privateAuthority(reservationEntries, _) = store.ledger(RecoveryAuthorityStore.reservationBasename)
        else { return required(store, transaction, "invalid-private-ledger") }
        guard store.appliedRecord() == .missing else {
            return required(store, transaction, "applied-state-ambiguous")
        }
        guard let snapshot = strictSnapshot() else {
            return required(store, transaction, "idle-power-state-unknown")
        }
        guard snapshot.sleepDisabled == false else {
            // No applied authority means LidSwitch cannot prove ownership of a
            // live global override. Never clear it from an idle assessment,
            // and never call that state pristine or terminal-safe.
            return required(store, transaction, "idle-sleep-override-active")
        }
        guard let proof = store.proof() else {
            return required(store, transaction, "missing-recovery-proof")
        }

        switch proof.kind {
        case .pristine:
            // Bootstrap is safe only while both history ledgers are exactly
            // empty and no applied authority exists.
            guard terminalEntries.isEmpty, reservationEntries.isEmpty else {
                return required(store, transaction, "pristine-history-conflict")
            }
            return .pristineIdle
        case .terminal:
            guard let session = proof.sessionID, terminalEntries.last == session else {
                return required(store, transaction, "terminal-proof-ledger-mismatch")
            }
            return .terminalIdle(session, proof.reason)
        case .migrated:
            guard terminalEntries.isEmpty, reservationEntries.isEmpty else {
                return required(store, transaction, "migrated-history-conflict")
            }
            return .migratedIdle(proof.reason)
        case .recoveryRequired:
            return .recoveryRequired(proof.reason)
        }
    }

    private func required(
        _ store: RecoveryAuthorityStore,
        _ transaction: VerifiedRootStateDirectory.Transaction,
        _ reason: String
    ) -> RecoveryAssessment {
        // This typed root-only proof is the authority result. A publication
        // fault may make even that conclusion unverified; earlier terminal,
        // applied, proof, or quarantine evidence is deliberately retained.
        switch store.proofRecord() {
        case .invalid:
            break
        case let .valid(proof) where proof.kind == .recoveryRequired || proof.kind == .migrated:
            break
        case .absent, .valid:
            _ = store.markRecoveryRequired(reason, transaction)
        }
        projectStatus(state: "recovery-required", reason: reason, sessionID: nil,
                      store: store, transaction: transaction)
        return .recoveryRequired(reason)
    }

    /// Claim under RootStateLock, run exactly one signal/reap/inventory action
    /// after releasing it, then compare-and-swap the same token back under the
    /// lock. A queued task is therefore never allowed to wedge XPC or status.
    static func scheduleContainmentCleanup(configuration: HelperServiceConfiguration, owner continuingOwner: UUID? = nil) {
        containmentCleanupQueue.async {
            guard let store = RecoveryAuthorityStore(supportDirectory: configuration.supportDirectory) else { return }
            let now = UInt64(max(0, MonotonicClock.seconds()) * 1_000_000_000)
            let owner = continuingOwner ?? UUID()
            var liveOwnerExpiry: UInt64?
            guard let receipt = store.withTransaction({ transaction -> ContainedProcessReceipt? in
                guard case let .valid(current) = store.containmentReceiptRecord() else { return nil }
                if current.cleanupOwnerToken != nil, current.cleanupOwnerToken != owner,
                   current.ownerDeadlineNanoseconds > now {
                    liveOwnerExpiry = current.ownerDeadlineNanoseconds
                    return nil
                }
                return store.claimContainmentReceipt(token: current.token, owner: owner, now: now,
                                                     until: now &+ 500_000_000, transaction)
            }) ?? nil else {
                if let liveOwnerExpiry {
                    let seconds = max(1, Int((liveOwnerExpiry &- now) / 1_000_000_000))
                    containmentCleanupQueue.asyncAfter(deadline: .now() + .seconds(seconds)) {
                        scheduleContainmentCleanup(configuration: configuration)
                    }
                }
                return
            }
            let action = ContainedProcessRunner.cleanupStep(receipt: receipt, owner: owner, now: now)
            switch action {
            case .extinguished:
                _ = store.withTransaction { transaction in
                    guard let extinct = receipt.advancing(to: .extinguished, owner: owner, deadline: receipt.ownerDeadlineNanoseconds),
                          store.advanceContainmentReceipt(expected: receipt, next: extinct, transaction),
                          case let .valid(current) = store.containmentReceiptRecord(), current == extinct
                    else { return false }
                    // Preserve an existing terminal/migrated proof; otherwise
                    // durably require explicit recovery before removing the
                    // fence, so no reconnect/begin path can auto-rearm.
                    switch store.proofRecord() {
                    case .absent, .invalid:
                        guard store.markRecoveryRequired("containment-extinguished-explicit-recovery-required", transaction).isVerified else { return false }
                    case .valid: break
                    }
                    return store.removeContainmentReceipt(expected: extinct, transaction) == .removed
                }
            case .signalKILL:
                // Persist both KILL intent and issued latch before the signal.
                // Restart can therefore reap/advance but never duplicate it.
                let persisted = store.withTransaction { transaction -> ContainedProcessReceipt? in
                    if receipt.phase == .kill {
                        guard let issued = receipt.markingKillSignalIssued(owner: owner, deadline: receipt.ownerDeadlineNanoseconds),
                              store.advanceContainmentReceipt(expected: receipt, next: issued, transaction)
                        else { return nil }
                        return issued
                    }
                    guard let intent = receipt.advancing(to: .kill, owner: owner, deadline: receipt.ownerDeadlineNanoseconds),
                          store.advanceContainmentReceipt(expected: receipt, next: intent, transaction),
                          let issued = intent.markingKillSignalIssued(owner: owner, deadline: receipt.ownerDeadlineNanoseconds),
                          store.advanceContainmentReceipt(expected: intent, next: issued, transaction)
                    else { return nil }
                    return issued
                }
                guard let killing = persisted ?? nil else { return }
                ContainedProcessRunner.executeCleanupAction(.signalKILL, receipt: killing)
                containmentCleanupQueue.asyncAfter(deadline: .now() + .milliseconds(250)) {
                    scheduleContainmentCleanup(configuration: configuration, owner: owner)
                }
            case .signalTERM:
                // As with KILL, durably latch TERM before issuing it. A crash
                // after this point can observe/reap but cannot send TERM twice.
                let persisted = store.withTransaction { transaction -> ContainedProcessReceipt? in
                    guard let marked = receipt.markingTermSignalIssued(owner: owner, deadline: receipt.ownerDeadlineNanoseconds),
                          store.advanceContainmentReceipt(expected: receipt, next: marked, transaction)
                    else { return nil }
                    return marked
                }
                guard let marked = persisted ?? nil else { return }
                ContainedProcessRunner.executeCleanupAction(.signalTERM, receipt: marked)
                containmentCleanupQueue.asyncAfter(deadline: .now() + .milliseconds(250)) {
                    scheduleContainmentCleanup(configuration: configuration, owner: owner)
                }
            case .reapLeader:
                // Persist the owner-bound attempt before waitpid. ECHILD,
                // EINTR exhaustion and lost-CAS therefore survive restart as
                // unproven observations; they cannot spin a 250 ms timer
                // forever or become extinction proof.
                let attempted = store.withTransaction { transaction -> ContainedProcessReceipt? in
                    guard let next = receipt.recordingReapAttempt(owner: owner, deadline: receipt.ownerDeadlineNanoseconds),
                          store.advanceContainmentReceipt(expected: receipt, next: next, transaction)
                    else { return nil }
                    return next
                }
                guard let attempted = attempted ?? nil else { return }
                guard ContainedProcessRunner.reapLeaderOutcome(attempted) == .reaped else {
                    containmentCleanupQueue.asyncAfter(deadline: .now() + .milliseconds(250)) {
                        scheduleContainmentCleanup(configuration: configuration, owner: owner)
                    }
                    return
                }
                _ = store.withTransaction { transaction in
                    guard let reaped = attempted.markingLeaderReaped(owner: owner, deadline: attempted.ownerDeadlineNanoseconds) else { return false }
                    return store.advanceContainmentReceipt(expected: attempted, next: reaped, transaction)
                }
                containmentCleanupQueue.asyncAfter(deadline: .now() + .milliseconds(250)) {
                    scheduleContainmentCleanup(configuration: configuration, owner: owner)
                }
            case .retainFence:
                // Ambiguous/reused identity is intentionally durable and
                // requires explicit recovery; no signal is retried.  Publish
                // a typed projection through the same durable task channel,
                // without reopening a power or lease path.
                _ = store.withTransaction { transaction in
                    guard case let .valid(current) = store.containmentReceiptRecord(), current == receipt,
                          let ambiguous = receipt.advancing(to: .ambiguous, owner: owner, deadline: receipt.ownerDeadlineNanoseconds),
                          store.advanceContainmentReceipt(expected: receipt, next: ambiguous, transaction),
                          StatusProjectionDispatcher.enqueue(
                        state: "recovery-required", reason: "containment-extinction-unproven", sessionID: nil,
                        store: store, transaction: transaction, configuration: configuration
                    ) else { return false }
                    return true
                }
                break
            }
        }
    }

    private func projectRequired(_ reason: String) -> RecoveryAssessment {
        // If no verified existing lock/capability is available, even a status
        // projection would be an unlocked mutation. Provisioning belongs only
        // to the explicit provision-root-state-lock mode.
        return .recoveryRequired(reason)
    }

    private func publicationReason(
        _ prefix: String,
        _ outcome: RecoveryPublicationOutcome
    ) -> String {
        switch outcome {
        case .alreadyVerified, .published: return prefix
        case .notPublished: return "\(prefix)-not-published"
        case .publishedButUnverified: return "\(prefix)-unverified"
        }
    }

    private func priorProofAllowsActiveState(
        _ record: RecoveryAuthorityStore.ProofRecord,
        state: AppliedState,
        terminalEntries: [UUID]
    ) -> Bool {
        guard case let .valid(proof) = record else { return false }
        guard !terminalEntries.contains(state.sessionID) else { return false }
        switch proof.kind {
        case .pristine:
            return terminalEntries.isEmpty
        case .terminal:
            guard let prior = proof.sessionID, prior != state.sessionID else { return false }
            return terminalEntries.last == prior
        case .migrated:
            return terminalEntries.isEmpty
        case .recoveryRequired:
            return false
        }
    }

    private struct Snapshot {
        let source: HelperPowerSource
        let sleepDisabled: Bool
        let acSleepMinutes: Int
        let batterySleepMinutes: Int?
    }

    private func strictSnapshot() -> Snapshot? {
        let source = power.powerSource()
        guard source == .ac || source == .battery,
              let disabled = power.sleepDisabled(),
              let ac = power.acSleepMinutes()
        else { return nil }
        return Snapshot(
            source: source,
            sleepDisabled: disabled,
            acSleepMinutes: ac,
            batterySleepMinutes: power.batterySleepMinutes()
        )
    }

    private func strictOwnedSnapshot() -> Bool {
        guard let snapshot = strictSnapshot() else { return false }
        return snapshot.source == .ac && snapshot.sleepDisabled && snapshot.acSleepMinutes == 0
    }
}
