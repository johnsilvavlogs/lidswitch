import Darwin
import Foundation
import LidSwitchCore

struct SessionHeartbeatObservation: Sendable {
    enum Power: Equatable, Sendable { case ac, disconnected, unknown }
    enum Authority: Equatable, Sendable { case verified, indeterminate, terminal(String) }

    let power: Power
    let authority: Authority
    let helperStatus: HelperStatusRecord?

    // Compatibility initializer for isolated existing fixtures. Production
    // supplies the explicit authority state and never turns a transport miss
    // into terminal truth.
    init(power: Power, leaseIsValid: Bool, helperStatus: HelperStatusRecord?) {
        self.power = power
        authority = leaseIsValid ? .verified : .indeterminate
        self.helperStatus = helperStatus
    }

    init(power: Power, authority: Authority, helperStatus: HelperStatusRecord?) {
        self.power = power
        self.authority = authority
        self.helperStatus = helperStatus
    }
}

/// A heartbeat only records a renewal after the helper has durably extended
/// the lease. RECONNECT is transport recovery, not authority advancement.
enum SessionHeartbeatAdvance: Equatable, Sendable {
    case renewed(expiryMonotonic: TimeInterval)
    case reconnected(originalExpiryMonotonic: TimeInterval)
    /// RECONNECT authenticated the generation but did not bind its new
    /// transport, so the next logical renewal must reconnect before RENEW.
    case reconnectedButUnbound(reason: String)
    /// Authenticated helper acceptance without a durable lease extension.
    case indeterminateNoAdvance(reason: String)
}

/// Normal heartbeat recovery may use the one client-owned reconnect allowance.
/// The immediate post-reconnect renewal is direct-only so it cannot rebind
/// transport a second time for the same logical heartbeat recovery.
enum SessionHeartbeatRenewalMode: Equatable, Sendable {
    case recoverTransportOnce
    case directOnly
}

final class SessionHeartbeatCoordinator: @unchecked Sendable {
    private enum Phase { case starting(deadlineMonotonic: TimeInterval), active, terminal }
    /// Captures the exact in-memory generation and hard deadline selected by a
    /// tick. The write-boundary observation must still match it before RENEW.
    private struct RenewalWritePermit: Sendable {
        let sessionID: UUID
        let generationVersion: UInt64
        let leaseExpiresMonotonic: TimeInterval
    }

    private let queue: DispatchQueue
    private let observationInterval: TimeInterval
    private let renewalInterval: TimeInterval
    private let acknowledgementTimeout: TimeInterval
    private let now: @Sendable () -> Date
    private let monotonicNow: @Sendable () -> TimeInterval
    private let observe: @Sendable (UUID) -> SessionHeartbeatObservation
    private let renew: @Sendable (UUID, SessionHeartbeatRenewalMode, @escaping @Sendable () -> Bool) throws -> SessionHeartbeatAdvance
    private let revoke: @Sendable () -> Void
    private let endRemote: @Sendable (UUID, String) -> Void
    private let diagnostics: SessionDiagnosticStore
    private let onAcknowledged: @Sendable (UUID) -> Void
    private let onEnded: @Sendable (UUID, String) -> Void

    private var timer: DispatchSourceTimer?
    private var sessionID: UUID?
    private var phase: Phase = .terminal
    private var nextRenewalMonotonic = TimeInterval.greatestFiniteMagnitude
    private var leaseExpiresMonotonic = TimeInterval.greatestFiniteMagnitude
    private var generationVersion: UInt64 = 0
    private var lastRecoveryAcknowledgement: String?
    private var projectionUnavailableIsRecorded = false

    init(
        observationInterval: TimeInterval = 1,
        renewalInterval: TimeInterval = 8,
        acknowledgementTimeout: TimeInterval = 20,
        queueLabel: String = "com.johnsilva.lidswitch.session-heartbeat",
        now: @escaping @Sendable () -> Date = Date.init,
        monotonicNow: @escaping @Sendable () -> TimeInterval = MonotonicClock.seconds,
        observe: @escaping @Sendable (UUID) -> SessionHeartbeatObservation,
        renew: @escaping @Sendable (UUID, SessionHeartbeatRenewalMode, @escaping @Sendable () -> Bool) throws -> SessionHeartbeatAdvance,
        revoke: @escaping @Sendable () -> Void,
        endRemote: @escaping @Sendable (UUID, String) -> Void = { _, _ in },
        diagnostics: SessionDiagnosticStore = .shared,
        onAcknowledged: @escaping @Sendable (UUID) -> Void,
        onEnded: @escaping @Sendable (UUID, String) -> Void
    ) {
        self.observationInterval = observationInterval
        self.renewalInterval = renewalInterval
        self.acknowledgementTimeout = acknowledgementTimeout
        queue = DispatchQueue(label: queueLabel, qos: .userInitiated)
        self.now = now
        self.monotonicNow = monotonicNow
        self.observe = observe
        self.renew = renew
        self.revoke = revoke
        self.endRemote = endRemote
        self.diagnostics = diagnostics
        self.onAcknowledged = onAcknowledged
        self.onEnded = onEnded
    }

