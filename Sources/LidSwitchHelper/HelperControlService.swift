import Darwin
import Foundation
import LidSwitchCore
import LidSwitchXPCBridge

typealias HelperTimerHandler = @Sendable () -> Void
typealias HelperTimerStarter = (@escaping HelperTimerHandler) -> AnyObject?

enum HelperDaemonPreparation: Equatable {
    case ready
    /// Recovery reached a durable fail-closed state. Exiting successfully keeps
    /// launchd's SuccessfulExit=false policy from respawning a write loop.
    case handledRecoveryRequired
    /// Store/lock/timer/preflight infrastructure failed without a durable stop.
    case transientFailure
}

struct HelperServiceConfiguration: Equatable, Sendable {
    enum Mode: Equatable, Sendable { case daemon, provisionRootStateLock, recoverOnce(RecoveryIntent) }
    let expectedOwnerUID: uid_t
    let qualifiedBuild: String
    let supportDirectory: String
    let appliedStatePath: String
    let statusPath: String
    let policyPath: String
    let mode: Mode

    init(
        expectedOwnerUID: uid_t,
        qualifiedBuild: String,
        supportDirectory: String,
        appliedStatePath: String,
        statusPath: String,
        policyPath: String,
        mode: Mode = .daemon
    ) {
        self.expectedOwnerUID = expectedOwnerUID
        self.qualifiedBuild = qualifiedBuild
        self.supportDirectory = supportDirectory
        self.appliedStatePath = appliedStatePath
        self.statusPath = statusPath
        self.policyPath = policyPath
        self.mode = mode
    }

    var terminalPath: String { supportDirectory + "/terminal-generations" }
    var recoveryReservationPath: String { supportDirectory + "/recovery-reservations" }

    static func parse(arguments: [String]) -> HelperServiceConfiguration? {
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            guard arguments[index].hasPrefix("--"), index + 1 < arguments.count,
                  values.updateValue(arguments[index + 1], forKey: arguments[index]) == nil else { return nil }
            index += 2
        }
        let mode: Mode
        switch values.removeValue(forKey: "--mode") {
        case nil: mode = .daemon
        case .some("provision-root-state-lock"): mode = .provisionRootStateLock
        case .some("recover-once"):
            guard let rawIntent = values.removeValue(forKey: "--intent"), let intent = RecoveryIntent(rawValue: rawIntent) else { return nil }
            mode = .recoverOnce(intent)
        default: return nil
        }
        guard values.count == 6, let ownerRaw = values["--owner-uid"], let owner = uid_t(ownerRaw),
              owner > 0, String(owner) == ownerRaw,
              let build = values["--qualified-build"], let support = values["--support-directory"],
              let applied = values["--applied-state"], let status = values["--status-path"],
              let policy = values["--policy-path"],
              build == ReleaseIdentity.qualifiedSystemBuild,
              support == ReleaseIdentity.rootSupportDirectory,
              applied == ReleaseIdentity.rootAppliedStatePath,
              status == ReleaseIdentity.rootStatusPath,
              policy == ReleaseIdentity.rootEnrollmentPolicyPath
        else { return nil }
        return HelperServiceConfiguration(expectedOwnerUID: owner, qualifiedBuild: build,
                                          supportDirectory: support, appliedStatePath: applied,
                                          statusPath: status, policyPath: policy, mode: mode)
    }
}

final class HelperSessionAuthority: @unchecked Sendable {
    private static let leaseLifetime: TimeInterval = 30
    // Longer than the app's eight-second renewal cadence plus scheduling
    // slack, but always clipped to the original thirty-second lease.
    private static let reconnectGrace: TimeInterval = 12
    /// Rollback accounting is bounded. A failure proven to precede the durable
    /// terminal/setter boundary may revalidate and retry; once a setter result
    /// is uncertain, every later tick and request is observation-only.
    private static let rollbackAttemptLimit = 6
    private static let rollbackMaximumBackoff: TimeInterval = 60
    private struct Peer: Equatable, Sendable {
        let pid: Int32; let euid: UInt32; let asid: UInt32
        let startSeconds: UInt64; let startMicroseconds: UInt64

        init?(_ raw: ls_peer_identity_t?) {
            guard let raw, raw.pid > 0, raw.start_tvsec > 0, raw.start_tvusec < 1_000_000 else { return nil }
            pid = raw.pid; euid = raw.euid; asid = raw.asid
            startSeconds = raw.start_tvsec; startMicroseconds = raw.start_tvusec
        }

        init?(owner: AppliedState.Owner) {
            guard owner.isWellFormed else { return nil }
            pid = owner.pid; euid = owner.euid; asid = owner.asid
            startSeconds = owner.startSeconds; startMicroseconds = owner.startMicroseconds
        }

        func owner(bootID: String) -> AppliedState.Owner {
            .init(pid: pid, startSeconds: startSeconds, startMicroseconds: startMicroseconds,
                  asid: asid, euid: euid, bootID: bootID)
        }

        var cValue: ls_peer_identity_t {
            ls_peer_identity_t(pid: pid, euid: euid, asid: asid, start_tvsec: startSeconds, start_tvusec: startMicroseconds)
        }

    }
    private let lock = NSLock()
    private let configuration: HelperServiceConfiguration
    private let power: HelperPowerSystem
    private let recoveryStoreFactory: (String) -> RecoveryAuthorityStore?
    private let statusProjectionWriter: StatusProjectionDispatcher.Writer
    private let appliedStatePublish: (
        AppliedState,
        RecoveryAuthorityStore,
        VerifiedRootStateDirectory.Transaction
    ) -> RecoveryPublicationOutcome
    // These seams make the process-bound ownership state machine testable
    // without weakening production's public-kernel peer capture/recheck.
    private let monotonicNow: () -> TimeInterval
    private let peerIsLive: (Peer) -> Bool
    private let bootIdentity: () -> String?
    private var activeSession: UUID?
    private var activeConnection: UInt64?
    /// Bridge-issued IDs increase for one helper process. Keeping only the
    /// high-watermark rejects every old connection forever without an
    /// unbounded retired-ID set or an arbitrary reconnect ceiling.
    private var connectionHighWatermark: UInt64 = 0
    private var activePeer: Peer?
    private var reconnectDeadline: TimeInterval?
    private var expiry: TimeInterval = 0
    private var successfulOverrideRecoveries = 0
    private var timerToken: AnyObject?
    private let timerStarter: HelperTimerStarter
    private let recoveryCoordinatorFactory: () -> RecoveryCoordinator
    private var recoveryRequired = false
    private var consecutiveUnknownPowerReads = 0
    private var lastTerminalSession: UUID?
    private var lastTerminalReason = "idle"
    private enum RollbackRetryKind {
        case noPowerMutationAttempted
        case mutationUncertain
    }
    private struct RollbackRetry {
        let kind: RollbackRetryKind
        let reason: String
        let attempts: Int
        let nextAttempt: TimeInterval
    }
    private var rollbackRetry: RollbackRetry?
#if DEBUG
    private var lastRollbackAssessment: RecoveryAssessment?
    private var lastPreparationAssessment: RecoveryAssessment?
    private var lastPreparationStage = "not-started"
#endif
    private var tickStoreAttempts = 0
    private enum NativePowerObservation { case intact, confirmedDrift, indeterminate }
    private enum StartupBinding {
        case bind(Peer, TimeInterval, Bool)
        case pristineIdle
        case migratedIdle(String)
        case terminalIdle(UUID, String)
        case recoveryRequired(String)
    }

