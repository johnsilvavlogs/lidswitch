import Darwin
import Foundation

/// Fixed-schema process contract shared by privileged helper callers.  It
/// deliberately exposes no shell, PATH lookup, or caller environment surface.
public enum ContainedProcessCommand: Sendable {
    case pmsetSleepDisabled(Bool)
    case pmsetACSleep(Int)
    case pmsetBatterySleep(Int)
    case currentHelperPrint
    case legacyHelperPrint(uid_t)
    case legacyHelperPrintDisabled(uid_t)

    fileprivate var executable: String {
        switch self {
        case .pmsetSleepDisabled, .pmsetACSleep, .pmsetBatterySleep: "/usr/bin/pmset"
        case .currentHelperPrint, .legacyHelperPrint, .legacyHelperPrintDisabled: "/bin/launchctl"
        }
    }

    fileprivate var arguments: [String] {
        switch self {
        case let .pmsetSleepDisabled(enabled): ["-a", "disablesleep", enabled ? "1" : "0"]
        case let .pmsetACSleep(minutes): ["-c", "sleep", String(minutes)]
        case let .pmsetBatterySleep(minutes): ["-b", "sleep", String(minutes)]
        case .currentHelperPrint: ["print", "system/com.johnsilva.lidswitch.helper"]
        case let .legacyHelperPrint(uid): ["print", "gui/\(uid)/com.johnsilva.LidSwitch.login"]
        case let .legacyHelperPrintDisabled(uid): ["print-disabled", "gui/\(uid)"]
        }
    }

    fileprivate var isValid: Bool {
        switch self {
        case let .pmsetACSleep(minutes), let .pmsetBatterySleep(minutes):
            return (0...1_440).contains(minutes)
        case .pmsetSleepDisabled, .currentHelperPrint, .legacyHelperPrint, .legacyHelperPrintDisabled:
            return true
        }
    }
}

public enum ContainedProcessOutcome: Equatable, Sendable {
    case completed
    case timedOut
    case signaled(Int32)
    case outputTruncated
    case launchFailed
    case containmentFailed
    /// The caller's finite synchronous window expired after a receipt was
    /// durably accepted by its authority boundary.  Callers must treat this as
    /// a mutation fence, never as a retryable command error.
    case containmentPending
}

public struct ContainedProcessIdentity: Equatable, Sendable {
    public let pid: Int32
    public let startSeconds: Int64
    public let startMicroseconds: Int32

    public init(pid: Int32, startSeconds: Int64, startMicroseconds: Int32) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }
}

/// A signal-eligible member is bound independently.  A group PID alone is not
/// sufficient: both its executable path and complete argv fingerprint travel
/// with its kernel birth tuple.
public struct ContainedProcessMember: Equatable, Sendable {
    public let identity: ContainedProcessIdentity
    public let executable: String
    public let commandFingerprint: String

    public init(identity: ContainedProcessIdentity, executable: String, commandFingerprint: String) {
        self.identity = identity
        self.executable = executable
        self.commandFingerprint = commandFingerprint
    }
}

/// Root-private handoff record for a command group that outlived the caller's
/// finite wait.  The helper owns serialization/persistence; this type is kept
/// in Core so the runner cannot silently choose an authority directory.
public struct ContainedProcessReceipt: Equatable, Sendable {
    public enum CleanupPhase: String, Equatable, Sendable { case pending, term, kill, extinguished, ambiguous }
    public let schema: Int
    public let token: UUID
    public let executable: String
    public let commandFingerprint: String
    public let leader: ContainedProcessIdentity
    public let members: [ContainedProcessMember]
    public let processGroupID: Int32
    public let sessionID: Int32
    public let rootDeadlineNanoseconds: UInt64
    public let cleanupDeadlineNanoseconds: UInt64
    public let noSecondMutation: Bool
    public let phase: CleanupPhase
    public let termSignalIssued: Bool
    public let killSignalIssued: Bool
    public let leaderReaped: Bool
    /// Persisted under the receipt CAS.  It bounds restart-time EINTR/ECHILD
    /// observation work without treating either as proof of extinction.
    public let reapAttemptCount: UInt8
    public let cleanupOwnerToken: UUID?
    public let ownerDeadlineNanoseconds: UInt64

    public init(token: UUID, executable: String, commandFingerprint: String,
                leader: ContainedProcessIdentity, members: [ContainedProcessMember],
                processGroupID: Int32, sessionID: Int32, rootDeadlineNanoseconds: UInt64,
                cleanupDeadlineNanoseconds: UInt64, noSecondMutation: Bool = true,
                phase: CleanupPhase = .pending, termSignalIssued: Bool = false, killSignalIssued: Bool = false, leaderReaped: Bool = false, reapAttemptCount: UInt8 = 0, cleanupOwnerToken: UUID? = nil,
                ownerDeadlineNanoseconds: UInt64 = 0) {
        self.schema = 4; self.token = token; self.executable = executable
        self.commandFingerprint = commandFingerprint; self.leader = leader
        self.members = members; self.processGroupID = processGroupID; self.sessionID = sessionID
        self.rootDeadlineNanoseconds = rootDeadlineNanoseconds
        self.cleanupDeadlineNanoseconds = cleanupDeadlineNanoseconds
        self.noSecondMutation = noSecondMutation
        self.phase = phase; self.termSignalIssued = termSignalIssued; self.killSignalIssued = killSignalIssued; self.leaderReaped = leaderReaped; self.reapAttemptCount = reapAttemptCount; self.cleanupOwnerToken = cleanupOwnerToken
        self.ownerDeadlineNanoseconds = ownerDeadlineNanoseconds
    }

    public func claimed(by owner: UUID, until deadline: UInt64) -> ContainedProcessReceipt? {
        guard phase == .pending, ownerDeadlineNanoseconds == 0, deadline > 0 else { return nil }
        return .init(token: token, executable: executable, commandFingerprint: commandFingerprint,
                     leader: leader, members: members, processGroupID: processGroupID, sessionID: sessionID,
                     rootDeadlineNanoseconds: rootDeadlineNanoseconds, cleanupDeadlineNanoseconds: cleanupDeadlineNanoseconds,
                     noSecondMutation: noSecondMutation, phase: .term, termSignalIssued: false, killSignalIssued: false, leaderReaped: false, reapAttemptCount: 0, cleanupOwnerToken: owner,
                     ownerDeadlineNanoseconds: deadline)
    }

    public func reclaimed(by owner: UUID, now: UInt64, until deadline: UInt64) -> ContainedProcessReceipt? {
        guard (phase == .term || phase == .kill), ownerDeadlineNanoseconds < now, deadline > now else { return nil }
        return .init(token: token, executable: executable, commandFingerprint: commandFingerprint,
                     leader: leader, members: members, processGroupID: processGroupID, sessionID: sessionID,
                     rootDeadlineNanoseconds: rootDeadlineNanoseconds, cleanupDeadlineNanoseconds: cleanupDeadlineNanoseconds,
                     // Restart only changes ownership.  Rewinding KILL to TERM
                     // would create a second mutation path after a crash.
                     noSecondMutation: noSecondMutation, phase: phase, termSignalIssued: termSignalIssued, killSignalIssued: killSignalIssued, leaderReaped: leaderReaped, reapAttemptCount: reapAttemptCount, cleanupOwnerToken: owner,
                     ownerDeadlineNanoseconds: deadline)
    }