    /// Existing isolated fixtures do not model wire mode. Production uses the
    /// mode-aware initializer above; this adapter keeps their mock behavior
    /// stable while the coordinator still exercises its state transitions.
    convenience init(
        observationInterval: TimeInterval = 1,
        renewalInterval: TimeInterval = 8,
        acknowledgementTimeout: TimeInterval = 20,
        queueLabel: String = "com.johnsilva.lidswitch.session-heartbeat",
        now: @escaping @Sendable () -> Date = Date.init,
        monotonicNow: @escaping @Sendable () -> TimeInterval = MonotonicClock.seconds,
        observe: @escaping @Sendable (UUID) -> SessionHeartbeatObservation,
        renew: @escaping @Sendable (UUID, @escaping @Sendable () -> Bool) throws -> SessionHeartbeatAdvance,
        revoke: @escaping @Sendable () -> Void,
        endRemote: @escaping @Sendable (UUID, String) -> Void = { _, _ in },
        diagnostics: SessionDiagnosticStore = .shared,
        onAcknowledged: @escaping @Sendable (UUID) -> Void,
        onEnded: @escaping @Sendable (UUID, String) -> Void
    ) {
        self.init(
            observationInterval: observationInterval,
            renewalInterval: renewalInterval,
            acknowledgementTimeout: acknowledgementTimeout,
            queueLabel: queueLabel,
            now: now,
            monotonicNow: monotonicNow,
            observe: observe,
            renew: { sessionID, _, commitGuard in try renew(sessionID, commitGuard) },
            revoke: revoke,
            endRemote: endRemote,
            diagnostics: diagnostics,
            onAcknowledged: onAcknowledged,
            onEnded: onEnded
        )
    }

    /// Compatibility adapter for pre-v2 fixture callers. Production uses the
    /// typed initializer above; this adapter cannot manufacture reconnect
    /// truth and therefore maps fixture values only to real renewals.
    convenience init(
        observationInterval: TimeInterval = 1,
        renewalInterval: TimeInterval = 8,
        acknowledgementTimeout: TimeInterval = 20,
        queueLabel: String = "com.johnsilva.lidswitch.session-heartbeat",
        now: @escaping @Sendable () -> Date = Date.init,
        monotonicNow: @escaping @Sendable () -> TimeInterval = MonotonicClock.seconds,
        observe: @escaping @Sendable (UUID) -> SessionHeartbeatObservation,
        renew: @escaping @Sendable (UUID, @escaping @Sendable () -> Bool) throws -> TimeInterval,
        revoke: @escaping @Sendable () -> Void,
        endRemote: @escaping @Sendable (UUID, String) -> Void = { _, _ in },
        diagnostics: SessionDiagnosticStore = .shared,
        onAcknowledged: @escaping @Sendable (UUID) -> Void,
        onEnded: @escaping @Sendable (UUID, String) -> Void
    ) {
        self.init(observationInterval: observationInterval, renewalInterval: renewalInterval,
                  acknowledgementTimeout: acknowledgementTimeout, queueLabel: queueLabel,
                  now: now, monotonicNow: monotonicNow, observe: observe,
                  renew: { id, guardCommit in
                      .renewed(expiryMonotonic: try renew(id, guardCommit))
                  }, revoke: revoke, endRemote: endRemote, diagnostics: diagnostics,
                  onAcknowledged: onAcknowledged, onEnded: onEnded)
    }

