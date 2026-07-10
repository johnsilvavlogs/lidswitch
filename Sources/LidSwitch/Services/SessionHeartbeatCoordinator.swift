import Darwin
import Foundation
import LidSwitchCore

struct SessionHeartbeatObservation: Sendable {
    enum Power: Equatable, Sendable { case ac, disconnected, unknown }

    let power: Power
    let leaseIsValid: Bool
    let helperStatus: HelperStatusRecord?
}

final class SessionHeartbeatCoordinator: @unchecked Sendable {
    private enum Phase { case starting(deadlineMonotonic: TimeInterval), active, terminal }

    private let queue: DispatchQueue
    private let observationInterval: TimeInterval
    private let renewalInterval: TimeInterval
    private let acknowledgementTimeout: TimeInterval
    private let now: @Sendable () -> Date
    private let monotonicNow: @Sendable () -> TimeInterval
    private let observe: @Sendable (UUID) -> SessionHeartbeatObservation
    private let renew: @Sendable (UUID, @escaping @Sendable () -> Bool) throws -> TimeInterval
    private let revoke: @Sendable () -> Void
    private let diagnostics: SessionDiagnosticStore
    private let onAcknowledged: @Sendable (UUID) -> Void
    private let onEnded: @Sendable (UUID, String) -> Void

    private var timer: DispatchSourceTimer?
    private var sessionID: UUID?
    private var phase: Phase = .terminal
    private var nextRenewalMonotonic = TimeInterval.greatestFiniteMagnitude
    private var leaseExpiresMonotonic = TimeInterval.greatestFiniteMagnitude
    private var lastRecoveryAcknowledgement: String?

    init(
        observationInterval: TimeInterval = 1,
        renewalInterval: TimeInterval = 8,
        acknowledgementTimeout: TimeInterval = 20,
        queueLabel: String = "com.johnsilva.lidswitch.session-heartbeat",
        now: @escaping @Sendable () -> Date = Date.init,
        monotonicNow: @escaping @Sendable () -> TimeInterval = MonotonicClock.seconds,
        observe: @escaping @Sendable (UUID) -> SessionHeartbeatObservation,
        renew: @escaping @Sendable (UUID, @escaping @Sendable () -> Bool) throws -> TimeInterval,
        revoke: @escaping @Sendable () -> Void,
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
        self.diagnostics = diagnostics
        self.onAcknowledged = onAcknowledged
        self.onEnded = onEnded
    }