    public func advancing(to next: CleanupPhase, owner: UUID, deadline: UInt64) -> ContainedProcessReceipt? {
        guard cleanupOwnerToken == owner, phase == .term || phase == .kill,
              (next == .kill || next == .ambiguous || next == .extinguished), deadline >= ownerDeadlineNanoseconds
        else { return nil }
        guard next != .extinguished || leaderReaped else { return nil }
        return .init(token: token, executable: executable, commandFingerprint: commandFingerprint,
                     leader: leader, members: members, processGroupID: processGroupID, sessionID: sessionID,
                     rootDeadlineNanoseconds: rootDeadlineNanoseconds, cleanupDeadlineNanoseconds: cleanupDeadlineNanoseconds,
                     noSecondMutation: noSecondMutation, phase: next, termSignalIssued: termSignalIssued, killSignalIssued: next == .kill ? false : killSignalIssued, leaderReaped: leaderReaped, reapAttemptCount: reapAttemptCount, cleanupOwnerToken: owner,
                     ownerDeadlineNanoseconds: deadline)
    }

    /// The TERM intent is committed before the signal.  On restart a committed
    /// intent is observed/reaped rather than emitted again.
    public func markingTermSignalIssued(owner: UUID, deadline: UInt64) -> ContainedProcessReceipt? {
        guard phase == .term, !termSignalIssued, cleanupOwnerToken == owner, deadline >= ownerDeadlineNanoseconds else { return nil }
        return .init(token: token, executable: executable, commandFingerprint: commandFingerprint,
                     leader: leader, members: members, processGroupID: processGroupID, sessionID: sessionID,
                     rootDeadlineNanoseconds: rootDeadlineNanoseconds, cleanupDeadlineNanoseconds: cleanupDeadlineNanoseconds,
                     noSecondMutation: noSecondMutation, phase: .term, termSignalIssued: true, killSignalIssued: false, leaderReaped: leaderReaped, reapAttemptCount: reapAttemptCount, cleanupOwnerToken: owner,
                     ownerDeadlineNanoseconds: deadline)
    }

    public func markingKillSignalIssued(owner: UUID, deadline: UInt64) -> ContainedProcessReceipt? {
        guard phase == .kill, !killSignalIssued, termSignalIssued, cleanupOwnerToken == owner,
              deadline >= ownerDeadlineNanoseconds else { return nil }
        return .init(token: token, executable: executable, commandFingerprint: commandFingerprint,
                     leader: leader, members: members, processGroupID: processGroupID, sessionID: sessionID,
                     rootDeadlineNanoseconds: rootDeadlineNanoseconds, cleanupDeadlineNanoseconds: cleanupDeadlineNanoseconds,
                     noSecondMutation: noSecondMutation, phase: .kill, termSignalIssued: true, killSignalIssued: true, leaderReaped: leaderReaped, reapAttemptCount: reapAttemptCount,
                     cleanupOwnerToken: owner, ownerDeadlineNanoseconds: deadline)
    }

    public func markingLeaderReaped(owner: UUID, deadline: UInt64) -> ContainedProcessReceipt? {
        guard !leaderReaped, cleanupOwnerToken == owner, deadline >= ownerDeadlineNanoseconds,
              phase == .term || phase == .kill else { return nil }
        return .init(token: token, executable: executable, commandFingerprint: commandFingerprint,
                     leader: leader, members: members, processGroupID: processGroupID, sessionID: sessionID,
                     rootDeadlineNanoseconds: rootDeadlineNanoseconds, cleanupDeadlineNanoseconds: cleanupDeadlineNanoseconds,
                     noSecondMutation: noSecondMutation, phase: phase, termSignalIssued: termSignalIssued,
                     killSignalIssued: killSignalIssued, leaderReaped: true, reapAttemptCount: reapAttemptCount, cleanupOwnerToken: owner,
                     ownerDeadlineNanoseconds: deadline)
    }

    /// Commit that this owner consumed one bounded waitpid observation before
    /// making it.  This lets a restart distinguish a genuinely unproven reap
    /// from a fresh receipt and gives deadline handling a durable cap.
    public func recordingReapAttempt(owner: UUID, deadline: UInt64) -> ContainedProcessReceipt? {
        guard cleanupOwnerToken == owner, deadline >= ownerDeadlineNanoseconds,
              !leaderReaped, (phase == .term || phase == .kill), reapAttemptCount < 8 else { return nil }
        return .init(token: token, executable: executable, commandFingerprint: commandFingerprint,
                     leader: leader, members: members, processGroupID: processGroupID, sessionID: sessionID,
                     rootDeadlineNanoseconds: rootDeadlineNanoseconds, cleanupDeadlineNanoseconds: cleanupDeadlineNanoseconds,
                     noSecondMutation: noSecondMutation, phase: phase, termSignalIssued: termSignalIssued,
                     killSignalIssued: killSignalIssued, leaderReaped: false, reapAttemptCount: reapAttemptCount + 1,
                     cleanupOwnerToken: owner, ownerDeadlineNanoseconds: deadline)
    }

    /// The synchronous caller can only extend a pending receipt within its
    /// fixed total containment lifetime.  It cannot alter identity, owner, or
    /// mutation phase while doing so.
    public func refreshingCleanupDeadline(_ deadline: UInt64) -> ContainedProcessReceipt? {
        guard phase == .pending, cleanupOwnerToken == nil, ownerDeadlineNanoseconds == 0,
              deadline >= cleanupDeadlineNanoseconds, deadline >= rootDeadlineNanoseconds else { return nil }
        return .init(token: token, executable: executable, commandFingerprint: commandFingerprint,
                     leader: leader, members: members, processGroupID: processGroupID, sessionID: sessionID,
                     rootDeadlineNanoseconds: rootDeadlineNanoseconds, cleanupDeadlineNanoseconds: deadline,
                     noSecondMutation: noSecondMutation, phase: phase, termSignalIssued: termSignalIssued,
                     killSignalIssued: killSignalIssued, leaderReaped: leaderReaped, reapAttemptCount: reapAttemptCount, cleanupOwnerToken: nil, ownerDeadlineNanoseconds: 0)
    }