    func start(sessionID: UUID, initialLeaseExpiresMonotonic: TimeInterval, initiallyAcknowledged: Bool = false) {
        queue.sync {
            cancelTimer()
            let startedMonotonic = monotonicNow()
            generationVersion &+= 1
            self.sessionID = sessionID
            lastRecoveryAcknowledgement = nil
            projectionUnavailableIsRecorded = false
            phase = initiallyAcknowledged ? .active : .starting(deadlineMonotonic: startedMonotonic + acknowledgementTimeout)
            nextRenewalMonotonic = startedMonotonic + renewalInterval
            leaseExpiresMonotonic = initialLeaseExpiresMonotonic
            diagnostics.record(event: "start", reason: "lease-issued", sessionID: sessionID)
            if initiallyAcknowledged { onAcknowledged(sessionID) }

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now() + observationInterval,
                repeating: observationInterval,
                leeway: .milliseconds(100)
            )
            timer.setEventHandler { [weak self] in self?.evaluate() }
            self.timer = timer
            timer.resume()
        }
    }

    @discardableResult
    func stop(reason: String) -> Bool {
        queue.sync {
            guard let sessionID, !isTerminal else { return true }
            return finish(sessionID: sessionID, reason: reason, notify: false)
        }
    }

    func evaluateForTesting() {
        queue.sync { evaluate() }
    }

    private var isTerminal: Bool {
        if case .terminal = phase { return true }
        return false
    }

    private func evaluate() {
        guard let sessionID, !isTerminal else { return }
        let checkedMonotonic = monotonicNow()
        let observation = observe(sessionID)
        if finishIfTerminalObservation(observation, sessionID: sessionID) {
            return
        }
        let matchingStatus = matchingStatus(in: observation, sessionID: sessionID)

        let hasFreshActiveProjection = matchingStatus?.state == "active"
            && matchingStatus?.isFresh(at: now()) == true
        if !hasFreshActiveProjection, !projectionUnavailableIsRecorded {
            // Projection loss is useful operator context, not renewal or
            // terminal authority. Record it once per in-memory generation so
            // it cannot turn a short-lived writer fault into diagnostic spam.
            diagnostics.record(event: "degraded", reason: "helper-projection-unavailable", sessionID: sessionID)
            projectionUnavailableIsRecorded = true
        }

        // Native disconnect remains immediate remote rollback. A hard lease
        // expiry is different: the helper's own expiry path already owns the
        // rollback, so local terminalization must not send a late RESTORE.
        if finishIfHardExpiry(sessionID: sessionID, at: checkedMonotonic) {
            return
        }
        switch observation.power {
        case .ac:
            break
        case .disconnected:
            // Handled above so disconnect retains its immediate RESTORE even
            // when the same tick observes a locally expired lease.
            return
        case .unknown:
            // Unknown app-side power is not terminal evidence. Withhold RENEW
            // and let the helper's existing hard lease bound rollback; an AC
            // sample before expiry may continue this exact generation.
            return
        }
        if let matchingStatus,
           matchingStatus.state == "active",
           matchingStatus.reason == "override-recovered",
           matchingStatus.isFresh(at: now()),
           lastRecoveryAcknowledgement != "\(sessionID.uuidString)-\(matchingStatus.updatedAt.timeIntervalSince1970)"
        {
            lastRecoveryAcknowledgement = "\(sessionID.uuidString)-\(matchingStatus.updatedAt.timeIntervalSince1970)"
            diagnostics.record(event: "recovered", reason: "override-recovered", sessionID: sessionID)
            onAcknowledged(sessionID)
        }

        switch phase {
        case let .starting(deadlineMonotonic):
            if let matchingStatus,
               matchingStatus.state == "active",
               matchingStatus.isFresh(at: now())
            {
                phase = .active
                diagnostics.record(event: "acknowledged", reason: "helper-active", sessionID: sessionID)
                onAcknowledged(sessionID)
            } else if checkedMonotonic >= deadlineMonotonic {
                finish(sessionID: sessionID, reason: "acknowledgement-timeout", notify: true)
                return
            } else {
                // The initial lease remains valid until its own monotonic
                // expiry, but an unacknowledged generation is never renewed.
                return
            }
        case .active: break
        case .terminal:
            return
        }

        guard checkedMonotonic >= nextRenewalMonotonic else { return }
        // Indeterminate transport/power truth never renews. It remains inside
        // the helper-chosen expiry instead of converting one missed probe into
        // a local RESTORE.
        guard case .verified = observation.authority else {
            nextRenewalMonotonic = min(checkedMonotonic + observationInterval, leaseExpiresMonotonic)
            return
        }
        guard let permit = renewalWritePermit(for: sessionID) else { return }
        do {
            let advance = try renew(sessionID, .recoverTransportOnce) { [weak self] in
                self?.commitAllowed(permit) == true
            }
            try applyLeaseAdvance(advance, sessionID: sessionID)
        } catch {
            // The client validates rejection binding before exposing its
            // reason; nevertheless a rejected transport response is not a
            // terminal fact until durable helper status or expiry confirms it.
            guard !isTerminal else { return }
            nextRenewalMonotonic = min(monotonicNow() + observationInterval, leaseExpiresMonotonic)
        }
    }

    private func applyLeaseAdvance(_ advance: SessionHeartbeatAdvance, sessionID: UUID) throws {
        switch advance {
        case let .renewed(expiryMonotonic):
            // A valid authenticated reply still cannot move this generation's
            // local hard deadline backwards or leave it unchanged.
            guard expiryMonotonic > leaseExpiresMonotonic else {
                nextRenewalMonotonic = min(monotonicNow() + observationInterval, leaseExpiresMonotonic)
                return
            }
            let issuedMonotonic = monotonicNow()
            nextRenewalMonotonic = issuedMonotonic + renewalInterval
            leaseExpiresMonotonic = expiryMonotonic
            diagnostics.recordRenewal(reason: "safety-probes-valid", sessionID: sessionID)
        case .indeterminateNoAdvance:
            // The authenticated helper response deliberately retained its old
            // hard deadline. Preserve that deadline and never record a false
            // renewal, issue BEGIN, or convert uncertainty into RESTORE.
            nextRenewalMonotonic = min(monotonicNow() + observationInterval, leaseExpiresMonotonic)
        case .reconnectedButUnbound:
            // The helper authenticated this generation but deliberately did
            // not bind the new connection. Do not direct-RENEW; a later normal
            // logical cycle will spend its one reconnect allowance first.
            nextRenewalMonotonic = min(monotonicNow() + observationInterval, leaseExpiresMonotonic)
        case let .reconnected(originalExpiryMonotonic):
            // Never replace the in-memory hard deadline with a reconnect
            // baseline until it is proved non-regressing. A greater baseline
            // can represent a lost successful RENEW; equal is merely a rebind.
            let preReconnectExpiry = leaseExpiresMonotonic
            guard originalExpiryMonotonic >= preReconnectExpiry else {
                nextRenewalMonotonic = min(monotonicNow() + observationInterval, preReconnectExpiry)
                return
            }
            // A strictly greater, exact-generation reconnect baseline is the
            // authenticated evidence of a reply-lost prior renewal. Retain it
            // as the hard deadline, but do not record a new local renewal: the
            // immediate direct RENEW still has to prove a further advancement.
            if originalExpiryMonotonic > preReconnectExpiry {
                leaseExpiresMonotonic = originalExpiryMonotonic
            }
            // Re-observe before exactly one direct-only RENEW. The raw client
            // already spent the single reconnect allowance to reach this case.
            let reobserved = observe(sessionID)
            if finishIfTerminalObservation(reobserved, sessionID: sessionID) {
                return
            }
            let reobservedMonotonic = monotonicNow()
            if finishIfHardExpiry(sessionID: sessionID, at: reobservedMonotonic) {
                return
            }
            guard reobserved.power == .ac, case .verified = reobserved.authority,
                  let permit = renewalWritePermit(for: sessionID) else {
                nextRenewalMonotonic = min(monotonicNow() + observationInterval, leaseExpiresMonotonic)
                return
            }
            let immediate = try renew(sessionID, .directOnly) { [weak self] in
                self?.commitAllowed(permit) == true
            }
            switch immediate {
            case let .renewed(expiryMonotonic):
                // A delayed direct reply cannot commit below the reconnect
                // baseline or merely equal the pre-reconnect deadline.
                guard expiryMonotonic > originalExpiryMonotonic,
                      expiryMonotonic > preReconnectExpiry else {
                    nextRenewalMonotonic = min(monotonicNow() + observationInterval, leaseExpiresMonotonic)
                    return
                }
                let issuedMonotonic = monotonicNow()
                nextRenewalMonotonic = issuedMonotonic + renewalInterval
                leaseExpiresMonotonic = expiryMonotonic
                diagnostics.recordRenewal(reason: "safety-probes-valid", sessionID: sessionID)
            case .indeterminateNoAdvance:
                // The direct request did not advance. Preserve the current
                // (possibly reply-lost recovered) deadline and do not turn a
                // no-advance reply into a newly recorded success.
                nextRenewalMonotonic = min(monotonicNow() + observationInterval, leaseExpiresMonotonic)
            case .reconnectedButUnbound:
                // A direct-only call must never consume another reconnect.
                // Preserve the deadline and let the next normal cycle recover.
                nextRenewalMonotonic = min(monotonicNow() + observationInterval, leaseExpiresMonotonic)
            case .reconnected:
                // Direct-only RENEW must never recursively reconnect. Treat an
                // unexpected fixture/protocol result as no commit.
                nextRenewalMonotonic = min(monotonicNow() + observationInterval, leaseExpiresMonotonic)
            }
        }
    }

    private func renewalWritePermit(for sessionID: UUID) -> RenewalWritePermit? {
        guard self.sessionID == sessionID,
              !isTerminal
        else { return nil }
        return RenewalWritePermit(
            sessionID: sessionID,
            generationVersion: generationVersion,
            leaseExpiresMonotonic: leaseExpiresMonotonic
        )
    }

    private func commitAllowed(_ permit: RenewalWritePermit) -> Bool {
        guard self.sessionID == permit.sessionID,
              !isTerminal,
              generationVersion == permit.generationVersion,
              leaseExpiresMonotonic == permit.leaseExpiresMonotonic
        else { return false }
        // This is the sole per-write native observation. The permit prevents a
        // delayed closure from reusing a tick after a generation/expiry change.
        // Fresh terminal authority must resolve here, rather than becoming a
        // rejected RENEW that the caller merely schedules for another tick.
        let observation = observe(permit.sessionID)
        if finishIfTerminalObservation(observation, sessionID: permit.sessionID) {
            return false
        }
        guard observation.power == .ac,
              case .verified = observation.authority
        else { return false }
        guard self.sessionID == permit.sessionID,
              !isTerminal,
              generationVersion == permit.generationVersion,
              leaseExpiresMonotonic == permit.leaseExpiresMonotonic
        else { return false }
        // One final clock sample owns the hard-expiry decision after the fresh
        // observation and exact permit revalidation. No later comparison may
        // silently turn this false into an unterminalized no-wire outcome.
        let finalBoundaryMonotonic = monotonicNow()
        if finishIfHardExpiry(sessionID: permit.sessionID, at: finalBoundaryMonotonic) {
            return false
        }
        return true
    }

    private func matchingStatus(
        in observation: SessionHeartbeatObservation,
        sessionID: UUID
    ) -> HelperStatusRecord? {
        observation.helperStatus.flatMap { status in
            status.sessionID == sessionID ? status : nil
        }
    }

    /// Terminal authority is the only status-file use that can end a live
    /// generation. Active and inactive projections remain diagnostic; they
    /// cannot veto an authenticated RENEW merely because a writer is delayed.
    @discardableResult
    private func finishIfTerminalObservation(
        _ observation: SessionHeartbeatObservation,
        sessionID: UUID
    ) -> Bool {
        if let matchingStatus = matchingStatus(in: observation, sessionID: sessionID),
           matchingStatus.state == "terminal",
           matchingStatus.isFresh(at: now())
        {
            finish(
                sessionID: sessionID,
                reason: "helper-\(normalized(matchingStatus.state))-\(normalized(matchingStatus.reason))",
                notify: true
            )
            return true
        }
        if case let .terminal(reason) = observation.authority {
            finish(sessionID: sessionID, reason: "helper-terminal-\(normalized(reason))", notify: true)
            return true
        }
        if observation.power == .disconnected {
            finish(sessionID: sessionID, reason: "power-disconnected", notify: true)
            return true
        }
        return false
    }

    @discardableResult
    private func finishIfHardExpiry(sessionID: UUID, at sampledMonotonic: TimeInterval) -> Bool {
        guard sampledMonotonic >= leaseExpiresMonotonic else { return false }
        finish(
            sessionID: sessionID,
            reason: "lease-expired-before-renewal",
            notify: true,
            performRemoteEffect: false
        )
        return true
    }

    @discardableResult
    private func finish(
        sessionID: UUID,
        reason: String,
        notify: Bool,
        performRemoteEffect: Bool = true
    ) -> Bool {
        guard !isTerminal else { return true }
        // The terminal latch is deliberately first: it invalidates every
        // renewal commit before the authoritative END/RESTORE exchange.
        phase = .terminal
        generationVersion &+= 1
        cancelTimer()
        // There is one authoritative remote termination per generation. END is
        // reserved for an explicit user stop; every safety-driven termination
        // is one RESTORE. Calling both overwrote terminal truth and could send a
        // second restore after the helper had already recorded the first cause.
        if performRemoteEffect {
            if reason == "user-end" {
                endRemote(sessionID, reason)
            } else {
                revoke()
            }
        }
        diagnostics.record(event: "end", reason: reason, sessionID: sessionID)
        // A terminal callback is a publication barrier, not merely a UI
        // notification. Failed diagnostics stay queued for retry and are
        // observable through this Bool, but never delay the safety rollback.
        let diagnosticsFlushed = diagnostics.flushStructuralSynchronously()
        // Do not release coordinator ownership before its start/end structural
        // evidence has either become durable or remained explicitly queued.
        self.sessionID = nil
        if notify { onEnded(sessionID, reason) }
        return diagnosticsFlushed
    }

    private func cancelTimer() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    private func normalized(_ raw: String) -> String {
        let safe = raw.lowercased().map { character -> Character in
            character.isLetter || character.isNumber || character == "-" ? character : "-"
        }
        return String(safe.prefix(48))
    }
}