    init(configuration: HelperServiceConfiguration, power: HelperPowerSystem,
         appliedStatePublish: ((AppliedState, RecoveryAuthorityStore, VerifiedRootStateDirectory.Transaction) -> RecoveryPublicationOutcome)? = nil,
         recoveryStoreFactory: ((String) -> RecoveryAuthorityStore?)? = nil,
         statusProjectionWriter: StatusProjectionDispatcher.Writer? = nil,
         monotonicNow: @escaping () -> TimeInterval = MonotonicClock.seconds,
         peerIsLive: @escaping (ls_peer_identity_t) -> Bool = { raw in
            var value = raw
            return ls_peer_identity_is_live(&value)
         }, bootIdentity: @escaping () -> String? = BootIdentity.current,
         timerStarter: @escaping HelperTimerStarter = HelperSessionAuthority.startSystemTimer,
         recoveryCoordinatorFactory: (() -> RecoveryCoordinator)? = nil) {
        self.configuration = configuration; self.power = power
        let resolvedStoreFactory: (String) -> RecoveryAuthorityStore? = recoveryStoreFactory ?? {
            RecoveryAuthorityStore(supportDirectory: $0)
        }
        let resolvedStatusProjectionWriter: StatusProjectionDispatcher.Writer = statusProjectionWriter ?? {
            task, configuration in
            HelperStatusStore.writeOutcome(task: task, path: configuration.statusPath)
        }
        self.recoveryStoreFactory = resolvedStoreFactory
        self.statusProjectionWriter = resolvedStatusProjectionWriter
        self.appliedStatePublish = appliedStatePublish ?? { state, store, transaction in
            store.publishApplied(state, transaction)
        }
        self.monotonicNow = monotonicNow
        self.peerIsLive = { peer in peerIsLive(peer.cValue) }
        self.bootIdentity = bootIdentity
        self.timerStarter = timerStarter
        self.recoveryCoordinatorFactory = recoveryCoordinatorFactory ?? {
            RecoveryCoordinator(
                configuration: configuration,
                power: power,
                bootIdentity: bootIdentity,
                storeFactory: resolvedStoreFactory,
                statusProjectionWriter: resolvedStatusProjectionWriter
            )
        }
    }

    func prepareBeforeListening() -> HelperDaemonPreparation {
        guard CompatibilityPolicy.isQualified(systemBuild: configuration.qualifiedBuild) else {
#if DEBUG
            lastPreparationStage = "compatibility-rejected"
#endif
            return .transientFailure
        }
        // Startup may require a second transaction to bind a reconnectable
        // authority. Wake the projection-only worker after the complete
        // preparation boundary so it cannot take the shared root lock between
        // recovery and that binding transaction.
        defer {
            StatusProjectionDispatcher.hydrate(
                configuration: configuration,
                storeFactory: recoveryStoreFactory,
                writer: statusProjectionWriter
            )
        }
        let coordinator = recoveryCoordinatorFactory()
        let preparationAssessment = coordinator.recover(
            intent: .startup,
            allowReconnect: true,
            terminalReason: "helper-restart",
            hydrateStatusProjection: false
        )
#if DEBUG
        lastPreparationAssessment = preparationAssessment
        lastPreparationStage = "assessment"
#endif
        switch preparationAssessment {
        case .pristineIdle:
            return startTimerOnly() ? .ready : .transientFailure
        case .migratedIdle:
            return startTimerOnly() ? .ready : .transientFailure
        case let .terminalIdle(session, reason):
            hydrateTerminal(session: session, reason: reason)
            return startTimerOnly() ? .ready : .transientFailure
        case let .reconnectCandidate(state):
            // The coordinator has proved the private schema-2 artifact and
            // owned power plus terminal/reservation non-membership. Listener
            // startup re-reads both ledgers, then proves the exact live peer
            // tuple and unexpired same-boot owner before exposing RECONNECT.
            guard let store = recoveryStoreFactory(configuration.supportDirectory) else {
#if DEBUG
                lastPreparationStage = "binding-store-unavailable"
#endif
                return .transientFailure
            }
            guard let binding = store.withTransaction({ transaction -> StartupBinding in
                      let spentBudget = store.recoveryBudgetRecord() == .valid(
                        RecoveryBudgetState(sessionID: state.sessionID, phase: .spent)
                      )
                      if state.isReconnectable,
                         let owner = state.owner,
                         let peer = Peer(owner: owner),
                         owner.bootID == self.bootIdentity(),
                         self.peerIsLive(peer),
                         let deadline = state.leaseExpiryMonotonic,
                         self.monotonicNow() < deadline,
                         self.privateAuthorityMatches(
                            expected: state,
                            peer: peer,
                            expiry: deadline,
                            store: store,
                            expectsRecoveryReservation: spentBudget
                         ),
                         self.ownedStateIsIntact() {
                          return .bind(peer, deadline, spentBudget)
                      }
                      let recovered = coordinator.recoverWithinTransaction(
                        store: store,
                        transaction: transaction,
                        intent: .startup,
                        allowReconnect: false,
                        terminalReason: "helper-restart"
                      )
                      switch recovered {
                      case .pristineIdle: return .pristineIdle
                      case let .migratedIdle(reason): return .migratedIdle(reason)
                      case let .terminalIdle(session, reason): return .terminalIdle(session, reason)
                      case .legacyRestoreOnly, .reconnectCandidate:
                          return .recoveryRequired("startup-recovery-incomplete")
                      case let .recoveryRequired(reason):
                          return .recoveryRequired(reason)
                      }
                  }) else {
#if DEBUG
                lastPreparationStage = "binding-lock-unavailable"
#endif
                return .transientFailure
            }
            switch binding {
            case let .bind(peer, deadline, spentBudget):
                activeSession = state.sessionID; activePeer = peer; activeConnection = nil; expiry = deadline
                successfulOverrideRecoveries = spentBudget ? 1 : 0
                reconnectDeadline = min(deadline, monotonicNow() + Self.reconnectGrace)
            case .pristineIdle:
                activeSession = nil; activePeer = nil; activeConnection = nil; expiry = 0; reconnectDeadline = nil
            case .migratedIdle:
                activeSession = nil; activePeer = nil; activeConnection = nil; expiry = 0; reconnectDeadline = nil
            case let .terminalIdle(session, reason):
                activeSession = nil; activePeer = nil; activeConnection = nil; expiry = 0; reconnectDeadline = nil
                hydrateTerminal(session: session, reason: reason)
            case let .recoveryRequired(reason):
                recoveryRequired = true
                return persistedRecoveryStop(expectedReason: reason)
            }
            // Status is projection-only; the private state and exact peer tuple
            // remain the reconnect authority.
            if case .bind(_, _, _) = binding {
                projectStatus(state: "active", reason: "reconnect-pending", sessionID: state.sessionID)
            }
            return startTimerOnly() ? .ready : .transientFailure
        case .legacyRestoreOnly:
            recoveryRequired = true
            return .transientFailure
        case let .recoveryRequired(reason):
            recoveryRequired = true
            return persistedRecoveryStop(expectedReason: reason)
        }
    }

    private func hydrateTerminal(session: UUID, reason: String) {
        lastTerminalSession = session
        lastTerminalReason = reason
    }