    public var storagePayload: String {
        let members = members.map { member in
            let executable = Data(member.executable.utf8).base64EncodedString()
            return "\(member.identity.pid):\(member.identity.startSeconds):\(member.identity.startMicroseconds):\(executable):\(member.commandFingerprint)"
        }.joined(separator: ",")
        return [
            "schema=4", "token=\(token.uuidString.lowercased())", "executable=\(executable)",
            "fingerprint=\(commandFingerprint)",
            "leader=\(leader.pid):\(leader.startSeconds):\(leader.startMicroseconds)",
            "members=\(members)", "pgid=\(processGroupID)", "sid=\(sessionID)",
            "root_deadline=\(rootDeadlineNanoseconds)", "cleanup_deadline=\(cleanupDeadlineNanoseconds)",
            "no_second_mutation=\(noSecondMutation ? "1" : "0")", "phase=\(phase.rawValue)", "term_signal_issued=\(termSignalIssued ? "1" : "0")", "kill_signal_issued=\(killSignalIssued ? "1" : "0")", "leader_reaped=\(leaderReaped ? "1" : "0")", "reap_attempts=\(reapAttemptCount)",
            "owner=\(cleanupOwnerToken?.uuidString.lowercased() ?? "none")",
            "owner_deadline=\(ownerDeadlineNanoseconds)", ""
        ].joined(separator: "\n")
    }

    public static func parse(_ raw: String) -> ContainedProcessReceipt? {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.last == "", lines.count == 19 else { return nil }
        var fields: [String: String] = [:]
        for line in lines.dropLast() {
            let pieces = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2, !pieces[0].isEmpty, fields[String(pieces[0])] == nil else { return nil }
            fields[String(pieces[0])] = String(pieces[1])
        }
        guard fields["schema"] == "4", fields["no_second_mutation"] == "1",
              let tokenRaw = fields["token"], tokenRaw == tokenRaw.lowercased(), let token = UUID(uuidString: tokenRaw),
              let executable = fields["executable"], ["/usr/bin/pmset", "/bin/launchctl"].contains(executable),
              let fingerprint = fields["fingerprint"], fingerprint.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil,
              let leader = parseIdentity(fields["leader"] ?? ""),
              let membersRaw = fields["members"], !membersRaw.isEmpty,
              let pgid = Int32(fields["pgid"] ?? ""), pgid == leader.pid,
              let sid = Int32(fields["sid"] ?? ""), sid > 0,
              let root = UInt64(fields["root_deadline"] ?? ""), let cleanup = UInt64(fields["cleanup_deadline"] ?? ""),
              cleanup >= root, let phaseRaw = fields["phase"], let phase = CleanupPhase(rawValue: phaseRaw),
              let termIssuedRaw = fields["term_signal_issued"], let termIssued = parseFlag(termIssuedRaw),
              let killIssuedRaw = fields["kill_signal_issued"], let killIssued = parseFlag(killIssuedRaw),
              let leaderReapedRaw = fields["leader_reaped"], let leaderReaped = parseFlag(leaderReapedRaw),
              let attemptsRaw = fields["reap_attempts"], let attempts = UInt8(attemptsRaw), attempts <= 8,
              let ownerRaw = fields["owner"], let ownerDeadline = UInt64(fields["owner_deadline"] ?? "")
        else { return nil }
        let memberEntries = membersRaw.split(separator: ",", omittingEmptySubsequences: false)
        let members = memberEntries.compactMap { parseMember(String($0)) }
        guard !members.isEmpty, members.count == memberEntries.count, members.count <= 64,
              members.contains(where: { $0.identity == leader && $0.executable == executable && $0.commandFingerprint == fingerprint }),
              Set(members.map { "\($0.identity.pid):\($0.identity.startSeconds):\($0.identity.startMicroseconds)" }).count == members.count
        else { return nil }
        let owner = ownerRaw == "none" ? nil : (ownerRaw == ownerRaw.lowercased() ? UUID(uuidString: ownerRaw) : nil)
        guard (phase == .pending && !termIssued && !killIssued && !leaderReaped && attempts == 0 && owner == nil && ownerDeadline == 0)
                || (phase == .term && !killIssued && owner != nil && ownerDeadline >= root)
                || (phase == .kill && termIssued && owner != nil && ownerDeadline >= root)
                || (phase == .extinguished && leaderReaped && owner != nil && ownerDeadline >= root)
                || (phase == .ambiguous && owner != nil && ownerDeadline >= root)
        else { return nil }
        return .init(token: token, executable: executable, commandFingerprint: fingerprint,
                     leader: leader, members: members, processGroupID: pgid, sessionID: sid,
                     rootDeadlineNanoseconds: root, cleanupDeadlineNanoseconds: cleanup,
                     phase: phase, termSignalIssued: termIssued, killSignalIssued: killIssued, leaderReaped: leaderReaped, reapAttemptCount: attempts, cleanupOwnerToken: owner, ownerDeadlineNanoseconds: ownerDeadline)
    }

    private static func parseIdentity(_ raw: String) -> ContainedProcessIdentity? {
        let pieces = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 3, let pid = Int32(pieces[0]), pid > 0,
              let sec = Int64(pieces[1]), sec > 0, let usec = Int32(pieces[2]), (0..<1_000_000).contains(usec)
        else { return nil }
        return .init(pid: pid, startSeconds: sec, startMicroseconds: usec)
    }

    private static func parseMember(_ raw: String) -> ContainedProcessMember? {
        let pieces = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 5,
              let identity = parseIdentity(pieces.prefix(3).joined(separator: ":")),
              let data = Data(base64Encoded: String(pieces[3])),
              let executable = String(data: data, encoding: .utf8),
              ["/usr/bin/pmset", "/bin/launchctl"].contains(executable),
              let fingerprint = Optional(String(pieces[4])),
              fingerprint.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil
        else { return nil }
        let canonical = Data(executable.utf8).base64EncodedString()
        guard canonical == String(pieces[3]) else { return nil }
        return .init(identity: identity, executable: executable, commandFingerprint: fingerprint)
    }

    private static func parseFlag(_ raw: String) -> Bool? { raw == "1" ? true : raw == "0" ? false : nil }
}

public struct ContainedProcessResult: Equatable, Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let outcome: ContainedProcessOutcome
    public let containmentReceipt: ContainedProcessReceipt?

    public init(stdout: String, stderr: String, exitCode: Int32,
                outcome: ContainedProcessOutcome, containmentReceipt: ContainedProcessReceipt? = nil) {
        self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode
        self.outcome = outcome; self.containmentReceipt = containmentReceipt
    }
}

/// Production cleanup and fixtures share this reducer. Syscall collection is
/// intentionally outside it: a PID is actionable only when the collector has
/// revalidated the recorded kernel birth tuple, PGID, SID and fixed command.
public enum ContainedProcessCleanupMachine {
    public enum Observation: Equatable, Sendable {
        case liveExact
        case leaderReapedAndExtinct
        case memberReusedOrUnknown
        case groupOrSessionMismatch
        case incompleteInventory
    }
    public enum Action: Equatable, Sendable { case signalTERM, signalKILL, reapLeader, extinguished, retainFence }