struct SessionDiagnosticEntry: Codable, Equatable, Sendable {
    /// Stable across retries. A post-rename durability error is ambiguous: the
    /// file may already contain this event even though publication returned an
    /// error, so retry merging keys on this identifier rather than appending.
    let id: String
    let schema: Int
    let timestamp: Date
    let sessionID: String
    let event: String
    let reason: String
    let appVersion: String
    let appBuild: String
    /// Present only for compact periodic renewal records; schema-1 structural
    /// entries remain backwards-decodable without it.
    let renewalCount: Int?

    private enum CodingKeys: String, CodingKey {
        case id, schema, timestamp, sessionID, event, reason, appVersion, appBuild, renewalCount
    }

    init(
        id: String = UUID().uuidString.lowercased(),
        schema: Int,
        timestamp: Date,
        sessionID: String,
        event: String,
        reason: String,
        appVersion: String,
        appBuild: String,
        renewalCount: Int?
    ) {
        self.id = id
        self.schema = schema
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.event = event
        self.reason = reason
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.renewalCount = renewalCount
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decode(Int.self, forKey: .schema)
        timestamp = try values.decode(Date.self, forKey: .timestamp)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        event = try values.decode(String.self, forKey: .event)
        reason = try values.decode(String.self, forKey: .reason)
        appVersion = try values.decode(String.self, forKey: .appVersion)
        appBuild = try values.decode(String.self, forKey: .appBuild)
        renewalCount = try values.decodeIfPresent(Int.self, forKey: .renewalCount)
        // Schema-1 artifacts predate explicit IDs. Give them a deterministic
        // legacy identity so a later retry does not duplicate their payload.
        id = try values.decodeIfPresent(String.self, forKey: .id)
            ?? "legacy:\(schema):\(timestamp.timeIntervalSince1970):\(sessionID):\(event):\(reason):\(renewalCount ?? 0)"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(schema, forKey: .schema)
        try values.encode(timestamp, forKey: .timestamp)
        try values.encode(sessionID, forKey: .sessionID)
        try values.encode(event, forKey: .event)
        try values.encode(reason, forKey: .reason)
        try values.encode(appVersion, forKey: .appVersion)
        try values.encode(appBuild, forKey: .appBuild)
        try values.encodeIfPresent(renewalCount, forKey: .renewalCount)
    }
}

