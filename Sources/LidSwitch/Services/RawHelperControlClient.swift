import Darwin
import Foundation
import LidSwitchCore
import LidSwitchXPCBridge

enum HelperControlError: Error, Equatable {
    case unavailable
    /// The request may have reached the helper but its reply was not known to
    /// this client. It is the only error class eligible for RECONNECT.
    case indeterminateTransport(Int32)
    case transport(Int32)
    case rejected(String)
    case malformedReply
}

/// Preserves the authority distinction that protocol-v2 introduced: a
/// RECONNECT rebinds transport but never grants a fresh lease.
enum HelperLeaseAdvance: Equatable, Sendable {
    case renewed(expiryMonotonic: TimeInterval)
    case reconnected(originalExpiryMonotonic: TimeInterval)
    /// RECONNECT authenticated the exact active generation but the helper did
    /// not bind this new transport. A later logical cycle must reconnect first.
    case reconnectedButUnbound(reason: String)
    /// The helper accepted the exact generation but deliberately retained its
    /// existing hard expiry because its native power reading was inconclusive.
    /// This is protocol truth, but never a lease advancement.
    case indeterminateNoAdvance(reason: String)
}

/// BEGIN is the only authority-creating exchange. Its result must preserve the
/// difference between a reply received on the original connection, an exact
/// same-process rebind after an indeterminate reply, proof that no generation
/// remains, and the safety-critical case where authority may still exist.
enum HelperLeaseBeginResolution: Equatable, Sendable {
    case issued(HelperControlReply)
    case reconnected(HelperControlReply)
    case idle(HelperControlReply)
    case terminal(HelperControlReply)
    case authorityMayRemain(String)
}

enum HelperGenerationTerminationIntent: Equatable, Sendable {
    case end
    case restore
}

enum HelperGenerationTerminationResolution: Equatable, Sendable {
    case terminated(HelperControlReply)
    case alreadyIdle(HelperControlReply)
    case alreadyTerminal(HelperControlReply)
    case authorityMayRemain(String)
}

struct HelperControlReply: Equatable, Sendable {
    enum State: UInt32, Equatable, Sendable { case idle = 0, active = 1, terminal = 2, recoveryRequired = 3 }
    enum Power: UInt32, Equatable, Sendable { case unknown = 0, ac = 1, disconnected = 2 }
    let reason: String
    let sessionID: UUID
    let expiryMonotonic: TimeInterval
    let state: State
    let power: Power
    let sleepDisabled: Bool
    let acSleepMinutes: Int?
}

enum HelperControlExchangeOutcome {
    case accepted(HelperControlReply)
    case rejected(HelperControlReply)
}

final class RawHelperControlClient: @unchecked Sendable {
    private enum TransportBinding: Equatable {
        case bound
        case reconnectRequired
    }

    /// This is deliberately a closed protocol set. Each member means the
    /// authenticated helper accepted the exact generation but retained its
    /// existing durable expiry, so it cannot be surfaced as `.renewed`.
    private enum NoAdvanceRenewalReason: String {
        case powerSourceUnconfirmed = "power-source-unconfirmed"
        case nativeStateIndeterminate = "native-state-indeterminate"
    }

    /// Must remain aligned with the helper's authority lifetime. A reply may
    /// spend a small amount of transport time in flight, but cannot confer an
    /// arbitrarily distant lease.
    static let maximumLeaseLifetime: TimeInterval = 30
    private static let replyExpirySlack: TimeInterval = 2
    private let lock = NSLock()
    private let helperIdentity: CodeIdentity
    private var rawClient: OpaquePointer?
    /// State is keyed by the exact generation. A stale session can never make
    /// another generation reconnect, and a new generation cannot silently
    /// consume a stale recovery marker.
    private var transportBindings: [UUID: TransportBinding] = [:]

    init(helperIdentity: CodeIdentity) { self.helperIdentity = helperIdentity }
    deinit { if let rawClient { ls_xpc_client_release(rawClient) } }

    static func production() throws -> RawHelperControlClient {
        guard !Self.isXCTestRuntime,
              let identity = CodeIdentity.staticCode(at: AppPaths.bundledHelperFile.path)
        else { throw HelperControlError.unavailable }
        return RawHelperControlClient(helperIdentity: identity)
    }

