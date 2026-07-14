import Darwin
import Foundation
import LidSwitchCore

/// Root-private work item for the public helper-status projection.  The public
/// file is diagnostic only; this record is the durable acknowledgement that an
/// authoritative state change still needs publication.
struct StatusProjectionTask: Equatable {
    static let maximumBytes = 1_024
    static let maximumAttempt = 8

    let token: UUID
    let generation: UInt64
    let authoritySnapshot: String
    let state: String
    let reason: String
    let reasonDigest: String
    let sessionID: UUID?
    let issuedEpoch: UInt64
    let issuedMonotonicMillis: UInt64
    let bootID: String
    let attempt: Int
    let deadlineNanoseconds: UInt64
    let nextAttemptNanoseconds: UInt64

    var isExhausted: Bool { attempt == Self.maximumAttempt && nextAttemptNanoseconds == .max }

    init?(token: UUID = UUID(), generation: UInt64, state: String, reason: String,
          sessionID: UUID?, issuedEpoch: UInt64 = UInt64(Date().timeIntervalSince1970),
          issuedMonotonicMillis: UInt64 = StatusProjectionTask.monotonicMillis(),
          bootID: String = BootIdentity.current() ?? "unknown", attempt: Int = 0,
          deadlineNanoseconds: UInt64, nextAttemptNanoseconds: UInt64 = 0) {
        guard generation > 0, Self.valid(state: state, reason: reason),
              bootID.range(of: "^[a-zA-Z0-9._-]{1,128}$", options: .regularExpression) != nil,
              attempt >= 0, attempt <= Self.maximumAttempt,
              deadlineNanoseconds > 0, nextAttemptNanoseconds <= deadlineNanoseconds || nextAttemptNanoseconds == .max
        else { return nil }
        self.token = token; self.generation = generation; self.state = state; self.reason = reason
        self.sessionID = sessionID; self.issuedEpoch = issuedEpoch
        self.issuedMonotonicMillis = issuedMonotonicMillis; self.bootID = bootID
        self.attempt = attempt; self.deadlineNanoseconds = deadlineNanoseconds
        self.nextAttemptNanoseconds = nextAttemptNanoseconds
        reasonDigest = Self.digest(reason)
        authoritySnapshot = Self.digest("\(generation)\n\(state)\n\(reason)\n\(sessionID?.uuidString.lowercased() ?? "none")")
    }

    private init(token: UUID, generation: UInt64, authoritySnapshot: String, state: String, reason: String,
                 reasonDigest: String, sessionID: UUID?, issuedEpoch: UInt64, issuedMonotonicMillis: UInt64,
                 bootID: String, attempt: Int, deadlineNanoseconds: UInt64, nextAttemptNanoseconds: UInt64) {
        self.token = token; self.generation = generation; self.authoritySnapshot = authoritySnapshot
        self.state = state; self.reason = reason; self.reasonDigest = reasonDigest; self.sessionID = sessionID
        self.issuedEpoch = issuedEpoch; self.issuedMonotonicMillis = issuedMonotonicMillis; self.bootID = bootID
        self.attempt = attempt; self.deadlineNanoseconds = deadlineNanoseconds; self.nextAttemptNanoseconds = nextAttemptNanoseconds
    }

    var payload: String {
        ["schema=1", "token=\(token.uuidString.lowercased())", "generation=\(generation)",
         "authority=\(authoritySnapshot)", "state=\(state)", "reason=\(reason)",
         "reason_digest=\(reasonDigest)", "session=\(sessionID?.uuidString.lowercased() ?? "none")",
         "issued_epoch=\(issuedEpoch)", "issued_monotonic_ms=\(issuedMonotonicMillis)", "boot_id=\(bootID)",
         "attempt=\(attempt)", "deadline_ns=\(deadlineNanoseconds)", "next_attempt_ns=\(nextAttemptNanoseconds)", ""].joined(separator: "\n")
    }

    var statusPayload: String {
        ["state=\(state)", "reason=\(reason)", "session=\(sessionID?.uuidString.lowercased() ?? "none")",
         "updated=\(issuedEpoch)", "boot_id=\(bootID)",
         "updated_monotonic=\(String(format: "%.3f", Double(issuedMonotonicMillis) / 1_000))",
         "projection_generation=\(generation)", "projection_token=\(token.uuidString.lowercased())",
         "projection_authority=\(authoritySnapshot)", ""].joined(separator: "\n")
    }