    func start(sessionID: UUID, initialLeaseExpiresMonotonic: TimeInterval) {
        queue.sync {
            cancelTimer()
            let startedMonotonic = monotonicNow()
            self.sessionID = sessionID
            phase = .starting(deadlineMonotonic: startedMonotonic + acknowledgementTimeout)
            nextRenewalMonotonic = startedMonotonic + renewalInterval
            leaseExpiresMonotonic = initialLeaseExpiresMonotonic
            diagnostics.record(event: "start", reason: "lease-issued", sessionID: sessionID)

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

    func stop(reason: String) {
        queue.sync {
            guard let sessionID, !isTerminal else { return }
            finish(sessionID: sessionID, reason: reason, notify: false)
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
        let checkedAt = now()
        let checkedMonotonic = monotonicNow()
        let observation = observe(sessionID)

        switch observation.power {
        case .ac: break
        case .disconnected:
            finish(sessionID: sessionID, reason: "power-disconnected", notify: true)
            return
        case .unknown:
            finish(sessionID: sessionID, reason: "power-source-unknown", notify: true)
            return
        }
        guard observation.leaseIsValid else {
            finish(sessionID: sessionID, reason: "lease-invalid-or-missing", notify: true)
            return
        }

        let matchingStatus = observation.helperStatus.flatMap { status in
            status.sessionID == sessionID ? status : nil
        }
        if let matchingStatus, matchingStatus.state != "active" {
            finish(
                sessionID: sessionID,
                reason: "helper-\(normalized(matchingStatus.state))-\(normalized(matchingStatus.reason))",
                notify: true
            )
            return
        }
        if let matchingStatus,
           matchingStatus.state == "active",
           matchingStatus.reason == "override-recovered",
           matchingStatus.isFresh(at: checkedAt),
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
               matchingStatus.isFresh(at: checkedAt)
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
        case .active:
            guard let matchingStatus,
                  matchingStatus.state == "active",
                  matchingStatus.isFresh(at: checkedAt)
            else {
                finish(sessionID: sessionID, reason: "helper-status-lost", notify: true)
                return
            }
        case .terminal:
            return
        }

        guard checkedMonotonic >= nextRenewalMonotonic else { return }
        guard checkedMonotonic < leaseExpiresMonotonic else {
            finish(sessionID: sessionID, reason: "lease-expired-before-renewal", notify: true)
            return
        }

        // A second probe closes the race where the helper reports inactive or
        // power disconnects after the periodic observation but before the write.
        let prewrite = observe(sessionID)
        guard prewrite.power == .ac,
              prewrite.leaseIsValid,
              let prewriteStatus = prewrite.helperStatus,
              prewriteStatus.sessionID == sessionID,
              prewriteStatus.state == "active",
              prewriteStatus.isFresh(at: now())
        else {
            finish(sessionID: sessionID, reason: "prewrite-safety-check-failed", notify: true)
            return
        }
        do {
            let committedExpiry = try renew(sessionID) { [weak self] in
                self?.commitAllowed(sessionID: sessionID) == true
            }
            let issuedMonotonic = monotonicNow()
            nextRenewalMonotonic = issuedMonotonic + renewalInterval
            leaseExpiresMonotonic = committedExpiry
            diagnostics.record(event: "renew", reason: "safety-probes-valid", sessionID: sessionID)
        } catch {
            finish(sessionID: sessionID, reason: "lease-renewal-failed", notify: true)
        }
    }

    private func commitAllowed(sessionID: UUID) -> Bool {
        guard self.sessionID == sessionID,
              !isTerminal,
              monotonicNow() < leaseExpiresMonotonic
        else { return false }
        let observation = observe(sessionID)
        guard observation.power == .ac,
              observation.leaseIsValid,
              let status = observation.helperStatus,
              status.sessionID == sessionID,
              status.state == "active",
              status.isFresh(at: now())
        else { return false }
        return true
    }

    private func finish(sessionID: UUID, reason: String, notify: Bool) {
        phase = .terminal
        self.sessionID = nil
        cancelTimer()
        revoke()
        diagnostics.record(event: "end", reason: reason, sessionID: sessionID)
        if notify { onEnded(sessionID, reason) }
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
    let schema: Int
    let timestamp: Date
    let sessionID: String
    let event: String
    let reason: String
    let appVersion: String
    let appBuild: String
}

final class SessionDiagnosticStore: @unchecked Sendable {
    static let shared = SessionDiagnosticStore(file: AppPaths.sessionHistoryFile)

    private let lock = NSLock()
    private let file: URL
    private let maximumEntries: Int
    private let maximumBytes: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(file: URL, maximumEntries: Int = 200, maximumBytes: Int = 128 * 1_024) {
        self.file = file
        self.maximumEntries = max(1, maximumEntries)
        self.maximumBytes = max(1_024, maximumBytes)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func record(event: String, reason: String, sessionID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadUnlocked()
        entries.append(SessionDiagnosticEntry(
            schema: 1,
            timestamp: Date(),
            sessionID: sessionID.uuidString.lowercased(),
            event: sanitize(event),
            reason: sanitize(reason),
            appVersion: AppPaths.appVersion,
            appBuild: AppPaths.appBuild
        ))
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
        var data = (try? encoder.encode(entries)) ?? Data("[]".utf8)
        while data.count > maximumBytes, entries.count > 1 {
            entries.removeFirst()
            data = (try? encoder.encode(entries)) ?? Data("[]".utf8)
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            _ = chmod(file.path, S_IRUSR | S_IWUSR)
        } catch {
            // Diagnostics must never interfere with the safety state machine.
        }
    }

    func entries() -> [SessionDiagnosticEntry] {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    private func loadUnlocked() -> [SessionDiagnosticEntry] {
        guard let data = try? Data(contentsOf: file), data.count <= maximumBytes else { return [] }
        return (try? decoder.decode([SessionDiagnosticEntry].self, from: data)) ?? []
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