    /// Resolves the single indeterminate-BEGIN window with exactly one
    /// same-session RECONNECT on a newly authenticated connection. RECONNECT
    /// can only recover the original generation and its original expiry; it
    /// never retries BEGIN, grants authority, renews, or loops.
    func resolveBegin(sessionID: UUID) throws -> HelperLeaseBeginResolution {
        lock.lock(); defer { lock.unlock() }
        let resolution = try Self.resolveBegin(sessionID: sessionID) { operation, requestedSessionID in
            try self.exchangeLocked(operation, sessionID: requestedSessionID)
        }
        recordBeginResolution(resolution, sessionID: sessionID)
        return resolution
    }

    func renew(sessionID: UUID) throws -> HelperLeaseAdvance {
        lock.lock(); defer { lock.unlock() }
        return try renewLocked(sessionID: sessionID) { operation, requestedSessionID in
            try self.exchangeLocked(operation, sessionID: requestedSessionID)
        }
    }

    /// Performs one authenticated RENEW exchange and never attempts RECONNECT.
    /// Heartbeat recovery uses this only after its one permitted reconnect, so
    /// an indeterminate immediate renewal cannot create a second wire rebind.
    func renewDirect(sessionID: UUID) throws -> HelperLeaseAdvance {
        lock.lock(); defer { lock.unlock() }
        return try renewDirectLocked(sessionID: sessionID) { operation, requestedSessionID in
            try self.exchangeLocked(operation, sessionID: requestedSessionID)
        }
    }

    private func renewLocked(
        sessionID: UUID,
        exchange: (UInt32, UUID) throws -> HelperControlExchangeOutcome
    ) throws -> HelperLeaseAdvance {
        if transportBindings[sessionID] == .reconnectRequired {
            return try reconnectLocked(sessionID: sessionID, exchange: exchange)
        }
        do {
            return try renewDirectLocked(sessionID: sessionID, exchange: exchange)
        } catch let HelperControlError.indeterminateTransport(status) {
            // `exchangeLocked` released the old client. Retain this exact
            // session marker, but leave the single recovery exchange to the
            // next heartbeat cycle. That boundary prevents one logical RENEW
            // from emitting both RENEW and RECONNECT on the wire.
            transportBindings[sessionID] = .reconnectRequired
            throw HelperControlError.indeterminateTransport(status)
        }
    }

    private func reconnectLocked(
        sessionID: UUID,
        exchange: (UInt32, UUID) throws -> HelperControlExchangeOutcome
    ) throws -> HelperLeaseAdvance {
        do {
            let reply = try Self.acceptedReply(
                from: exchange(UInt32(LS_OPERATION_RECONNECT.rawValue), sessionID)
            )
            // Helper source semantics are intentionally stronger than an
            // active reply: `native-state-indeterminate` returns before the
            // helper sets activeConnection. Treat every reconnect no-advance
            // response as unbound unless a future helper contract proves one.
            if let reason = Self.noAdvanceRenewalReason(for: reply) {
                transportBindings[sessionID] = .reconnectRequired
                return .reconnectedButUnbound(reason: reason.rawValue)
            }
            guard reply.reason == "reconnected" else {
                transportBindings[sessionID] = .reconnectRequired
                return .reconnectedButUnbound(reason: reply.reason)
            }
            transportBindings[sessionID] = .bound
            return .reconnected(originalExpiryMonotonic: reply.expiryMonotonic)
        } catch let HelperControlError.indeterminateTransport(status) {
            transportBindings[sessionID] = .reconnectRequired
            throw HelperControlError.indeterminateTransport(status)
        }
    }

    private func renewDirectLocked(
        sessionID: UUID,
        exchange: (UInt32, UUID) throws -> HelperControlExchangeOutcome
    ) throws -> HelperLeaseAdvance {
        guard transportBindings[sessionID] != .reconnectRequired else {
            return .reconnectedButUnbound(reason: "reconnect-required")
        }
        do {
            let reply = try Self.acceptedReply(
                from: exchange(UInt32(LS_OPERATION_RENEW.rawValue), sessionID)
            )
            // Both successful and accepted no-advance RENEW replies require a
            // helper-side activeConnection match before native power is read.
            transportBindings[sessionID] = .bound
            return Self.classifyRenewalReply(reply)
        } catch let HelperControlError.indeterminateTransport(status) {
            transportBindings[sessionID] = .reconnectRequired
            throw HelperControlError.indeterminateTransport(status)
        }
    }