    func retrying(now: UInt64) -> StatusProjectionTask? {
        if attempt >= Self.maximumAttempt || now >= deadlineNanoseconds {
            return .init(token: token, generation: generation, authoritySnapshot: authoritySnapshot, state: state,
                         reason: reason, reasonDigest: reasonDigest, sessionID: sessionID, issuedEpoch: issuedEpoch,
                         issuedMonotonicMillis: issuedMonotonicMillis, bootID: bootID, attempt: Self.maximumAttempt,
                         deadlineNanoseconds: deadlineNanoseconds, nextAttemptNanoseconds: .max)
        }
        let nextAttempt = min(attempt + 1, Self.maximumAttempt)
        let seconds = UInt64(1 << min(nextAttempt, 6))
        let next = min(deadlineNanoseconds, now &+ seconds * 1_000_000_000)
        return .init(token: token, generation: generation, authoritySnapshot: authoritySnapshot, state: state,
                     reason: reason, reasonDigest: reasonDigest, sessionID: sessionID, issuedEpoch: issuedEpoch,
                     issuedMonotonicMillis: issuedMonotonicMillis, bootID: bootID, attempt: nextAttempt,
                     deadlineNanoseconds: deadlineNanoseconds, nextAttemptNanoseconds: next)
    }

    /// Monotonic deadlines cannot survive a reboot.  Keep the authority
    /// target and finite retry budget, but reset the timer from the observed
    /// boot before publication can be attempted.
    func rebasedForCurrentBoot(now: UInt64, bootID: String) -> StatusProjectionTask? {
        guard bootID != self.bootID,
              bootID.range(of: "^[a-zA-Z0-9._-]{1,128}$", options: .regularExpression) != nil else { return nil }
        let deadline = now &+ 300_000_000_000
        return .init(token: token, generation: generation, authoritySnapshot: authoritySnapshot, state: state,
                     reason: reason, reasonDigest: reasonDigest, sessionID: sessionID, issuedEpoch: issuedEpoch,
                     issuedMonotonicMillis: Self.monotonicMillis(), bootID: bootID, attempt: attempt,
                     deadlineNanoseconds: deadline, nextAttemptNanoseconds: now)
    }

    static func parse(_ raw: String) -> StatusProjectionTask? {
        guard raw.utf8.count <= maximumBytes, raw.hasSuffix("\n"), !raw.hasSuffix("\n\n") else { return nil }
        var fields: [String: String] = [:]
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, fields.updateValue(String(pair[1]), forKey: String(pair[0])) == nil else { return nil }
        }
        guard fields.count == 14, fields["schema"] == "1", let tokenRaw = fields["token"], tokenRaw == tokenRaw.lowercased(),
              let token = UUID(uuidString: tokenRaw), let generation = UInt64(fields["generation"] ?? ""), generation > 0,
              let authority = fields["authority"], Self.validDigest(authority), let state = fields["state"], let reason = fields["reason"],
              Self.valid(state: state, reason: reason), let reasonDigest = fields["reason_digest"], reasonDigest == Self.digest(reason),
              let epoch = UInt64(fields["issued_epoch"] ?? ""), let monotonic = UInt64(fields["issued_monotonic_ms"] ?? ""),
              let boot = fields["boot_id"], boot.range(of: "^[a-zA-Z0-9._-]{1,128}$", options: .regularExpression) != nil,
              let attempt = Int(fields["attempt"] ?? ""), attempt >= 0, attempt <= maximumAttempt,
              let deadline = UInt64(fields["deadline_ns"] ?? ""), deadline > 0,
              let next = UInt64(fields["next_attempt_ns"] ?? ""), next <= deadline || next == .max
        else { return nil }
        let session: UUID?
        if fields["session"] == "none" { session = nil }
        else if let rawSession = fields["session"], rawSession == rawSession.lowercased(), let parsed = UUID(uuidString: rawSession) { session = parsed }
        else { return nil }
        let candidate = StatusProjectionTask(token: token, generation: generation, authoritySnapshot: authority, state: state,
                                             reason: reason, reasonDigest: reasonDigest, sessionID: session, issuedEpoch: epoch,
                                             issuedMonotonicMillis: monotonic, bootID: boot, attempt: attempt,
                                             deadlineNanoseconds: deadline, nextAttemptNanoseconds: next)
        guard candidate.authoritySnapshot == Self.digest("\(generation)\n\(state)\n\(reason)\n\(session?.uuidString.lowercased() ?? "none")"),
              candidate.payload == raw else { return nil }
        return candidate
    }

    private static func valid(state: String, reason: String) -> Bool {
        state.range(of: "^[a-z0-9-]{1,32}$", options: .regularExpression) != nil
            && reason.range(of: "^[a-z0-9-]{1,96}$", options: .regularExpression) != nil
    }
    private static func validDigest(_ value: String) -> Bool { value.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil }
    static func digest(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 { hash ^= UInt64(byte); hash &*= 0x100000001b3 }
        return String(format: "%016llx", hash)
    }
    static func monotonicMillis() -> UInt64 { UInt64(max(0, MonotonicClock.seconds()) * 1_000) }
}