enum SessionDiagnosticRetryLifetimePolicy: Sendable {
    /// The app-owned singleton has an external process lifetime and may retain
    /// bounded backoff retries until diagnostics storage becomes available.
    case singletonPersistent
    /// Injected stores retain an accepted active attempt, but a delayed retry
    /// is weak/cancellable once their external owner releases them.
    case externalOwner
}

final class SessionDiagnosticStore: @unchecked Sendable {
    static let shared = SessionDiagnosticStore(
        file: AppPaths.sessionHistoryFile,
        retryLifetimePolicy: .singletonPersistent
    )

    private let lock = NSLock()
    private let file: URL
    private let maximumEntries: Int
    private let maximumBytes: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let now: @Sendable () -> Date
    private let writeObserver: @Sendable () -> Void
    private let publisher: (@Sendable (Data) throws -> Void)?
    private let renewalFlushInterval: TimeInterval
    private let retryLifetimePolicy: SessionDiagnosticRetryLifetimePolicy
    private let beforeDrain: @Sendable () -> Void
    private let onDeinit: @Sendable () -> Void
    private var pendingRenewals: [String: (sessionID: UUID, count: Int, reason: String)] = [:]
    private var pendingRenewalWindowStartedAt: Date?
    private let writerQueue = DispatchQueue(label: "com.johnsilva.lidswitch.session-diagnostics.writer", qos: .utility)
    private var writeScheduled = false
    private var structuralEvents: [SessionDiagnosticEntry] = []
    private let writerSpecific = DispatchSpecificKey<UInt8>()
    private var retryDelay: TimeInterval = 0.1