    private static func classifyRenewalReply(_ reply: HelperControlReply) -> HelperLeaseAdvance {
        guard let reason = noAdvanceRenewalReason(for: reply) else {
            return .renewed(expiryMonotonic: reply.expiryMonotonic)
        }
        return .indeterminateNoAdvance(reason: reason.rawValue)
    }

    private static func noAdvanceRenewalReason(for reply: HelperControlReply) -> NoAdvanceRenewalReason? {
        NoAdvanceRenewalReason(rawValue: reply.reason)
    }

    private func recordBeginResolution(_ resolution: HelperLeaseBeginResolution, sessionID: UUID) {
        switch resolution {
        case .issued:
            transportBindings[sessionID] = .bound
        case let .reconnected(reply):
            // A reconnect can authenticate an active reply before the helper
            // binds its connection. Its exact source-level `reconnected`
            // reason is the binding proof; all other replies stay recoverable.
            transportBindings[sessionID] = reply.reason == "reconnected" ? .bound : .reconnectRequired
        case .idle, .terminal:
            transportBindings.removeValue(forKey: sessionID)
        case .authorityMayRemain:
            break
        }
    }

    private func clearTransportBindingIfTerminal(
        _ resolution: HelperGenerationTerminationResolution,
        sessionID: UUID
    ) {
        switch resolution {
        case .terminated, .alreadyIdle, .alreadyTerminal:
            transportBindings.removeValue(forKey: sessionID)
        case .authorityMayRemain:
            break
        }
    }

    #if DEBUG
    static func classifyRenewalReplyForTesting(_ reply: HelperControlReply) -> HelperLeaseAdvance {
        classifyRenewalReply(reply)
    }

    func renewForTesting(
        sessionID: UUID,
        exchange: (UInt32, UUID) throws -> HelperControlExchangeOutcome
    ) throws -> HelperLeaseAdvance {
        lock.lock(); defer { lock.unlock() }
        return try renewLocked(sessionID: sessionID, exchange: exchange)
    }

    func renewDirectForTesting(
        sessionID: UUID,
        exchange: (UInt32, UUID) throws -> HelperControlExchangeOutcome
    ) throws -> HelperLeaseAdvance {
        lock.lock(); defer { lock.unlock() }
        return try renewDirectLocked(sessionID: sessionID, exchange: exchange)
    }

    func resolveBeginWithTransportStateForTesting(
        sessionID: UUID,
        exchange: (UInt32, UUID) throws -> HelperControlExchangeOutcome
    ) throws -> HelperLeaseBeginResolution {
        lock.lock(); defer { lock.unlock() }
        let resolution = try Self.resolveBegin(sessionID: sessionID, exchange: exchange)
        recordBeginResolution(resolution, sessionID: sessionID)
        return resolution
    }

    func terminateGenerationWithTransportStateForTesting(
        sessionID: UUID,
        intent: HelperGenerationTerminationIntent,
        exchange: (UInt32, UUID) throws -> HelperControlExchangeOutcome
    ) -> HelperGenerationTerminationResolution {
        lock.lock(); defer { lock.unlock() }
        let resolution = Self.terminateGeneration(sessionID: sessionID, intent: intent) {
            operation, requestedSessionID, _ in
            try exchange(operation, requestedSessionID)
        }
        clearTransportBindingIfTerminal(resolution, sessionID: sessionID)
        return resolution
    }
    #endif
    /// Claims one bounded terminal exchange for an existing generation. Every
    /// caller first exact-session RECONNECTs, even if it believes its current
    /// transport is still bound. This closes the reply-lost/invalidation race:
    /// a fresh RESTORE alone would be rejected as a second connection, whereas
    /// rebind-then-END/RESTORE remains exact-process and never extends expiry.
    func terminateGeneration(
        sessionID: UUID,
        intent: HelperGenerationTerminationIntent
    ) -> HelperGenerationTerminationResolution {
        lock.lock(); defer { lock.unlock() }
        let resolution = Self.terminateGeneration(sessionID: sessionID, intent: intent) {
            operation, requestedSessionID, timeout in
            try self.exchangeLocked(operation, sessionID: requestedSessionID, timeout: timeout)
        }
        clearTransportBindingIfTerminal(resolution, sessionID: sessionID)
        return resolution
    }