    public static func next(
        receipt: ContainedProcessReceipt,
        owner: UUID,
        now: UInt64,
        observation: Observation
    ) -> Action {
        guard receipt.cleanupOwnerToken == owner, receipt.noSecondMutation else { return .retainFence }
        switch observation {
        case .memberReusedOrUnknown, .groupOrSessionMismatch, .incompleteInventory:
            return .retainFence
        case .leaderReapedAndExtinct:
            if receipt.leaderReaped { return .extinguished }
            // Absence of members cannot remove a receipt until this parent has
            // itself reaped the recorded leader.  At lease expiry it becomes
            // one retained ambiguity, not an endlessly scheduled waitpid.
            return now < receipt.ownerDeadlineNanoseconds && receipt.reapAttemptCount < 8 ? .reapLeader : .retainFence
        case .liveExact:
            guard now < receipt.cleanupDeadlineNanoseconds else { return .retainFence }
            switch receipt.phase {
            case .term:
                if !receipt.termSignalIssued { return .signalTERM }
                return now < receipt.ownerDeadlineNanoseconds ? .reapLeader : .signalKILL
            case .kill: return receipt.killSignalIssued ? .reapLeader : .signalKILL
            case .pending, .extinguished, .ambiguous: return .retainFence
            }
        }
    }
}

public extension ContainedProcessRunner {
    /// Performs at most one exact-identity cleanup action. It never signals a
    /// numeric process group: after a helper restart that number may belong to
    /// unrelated work. The caller persists every phase transition separately.
    static func cleanupStep(
        receipt: ContainedProcessReceipt,
        owner: UUID,
        now: UInt64
    ) -> ContainedProcessCleanupMachine.Action {
        let observation = cleanupObservation(receipt)
        let action = ContainedProcessCleanupMachine.next(receipt: receipt, owner: owner, now: now, observation: observation)
        return action
    }

    static func executeCleanupAction(_ action: ContainedProcessCleanupMachine.Action, receipt: ContainedProcessReceipt) {
        switch action {
        case .signalTERM: signalExactMembers(receipt, signal: SIGTERM)
        case .signalKILL: signalExactMembers(receipt, signal: SIGKILL)
        case .reapLeader: _ = reapLeaderIfExited(receipt)
        case .extinguished, .retainFence: break
        }
    }

    enum LeaderReapOutcome: Equatable, Sendable { case reaped, live, echild, interruptedLimit, failed(Int32) }

    /// Parent-only, nonblocking reap proof. EINTR is bounded and ECHILD is
    /// typed explicitly; neither is extinction proof.
    static func reapLeaderIfExited(_ receipt: ContainedProcessReceipt) -> Bool {
        reapLeaderOutcome(receipt) == .reaped
    }

    static func reapLeaderOutcome(_ receipt: ContainedProcessReceipt) -> LeaderReapOutcome {
        reapLeaderOutcome(receipt) { pid in
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            return (result, errno)
        }
    }

    /// Production waitpid loop with an injectable syscall boundary for the
    /// source fixture. A transient EINTR is retried; ECHILD and every other
    /// unexpected result intentionally leave the receipt fenced.
    static func reapLeaderIfExited(
        _ receipt: ContainedProcessReceipt,
        waitNoHang: (pid_t) -> (result: pid_t, error: Int32)
    ) -> Bool {
        reapLeaderOutcome(receipt, waitNoHang: waitNoHang) == .reaped
    }

    static func reapLeaderOutcome(
        _ receipt: ContainedProcessReceipt,
        maximumInterrupts: UInt8 = 4,
        waitNoHang: (pid_t) -> (result: pid_t, error: Int32)
    ) -> LeaderReapOutcome {
        var interrupts: UInt8 = 0
        while true {
            let observed = waitNoHang(receipt.leader.pid)
            if observed.result == receipt.leader.pid { return .reaped }
            if observed.result == 0 { return .live }
            if observed.error == ECHILD { return .echild }
            if observed.error == EINTR {
                guard interrupts < maximumInterrupts else { return .interruptedLimit }
                interrupts += 1
                continue
            }
            return .failed(observed.error)
        }
    }

    private static func cleanupObservation(_ receipt: ContainedProcessReceipt) -> ContainedProcessCleanupMachine.Observation {
        var live = 0
        for member in receipt.members {
            guard let current = processIdentity(member.identity.pid) else { continue }
            guard current == member.identity else { return .memberReusedOrUnknown }
            guard getpgid(member.identity.pid) == receipt.processGroupID, getsid(member.identity.pid) == receipt.sessionID else {
                return .groupOrSessionMismatch
            }
            guard exactCommandFingerprint(member.identity.pid, executable: member.executable) == member.commandFingerprint else {
                return .memberReusedOrUnknown
            }
            live += 1
        }
        let firstGroup = exactInventory(processGroup: receipt.processGroupID, session: receipt.sessionID)
        let secondGroup = exactInventory(processGroup: receipt.processGroupID, session: receipt.sessionID)
        guard case let .exact(first) = firstGroup, case let .exact(second) = secondGroup, first == second else {
            return .incompleteInventory
        }
        // A member arriving after the receipt or an unexpected process in the
        // saved PGID/SID is not ours to signal and prevents extinction proof.
        guard first.allSatisfy({ identity in receipt.members.contains(where: { $0.identity == identity }) }) else { return .incompleteInventory }
        guard live == 0, first.isEmpty else { return .liveExact }
        return .leaderReapedAndExtinct
    }

    private static func signalExactMembers(_ receipt: ContainedProcessReceipt, signal: Int32) {
        for member in receipt.members where processIdentity(member.identity.pid) == member.identity
            && getpgid(member.identity.pid) == receipt.processGroupID
            && getsid(member.identity.pid) == receipt.sessionID
            && exactCommandFingerprint(member.identity.pid, executable: member.executable) == member.commandFingerprint {
            var interrupts = 0
            while kill(member.identity.pid, signal) != 0, errno == EINTR, interrupts < 4 { interrupts += 1 }
        }
    }
}

/// Bounded direct-exec runner for helper-only fixed commands. The atomic spawn
/// group is observed through Darwin's process-group inventory while its leader
/// remains unreaped, preserving the PGID reservation through final containment.
public enum ContainedProcessRunner {
    private static let cleanEnvironment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
    private static let receiptSinkKey = "com.johnsilva.lidswitch.contained-process-receipt-sink"

    private final class ReceiptSinkBox: NSObject {
        let sink: (ContainedProcessReceipt) -> Bool
        let replace: (ContainedProcessReceipt, ContainedProcessReceipt) -> Bool
        let release: (ContainedProcessReceipt) -> Bool
        let accepted: () -> Bool
        init(_ sink: @escaping (ContainedProcessReceipt) -> Bool,
             replace: @escaping (ContainedProcessReceipt, ContainedProcessReceipt) -> Bool,
             release: @escaping (ContainedProcessReceipt) -> Bool,
             accepted: @escaping () -> Bool) {
            self.sink = sink; self.replace = replace; self.release = release; self.accepted = accepted
        }
    }