/// The only writer for durable helper/recovery status.  It owns no power,
/// lease, session, XPC, timer, or containment API; cleanup never waits for it.
enum StatusProjectionDispatcher {
    private static let queue = DispatchQueue(label: "com.johnsilva.lidswitch.status-projection")
    typealias StoreFactory = (String) -> RecoveryAuthorityStore?
    typealias Writer = (StatusProjectionTask, HelperServiceConfiguration) -> HelperStatusStore.WriteOutcome

    static func enqueue(state: String, reason: String, sessionID: UUID?, store: RecoveryAuthorityStore,
                        transaction: VerifiedRootStateDirectory.Transaction, configuration: HelperServiceConfiguration,
                        storeFactory: @escaping StoreFactory = { RecoveryAuthorityStore(supportDirectory: $0) },
                        writer: @escaping Writer = { task, configuration in
                            HelperStatusStore.writeOutcome(task: task, path: configuration.statusPath)
                        }) -> Bool {
        guard store.enqueueStatusProjection(state: state, reason: reason, sessionID: sessionID, transaction) != nil else { return false }
        return transaction.afterUnlock { queue.async { drain(configuration: configuration, storeFactory: storeFactory, writer: writer) } }
    }

    /// Called before recovery decisions. It only discovers durable dirty work;
    /// it never creates authority or mutates power/session state.
    static func hydrate(configuration: HelperServiceConfiguration, storeFactory: @escaping StoreFactory,
                        writer: @escaping Writer = { task, configuration in
                            HelperStatusStore.writeOutcome(task: task, path: configuration.statusPath)
                        }) {
        guard storeFactory(configuration.supportDirectory) != nil else { return }
        queue.async { drain(configuration: configuration, storeFactory: storeFactory, writer: writer) }
    }

    private static func drain(configuration: HelperServiceConfiguration, storeFactory: @escaping StoreFactory,
                              writer: @escaping Writer) {
        guard let store = storeFactory(configuration.supportDirectory) else { return }
        let now = UInt64(max(0, MonotonicClock.seconds()) * 1_000_000_000)
        let currentBoot = BootIdentity.current() ?? "unknown"
        guard let task = store.withTransaction({ transaction -> StatusProjectionTask? in
            guard case let .valid(task) = store.statusProjectionTaskRecord(), !task.isExhausted else { return nil }
            guard task.bootID != currentBoot else { return task }
            guard let rebased = task.rebasedForCurrentBoot(now: now, bootID: currentBoot),
                  store.advanceStatusProjectionTask(expected: task, next: rebased, transaction) else { return nil }
            return rebased
        }) ?? nil else { return }
        if task.nextAttemptNanoseconds > now {
            let delay = max(1, min(60, Int((task.nextAttemptNanoseconds &- now) / 1_000_000_000)))
            queue.asyncAfter(deadline: .now() + .seconds(delay)) {
                drain(configuration: configuration, storeFactory: storeFactory, writer: writer)
            }
            return
        }
        let writeOutcome = writer(task, configuration)
        let successor: StatusProjectionTask? = store.withTransaction { transaction in
            guard case let .valid(current) = store.statusProjectionTaskRecord(), current == task else { return nil }
            switch writeOutcome {
            case .written, .alreadyCurrent:
                if store.removeStatusProjectionTask(expected: task, transaction) { return nil }
            case let .staleNewer(observedGeneration):
                guard let replacement = store.enqueueStatusProjection(
                        state: task.state, reason: task.reason, sessionID: task.sessionID,
                        transaction, generationFloor: observedGeneration
                      )
                else { break }
                return replacement
            case .conflict, .unsafeExisting, .ioFailure, .indeterminate:
                break
            }
            guard let retry = task.retrying(now: now), store.advanceStatusProjectionTask(expected: task, next: retry, transaction) else { return nil }
            return retry
        } ?? nil
        if let successor, !successor.isExhausted {
            if successor.nextAttemptNanoseconds <= now {
                queue.async { drain(configuration: configuration, storeFactory: storeFactory, writer: writer) }
                return
            }
            let delay = max(1, min(60, Int((successor.nextAttemptNanoseconds &- now) / 1_000_000_000)))
            queue.asyncAfter(deadline: .now() + .seconds(delay)) {
                drain(configuration: configuration, storeFactory: storeFactory, writer: writer)
            }
        }
    }
}