    private static func resolveBegin(
        sessionID: UUID,
        exchange: (UInt32, UUID) throws -> HelperControlExchangeOutcome
    ) throws -> HelperLeaseBeginResolution {
        do {
            return classifyBeginOutcome(
                try exchange(UInt32(LS_OPERATION_BEGIN.rawValue), sessionID),
                expectedSessionID: sessionID,
                acceptedCase: HelperLeaseBeginResolution.issued
            )
        } catch let HelperControlError.indeterminateTransport(_) {
            // `exchangeLocked` invalidates the old raw client before throwing,
            // so this one recovery exchange necessarily authenticates a fresh
            // connection. Any second uncertainty is terminal for this resolver.
            do {
                return classifyBeginOutcome(
                    try exchange(UInt32(LS_OPERATION_RECONNECT.rawValue), sessionID),
                    expectedSessionID: sessionID,
                    acceptedCase: HelperLeaseBeginResolution.reconnected
                )
            } catch {
                return .authorityMayRemain(describe(error))
            }
        }
    }

    private static func classifyBeginOutcome(
        _ outcome: HelperControlExchangeOutcome,
        expectedSessionID: UUID,
        acceptedCase: (HelperControlReply) -> HelperLeaseBeginResolution
    ) -> HelperLeaseBeginResolution {
        switch outcome {
        case let .accepted(reply):
            guard reply.sessionID == expectedSessionID else {
                return .authorityMayRemain("begin-reply-session-mismatch")
            }
            return acceptedCase(reply)
        case let .rejected(reply):
            guard reply.sessionID == expectedSessionID else {
                return .authorityMayRemain("begin-reply-session-mismatch")
            }
            switch reply.state {
            case .idle: return .idle(reply)
            case .terminal: return .terminal(reply)
            case .active, .recoveryRequired:
                return .authorityMayRemain(reply.reason)
            }
        }
    }

    private static func terminateGeneration(
        sessionID: UUID,
        intent: HelperGenerationTerminationIntent,
        exchange: (UInt32, UUID, Double) throws -> HelperControlExchangeOutcome
    ) -> HelperGenerationTerminationResolution {
        let rebound: HelperControlExchangeOutcome
        do {
            let operation = UInt32(LS_OPERATION_RECONNECT.rawValue)
            rebound = try exchange(operation, sessionID, timeoutSeconds(for: operation, terminalContext: true))
        } catch {
            return .authorityMayRemain(describe(error))
        }
        switch rebound {
        case let .rejected(reply):
            guard isExactOwnerReply(reply, expectedSessionID: sessionID) else {
                return .authorityMayRemain("terminal-reconnect-session-mismatch")
            }
            switch reply.state {
            case .idle: return .alreadyIdle(reply)
            case .terminal: return .alreadyTerminal(reply)
            case .active, .recoveryRequired:
                return .authorityMayRemain(reply.reason)
            }
        case .accepted:
            break
        }

        let operation: UInt32
        let requestedSessionID: UUID
        switch intent {
        case .end:
            operation = UInt32(LS_OPERATION_END.rawValue)
            requestedSessionID = sessionID
        case .restore:
            operation = UInt32(LS_OPERATION_RESTORE.rawValue)
            requestedSessionID = zeroUUID
        }
        do {
            return classifyTerminalOutcome(
                try exchange(operation, requestedSessionID, timeoutSeconds(for: operation, terminalContext: true)),
                expectedSessionID: sessionID
            )
        } catch {
            return .authorityMayRemain(describe(error))
        }
    }

    /// RESTORE is addressed on the wire with the zero UUID, but it still
    /// resolves only the generation that performed the prior exact-session
    /// RECONNECT. Never let the wire routing value turn another session's
    /// terminal-looking reply into this owner's cleanup proof.
    private static func classifyTerminalOutcome(
        _ outcome: HelperControlExchangeOutcome,
        expectedSessionID: UUID
    ) -> HelperGenerationTerminationResolution {
        switch outcome {
            case let .accepted(reply):
                guard isExactOwnerReply(reply, expectedSessionID: expectedSessionID) else {
                    return .authorityMayRemain("terminal-reply-session-mismatch")
                }
                return .terminated(reply)
            case let .rejected(reply):
                guard isExactOwnerReply(reply, expectedSessionID: expectedSessionID) else {
                    return .authorityMayRemain("terminal-reply-session-mismatch")
                }
                switch reply.state {
                case .idle: return .alreadyIdle(reply)
                case .terminal: return .alreadyTerminal(reply)
                case .active, .recoveryRequired:
                    return .authorityMayRemain(reply.reason)
                }
            }
    }