    private func adoptDurableTerminalForActiveSession(
        store: RecoveryAuthorityStore
    ) -> (sessionID: UUID, reason: String)? {
        guard let sessionID = activeSession,
              store.appliedRecord() == .missing,
              store.recoveryBudgetRecord() == .absent,
              case let .valid(proof) = store.proofRecord(),
              proof.kind == .terminal,
              proof.sessionID == sessionID,
              case let .privateAuthority(terminalEntries, _) = store.ledger(
                RecoveryAuthorityStore.terminalBasename
              ),
              terminalEntries.last == sessionID
        else { return nil }

        activeSession = nil
        activeConnection = nil
        activePeer = nil
        reconnectDeadline = nil
        expiry = 0
        successfulOverrideRecoveries = 0
        rollbackRetry = nil
        recoveryRequired = false
        hydrateTerminal(session: sessionID, reason: proof.reason)
        return (sessionID, proof.reason)
    }

    private func persistedRecoveryStop(expectedReason: String) -> HelperDaemonPreparation {
        guard let store = recoveryStoreFactory(configuration.supportDirectory),
              let persisted = store.withTransaction({ _ -> Bool in
                  guard case let .valid(proof) = store.proofRecord() else { return false }
                  return proof.kind == .recoveryRequired && proof.reason == expectedReason
              })
        else { return .transientFailure }
        return persisted ? .handledRecoveryRequired : .transientFailure
    }

    private func startTimerOnly() -> Bool {
        guard timerToken == nil else { return false }
        guard let token = timerStarter({ [weak self] in self?.tick() }) else { return false }
        timerToken = token
        return true
    }

    private static func startSystemTimer(_ handler: @escaping HelperTimerHandler) -> AnyObject? {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.johnsilva.lidswitch.helper.reconcile"))
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer as AnyObject
    }

    func handle(connection: UInt64, peer rawPeer: ls_peer_identity_t?, operation: UInt32, sessionID: UUID) -> AuthorityReply {
        lock.lock(); defer { lock.unlock() }
        // A malformed/unavailable tuple on another authenticated connection is
        // not evidence that the currently bound owner died. Only the helper
        // tick rechecks and terminalizes the original persisted owner.
        guard let peer = Peer(rawPeer), peer.euid == UInt32(configuration.expectedOwnerUID), peerIsLive(peer) else {
            return snapshot(result: 77, reason: "peer-process-unavailable", requested: sessionID)
        }
        let snapshotOperation = operation == UInt32(LS_OPERATION_SNAPSHOT.rawValue)
        // A containment receipt is a hard mutation fence. Snapshot remains
        // responsive, but RESTORE is a power mutation and must wait for exact
        // cleanup/extinction plus an explicit administrator recovery path.
        guard !recoveryRequired || (snapshotOperation && activeSession != nil) else {
            return snapshot(result: 75, reason: "recovery-required", requested: sessionID)
        }
        if operation == UInt32(LS_OPERATION_RESTORE.rawValue) {
            guard sessionID == Self.zeroUUID else { return snapshot(result: 64, reason: "restore-session-forbidden", requested: sessionID) }
        } else if operation != UInt32(LS_OPERATION_SNAPSHOT.rawValue), sessionID == Self.zeroUUID {
            return snapshot(result: 64, reason: "zero-session-forbidden", requested: sessionID)
        }
        guard let store = recoveryStoreFactory(configuration.supportDirectory) else {
            registerAuthorityUnavailableIfActive()
            return snapshot(result: 75, reason: "unsafe-root-state-directory", requested: sessionID)
        }
        guard let reply = store.withTransaction({ transaction in
            self.handleLocked(
                connection: connection,
                peer: peer,
                operation: operation,
                sessionID: sessionID,
                store: store,
                transaction: transaction
            )
        }) else {
            registerAuthorityUnavailableIfActive()
            return snapshot(result: 75, reason: "root-state-lock-unavailable", requested: sessionID)
        }
        return reply
    }

    private func handleLocked(
        connection: UInt64,
        peer: Peer,
        operation: UInt32,
        sessionID: UUID,
        store: RecoveryAuthorityStore,
        transaction: VerifiedRootStateDirectory.Transaction
    ) -> AuthorityReply {
        if store.containmentReceiptRecord() != .absent {
            recoveryRequired = true
            if operation == UInt32(LS_OPERATION_SNAPSHOT.rawValue) {
                return snapshot(result: 75, reason: "containment-pending", requested: sessionID)
            }
            return snapshot(result: 75, reason: "containment-pending", requested: sessionID)
        }
        // Administrator recovery can terminalize the durable generation while
        // this helper process still has its former owner cached in memory.
        // Adopt only the complete private terminal proof; never re-enter power
        // rollback after that proof has already removed the applied authority.
        if let terminal = adoptDurableTerminalForActiveSession(store: store) {
            return snapshot(result: 75, reason: terminal.reason, requested: terminal.sessionID)
        }
        switch operation {
        case UInt32(LS_OPERATION_BEGIN.rawValue):
            return begin(connection: connection, peer: peer, sessionID: sessionID, store: store, transaction: transaction)
        case UInt32(LS_OPERATION_RECONNECT.rawValue):
            return reconnect(connection: connection, peer: peer, sessionID: sessionID, store: store, transaction: transaction)
        case UInt32(LS_OPERATION_RENEW.rawValue):
            return renew(connection: connection, peer: peer, sessionID: sessionID, store: store, transaction: transaction)
        case UInt32(LS_OPERATION_END.rawValue):
            return end(connection: connection, peer: peer, sessionID: sessionID, reason: "user-end", store: store, transaction: transaction)
        case UInt32(LS_OPERATION_SNAPSHOT.rawValue):
            guard activeSession == nil || (activeConnection == connection && activePeer == peer) else {
                return snapshot(result: 77, reason: "second-connection", requested: sessionID)
            }
            guard activeSession == nil || activeSession == sessionID else {
                return snapshot(result: 78, reason: "protocol-session-mismatch", requested: sessionID)
            }
            guard let activeSession, let activePeer else {
                return snapshot(result: 0, reason: "idle", requested: sessionID)
            }
            guard privateAuthorityMatches(
                expectedSession: activeSession,
                peer: activePeer,
                expiry: expiry,
                store: store
            ), ownedStateIsIntact() else {
                return restoreActive(
                    reason: "snapshot-authority-mismatch",
                    result: 75,
                    store: store,
                    transaction: transaction
                )
            }
            return snapshot(result: 0, reason: "verified", requested: sessionID)
        case UInt32(LS_OPERATION_RESTORE.rawValue):
            guard activeSession == nil || (activeConnection == connection && activePeer == peer) else {
                return snapshot(result: 77, reason: "second-connection", requested: sessionID)
            }
            return restoreActive(reason: "peer-restore", store: store, transaction: transaction)
        default:
            return snapshot(result: 64, reason: "unknown-operation", requested: sessionID)
        }
    }

    /// Fixture-only compatibility entry point. Production reaches the overload
    /// above exclusively through the bridge's authenticated capture path.
    func handle(connection: UInt64, operation: UInt32, sessionID: UUID) -> AuthorityReply {
        var peer = ls_peer_identity_t()
        guard ls_peer_identity_for_current_process(&peer) else {
            return AuthorityReply(result: 75, reason: "peer-process-invalid", sessionID: sessionID,
                                  expiryMonotonic: 0, state: 2, power: 0, sleepDisabled: false, acSleepMinutes: -1)
        }
        return handle(connection: connection, peer: peer, operation: operation, sessionID: sessionID)
    }