    init(
        file: URL,
        maximumEntries: Int = 200,
        maximumBytes: Int = 128 * 1_024,
        renewalFlushInterval: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = Date.init,
        writeObserver: @escaping @Sendable () -> Void = {},
        publisher: (@Sendable (Data) throws -> Void)? = nil,
        retryLifetimePolicy: SessionDiagnosticRetryLifetimePolicy = .externalOwner,
        beforeDrain: @escaping @Sendable () -> Void = {},
        onDeinit: @escaping @Sendable () -> Void = {}
    ) {
        self.file = file
        self.maximumEntries = max(1, maximumEntries)
        self.maximumBytes = max(1_024, maximumBytes)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.renewalFlushInterval = max(1, renewalFlushInterval)
        self.now = now
        self.writeObserver = writeObserver
        self.publisher = publisher
        self.retryLifetimePolicy = retryLifetimePolicy
        self.beforeDrain = beforeDrain
        self.onDeinit = onDeinit
        writerQueue.setSpecific(key: writerSpecific, value: 1)
    }

    deinit {
        // No queue synchronization here: deinitialization may occur from the
        // writer itself. External-owner delayed retries use weak capture, so
        // this is a cancellation boundary rather than a queue teardown.
        onDeinit()
    }

    func record(event: String, reason: String, sessionID: UUID) {
        lock.lock()
        let timestamp = now()
        // A structural fact is a causal boundary: any preceding renewal
        // aggregate must be materialized before this start/ack/end event.
        materializePendingRenewalsUnlocked(at: timestamp)
        structuralEvents.append(makeEntry(event: event, reason: reason, sessionID: sessionID, timestamp: timestamp))
        scheduleWriteUnlocked()
        lock.unlock()
    }

    /// The heartbeat remains at its eight-second safety cadence; only its
    /// routine diagnostics are coalesced in memory and flushed at most every
    /// five minutes. Structural and terminal events still use `record`.
    func recordRenewal(reason: String, sessionID: UUID) {
        lock.lock()
        let timestamp = now()
        let key = sessionID.uuidString.lowercased()
        let pending = pendingRenewals[key]
        pendingRenewals[key] = (sessionID, (pending?.count ?? 0) + 1, sanitize(reason))
        if pendingRenewalWindowStartedAt == nil {
            pendingRenewalWindowStartedAt = timestamp
            lock.unlock()
            return
        }
        guard timestamp.timeIntervalSince(pendingRenewalWindowStartedAt!) >= renewalFlushInterval else {
            lock.unlock()
            return
        }
        // Interval-driven materialization is the only renewal path that
        // schedules a write without a following structural event.
        materializePendingRenewalsUnlocked(at: timestamp)
        scheduleWriteUnlocked()
        lock.unlock()
    }