    private static func isExactOwnerReply(
        _ reply: HelperControlReply,
        expectedSessionID: UUID
    ) -> Bool {
        expectedSessionID != zeroUUID
            && reply.sessionID == expectedSessionID
            && reply.sessionID != zeroUUID
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let HelperControlError.indeterminateTransport(status): return "indeterminate-transport-\(status)"
        case let HelperControlError.transport(status): return "transport-\(status)"
        case let HelperControlError.rejected(reason): return reason
        case HelperControlError.unavailable: return "helper-unavailable"
        case HelperControlError.malformedReply: return "malformed-reply"
        default: return "helper-control-failure"
        }
    }

#if DEBUG
    static func resolveBeginForTesting(
        sessionID: UUID,
        exchange: (UInt32, UUID) throws -> HelperControlExchangeOutcome
    ) throws -> HelperLeaseBeginResolution {
        try resolveBegin(sessionID: sessionID, exchange: exchange)
    }

    static func terminateGenerationForTesting(
        sessionID: UUID,
        intent: HelperGenerationTerminationIntent,
        exchange: (UInt32, UUID) throws -> HelperControlExchangeOutcome
    ) -> HelperGenerationTerminationResolution {
        terminateGeneration(sessionID: sessionID, intent: intent) { operation, requestedSessionID, _ in
            try exchange(operation, requestedSessionID)
        }
    }

    static func terminateGenerationWithTimeoutsForTesting(
        sessionID: UUID,
        intent: HelperGenerationTerminationIntent,
        exchange: (UInt32, UUID, Double) throws -> HelperControlExchangeOutcome
    ) -> HelperGenerationTerminationResolution {
        terminateGeneration(sessionID: sessionID, intent: intent, exchange: exchange)
    }