    func connectionInvalidated(_ connection: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard activeConnection == connection else { return }
        guard let store = recoveryStoreFactory(configuration.supportDirectory),
              store.withTransaction({ _ in
                  guard let session = self.activeSession,
                        let peer = self.activePeer,
                        self.privateAuthorityMatches(expectedSession: session, peer: peer, expiry: self.expiry, store: store)
                  else { return false }
                  return true
              }) == true
        else {
            registerAuthorityUnavailableIfActive()
            return
        }
        activeConnection = nil
        // Do not renew or extend. The original lease remains the hard upper
        // bound while the exact process gets one short reconnect opportunity.
        reconnectDeadline = min(expiry, monotonicNow() + Self.reconnectGrace)
    }

    private func begin(
        connection: UInt64,
        peer: Peer,
        sessionID: UUID,
        store: RecoveryAuthorityStore,
        transaction: VerifiedRootStateDirectory.Transaction
    ) -> AuthorityReply {
        guard activeSession == nil, activeConnection == nil else { return snapshot(result: 77, reason: "second-session", requested: sessionID) }
        // A lower bridge ID belongs to an earlier connection in this helper
        // process and can never start a new generation after being superseded.
        guard connection >= connectionHighWatermark else { return snapshot(result: 77, reason: "connection-replay", requested: sessionID) }
        guard idleAuthorityAllowsBegin(sessionID: sessionID, store: store) else {
            lastTerminalSession = sessionID; lastTerminalReason = "replay-or-durability-denial"
            projectStatus(state: "terminal", reason: lastTerminalReason, sessionID: sessionID,
                          store: store, transaction: transaction)
            return snapshot(result: 79, reason: "replay-or-durability-denial", requested: sessionID)
        }
        guard power.powerSource() == .ac, power.sleepDisabled() == false, let originalAC = power.acSleepMinutes() else {
            return snapshot(result: 74, reason: "preflight-failed", requested: sessionID)
        }
        guard let boot = bootIdentity() else { return snapshot(result: 74, reason: "boot-identity-unavailable", requested: sessionID) }
        let deadline = monotonicNow() + Self.leaseLifetime
        let owner = AppliedState.Owner(pid: peer.pid, startSeconds: peer.startSeconds,
                                       startMicroseconds: peer.startMicroseconds, asid: peer.asid,
                                       euid: peer.euid, bootID: boot)
        // The complete owner tuple and original lease are durable before the
        // first power mutation, so restart/reconnect cannot adopt another PID.
        let state = AppliedState.currentAuthority(
            sessionID: sessionID,
            changedSleepDisabled: true,
            changedACSleep: originalAC != 0,
            originalACSleep: originalAC == 0 ? nil : originalAC,
            owner: owner,
            leaseExpiryMonotonic: deadline
        )
        // The process tuple was checked before waiting for RootStateLock. Check
        // it again while the transaction is held so a peer that exits during
        // the wait can never publish authority or reach a power mutation.
        guard peerIsLive(peer) else {
            return snapshot(result: 77, reason: "peer-process-unavailable", requested: sessionID)
        }
        let publication = appliedStatePublish(state, store, transaction)
        guard publication.isVerified, store.appliedRecord() == .privateAuthority(state) else {
            let outcome = recoveryCoordinatorFactory().recoverWithinTransaction(
                store: store,
                transaction: transaction,
                intent: .userRestore,
                allowReconnect: false,
                terminalReason: "activation-publication-failed"
            )
            switch outcome {
            case .pristineIdle, .migratedIdle, .terminalIdle:
                break
            case .recoveryRequired, .legacyRestoreOnly, .reconnectCandidate:
                recoveryRequired = true
            }
            return snapshot(result: 70, reason: "activation-publication-failed", requested: sessionID)
        }
        // Once the private applied authority is durable, every failure follows
        // the one coordinator ordering: terminal -> restore -> proof -> remove.
        activeSession = sessionID; activeConnection = connection; activePeer = peer
        connectionHighWatermark = max(connectionHighWatermark, connection)
        expiry = deadline; reconnectDeadline = nil; successfulOverrideRecoveries = 0
        var activationMutationIndeterminate = false
        do {
            try withContainmentReceipt(store: store, transaction: transaction) {
                if originalAC != 0 { try power.setACSleepMinutes(0) }
                try power.setSleepDisabled(true)
            }
        } catch HelperPowerMutationError.containmentPending {
            recoveryRequired = true
            return snapshot(result: 75, reason: "containment-pending", requested: sessionID)
        } catch {
            // A contained runner failure may arrive after pmset has committed.
            // Reconcile once from native truth; do not issue another setter.
            activationMutationIndeterminate = true
        }
        guard power.powerSource() == .ac, power.sleepDisabled() == true, power.acSleepMinutes() == 0 else {
            return restoreActive(
                reason: activationMutationIndeterminate ? "activation-indeterminate" : "activation-verification-failed",
                result: 70,
                store: store,
                transaction: transaction
            )
        }
        projectStatus(state: "active", reason: activationMutationIndeterminate ? "verified-after-indeterminate-runner" : "verified",
                      sessionID: sessionID, store: store, transaction: transaction)
        return snapshot(result: 0, reason: "verified", requested: sessionID)
    }

    private func reconnect(
        connection: UInt64,
        peer: Peer,
        sessionID: UUID,
        store: RecoveryAuthorityStore,
        transaction: VerifiedRootStateDirectory.Transaction
    ) -> AuthorityReply {
        // An authenticated but different exact-code process is not authority
        // to terminate a live owner. Reject it and preserve the original
        // deadline; only the original owner/liveness or durable safety facts
        // below can terminalize this generation.
        guard activeSession == sessionID, activePeer == peer else {
            return snapshot(result: 77, reason: "reconnect-peer-mismatch", requested: sessionID)
        }
        guard activeConnection == connection || connection > connectionHighWatermark else {
            return snapshot(result: 77, reason: "reconnect-connection-replay", requested: sessionID)
        }
        let replacingBoundConnection = activeConnection != nil
        guard monotonicNow() < expiry else {
            return restoreActive(reason: "reconnect-expired", result: 75, store: store, transaction: transaction)
        }
        // XPC invalidation is cross-connection ordered. The exact live owner
        // may prove an authenticated same-process replacement before the old
        // connection's invalidation arrives. That atomic rebind has no grace
        // dependency and keeps the original expiry; all other tuples reject.
        if !replacingBoundConnection {
            guard let deadline = reconnectDeadline, monotonicNow() < deadline else {
                return restoreActive(reason: "reconnect-expired", result: 75, store: store, transaction: transaction)
            }
        }
        guard privateAuthorityMatches(expectedSession: sessionID, peer: peer, expiry: expiry, store: store) else {
            return restoreActive(reason: "reconnect-state-mismatch", result: 75, store: store, transaction: transaction)
        }
        switch nativePowerObservation() {
        case .intact: break
        case .confirmedDrift:
            return restoreActive(reason: "reconnect-power-unsafe", result: 75, store: store, transaction: transaction)
        case .indeterminate:
            return snapshot(result: 0, reason: "native-state-indeterminate", requested: sessionID)
        }
        projectStatus(state: "active", reason: "reconnected", sessionID: sessionID,
                      store: store, transaction: transaction)
        activeConnection = connection; connectionHighWatermark = connection; reconnectDeadline = nil
        return snapshot(result: 0, reason: "reconnected", requested: sessionID)
    }