    /// Installs a transaction-scoped authority sink for one synchronous power
    /// mutation.  The runner never creates its own background owner: pending
    /// containment is reportable only after this sink has persisted the token.
    public static func withContainmentReceiptSink<T>(
        _ sink: @escaping (ContainedProcessReceipt) -> Bool,
        replace: @escaping (ContainedProcessReceipt, ContainedProcessReceipt) -> Bool,
        release: @escaping (ContainedProcessReceipt) -> Bool,
        onAccepted: @escaping () -> Bool = { true },
        _ body: () throws -> T
    ) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let prior = dictionary[receiptSinkKey]
        dictionary[receiptSinkKey] = ReceiptSinkBox(sink, replace: replace, release: release, accepted: onAccepted)
        defer {
            if let prior { dictionary[receiptSinkKey] = prior }
            else { dictionary.removeObject(forKey: receiptSinkKey) }
        }
        return try body()
    }

    public static func run(
        _ command: ContainedProcessCommand,
        timeout: TimeInterval = 2,
        maximumOutputBytes: Int = 16 * 1_024
    ) -> ContainedProcessResult {
        runSpawned(command, timeout: timeout, maximumOutputBytes: maximumOutputBytes)
    }

    /// Pure deterministic containment decision seam. Production supplies the
    /// observations from waitid/kill/poll; fixtures can cover deadlines and
    /// descendant boundaries without launching a subprocess.
    public struct FixtureState: Equatable, Sendable {
        public let leaderExited: Bool
        public let groupGone: Bool
        public let stdoutEOF: Bool
        public let stderrEOF: Bool
        public let outputExceeded: Bool
        public let now: UInt64
        public let deadline: UInt64
        public let killDeadline: UInt64
        public let cleanupDeadline: UInt64
        public let phase: Int

        public init(leaderExited: Bool, groupGone: Bool, stdoutEOF: Bool, stderrEOF: Bool,
                    outputExceeded: Bool, now: UInt64, deadline: UInt64, killDeadline: UInt64,
                    cleanupDeadline: UInt64, phase: Int) {
            self.leaderExited = leaderExited; self.groupGone = groupGone
            self.stdoutEOF = stdoutEOF; self.stderrEOF = stderrEOF
            self.outputExceeded = outputExceeded; self.now = now; self.deadline = deadline
            self.killDeadline = killDeadline; self.cleanupDeadline = cleanupDeadline; self.phase = phase
        }
    }

    public enum FixtureDecision: Equatable, Sendable { case wait, term, kill, completed, outputLimit, containmentFailure }

    public static func fixtureDecision(_ state: FixtureState) -> FixtureDecision {
        if state.leaderExited && state.groupGone && state.stdoutEOF && state.stderrEOF {
            return state.outputExceeded ? .outputLimit : .completed
        }
        if state.phase >= 2 && state.now >= state.cleanupDeadline { return .containmentFailure }
        if state.phase == 1 && state.now >= state.killDeadline { return .kill }
        if (state.phase == 0 && state.now >= state.deadline) || (state.outputExceeded && state.phase == 0) { return .term }
        return .wait
    }

    /// Scripted syscall boundary for deterministic tests. It deliberately
    /// models setup, nonblocking drains, descriptor closure, group inventory,
    /// and deadlines without constructing a child process in the test target.
    public enum FixtureSetup: Equatable, Sendable {
        case ready, pipeFailure, fcntlFailure, fileActionFailure, attributeFailure, spawnFailure, descriptorClosureFailure
    }
    public enum FixtureDrain: Equatable, Sendable { case open, eof, interrupted, wouldBlock, failure }
    public enum FixtureGroup: Equatable, Sendable { case live, gone, ambiguous }
    public enum FixtureEvaluation: Equatable, Sendable { case wait, term, kill, completed, outputLimit, launchFailed, containmentFailure }
    public struct FixtureAdapterState: Equatable, Sendable {
        public let setup: FixtureSetup
        public let stdout: FixtureDrain
        public let stderr: FixtureDrain
        public let group: FixtureGroup
        public let leaderExited: Bool
        public let outputExceeded: Bool
        public let deadlineExpired: Bool
        public let termDeadlineExpired: Bool
        public let cleanupDeadlineExpired: Bool

        public init(setup: FixtureSetup, stdout: FixtureDrain, stderr: FixtureDrain,
                    group: FixtureGroup, leaderExited: Bool, outputExceeded: Bool,
                    deadlineExpired: Bool, termDeadlineExpired: Bool, cleanupDeadlineExpired: Bool) {
            self.setup = setup; self.stdout = stdout; self.stderr = stderr; self.group = group
            self.leaderExited = leaderExited; self.outputExceeded = outputExceeded
            self.deadlineExpired = deadlineExpired; self.termDeadlineExpired = termDeadlineExpired
            self.cleanupDeadlineExpired = cleanupDeadlineExpired
        }
    }

    public static func fixtureEvaluation(_ state: FixtureAdapterState) -> FixtureEvaluation {
        switch state.setup {
        case .spawnFailure: return .launchFailed
        case .ready: break
        case .pipeFailure, .fcntlFailure, .fileActionFailure, .attributeFailure, .descriptorClosureFailure:
            return .containmentFailure
        }
        guard state.stdout != .failure, state.stderr != .failure else { return .containmentFailure }
        // EINTR/EAGAIN are normal bounded-drain observations, not completion.
        if state.group == .ambiguous { return .containmentFailure }
        let streamsAtEOF = state.stdout == .eof && state.stderr == .eof
        if state.leaderExited && state.group == .gone && streamsAtEOF {
            return state.outputExceeded ? .outputLimit : .completed
        }
        if state.cleanupDeadlineExpired { return .containmentFailure }
        if state.termDeadlineExpired { return .kill }
        if state.outputExceeded || state.deadlineExpired { return .term }
        return .wait
    }

    /// Mirrors the synchronous post-spawn containment loop: fixtures drive
    /// TERM/KILL, inventory and reap observations one transition at a time.
    public enum CleanupPhase: Equatable, Sendable { case term, kill }
    public enum CleanupSignal: Equatable, Sendable { case sent, gone, failed }
    public enum CleanupTransition: Equatable, Sendable { case signalTerm, signalKill, wait, reaped, retainOwnership }
    public struct CleanupFixture: Equatable, Sendable {
        public let phase: CleanupPhase
        public let group: FixtureGroup
        public let leaderExited: Bool
        public let reapSucceeded: Bool
        public let signal: CleanupSignal
        public let termDeadlineExpired: Bool
        public init(phase: CleanupPhase, group: FixtureGroup, leaderExited: Bool, reapSucceeded: Bool,
                    signal: CleanupSignal, termDeadlineExpired: Bool) {
            self.phase = phase; self.group = group; self.leaderExited = leaderExited
            self.reapSucceeded = reapSucceeded; self.signal = signal; self.termDeadlineExpired = termDeadlineExpired
        }
    }
    public static func cleanupTransition(_ fixture: CleanupFixture) -> CleanupTransition {
        if fixture.leaderExited, fixture.group == .gone {
            return fixture.reapSucceeded ? .reaped : .retainOwnership
        }
        if fixture.phase == .term, !fixture.termDeadlineExpired { return .signalTerm }
        if fixture.phase == .term || fixture.signal == .failed { return .signalKill }
        return .signalKill
    }

    private static func runSpawned(
        _ command: ContainedProcessCommand,
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) -> ContainedProcessResult {
        guard command.isValid,
              timeout.isFinite, timeout > 0, timeout <= 30, maximumOutputBytes > 0 else {
            return .init(stdout: "", stderr: "invalid-contained-command-limit", exitCode: 125, outcome: .containmentFailed)
        }
        guard let spawned = spawn(command) else {
            return .init(stdout: "", stderr: "contained-spawn-failed", exitCode: 127, outcome: .launchFailed)
        }
        defer { close(spawned.stdout); close(spawned.stderr) }
        // `spawn` leaves the child stopped.  The exact leader receipt must be
        // durable before SIGCONT; a missing or failing authority sink is
        // resolved by killing and reaping that still-suspended one PID.
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        let initialCleanupDeadline = deadline &+ 5_000_000_000
        guard let receipt = makeReceipt(command: command, spawned: spawned,
                                        rootDeadline: deadline, cleanupDeadline: initialCleanupDeadline),
              let sink = Thread.current.threadDictionary[receiptSinkKey] as? ReceiptSinkBox,
              sink.sink(receipt)
        else {
            return discardSuspendedUnowned(spawned, stderr: "contained-receipt-unavailable")
        }
        // The helper-provided callback is registered against the root
        // transaction's after-unlock list, so cleanup cannot serialize behind
        // this synchronous process loop.
        guard sink.accepted() else {
            let result = discardSuspendedUnowned(spawned, stderr: "contained-cleanup-schedule-unverified")
            guard sink.release(receipt) else {
                // The child was synchronously reaped, but an unverified
                // receipt removal is still durable recovery work. Do not
                // collapse that scheduling/release failure to an ordinary
                // launch failure or hide the fence from the caller.
                return .init(stdout: result.stdout,
                             stderr: result.stderr + "\ncontained-receipt-release-pending",
                             exitCode: result.exitCode, outcome: .containmentPending,
                             containmentReceipt: receipt)
            }
            return result
        }
        guard resumeSuspended(spawned.child) else {
            return transferContainment(receipt: receipt, sink: sink, stdout: "",
                                       stderr: "contained-resume-failed")
        }
        guard setNonblocking(spawned.stdout), setNonblocking(spawned.stderr) else {
            return transferContainment(receipt: receipt, sink: sink, stdout: "", stderr: "contained-pipe-setup-failed")
        }
        let output = BoundedOutput(limit: maximumOutputBytes)
        let errors = BoundedOutput(limit: maximumOutputBytes)
        var stdoutEOF = false
        var stderrEOF = false
        var leaderExited = false
        var status: Int32 = 0
        while true {
            leaderExited = leaderExited || leaderHasExited(spawned.child)
            let group = groupObservation(spawned.child, leaderExited: leaderExited)
            let groupGone = group == .gone
            let stdoutSafe = drain(spawned.stdout, into: output, eof: &stdoutEOF)
            let stderrSafe = drain(spawned.stderr, into: errors, eof: &stderrEOF)
            guard stdoutSafe && stderrSafe else {
                return transferContainment(receipt: receipt, sink: sink, stdout: output.text,
                                           stderr: errors.text + "\ncontained-pipe-read-failed")
            }
            // The synchronous runner never signals. Incomplete inventory,
            // output bounds, timeouts, and I/O faults transfer the still
            // tracked child to durable cleanup before a signal is eligible.
            if group == .unknown || output.truncated || errors.truncated {
                return transferContainment(receipt: receipt, sink: sink, stdout: output.text, stderr: errors.text)
            }
            if leaderExited && groupGone && stdoutEOF && stderrEOF {
                guard reapSynchronously(spawned.child, status: &status) == .reaped else {
                    return transferContainment(receipt: receipt, sink: sink, stdout: output.text,
                                               stderr: errors.text + "\ncontained-reap-ambiguous")
                }
                guard sink.release(receipt) else {
                    return .init(stdout: output.text, stderr: errors.text + "\ncontained-receipt-release-pending",
                                 exitCode: normalizedExit(status), outcome: .containmentPending, containmentReceipt: receipt)
                }
                if output.truncated || errors.truncated {
                    return .init(stdout: output.text, stderr: errors.text, exitCode: normalizedExit(status), outcome: .outputTruncated)
                }
                if let signal = waitStatusSignal(status) {
                    return .init(stdout: output.text, stderr: errors.text, exitCode: 128 + signal, outcome: .signaled(signal))
                }
                return .init(stdout: output.text, stderr: errors.text, exitCode: normalizedExit(status), outcome: .completed)
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline {
                return transferContainment(receipt: receipt, sink: sink, stdout: output.text,
                                           stderr: errors.text + "\ncontained-sync-window-expired")
            }
            var descriptors = [
                pollfd(fd: stdoutEOF ? -1 : spawned.stdout, events: Int16(POLLIN | POLLHUP), revents: 0),
                pollfd(fd: stderrEOF ? -1 : spawned.stderr, events: Int16(POLLIN | POLLHUP), revents: 0),
            ]
            let pollResult = descriptors.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), 20) }
            if pollResult < 0 && errno != EINTR {
                return transferContainment(receipt: receipt, sink: sink, stdout: output.text,
                                           stderr: errors.text + "\ncontained-poll-failed")
            }
        }
    }

    private struct Spawned { let child: pid_t; let stdout: Int32; let stderr: Int32 }

    /// This is the only untracked-child path.  `spawn` guarantees the child is
    /// still stopped. The direct parent/child relationship returned by
    /// `posix_spawn` remains exclusive until this parent reaps it, so its PID
    /// cannot be recycled into an unrelated target on this path. We reap
    /// before returning.
    private static func discardSuspendedUnowned(_ spawned: Spawned, stderr: String) -> ContainedProcessResult {
        var status: Int32 = 0
        while kill(spawned.child, SIGKILL) != 0, errno == EINTR {}
        guard reapSynchronously(spawned.child, status: &status) == .reaped else {
            return .init(stdout: "", stderr: stderr + "\ncontained-suspended-reap-ambiguous",
                         exitCode: 125, outcome: .containmentFailed)
        }
        return .init(stdout: "", stderr: stderr + "\ncontained-suspended-reaped",
                     exitCode: normalizedExit(status), outcome: .containmentFailed)
    }

    private static func resumeSuspended(_ child: pid_t) -> Bool {
        guard processIdentity(child) != nil else { return false }
        while kill(child, SIGCONT) != 0 {
            if errno != EINTR { return false }
        }
        return true
    }

    private static func spawn(_ command: ContainedProcessCommand) -> Spawned? {
        var out = [Int32](repeating: -1, count: 2)
        var err = [Int32](repeating: -1, count: 2)
        guard pipe(&out) == 0, pipe(&err) == 0 else {
            out.filter { $0 >= 0 }.forEach { close($0) }
            err.filter { $0 >= 0 }.forEach { close($0) }
            return nil
        }
        guard normalizePipeEndpoints(&out), normalizePipeEndpoints(&err) else {
            out.filter { $0 >= 0 }.forEach { close($0) }
            err.filter { $0 >= 0 }.forEach { close($0) }
            return nil
        }
        defer {
            out.filter { $0 >= 0 }.forEach { close($0) }
            err.filter { $0 >= 0 }.forEach { close($0) }
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        let actionsReady = posix_spawn_file_actions_init(&actions) == 0
        guard actionsReady else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let attributesReady = posix_spawnattr_init(&attributes) == 0
        guard attributesReady else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        let actionResults = [
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, out[0]),
            posix_spawn_file_actions_addclose(&actions, err[0]),
            posix_spawn_file_actions_addclose(&actions, out[1]),
            posix_spawn_file_actions_addclose(&actions, err[1]),
        ]
        var mask = sigset_t()
        var defaults = sigset_t()
        guard sigemptyset(&mask) == 0, sigfillset(&defaults) == 0,
              actionResults.allSatisfy({ $0 == 0 }),
              posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_START_SUSPENDED)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0
        else { return nil }
        let argvStrings = [command.executable] + command.arguments
        let envStrings = cleanEnvironment.map { "\($0.key)=\($0.value)" }.sorted()
        return withCStringVector(argvStrings) { argv in
            guard let argv else { return nil }
            return withCStringVector(envStrings) { env in
                guard let env else { return nil }
                var child: pid_t = 0
                let result = command.executable.withCString {
                    posix_spawn(&child, $0, &actions, &attributes, argv, env)
                }
                guard result == 0 else { return nil }
                close(out[1]); out[1] = -1
                close(err[1]); err[1] = -1
                let spawned = Spawned(child: child, stdout: out[0], stderr: err[0])
                out[0] = -1; err[0] = -1
                return spawned
            } ?? nil
        } ?? nil
    }

    private static func withCStringVector<T>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> T
    ) -> T? {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { if let pointer = $0 { free(pointer) } } }
        guard pointers.dropLast().allSatisfy({ $0 != nil }) else { return nil }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress) }
    }

    private static func setNonblocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    /// Pipes can be allocated into closed standard-descriptor slots. Move each
    /// endpoint above STDERR using F_DUPFD_CLOEXEC before constructing spawn
    /// actions, then close the original. Parent endpoints consequently cannot
    /// leak across any later exec and child close/dup ordering is unambiguous.
    private static func normalizePipeEndpoints(_ endpoints: inout [Int32]) -> Bool {
        guard endpoints.count == 2 else { return false }
        for index in endpoints.indices {
            let original = endpoints[index]
            guard original >= 0 else { return false }
            let duplicate = fcntl(original, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            guard duplicate >= STDERR_FILENO + 1 else { return false }
            close(original)
            endpoints[index] = duplicate
        }
        return true
    }

    private static func drain(_ descriptor: Int32, into output: BoundedOutput, eof: inout Bool) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while !eof {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 { output.append(Data(buffer.prefix(count))); continue }
            if count == 0 { eof = true; return true }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return true }
            return false
        }
        return true
    }

    private static func leaderHasExited(_ child: pid_t) -> Bool {
        while true {
            var info = siginfo_t()
            if waitid(P_PID, id_t(child), &info, WEXITED | WNOHANG | WNOWAIT) == 0 {
                return info.si_pid != 0
            }
            if errno != EINTR { return false }
        }
    }

    /// Transfers post-resume ownership by refreshing the already durable
    /// pending receipt.  It cannot create a new untracked ownership window.
    /// The total lifetime is capped from the original synchronous deadline;
    /// reaching that cap leaves durable ambiguous evidence for recovery.
    private static func transferContainment(
        receipt: ContainedProcessReceipt,
        sink: ReceiptSinkBox,
        stdout: String,
        stderr: String
    ) -> ContainedProcessResult {
        let now = DispatchTime.now().uptimeNanoseconds
        let maximumLifetime = receipt.rootDeadlineNanoseconds &+ 30_000_000_000
        guard now < maximumLifetime else {
            return .init(stdout: stdout, stderr: stderr + "\ncontained-cleanup-lifetime-exhausted",
                         exitCode: 125, outcome: .containmentPending, containmentReceipt: receipt)
        }
        let freshCleanupDeadline = min(maximumLifetime, max(receipt.cleanupDeadlineNanoseconds, now &+ 5_000_000_000))
        guard let refreshed = receipt.refreshingCleanupDeadline(freshCleanupDeadline),
              sink.replace(receipt, refreshed)
        else {
            // The original durable receipt remains the fence. Do not signal
            // here, and never return a misleading completed/failed outcome.
            return .init(stdout: stdout, stderr: stderr + "\ncontained-receipt-refresh-pending",
                         exitCode: 125, outcome: .containmentPending, containmentReceipt: receipt)
        }
        return .init(stdout: stdout, stderr: stderr + "\ncontained-cleanup-pending",
                     exitCode: 125, outcome: .containmentPending, containmentReceipt: refreshed)
    }

    private static func makeReceipt(
        command: ContainedProcessCommand,
        spawned: Spawned,
        rootDeadline: UInt64,
        cleanupDeadline: UInt64
    ) -> ContainedProcessReceipt? {
        let session = getsid(spawned.child)
        guard let leader = processIdentity(spawned.child), session > 0,
              exactCommandFingerprint(spawned.child, executable: command.executable) == commandFingerprint(command)
        else { return nil }
        // The suspended child normally has no descendants, but the receipt
        // still enumerates and independently binds every initial member. A
        // later arrival remains an unbound ambiguity fence rather than being
        // assigned the leader's executable/argv fingerprint.
        guard case let .exact(initialMembers) = exactInventory(processGroup: spawned.child, session: session),
              !initialMembers.isEmpty, initialMembers.contains(leader)
        else { return nil }
        var members: [ContainedProcessMember] = []
        for identity in initialMembers {
            guard let binding = exactExecutableAndFingerprint(identity.pid) else { return nil }
            members.append(.init(identity: identity, executable: binding.executable,
                                 commandFingerprint: binding.fingerprint))
        }
        guard members.contains(where: {
            $0.identity == leader && $0.executable == command.executable && $0.commandFingerprint == commandFingerprint(command)
        }) else { return nil }
        return .init(token: UUID(), executable: command.executable,
                     commandFingerprint: commandFingerprint(command), leader: leader,
                     members: members, processGroupID: spawned.child, sessionID: session,
                     rootDeadlineNanoseconds: rootDeadline, cleanupDeadlineNanoseconds: cleanupDeadline)
    }

    private static func commandFingerprint(_ command: ContainedProcessCommand) -> String {
        // Fixed commands make a bounded deterministic fingerprint sufficient;
        // it is stored alongside the canonical executable and never accepts
        // caller-supplied argv or PATH data.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in ([command.executable] + command.arguments).joined(separator: "\u{0}").utf8 {
            hash ^= UInt64(byte); hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private static func processIdentity(_ pid: pid_t) -> ContainedProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard count == Int32(MemoryLayout<proc_bsdinfo>.size), info.pbi_start_tvsec > 0 else { return nil }
        return .init(pid: pid, startSeconds: Int64(info.pbi_start_tvsec),
                     startMicroseconds: Int32(info.pbi_start_tvusec))
    }

    private enum ExactInventory { case exact([ContainedProcessIdentity]), indeterminate }

    /// Two reads are compared by the caller.  A failed listing, an identity
    /// that disappears while being inspected, or a PID whose SID is not the
    /// recorded SID is intentionally indeterminate rather than empty.
    private static func exactInventory(processGroup: pid_t, session: pid_t) -> ExactInventory {
        guard let pids = ProcessGroupSnapshot.stableMembers(processGroup) else { return .indeterminate }
        var result: [ContainedProcessIdentity] = []
        for pid in pids {
            guard getsid(pid) == session, getpgid(pid) == processGroup, let identity = processIdentity(pid) else {
                return .indeterminate
            }
            result.append(identity)
        }
        guard Set(result.map { "\($0.pid):\($0.startSeconds):\($0.startMicroseconds)" }).count == result.count else {
            return .indeterminate
        }
        return .exact(result.sorted { $0.pid < $1.pid })
    }

    /// Resolve the supported `kern.procargs2` MIB by name, append the target
    /// PID, then perform bounded size/read calls. This deliberately avoids an
    /// invented libproc flavor or locally copied KERN_PROCARGS2 number.
    private static func exactCommandFingerprint(_ pid: pid_t, executable: String?) -> String? {
        guard let binding = exactExecutableAndFingerprint(pid),
              executable == nil || binding.executable == executable
        else { return nil }
        return binding.fingerprint
    }

    private static func exactExecutableAndFingerprint(_ pid: pid_t) -> (executable: String, fingerprint: String)? {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathCount = path.withUnsafeMutableBufferPointer {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard pathCount > 0 else { return nil }
        let resolved = String(cString: path)
        guard let arguments = boundedKernelArguments(pid) else { return nil }
        guard !arguments.isEmpty, arguments[0] == resolved else { return nil }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in arguments.joined(separator: "\u{0}").utf8 { hash ^= UInt64(byte); hash &*= 0x100000001b3 }
        return (resolved, String(format: "%016llx", hash))
    }

    private static func boundedKernelArguments(_ pid: pid_t) -> [String]? {
        let maximumBytes = 64 * 1_024
        var mib = [Int32](repeating: 0, count: Int(CTL_MAXNAME))
        var mibCount = mib.count
        let named = mib.withUnsafeMutableBufferPointer { buffer in
            sysctlnametomib("kern.procargs2", buffer.baseAddress, &mibCount)
        }
        guard named == 0, mibCount > 0, mibCount < mib.count else { return nil }
        mib[mibCount] = pid
        mibCount += 1
        var byteCount = 0
        let sized = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, UInt32(mibCount), nil, &byteCount, nil, 0)
        }
        guard sized == 0, byteCount > MemoryLayout<Int32>.size, byteCount <= maximumBytes else { return nil }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        var readCount = byteCount
        let read = mib.withUnsafeMutableBufferPointer { mibBuffer in
            bytes.withUnsafeMutableBytes { byteBuffer in
                sysctl(mibBuffer.baseAddress, UInt32(mibCount), byteBuffer.baseAddress, &readCount, nil, 0)
            }
        }
        guard read == 0, readCount > MemoryLayout<Int32>.size, readCount <= byteCount else { return nil }
        return parseKernelArgumentsFixture(Array(bytes.prefix(readCount)))
    }

    /// `kern.procargs2` starts with a native Int32 argc, followed by an
    /// executable C string, padding NULs, exactly argc non-empty argv strings,
    /// then environment bytes. The parser ignores that suffix and rejects any
    /// malformed boundary, argc, padding-only, or oversized representation.
    static func parseKernelArgumentsFixture(_ bytes: [UInt8]) -> [String]? {
        let maximumArguments = 32
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        // `sysctl` storage has no Swift alignment guarantee. Decode the
        // native little-endian Darwin Int32 bytewise instead of performing an
        // unaligned UnsafeRawBufferPointer.load.
        let rawArgc = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        let argc = Int32(bitPattern: rawArgc)
        guard argc > 0, argc <= maximumArguments else { return nil }
        var index = MemoryLayout<Int32>.size
        func cString() -> String? {
            guard index < bytes.count, let end = bytes[index...].firstIndex(of: 0), end > index else { return nil }
            guard let value = String(bytes: bytes[index..<end], encoding: .utf8) else { return nil }
            index = end + 1
            return value.isEmpty || value.utf8.contains(0) ? nil : value
        }
        guard let executable = cString() else { return nil }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var argv = [executable]
        for _ in 0..<Int(argc) {
            guard let value = cString() else { return nil }
            argv.append(value)
        }
        // The executable record is not argv[0]; parse exactly argc argv words.
        guard argv.count == Int(argc) + 1 else { return nil }
        return Array(argv.dropFirst())
    }

    private enum ReapResult { case reaped, ambiguous }

    private static func reapSynchronously(_ child: pid_t, status: inout Int32) -> ReapResult {
        var interruptions = 0
        while true {
            let result = waitpid(child, &status, 0)
            if result == child { return .reaped }
            if result < 0, errno == EINTR, interruptions < 8 {
                interruptions += 1
                continue
            }
            return .ambiguous
        }
    }

    /// Darwin exposes these as C preprocessor macros, which are not imported
    /// into Swift by every Command Line Tools SDK. Decode the documented
    /// low-seven-bit termination field directly instead. A zero field is a
    /// normal exit; 0x7f represents a stopped process, not a signal exit.
    static func waitStatusSignal(_ status: Int32) -> Int32? {
        let termination = Int32(UInt32(bitPattern: status) & 0x7f)
        guard termination != 0, termination != 0x7f else { return nil }
        return termination
    }

    static func waitStatusNormalExitCode(_ status: Int32) -> Int32? {
        guard (UInt32(bitPattern: status) & 0x7f) == 0 else { return nil }
        return Int32((UInt32(bitPattern: status) >> 8) & 0xff)
    }

    private static func normalizedExit(_ status: Int32) -> Int32 {
        if let exitCode = waitStatusNormalExitCode(status) { return exitCode }
        if let signal = waitStatusSignal(status) { return 128 + signal }
        return 125
    }

    private enum GroupObservation { case live, gone, unknown }

    /// `proc_listpgrppids` may include the held zombie leader. A stable list
    /// containing no PID other than that exact leader is therefore the only
    /// successful group-quiescence observation; unstable or failed reads are
    /// deliberately indeterminate.
    private static func groupObservation(_ group: pid_t, leaderExited: Bool) -> GroupObservation {
        guard let members = ProcessGroupSnapshot.stableMembers(group) else { return .unknown }
        if members.contains(where: { $0 != group }) { return .live }
        return leaderExited ? .gone : .live
    }

}

private final class BoundedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private(set) var truncated = false

    init(limit: Int) { self.limit = limit }

    func append(_ next: Data) {
        lock.lock(); defer { lock.unlock() }
        let available = max(0, limit - data.count)
        if next.count > available { truncated = true }
        if available > 0 { data.append(contentsOf: next.prefix(available)) }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