#endif

    private static func acceptedReply(
        from outcome: HelperControlExchangeOutcome
    ) throws -> HelperControlReply {
        switch outcome {
        case let .accepted(reply): return reply
        case let .rejected(reply): throw HelperControlError.rejected(reply.reason)
        }
    }

    private func exchangeLocked(
        _ operation: UInt32,
        sessionID: UUID,
        timeout: Double? = nil
    ) throws -> HelperControlExchangeOutcome {
        let client = try connectedClient()
        var rawReply: OpaquePointer?
        let status = ls_xpc_client_send(
            client,
            operation,
            UUID().uuidString.lowercased(),
            sessionID.uuidString.lowercased(),
            timeout ?? Self.timeoutSeconds(for: operation),
            &rawReply
        )
        guard status == 0, let rawReply else {
            invalidateClientLocked()
            if ls_xpc_status_is_indeterminate(status) {
                throw HelperControlError.indeterminateTransport(status)
            }
            throw HelperControlError.transport(status)
        }
        BenchmarkProbe.record("xpc_authenticated_reply")
        BenchmarkProbe.record("xpc_identity_ns", count: Int(clamping: ls_xpc_last_identity_duration_ns()))
        defer { ls_xpc_reply_release(rawReply) }
        guard let reasonPointer = ls_xpc_reply_reason(rawReply), let sessionPointer = ls_xpc_reply_session_id(rawReply),
              let replySession = UUID(uuidString: String(cString: sessionPointer)),
              let state = HelperControlReply.State(rawValue: ls_xpc_reply_state(rawReply)),
              let power = HelperControlReply.Power(rawValue: ls_xpc_reply_power_source(rawReply))
        else { invalidateClientLocked(); throw HelperControlError.malformedReply }
        // The reason is deliberately not materialized/exposed until result,
        // operation, session, state, and expiry binding have all validated.
        let reasonLength = strnlen(reasonPointer, 97)
        guard reasonLength > 0, reasonLength <= 96 else { invalidateClientLocked(); throw HelperControlError.malformedReply }
        let result = ls_xpc_reply_result(rawReply)
        do {
            if result == 0 {
                try Self.validateSuccessfulReply(operation: operation, requestedSessionID: sessionID,
                                                 replySessionID: replySession, state: state,
                                                 expiryMonotonic: ls_xpc_reply_expiry_monotonic(rawReply))
            } else {
                try Self.validateRejectedReply(operation: operation, requestedSessionID: sessionID,
                                               replySessionID: replySession, state: state,
                                               expiryMonotonic: ls_xpc_reply_expiry_monotonic(rawReply))
            }
        } catch {
            invalidateClientLocked()
            throw error
        }
        let reason = String(cString: reasonPointer)
        let ac = ls_xpc_reply_ac_sleep_minutes(rawReply)
        let reply = HelperControlReply(reason: reason, sessionID: replySession,
                                       expiryMonotonic: ls_xpc_reply_expiry_monotonic(rawReply), state: state,
                                       power: power, sleepDisabled: ls_xpc_reply_sleep_disabled(rawReply),
                                       acSleepMinutes: ac >= 0 ? Int(ac) : nil)
        return result == 0 ? .accepted(reply) : .rejected(reply)
    }

    static func validateSuccessfulReply(
        operation: UInt32,
        requestedSessionID: UUID,
        replySessionID: UUID,
        state: HelperControlReply.State,
        expiryMonotonic: TimeInterval
    ) throws {
        switch operation {
        case UInt32(LS_OPERATION_BEGIN.rawValue), UInt32(LS_OPERATION_RENEW.rawValue),
             UInt32(LS_OPERATION_RECONNECT.rawValue):
            guard replySessionID == requestedSessionID,
                  state == .active,
                  validActiveExpiry(expiryMonotonic)
            else { throw HelperControlError.malformedReply }
        case UInt32(LS_OPERATION_END.rawValue):
            guard replySessionID == requestedSessionID, state == .terminal, expiryMonotonic == 0 else {
                throw HelperControlError.malformedReply
            }
        case UInt32(LS_OPERATION_SNAPSHOT.rawValue):
            guard replySessionID == requestedSessionID else { throw HelperControlError.malformedReply }
            if state == .active {
                guard validActiveExpiry(expiryMonotonic) else { throw HelperControlError.malformedReply }
            } else if expiryMonotonic != 0 { throw HelperControlError.malformedReply }
        case UInt32(LS_OPERATION_RESTORE.rawValue):
            guard (state == .idle || state == .terminal || state == .recoveryRequired), expiryMonotonic == 0 else {
                throw HelperControlError.malformedReply
            }
        default:
            throw HelperControlError.malformedReply
        }
    }

    static func validateRejectedReply(
        operation: UInt32,
        requestedSessionID: UUID,
        replySessionID: UUID,
        state: HelperControlReply.State,
        expiryMonotonic: TimeInterval
    ) throws {
        guard isKnownOperation(operation) else { throw HelperControlError.malformedReply }
        if state == .active {
            // A rejected connection-mismatch/second-connection reply truthfully
            // names the *currently active* generation. The authenticated
            // bridge still binds request-id and code identity; accepting this
            // one shape avoids hiding a safety-relevant active lease.
            guard validActiveExpiry(expiryMonotonic) else { throw HelperControlError.malformedReply }
            return
        }
        // RESTORE may surface an already terminalized prior generation. Other
        // non-active rejections remain exactly request-session bound.
        if operation != UInt32(LS_OPERATION_RESTORE.rawValue), replySessionID != requestedSessionID {
            throw HelperControlError.malformedReply
        }
        guard expiryMonotonic == 0 else {
            throw HelperControlError.malformedReply
        }
    }

    static func validActiveExpiry(_ expiry: TimeInterval, now: TimeInterval = MonotonicClock.seconds()) -> Bool {
        expiry.isFinite && expiry > now && expiry <= now + maximumLeaseLifetime + replyExpirySlack
    }

    private static func isKnownOperation(_ operation: UInt32) -> Bool {
        switch operation {
        case UInt32(LS_OPERATION_BEGIN.rawValue), UInt32(LS_OPERATION_RENEW.rawValue),
             UInt32(LS_OPERATION_RECONNECT.rawValue), UInt32(LS_OPERATION_END.rawValue),
             UInt32(LS_OPERATION_SNAPSHOT.rawValue), UInt32(LS_OPERATION_RESTORE.rawValue):
            return true
        default:
            return false
        }
    }

    /// A terminal generation must first RECONNECT its exact process before its
    /// one END/RESTORE effect. Give that prerequisite rebind the same bounded
    /// terminal budget without widening normal heartbeat reconnects.
    private static func timeoutSeconds(for operation: UInt32, terminalContext: Bool = false) -> Double {
        switch operation {
        case UInt32(LS_OPERATION_END.rawValue), UInt32(LS_OPERATION_RESTORE.rawValue):
            return 10
        case UInt32(LS_OPERATION_RECONNECT.rawValue) where terminalContext:
            return 10
        default:
            return 5
        }
    }