    private func renew(
        connection: UInt64,
        peer: Peer,
        sessionID: UUID,
        store: RecoveryAuthorityStore,
        transaction: VerifiedRootStateDirectory.Transaction
    ) -> AuthorityReply {
        guard activeConnection == connection, activePeer == peer else { return snapshot(result: 77, reason: "connection-mismatch", requested: sessionID) }
        guard activeSession == sessionID else { return snapshot(result: 78, reason: "stale-renewal", requested: sessionID) }
        guard monotonicNow() < expiry else { return restoreActive(reason: "expired", result: 75, store: store, transaction: transaction) }
        guard privateAuthorityMatches(expectedSession: sessionID, peer: peer, expiry: expiry, store: store) else {
            return restoreActive(reason: "renewal-authority-mismatch", result: 75, store: store, transaction: transaction)
        }
        switch power.powerSource() {
        case .ac: consecutiveUnknownPowerReads = 0
        case .battery: return restoreActive(reason: "ac-disconnect", result: 75, store: store, transaction: transaction)
        case .unknown:
            consecutiveUnknownPowerReads += 1
            // Never extend authority while power is uncertain; the existing
            // helper-chosen expiry remains the hard upper bound.
            return snapshot(result: 0, reason: "native-state-indeterminate", requested: sessionID)
        }
        switch nativePowerObservation() {
        case .intact: break
        case .indeterminate:
            return snapshot(result: 0, reason: "native-state-indeterminate", requested: sessionID)
        case .confirmedDrift:
            return restoreActive(reason: "drift", result: 75, store: store, transaction: transaction)
        }
        let renewedExpiry = monotonicNow() + Self.leaseLifetime
        guard persistRenewedExpiry(sessionID: sessionID, peer: peer, renewedExpiry: renewedExpiry, store: store, transaction: transaction) else {
            return restoreActive(reason: "renewal-publication-failed", result: 75, store: store, transaction: transaction)
        }
        expiry = renewedExpiry
        return snapshot(result: 0, reason: successfulOverrideRecoveries == 0 ? "verified" : "override-recovered", requested: sessionID)
    }

    private func end(
        connection: UInt64,
        peer: Peer,
        sessionID: UUID,
        reason: String,
        store: RecoveryAuthorityStore,
        transaction: VerifiedRootStateDirectory.Transaction
    ) -> AuthorityReply {
        guard activeConnection == connection, activePeer == peer else { return snapshot(result: 77, reason: "second-connection", requested: sessionID) }
        guard activeSession == sessionID else { return snapshot(result: 78, reason: "protocol-session-mismatch", requested: sessionID) }
        return restoreActive(reason: reason, store: store, transaction: transaction)
    }

    private func tick() {
        lock.lock(); defer { lock.unlock() }
        guard let session = activeSession else { return }
        // The retry latch is deliberately checked before store construction and
        // before RootStateLock. Pending and exhausted ticks are true no-ops.
        if let retry = rollbackRetry {
            guard retry.attempts < Self.rollbackAttemptLimit,
                  monotonicNow() >= retry.nextAttempt else { return }
        }
        tickStoreAttempts += 1
        guard let store = recoveryStoreFactory(configuration.supportDirectory) else {
            registerRollbackFailure(
                reason: rollbackRetry?.reason ?? "authority-unavailable",
                kind: .noPowerMutationAttempted,
                publishStatus: false
            )
            return
        }
        guard store.withTransaction({ transaction in
            self.tickLocked(session: session, store: store, transaction: transaction)
            return true
        }) == true else {
            registerRollbackFailure(
                reason: rollbackRetry?.reason ?? "authority-unavailable",
                kind: .noPowerMutationAttempted,
                publishStatus: false
            )
            return
        }
    }

    private func tickLocked(
        session: UUID,
        store: RecoveryAuthorityStore,
        transaction: VerifiedRootStateDirectory.Transaction
    ) {
        let revalidatingNoMutationRetry: Bool
        if let retry = rollbackRetry {
            switch retry.kind {
            case .noPowerMutationAttempted:
                // The exact terminal ledger proves no power mutation was
                // attempted before this retry. Retain that capability until the
                // authority and native state are both revalidated: a prior
                // pre-terminal failure may have published recovery-required
                // proof that only RecoveryCoordinator may consume on retry.
                revalidatingNoMutationRetry = true
            case .mutationUncertain:
                // Preserve bounded retry accounting/status cadence without
                // re-entering RecoveryCoordinator: its terminal path could
                // issue a second pmset command after an unproved first command.
                registerRollbackFailure(reason: retry.reason, kind: retry.kind, publishStatus: false)
                return
            }
        } else {
            revalidatingNoMutationRetry = false
        }
        guard let activePeer else {
            _ = restoreActive(reason: "peer-process-invalid", store: store, transaction: transaction)
            return
        }
        guard privateAuthorityMatches(expectedSession: session, peer: activePeer, expiry: expiry, store: store) else {
            _ = restoreActive(reason: "invalid-applied-state", store: store, transaction: transaction)
            return
        }
        if monotonicNow() >= expiry {
            _ = restoreActive(reason: "expired", store: store, transaction: transaction)
            return
        }
        guard peerIsLive(activePeer) else {
            _ = restoreActive(reason: "peer-process-invalid", store: store, transaction: transaction)
            return
        }
        if activeConnection == nil, let reconnectDeadline, monotonicNow() >= reconnectDeadline {
            _ = restoreActive(reason: "reconnect-expired", store: store, transaction: transaction)
            return
        }
        switch power.powerSource() {
        case .ac:
            consecutiveUnknownPowerReads = 0
        case .battery:
            _ = restoreActive(reason: "ac-disconnect", store: store, transaction: transaction)
            return
        case .unknown:
            consecutiveUnknownPowerReads += 1
            return
        }
        // A disconnected transport may only retain an exact authority and
        // exact owned power. It never spends the recovery budget or rearms.
        if activeConnection == nil {
            switch nativePowerObservation() {
            case .intact:
                if revalidatingNoMutationRetry { clearNoMutationRetryAfterExactRevalidation() }
            case .confirmedDrift:
                _ = restoreActive(reason: "reconnect-power-drift", store: store, transaction: transaction)
                return
            case .indeterminate:
                return
            }
            return
        }
        switch nativePowerObservation() {
        case .intact:
            if revalidatingNoMutationRetry { clearNoMutationRetryAfterExactRevalidation() }
            return
        case .confirmedDrift:
            // This is the one connected production tick that may spend the
            // owned one-time repair budget. The helper re-reads all native
            // values and exact private authority inside
            // `verifyOrRecoverOwnedState`; every other drift is terminal.
            if verifyOrRecoverOwnedState(
                sessionID: session,
                peer: activePeer,
                store: store,
                transaction: transaction
            ) {
                if revalidatingNoMutationRetry { clearNoMutationRetryAfterExactRevalidation() }
                return
            }
            _ = restoreActive(reason: "drift", store: store, transaction: transaction)
        case .indeterminate:
            return
        }
    }

    private func clearNoMutationRetryAfterExactRevalidation() {
        guard let retry = rollbackRetry,
              case .noPowerMutationAttempted = retry.kind
        else { return }
        rollbackRetry = nil
        recoveryRequired = false
    }

    private func ownedStateIsIntact() -> Bool {
        nativePowerObservation() == .intact
    }

    private func nativePowerObservation() -> NativePowerObservation {
        guard power.powerSource() == .ac,
              let disabled = power.sleepDisabled(),
              let ac = power.acSleepMinutes()
        else { return .indeterminate }
        return disabled && ac == 0 ? .intact : .confirmedDrift
    }