    func entries() -> [SessionDiagnosticEntry] {
        if DispatchQueue.getSpecific(key: writerSpecific) != nil {
            return loadUnlocked()
        }
        return writerQueue.sync {
            drainPendingWrites()
            return loadUnlocked()
        }
    }

    @discardableResult
    func flushForTesting() -> Bool {
        if DispatchQueue.getSpecific(key: writerSpecific) != nil {
            return drainPendingWrites(materializingPendingRenewals: true)
        }
        return writerQueue.sync {
            return drainPendingWrites(materializingPendingRenewals: true)
        }
    }

    /// Drains structural events synchronously. `false` means publication
    /// failed and the exact drained structural entries remain queued for the
    /// independent retry writer; callers must not mistake it for a rollback
    /// failure.
    @discardableResult
    func flushStructuralSynchronously() -> Bool {
        flushSynchronously()
    }

    private func flushSynchronously() -> Bool {
        if DispatchQueue.getSpecific(key: writerSpecific) != nil {
            return drainPendingWrites()
        } else {
            return writerQueue.sync { self.drainPendingWrites() }
        }
    }

    private func scheduleWriteUnlocked() {
        guard !writeScheduled else { return }
        writeScheduled = true
        // Accepted writes intentionally retain this store. There is no
        // implicit cancellation policy for structural evidence: a store can
        // deallocate only after its accepted queue work has attempted publish.
        writerQueue.async {
            self.beforeDrain()
            _ = self.drainPendingWrites()
        }
    }