#if DEBUG
    static func timeoutSecondsForTesting(operation: UInt32, terminalContext: Bool = false) -> Double {
        timeoutSeconds(for: operation, terminalContext: terminalContext)
    }
#endif

    private func invalidateClientLocked() {
        if let rawClient {
            ls_xpc_client_release(rawClient)
            self.rawClient = nil
        }
    }

    private func connectedClient() throws -> OpaquePointer {
        if let rawClient { return rawClient }
        let readPolicy = BoundedFileReadPolicy(maximumBytes: EnrollmentPolicy.maximumBytes, expectedOwnerUID: 0,
                                               requireSingleLink: true, rejectGroupOrWorldWritable: true,
                                               requireNonEmpty: true, safeParentDepth: 1)
        guard case let .success(raw) = BoundedFileReader.readUTF8(path: AppPaths.rootEnrollmentPolicyPath, policy: readPolicy),
              let enrollment = EnrollmentPolicy.parse(raw), enrollment.helperIdentifier == helperIdentity.identifier,
              enrollment.helperCDHash == helperIdentity.cdhash else { throw HelperControlError.unavailable }
        let expectedUID: uid_t = 0
        let policy = helperIdentity.withPolicy(expectedEUID: expectedUID, profile: enrollment.profile,
                                               teamIdentifier: enrollment.teamIdentifier)
        guard let policy else { throw HelperControlError.unavailable }
        defer { ls_identity_policy_release(policy) }
        guard let client = ls_xpc_client_create(AppPaths.helperMachService, policy) else { throw HelperControlError.unavailable }
        rawClient = client
        return client
    }

    private static let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    private static var isXCTestRuntime: Bool {
        let process = ProcessInfo.processInfo
        let executable = process.arguments.first ?? ""
        return executable.contains(".xctest") || executable.hasSuffix("/xctest")
            || process.environment["XCTestConfigurationFilePath"] != nil
            || process.environment["XCTestBundlePath"] != nil
    }
}

struct CodeIdentity: Equatable, Sendable {
    let identifier: String
    let cdhash: Data
    let teamIdentifier: String?

    static func current() -> CodeIdentity? { copy(ls_copy_current_code_identity()) }
    static func staticCode(at path: String) -> CodeIdentity? { copy(ls_copy_static_code_identity(path)) }

    private static func copy(_ raw: OpaquePointer?) -> CodeIdentity? {
        guard let raw else { return nil }
        defer { ls_code_identity_release(raw) }
        guard let identifier = ls_code_identity_identifier(raw), let bytes = ls_code_identity_cdhash(raw) else { return nil }
        let count = ls_code_identity_cdhash_length(raw)
        guard count == 20 else { return nil }
        let team = ls_code_identity_team_identifier(raw).flatMap { pointer -> String? in
            let value = String(cString: pointer); return value.isEmpty ? nil : value
        }
        return CodeIdentity(identifier: String(cString: identifier), cdhash: Data(bytes: bytes, count: count), teamIdentifier: team)
    }

    func withPolicy(expectedEUID: uid_t, profile: EnrollmentProfile, teamIdentifier enrolledTeam: String?) -> OpaquePointer? {
        cdhash.withUnsafeBytes { buffer in
            if profile == .developerIDExact, let enrolledTeam, enrolledTeam == teamIdentifier {
                return enrolledTeam.withCString { team in
                    ls_identity_policy_create(identifier, buffer.bindMemory(to: UInt8.self).baseAddress, cdhash.count,
                                              expectedEUID, LS_IDENTITY_DEVELOPER_ID_EXACT, team)
                }
            }
            guard profile == .manualExact, enrolledTeam == nil else { return nil }
            return ls_identity_policy_create(identifier, buffer.bindMemory(to: UInt8.self).baseAddress, cdhash.count,
                                             expectedEUID, LS_IDENTITY_MANUAL_EXACT, nil)
        }
    }
}