    private func persistRenewedExpiry(
        sessionID: UUID,
        peer: Peer,
        renewedExpiry: TimeInterval,
        store: RecoveryAuthorityStore,
        transaction: VerifiedRootStateDirectory.Transaction
    ) -> Bool {
        guard case let .privateAuthority(current) = store.appliedRecord(),
              privateAuthorityMatches(expected: current, peer: peer, expiry: expiry, store: store),
              current.sessionID == sessionID
        else { return false }
        guard let renewed = current.replacingLeaseExpiry(renewedExpiry) else { return false }
        guard appliedStatePublish(renewed, store, transaction).isVerified,
              privateAuthorityMatches(expected: renewed, peer: peer, expiry: renewedExpiry, store: store)
        else { return false }
        projectStatus(state: "active", reason: "renewed", sessionID: sessionID,
                      store: store, transaction: transaction)
        return true
    }

    /// The runner may return only after this exact transaction has accepted a
    /// root-private receipt.  The receipt itself becomes the cross-restart
    /// mutation fence; this closure never opens a nested RootStateLock.
    private func withContainmentReceipt<T>(
        store: RecoveryAuthorityStore,
        transaction: VerifiedRootStateDirectory.Transaction,
        _ body: () throws -> T
    ) rethrows -> T {
        try ContainedProcessRunner.withContainmentReceiptSink({ receipt in
            store.publishInitialContainmentReceipt(receipt, transaction)
        }, replace: { current, next in
            store.advanceContainmentReceipt(expected: current, next: next, transaction)
        }, release: { receipt in
            store.removeContainmentReceipt(expected: receipt, transaction) == .removed
        }, onAccepted: {
            transaction.afterUnlock {
                RecoveryCoordinator.scheduleContainmentCleanup(configuration: self.configuration)
            }
        }, body)
    }