    @discardableResult
    private func drainPendingWrites(materializingPendingRenewals: Bool = false) -> Bool {
        lock.lock()
        if materializingPendingRenewals {
            materializePendingRenewalsUnlocked(at: now())
        }
        var events = structuralEvents
        structuralEvents.removeAll(keepingCapacity: true)
        writeScheduled = false
        lock.unlock()
        guard !events.isEmpty else { return true }
        // All filesystem reads, JSON decoding, compaction, and publication run
        // after releasing the handoff lock. The heartbeat only ever appends a
        // bounded in-memory event, even while a slow disk is unavailable.
        let entries = mergedEntries(loadUnlocked(), adding: events)
        let persisted = persist(entries)
        lock.lock()
        if persisted {
            retryDelay = 0.1
            if !structuralEvents.isEmpty { scheduleWriteUnlocked() }
            lock.unlock()
            return true
        } else {
            // Publish failure is non-authoritative but lossless: retain the
            // drained structural and renewal summaries in their original
            // order and retry from the independent writer. Renewals are
            // coalesced before they reach this queue; structural events never
            // drop merely because a publisher is unavailable.
            structuralEvents = events + structuralEvents
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, 5)
            writeScheduled = true
            switch retryLifetimePolicy {
            case .singletonPersistent:
                writerQueue.asyncAfter(deadline: .now() + delay) {
                    _ = self.drainPendingWrites()
                }
            case .externalOwner:
                writerQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    _ = self?.drainPendingWrites()
                }
            }
            lock.unlock()
            return false
        }
    }

    private func loadUnlocked() -> [SessionDiagnosticEntry] {
        let policy = BoundedFileReadPolicy(
            maximumBytes: maximumBytes, expectedOwnerUID: getuid(), requireSingleLink: true,
            rejectGroupOrWorldWritable: true, requireNonEmpty: false, safeParentDepth: 1
        )
        guard case let .success(raw) = BoundedFileReader.readUTF8(path: file.path, policy: policy) else { return [] }
        let data = Data(raw.utf8)
        return (try? decoder.decode([SessionDiagnosticEntry].self, from: data)) ?? []
    }

    private func makeEntry(event: String, reason: String, sessionID: UUID, timestamp: Date) -> SessionDiagnosticEntry {
        SessionDiagnosticEntry(
            schema: 1, timestamp: timestamp, sessionID: sessionID.uuidString.lowercased(),
            event: sanitize(event), reason: sanitize(reason), appVersion: AppPaths.appVersion,
            appBuild: AppPaths.appBuild, renewalCount: nil
        )
    }

    private func materializePendingRenewalsUnlocked(at timestamp: Date) {
        guard !pendingRenewals.isEmpty else { return }
        for pending in pendingRenewals.values.sorted(by: { $0.sessionID.uuidString < $1.sessionID.uuidString }) {
            structuralEvents.append(SessionDiagnosticEntry(
                schema: 2, timestamp: timestamp, sessionID: pending.sessionID.uuidString.lowercased(),
                event: "renew-summary", reason: pending.reason, appVersion: AppPaths.appVersion,
                appBuild: AppPaths.appBuild, renewalCount: pending.count
            ))
        }
        pendingRenewals.removeAll()
        pendingRenewalWindowStartedAt = nil
    }

    private func mergedEntries(
        _ persisted: [SessionDiagnosticEntry],
        adding pending: [SessionDiagnosticEntry]
    ) -> [SessionDiagnosticEntry] {
        var seenIDs = Set<String>()
        var merged: [SessionDiagnosticEntry] = []
        for entry in persisted + pending where seenIDs.insert(entry.id).inserted {
            merged.append(entry)
        }
        return merged
    }

    @discardableResult
    private func persist(_ rawEntries: [SessionDiagnosticEntry]) -> Bool {
        var entries = rawEntries
        while entries.count > maximumEntries { evictOne(from: &entries) }
        var data = (try? encoder.encode(entries)) ?? Data("[]".utf8)
        while data.count > maximumBytes, entries.count > 1 {
            evictOne(from: &entries)
            data = (try? encoder.encode(entries)) ?? Data("[]".utf8)
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let publisher { try publisher(data) } else { try publishOwnerOnly(data) }
            BenchmarkProbe.record("diagnostic_write")
            writeObserver()
            return true
        } catch {
            // Diagnostics must never interfere with the safety state machine;
            // the caller requeues the exact drained event sequence.
            return false
        }
    }

    private func evictOne(from entries: inout [SessionDiagnosticEntry]) {
        // Migration-era schema-1 `renew` rows are obsolete per-renewal noise.
        // Retire them before compact summaries so a cap-full legacy history
        // cannot immediately discard the first v0.2.10 summary. If no legacy
        // raw renewal remains, summaries are still the next eviction class.
        // Thus renewal-only histories retire raw rows then summaries; whenever
        // either renewal class exists, structural start/degraded/end evidence
        // is protected. With no renewal candidate, structural-only histories
        // retain the preexisting FIFO bound.
        if let legacyRenewal = entries.firstIndex(where: { $0.schema == 1 && $0.event == "renew" }) {
            entries.remove(at: legacyRenewal)
        } else if let summary = entries.firstIndex(where: { $0.event == "renew-summary" }) {
            entries.remove(at: summary)
        } else {
            entries.removeFirst()
        }
    }

    /// Diagnostics remain non-authoritative, but publication still never
    /// exposes a permissive replacement: a same-directory no-follow 0600 temp
    /// is fully written and verified before rename, then the final artifact is
    /// reopened through the bounded reader for owner/type/link/mode/content
    /// verification. Any failure is intentionally swallowed by `persist`.
    private func publishOwnerOnly(_ data: Data) throws {
        let directory = file.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".session-diagnostics.\(UUID().uuidString)")
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var published = false
        defer {
            close(descriptor)
            if !published { unlink(temporary.path) }
        }
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if count > 0 { offset += count; continue }
            if count < 0, errno == EINTR { continue }
            throw POSIXError(.init(rawValue: errno == 0 ? EIO : errno) ?? .EIO)
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var temporaryStatus = stat()
        guard fstat(descriptor, &temporaryStatus) == 0,
              (temporaryStatus.st_mode & S_IFMT) == S_IFREG,
              temporaryStatus.st_uid == getuid(),
              temporaryStatus.st_nlink == 1,
              temporaryStatus.st_mode & 0o777 == 0o600,
              fsync(descriptor) == 0,
              rename(temporary.path, file.path) == 0
        else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        published = true
        let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        let finalDescriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard finalDescriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(finalDescriptor) }
        var finalStatus = stat()
        guard fstat(finalDescriptor, &finalStatus) == 0,
              (finalStatus.st_mode & S_IFMT) == S_IFREG,
              finalStatus.st_uid == getuid(),
              finalStatus.st_nlink == 1,
              finalStatus.st_mode & 0o777 == 0o600,
              finalStatus.st_size == off_t(data.count)
        else { throw POSIXError(.EIO) }
        var finalBytes = [UInt8](repeating: 0, count: data.count)
        var finalOffset = 0
        while finalOffset < finalBytes.count {
            let remaining = finalBytes.count - finalOffset
            let count = finalBytes.withUnsafeMutableBytes { buffer in
                Darwin.read(finalDescriptor, buffer.baseAddress!.advanced(by: finalOffset), remaining)
            }
            if count > 0 { finalOffset += count; continue }
            if count < 0, errno == EINTR { continue }
            throw POSIXError(.init(rawValue: errno == 0 ? EIO : errno) ?? .EIO)
        }
        var trailing: UInt8 = 0
        guard Darwin.read(finalDescriptor, &trailing, 1) == 0,
              Data(finalBytes) == data
        else { throw POSIXError(.EIO) }
    }

    private func sanitize(_ raw: String) -> String {
        let lowered = raw.lowercased()
        guard !lowered.isEmpty,
              lowered.count <= 96,
              lowered.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
        else { return "redacted" }
        return lowered
    }
}