    /// The public file is a status projection, never authority.  The dirty
    /// task is persisted before asynchronous I/O so a failed write cannot be
    /// mistaken for convergence or delay the caller's root transaction.
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
                                                 storeFactory: recoveryStoreFactory,
                                                 writer: statusProjectionWriter) else {
            // A public write may fail later, but failure to persist the dirty
            // intent is an authority failure now and must not be silent.
            _ = store.markRecoveryRequired("status-projection-enqueue-failed", transaction)
            return false
        }
        return true
    }

    @discardableResult
    private func projectStatus(state: String, reason: String, sessionID: UUID?) -> Bool {
        guard let store = recoveryStoreFactory(configuration.supportDirectory) else { return false }
        return store.withTransaction { transaction in
            projectStatus(state: state, reason: reason, sessionID: sessionID, store: store, transaction: transaction)
        } ?? false
    }

    private func verifyOrRecoverOwnedState(
        sessionID: UUID,
        peer: Peer,
        store: RecoveryAuthorityStore,
        transaction: VerifiedRootStateDirectory.Transaction
    ) -> Bool {
        guard power.powerSource() == .ac, let disabled = power.sleepDisabled(), let ac = power.acSleepMinutes() else { return false }
        if disabled && ac == 0 { return true }
        guard !disabled, ac == 0, successfulOverrideRecoveries == 0,
              privateAuthorityMatches(expectedSession: sessionID, peer: peer, expiry: expiry, store: store),
              store.recoveryBudgetRecord() == .absent,
              store.recordTerminal(
                sessionID,
                into: RecoveryAuthorityStore.reservationBasename,
                transaction: transaction
              ).isVerified,
              store.publishRecoveryBudget(
                RecoveryBudgetState(sessionID: sessionID, phase: .reserved),
                transaction
              ).isVerified,
              privateAuthorityMatches(
                expectedSession: sessionID,
                peer: peer,
                expiry: expiry,
                store: store,
                expectsRecoveryReservation: true
              )
        else { return false }
        do {
            try withContainmentReceipt(store: store, transaction: transaction) {
                try power.setSleepDisabled(true)
            }
        } catch HelperPowerMutationError.containmentPending {
            recoveryRequired = true
            return false
        } catch {
            // A contained runner timeout, truncation, or containment failure
            // cannot prove that pmset did not commit.  Never issue a second
            // setter: accept this one attempt only when a fresh exact native
            // observation proves the requested owned postcondition.
            guard power.sleepDisabled() == true,
                  power.acSleepMinutes() == 0,
                  privateAuthorityMatches(
                    expectedSession: sessionID,
                    peer: peer,
                    expiry: expiry,
                    store: store,
                    expectsRecoveryReservation: true
                  ),
                  store.publishRecoveryBudget(
                    RecoveryBudgetState(sessionID: sessionID, phase: .spent),
                    transaction
                  ).isVerified
            else { return false }
            successfulOverrideRecoveries = 1
            projectStatus(state: "active", reason: "override-recovered-after-indeterminate-runner",
                          sessionID: sessionID, store: store, transaction: transaction)
            return true
        }
        guard power.sleepDisabled() == true,
              power.acSleepMinutes() == 0,
              privateAuthorityMatches(
                expectedSession: sessionID,
                peer: peer,
                expiry: expiry,
                store: store,
                expectsRecoveryReservation: true
              ),
              store.publishRecoveryBudget(
                RecoveryBudgetState(sessionID: sessionID, phase: .spent),
                transaction
              ).isVerified
        else { return false }
        successfulOverrideRecoveries = 1
        projectStatus(state: "active", reason: "override-recovered", sessionID: sessionID,
                      store: store, transaction: transaction)
        return true
    }

    private func restoreActive(
        reason: String,
        result terminalResult: Int32 = 0,
        store: RecoveryAuthorityStore,
        transaction: VerifiedRootStateDirectory.Transaction
    ) -> AuthorityReply {
        guard let session = activeSession else {
            // RESTORE is idempotent. A peer retry after an AC disconnect (or
            // after helper restart) must surface the durable terminal session
            // and reason, not overwrite it with peer-restore/session=nil.
            if let lastTerminalSession {
                return snapshot(result: terminalResult, reason: lastTerminalReason, requested: lastTerminalSession)
            }
            return snapshot(result: terminalResult, reason: "idle", requested: Self.zeroUUID)
        }
        let priorRetry = rollbackRetry
        if let priorRetry {
            guard priorRetry.attempts < Self.rollbackAttemptLimit, monotonicNow() >= priorRetry.nextAttempt else {
                return snapshot(result: 75, reason: "rollback-pending", requested: session)
            }
            if case .mutationUncertain = priorRetry.kind {
                // Snapshot and RESTORE share this path. Neither may bypass the
                // no-second-setter fence after an indeterminate mutation.
                registerRollbackFailure(
                    reason: priorRetry.reason,
                    kind: .mutationUncertain,
                    publishStatus: false
                )
                return snapshot(result: 75, reason: "rollback-unverified", requested: session)
            }
        }
        let outcome = recoveryCoordinatorFactory().recoverWithinTransaction(
            store: store,
            transaction: transaction,
            intent: .userRestore,
            allowReconnect: false,
            terminalReason: reason,
            permitRecoveryRequiredRetry: priorRetry != nil
        )
#if DEBUG
        lastRollbackAssessment = outcome
#endif
        guard case let .terminalIdle(terminalSession, terminalReason) = outcome, terminalSession == session else {
            // RecoveryCoordinator records this exact session in the private
            // terminal ledger before its first power setter. A valid ledger
            // that still excludes the session therefore proves retry safety;
            // an unreadable ledger or current terminal receipt cannot.
            let retryKind: RollbackRetryKind
            if let terminalEntries = store.privateLedger(RecoveryAuthorityStore.terminalBasename),
               !terminalEntries.contains(session) {
                retryKind = .noPowerMutationAttempted
            } else {
                retryKind = .mutationUncertain
            }
            registerRollbackFailure(reason: reason, kind: retryKind, publishStatus: true)
            return snapshot(result: 75, reason: "rollback-unverified", requested: session)
        }
        activeSession = nil; activeConnection = nil; activePeer = nil; reconnectDeadline = nil; expiry = 0
        rollbackRetry = nil; recoveryRequired = false
        hydrateTerminal(session: session, reason: terminalReason)
        return snapshot(result: terminalResult, reason: terminalReason, requested: session)
    }

    private func registerAuthorityUnavailableIfActive() {
        guard activeSession != nil else { return }
        registerRollbackFailure(
            reason: rollbackRetry?.reason ?? "authority-unavailable",
            kind: .noPowerMutationAttempted,
            publishStatus: false
        )
    }

    private func registerRollbackFailure(
        reason: String,
        kind: RollbackRetryKind,
        publishStatus: Bool
    ) {
        recoveryRequired = true
        if let retry = rollbackRetry,
           retry.attempts >= Self.rollbackAttemptLimit || monotonicNow() < retry.nextAttempt {
            return
        }
        let attempt = min((rollbackRetry?.attempts ?? 0) + 1, Self.rollbackAttemptLimit)
        let delay = min(TimeInterval(1 << attempt), Self.rollbackMaximumBackoff)
        let effectiveKind: RollbackRetryKind
        switch (rollbackRetry?.kind, kind) {
        case (.some(.mutationUncertain), _), (_, .mutationUncertain):
            // Once any setter result is unproved, no earlier transient lock
            // classification may make the retry safe to re-enter. Mutation
            // uncertainty is an absorbing no-second-setter fence.
            effectiveKind = .mutationUncertain
        case (.some(.noPowerMutationAttempted), .noPowerMutationAttempted),
             (.none, .noPowerMutationAttempted):
            effectiveKind = .noPowerMutationAttempted
        }
        rollbackRetry = .init(
            kind: effectiveKind,
            reason: reason,
            attempts: attempt,
            nextAttempt: monotonicNow() + delay
        )
        if publishStatus, let session = activeSession {
            projectStatus(state: "recovery-required", reason: "\(reason)-rollback-unverified", sessionID: session)
        }
    }

    /// Exact private authority validation. Callers invoke this only while the
    /// shared RootStateLock transaction is held, so the applied state, both
    /// ledgers, proof, and process tuple form one serialized decision.
    private func privateAuthorityMatches(
        expectedSession: UUID,
        peer: Peer,
        expiry: TimeInterval,
        store: RecoveryAuthorityStore,
        expectsRecoveryReservation: Bool? = nil
    ) -> Bool {
        guard case let .privateAuthority(state) = store.appliedRecord(),
              state.sessionID == expectedSession
        else { return false }
        return privateAuthorityMatches(
            expected: state,
            peer: peer,
            expiry: expiry,
            store: store,
            expectsRecoveryReservation: expectsRecoveryReservation
        )
    }

    private func privateAuthorityMatches(
        expected: AppliedState,
        peer: Peer,
        expiry: TimeInterval,
        store: RecoveryAuthorityStore,
        expectsRecoveryReservation: Bool? = nil
    ) -> Bool {
        // During one locked repair `reserved` is a mutation fence, not a
        // completion claim, so either phase may satisfy this local continuity
        // check. Startup passes only its separately derived `spentBudget`,
        // preventing a crash-left reserved record from reauthorizing a setter.
        let expectsReservation = expectsRecoveryReservation ?? (successfulOverrideRecoveries == 1)
        guard expected.isReconnectable,
              expected.leaseExpiryMonotonic == expiry,
              let boot = bootIdentity(),
              expected.owner == Optional(peer.owner(bootID: boot)),
              peerIsLive(peer),
              store.appliedRecord() == .privateAuthority(expected),
              case let .privateAuthority(terminalEntries, _) = store.ledger(RecoveryAuthorityStore.terminalBasename),
              case let .privateAuthority(reservationEntries, _) = store.ledger(RecoveryAuthorityStore.reservationBasename),
              !terminalEntries.contains(expected.sessionID),
              reservationEntries.contains(expected.sessionID) == expectsReservation,
              recoveryBudgetMatches(
                store.recoveryBudgetRecord(),
                session: expected.sessionID,
                expectsReservation: expectsReservation
              ),
              case let .valid(proof) = store.proofRecord(),
              proof.kind != .recoveryRequired
        else { return false }
        switch proof.kind {
        case .pristine:
            return terminalEntries.isEmpty
        case .migrated:
            return terminalEntries.isEmpty && reservationEntries.isEmpty
        case .terminal:
            guard let prior = proof.sessionID, prior != expected.sessionID else { return false }
            return terminalEntries.last == prior
        case .recoveryRequired:
            return false
        }
    }

    private func recoveryBudgetMatches(
        _ record: RecoveryAuthorityStore.BudgetRecord,
        session: UUID,
        expectsReservation: Bool
    ) -> Bool {
        switch record {
        case .absent:
            return !expectsReservation
        case let .valid(budget):
            guard budget.sessionID == session else { return false }
            if expectsReservation {
                return budget.phase == .reserved || budget.phase == .spent
            }
            return false
        case .invalid:
            return false
        }
    }

    private func idleAuthorityAllowsBegin(sessionID: UUID, store: RecoveryAuthorityStore) -> Bool {
        guard store.appliedRecord() == .missing,
              case let .privateAuthority(terminalEntries, _) = store.ledger(RecoveryAuthorityStore.terminalBasename),
              case let .privateAuthority(reservationEntries, _) = store.ledger(RecoveryAuthorityStore.reservationBasename),
              !terminalEntries.contains(sessionID),
              !reservationEntries.contains(sessionID),
              case let .valid(proof) = store.proofRecord()
        else { return false }
        switch proof.kind {
        case .pristine:
            return terminalEntries.isEmpty && reservationEntries.isEmpty
        case .migrated:
            return terminalEntries.isEmpty && reservationEntries.isEmpty
        case .terminal:
            guard let prior = proof.sessionID else { return false }
            return terminalEntries.last == prior
        case .recoveryRequired:
            return false
        }
    }

    private func snapshot(result: Int32, reason: String, requested: UUID) -> AuthorityReply {
        let source = power.powerSource()
        let isPriorTerminal = activeSession == nil && lastTerminalSession == requested
        return AuthorityReply(result: result, reason: isPriorTerminal ? lastTerminalReason : reason, sessionID: activeSession ?? requested,
                              expiryMonotonic: activeSession == nil ? 0 : expiry,
                              // A rejected pristine/idle request is not a
                              // terminal authority claim. Only the exact
                              // retained terminal generation receives state 2.
                              state: recoveryRequired ? 3 : (activeSession == nil ? (isPriorTerminal ? 2 : 0) : 1),
                              power: source == .ac ? 1 : (source == .battery ? 2 : 0),
                              sleepDisabled: power.sleepDisabled() ?? false,
                              acSleepMinutes: power.acSleepMinutes() ?? -1)
    }

    private static let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    func reconcileForTesting() { tick() }
    var rollbackAttemptCountForTesting: Int {
        lock.lock(); defer { lock.unlock() }
        return rollbackRetry?.attempts ?? 0
    }
    var tickStoreAttemptCountForTesting: Int {
        lock.lock(); defer { lock.unlock() }
        return tickStoreAttempts
    }
    var rollbackNextAttemptForTesting: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return rollbackRetry?.nextAttempt
    }
#if DEBUG
    var lastRollbackAssessmentForTesting: RecoveryAssessment? {
        lock.lock(); defer { lock.unlock() }
        return lastRollbackAssessment
    }
    var lastPreparationAssessmentForTesting: RecoveryAssessment? { lastPreparationAssessment }
    var lastPreparationStageForTesting: String { lastPreparationStage }
#endif
}

struct AuthorityReply {
    let result: Int32; let reason: String; let sessionID: UUID; let expiryMonotonic: TimeInterval
    let state: UInt32; let power: UInt32; let sleepDisabled: Bool; let acSleepMinutes: Int
}

struct HelperControlServiceOperations: @unchecked Sendable {
    let provision: (HelperServiceConfiguration) -> RecoveryProvisionOutcome
    let recover: (HelperServiceConfiguration, RecoveryIntent) -> RecoveryAssessment
    let daemon: (HelperServiceConfiguration) -> Int32

    static let system = HelperControlServiceOperations(
        provision: { configuration in
            RecoveryCoordinator(configuration: configuration, power: SystemPowerSystem()).provision()
        },
        recover: { configuration, intent in
            RecoveryCoordinator(configuration: configuration, power: SystemPowerSystem())
                .recover(intent: intent, allowReconnect: false)
        },
        daemon: { configuration in HelperControlService.runDaemon(configuration: configuration) }
    )
}

enum HelperControlService {
    static func run(configuration: HelperServiceConfiguration) -> Int32 {
        execute(configuration: configuration, operations: .system).exitCode
    }

    static func run(
        configuration: HelperServiceConfiguration,
        operations: HelperControlServiceOperations
    ) -> Int32 {
        execute(configuration: configuration, operations: operations).exitCode
    }

    static func execute(
        configuration: HelperServiceConfiguration,
        operations: HelperControlServiceOperations = .system
    ) -> HelperServiceExecution {
        switch configuration.mode {
        case .provisionRootStateLock:
            switch operations.provision(configuration) {
            case .ready:
                return .oneShot(.provisionReady)
            case let .recoveryRequired(reason):
                return .oneShot(.internalFailure(reason: reason))
            }
        case let .recoverOnce(intent):
            switch operations.recover(configuration, intent) {
            case .pristineIdle:
                return .oneShot(.pristineIdle)
            case let .migratedIdle(reason):
                return .oneShot(.migratedIdle(reason: reason))
            case let .terminalIdle(session, reason):
                return .oneShot(.terminalIdle(sessionID: session, reason: reason))
            case let .recoveryRequired(reason):
                return .oneShot(.recoveryRequired(reason: reason))
            case .legacyRestoreOnly, .reconnectCandidate:
                return .oneShot(.internalFailure(reason: "invalid-one-shot-outcome"))
            }
        case .daemon:
            return .daemon(exitCode: operations.daemon(configuration))
        }
    }

    fileprivate static func runDaemon(configuration: HelperServiceConfiguration) -> Int32 {
        guard SystemBuild.current() == configuration.qualifiedBuild,
              let policy = loadPolicy(configuration), let current = HelperCodeIdentity.current(),
              current.identifier == policy.helperIdentifier, current.cdhash == policy.helperCDHash,
              policy.ownerUID == configuration.expectedOwnerUID,
              policy.qualifiedBuild == configuration.qualifiedBuild else { return 78 }
        let authority = HelperSessionAuthority(configuration: configuration, power: SystemPowerSystem())
        let clientPolicy = policy.appCDHash.withUnsafeBytes { buffer -> OpaquePointer? in
            if let team = policy.teamIdentifier {
                return team.withCString {
                    ls_identity_policy_create(policy.appIdentifier, buffer.bindMemory(to: UInt8.self).baseAddress,
                                              policy.appCDHash.count, uid_t(policy.ownerUID), LS_IDENTITY_DEVELOPER_ID_EXACT, $0)
                }
            }
            return ls_identity_policy_create(policy.appIdentifier, buffer.bindMemory(to: UInt8.self).baseAddress,
                                             policy.appCDHash.count, uid_t(policy.ownerUID), LS_IDENTITY_MANUAL_EXACT, nil)
        }
        guard let clientPolicy else { return 78 }
        defer { ls_identity_policy_release(clientPolicy) }
        let context = Unmanaged.passRetained(authority).toOpaque()
        defer { Unmanaged<HelperSessionAuthority>.fromOpaque(context).release() }
        return runPreparedDaemon(authority: authority) {
            Int32(ls_xpc_server_run(ReleaseIdentity.machService, clientPolicy, { context, connection, peer, operation, _, session, writer in
                // `peer` is bridge-owned callback storage. Copy it synchronously
                // into the authority; nothing in Swift retains that pointer.
                guard let context, let peer, let session, let writer, let sessionID = UUID(uuidString: String(cString: session)) else { return }
                BenchmarkProbe.record("xpc_authenticated_request")
                BenchmarkProbe.record("xpc_identity_ns", count: Int(clamping: ls_xpc_last_identity_duration_ns()))
                let authority = Unmanaged<HelperSessionAuthority>.fromOpaque(context).takeUnretainedValue()
                let reply = authority.handle(connection: connection, peer: peer.pointee, operation: operation, sessionID: sessionID)
                ls_reply_writer_set(writer, reply.result, reply.reason, reply.sessionID.uuidString.lowercased(),
                                    reply.expiryMonotonic, reply.state, reply.power, reply.sleepDisabled, Int32(reply.acSleepMinutes))
            }, { context, connection, invalidated in
                guard invalidated, let context else { return }
                Unmanaged<HelperSessionAuthority>.fromOpaque(context).takeUnretainedValue().connectionInvalidated(connection)
            }, context))
        }
    }

    static func runPreparedDaemon(
        authority: HelperSessionAuthority,
        listener: () -> Int32
    ) -> Int32 {
        switch authority.prepareBeforeListening() {
        case .ready:
            return listener() == 0 ? 0 : 78
        case .handledRecoveryRequired:
            return 0
        case .transientFailure:
            return 78
        }
    }

    private static func loadPolicy(_ configuration: HelperServiceConfiguration) -> EnrollmentPolicy? {
        let readPolicy = BoundedFileReadPolicy(maximumBytes: EnrollmentPolicy.maximumBytes, expectedOwnerUID: 0,
                                               requireSingleLink: true, rejectGroupOrWorldWritable: true,
                                               requireNonEmpty: true, safeParentDepth: 1)
        guard case let .success(raw) = BoundedFileReader.readUTF8(path: configuration.policyPath, policy: readPolicy) else { return nil }
        return EnrollmentPolicy.parse(raw)
    }
}

enum HelperServiceExecution: Equatable {
    case daemon(exitCode: Int32)
    case oneShot(HelperOneShotResult)

    var exitCode: Int32 {
        switch self {
        case let .daemon(exitCode): exitCode
        case let .oneShot(result): result.exitCode
        }
    }
}

private struct HelperCodeIdentity {
    let identifier: String; let cdhash: Data
    static func current() -> HelperCodeIdentity? {
        guard let raw = ls_copy_current_code_identity() else { return nil }
        defer { ls_code_identity_release(raw) }
        guard let identifier = ls_code_identity_identifier(raw), let bytes = ls_code_identity_cdhash(raw) else { return nil }
        let count = ls_code_identity_cdhash_length(raw)
        guard count == 20 else { return nil }
        return HelperCodeIdentity(identifier: String(cString: identifier), cdhash: Data(bytes: bytes, count: count))
    }
}
