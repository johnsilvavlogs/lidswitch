import Darwin
import Foundation
import LidSwitchCore

enum ProcessOutcome: Equatable, Sendable { case completed, timedOut, containmentFailed, spawnFailed, rejected }
enum ProcessReconciliation: Equatable, Sendable { case notRequired, passed, failed, indeterminate }

struct ProcessResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let outcome: ProcessOutcome
    let reconciliation: ProcessReconciliation

    init(stdout: String, stderr: String, exitCode: Int32, outcome: ProcessOutcome = .completed,
         reconciliation: ProcessReconciliation = .notRequired) {
        self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode; self.outcome = outcome
        self.reconciliation = reconciliation
    }
}

final class BoundedProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var bytes: [UInt8] = []
    private var truncated = false

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    func append(_ bytesRead: UnsafeRawBufferPointer) {
        lock.lock(); defer { lock.unlock() }
        let permitted = max(0, maximumBytes - bytes.count)
        if permitted < bytesRead.count { truncated = true }
        let retained = UnsafeRawBufferPointer(rebasing: bytesRead.prefix(permitted))
        bytes.append(contentsOf: retained.bindMemory(to: UInt8.self))
    }

    func text() -> String {
        lock.lock(); defer { lock.unlock() }
        let suffix = truncated ? "\n[output truncated]" : ""
        return String(decoding: bytes, as: UTF8.self) + suffix
    }
}

/// Absolute-path subprocess runner. Every spawn receives an atomic dedicated
/// process group, so a timeout can kill and reap the complete owned group before
/// it returns.  The leader is deliberately retained as a zombie until group
/// membership and both output streams are quiescent: reaping it first would
/// permit PID/PGID reuse before the final probe or signal.
enum Shell {
    enum LaunchctlDomain: Equatable, Sendable {
        case system
        case gui(uid_t)

        fileprivate var missingServiceDescription: String {
            switch self {
            case .system:
                return "system"
            case let .gui(uid):
                return "user gui: \(uid)"
            }
        }
    }

    enum LaunchctlPresence: Equatable, Sendable {
        case present
        case absent
        case indeterminate
    }

    enum SetupStage: CaseIterable, Equatable, Sendable {
        case reaperReservation, pipe, descriptorNormalization, closeOnExec, fileActions, attributes, processGroup, argv, spawn
    }

    static func setupFailure(_ stage: SetupStage, message: String = "runner setup failed") -> ProcessResult {
        ProcessResult(stdout: "", stderr: "\(message) [\(stage)]", exitCode: 127, outcome: .spawnFailed)
    }

    static func reconciliationOutcome(timedOut: Bool, commandClass: CommandClass,
                                      reconcile: (@Sendable () -> Bool)?) -> ProcessReconciliation {
        guard timedOut else { return .notRequired }
        guard commandClass == .reversibleMutation, let reconcile else { return .indeterminate }
        return reconcile() ? .passed : .failed
    }
    struct CommandSpec: Sendable {
        let executable: String
        let arguments: [String]
        let commandClass: CommandClass
        let timeout: TimeInterval
        let maximumOutputBytes: Int
        /// Timed reversible mutation is valid only when its caller can
        /// reconcile durable truth after an indeterminate timeout.
        let reconcileAfterTimeout: (@Sendable () -> Bool)?

        /// File-scoped so the reviewed factory surface in `Shell` is the only
        /// production construction path, while nested-type access remains
        /// valid under Swift's lexical `private` rules.
        fileprivate init(executable: String, arguments: [String], commandClass: CommandClass,
                         timeout: TimeInterval, maximumOutputBytes: Int = 1 * 1_024 * 1_024,
                         reconcileAfterTimeout: (@Sendable () -> Bool)? = nil) {
            self.executable = executable; self.arguments = arguments; self.commandClass = commandClass
            self.timeout = timeout; self.maximumOutputBytes = maximumOutputBytes
            self.reconcileAfterTimeout = reconcileAfterTimeout
        }

        // Call sites use contextual leading-dot construction (`.launchctlPrint`)
        // where Swift resolves static members on the expected `CommandSpec`
        // type. Keep those entry points as narrow forwarding shims so the
        // reviewed schemas remain centralized on `Shell`.
        static func rootFileContents(_ path: String,
                                     maximumOutputBytes: Int = 1_024 * 1_024) -> Self {
            Shell.rootFileContents(path, maximumOutputBytes: maximumOutputBytes)
        }

        static func launchctlPrint(_ target: String) -> Self {
            Shell.launchctlPrint(target)
        }

        static func launchctlPrintDisabled(_ domain: String) -> Self {
            Shell.launchctlPrintDisabled(domain)
        }

        static func launchctlMutation(_ mutation: Shell.LaunchctlMutation,
                                      reconcileAfterTimeout: @escaping @Sendable () -> Bool) -> Self {
            Shell.launchctlMutation(mutation, reconcileAfterTimeout: reconcileAfterTimeout)
        }

        static func codeSignatureVerification(_ path: String) -> Self {
            Shell.codeSignatureVerification(path)
        }

        static func privilegedAppleScript(_ source: String) -> Self {
            Shell.privilegedAppleScript(source)
        }

        #if DEBUG
        static func fixture(executable: String, arguments: [String] = [], timeout: TimeInterval = 1,
                            maximumOutputBytes: Int = 1 * 1_024 * 1_024) -> Self {
            Shell.fixture(executable: executable, arguments: arguments, timeout: timeout,
                          maximumOutputBytes: maximumOutputBytes)
        }
        #endif
    }

    /// Production can construct only direct-exec command schemas reviewed here.
    /// The runner has no generic initializer because that would make detached
    /// descendants or shell contracts reachable again.
    static func launchctlPrint(_ target: String) -> CommandSpec {
        CommandSpec(executable: "/bin/launchctl", arguments: ["print", target], commandClass: .observation, timeout: 5)
    }

    static func launchctlPrintDisabled(_ domain: String) -> CommandSpec {
        CommandSpec(executable: "/bin/launchctl", arguments: ["print-disabled", domain], commandClass: .observation, timeout: 5)
    }

    /// `launchctl print` writes a precise two-line diagnostic for an absent
    /// service on current macOS releases. Older supported releases omit the
    /// leading `Bad request.` line. Accept only those exact shapes for the
    /// expected label/domain; every other nonzero result remains unknown.
    static func launchctlPresence(
        _ result: ProcessResult,
        serviceLabel: String,
        domain: LaunchctlDomain
    ) -> LaunchctlPresence {
        guard result.outcome == .completed else { return .indeterminate }
        if result.exitCode == 0 { return .present }
        guard result.stdout.isEmpty else { return .indeterminate }

        let missing = "Could not find service \"\(serviceLabel)\" in domain for \(domain.missingServiceDescription)"
        let accepted = [
            missing,
            missing + "\n",
            "Bad request.\n" + missing,
            "Bad request.\n" + missing + "\n",
        ]
        return accepted.contains(result.stderr) ? .absent : .indeterminate
    }

    enum LaunchctlMutation: Sendable {
        case disable(String)
        case bootoutService(String)
        case bootoutPath(domain: String, path: String)

        fileprivate var arguments: [String] {
            switch self {
            case let .disable(target): ["disable", target]
            case let .bootoutService(target): ["bootout", target]
            case let .bootoutPath(domain, path): ["bootout", domain, path]
            }
        }
    }

    static func launchctlMutation(_ mutation: LaunchctlMutation,
                                  reconcileAfterTimeout: @escaping @Sendable () -> Bool) -> CommandSpec {
        CommandSpec(executable: "/bin/launchctl", arguments: mutation.arguments,
                    commandClass: .reversibleMutation, timeout: 10,
                    reconcileAfterTimeout: reconcileAfterTimeout)
    }

    static func rootFileContents(_ path: String, maximumOutputBytes: Int = 1_024 * 1_024) -> CommandSpec {
        CommandSpec(executable: "/bin/cat", arguments: [path], commandClass: .observation,
                    timeout: 5, maximumOutputBytes: maximumOutputBytes)
    }

    static func codeSignatureVerification(_ path: String) -> CommandSpec {
        CommandSpec(executable: "/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", "--verbose=2", path], commandClass: .observation, timeout: 20)
    }

    /// A timeout here means only that the parent runner stopped waiting. The
    /// admin command might already be committed, so callers must reconcile
    /// durable state and never interpret it as cancellation.
    static func privilegedAppleScript(_ source: String) -> CommandSpec {
        CommandSpec(executable: "/usr/bin/osascript", arguments: ["-e", source], commandClass: .privilegedMutation, timeout: 45)
    }

    #if DEBUG
    /// This factory is compiled only for test/debug fixtures and does not
    /// expose a production command construction path.
    static func fixture(executable: String, arguments: [String] = [], timeout: TimeInterval = 1,
                        maximumOutputBytes: Int = 1 * 1_024 * 1_024) -> CommandSpec {
        CommandSpec(executable: executable, arguments: arguments, commandClass: .observation,
                    timeout: timeout, maximumOutputBytes: maximumOutputBytes)
    }
    #endif
    /// Pure fixture seam for deterministic runner-state coverage. The live
    /// loop below supplies actual poll/wait/group observations; tests can cover
    /// exited leaders, held FDs, zombies, and cleanup expiry without spawning.
    struct RunnerFixtureState: Equatable, Sendable {
        let directChildReaped: Bool
        let processGroupQuiescent: Bool
        let stdoutEOF: Bool
        let stderrEOF: Bool
        let cleanupDeadlineExpired: Bool
    }

    enum RunnerFixtureOutcome: Equatable, Sendable { case wait, complete, containmentFailed(childReapFailed: Bool) }

    static func fixtureOutcome(_ state: RunnerFixtureState) -> RunnerFixtureOutcome {
        if state.cleanupDeadlineExpired { return .containmentFailed(childReapFailed: !state.directChildReaped) }
        if state.directChildReaped && state.processGroupQuiescent && state.stdoutEOF && state.stderrEOF { return .complete }
        return .wait
    }

    /// The production loop and deterministic tests share this monotonic state
    /// machine. Its caller supplies syscall observations, so tests never need
    /// to create a child process, pipe, or process group.
    struct RunnerMachine: Sendable {
        enum Group: Equatable, Sendable { case live, goneESRCH, unknown }
        enum Stream: Equatable, Sendable { case open, eof, interrupted, wouldBlock }
        enum Signal: Equatable, Sendable { case none, term, kill }
        enum Result: Equatable, Sendable { case wait(Signal), completed, containmentFailed }

        private enum Stage: Sendable { case running, term, kill }
        private var stage: Stage = .running
        private let termBudget: UInt64
        private let cleanupBudget: UInt64
        private var deadline: UInt64
        private var groupGone = false
        private(set) var didTimeOut = false

        init(commandDeadline: UInt64, termBudget: UInt64 = 500_000_000, cleanupBudget: UInt64 = 3_000_000_000) {
            self.termBudget = termBudget; self.cleanupBudget = cleanupBudget
            deadline = commandDeadline
        }

        mutating func advance(now: UInt64, childReaped: Bool, group: Group, stdout: Stream, stderr: Stream) -> Result {
            if group == .goneESRCH { groupGone = true }
            if childReaped && groupGone && stdout == .eof && stderr == .eof { return .completed }
            switch stage {
            case .running:
                guard now >= deadline else { return .wait(.none) }
                didTimeOut = true
                stage = .term; deadline = now &+ termBudget
                return .wait(groupGone ? .none : .term)
            case .term:
                guard now >= deadline else { return .wait(groupGone ? .none : .term) }
                stage = .kill; deadline = now &+ cleanupBudget
                return .wait(groupGone ? .none : .kill)
            case .kill:
                guard now >= deadline else { return .wait(groupGone ? .none : .kill) }
                return .containmentFailed
            }
        }

        mutating func forceCleanup(now: UInt64) {
            didTimeOut = true
            if case .running = stage {
                deadline = now
            }
        }
    }

    typealias GroupMembershipAdapter = ProcessGroupSnapshot.Adapter

    static func stableGroupMembers(_ group: pid_t, adapter: GroupMembershipAdapter) -> [pid_t]? {
        ProcessGroupSnapshot.stableMembers(group, adapter: adapter)
    }

    enum CommandClass: Sendable, Equatable {
        /// Direct-exec, no-detach observations only. Timed calls are limited to
        /// the allowlist below and never accept an interpreter `-c` contract.
        case observation
        /// A normal mutation can be timed only when its caller supplies a
        /// durable reconciler; this runner never claims timeout canceled work.
        case reversibleMutation
        /// Privileged work has a finite wait but a timeout remains
        /// completion-indeterminate; it never means the privileged child was
        /// canceled.
        case privilegedMutation
    }

    private static let timedObservationAllowlist: Set<String> = [
        "/bin/cat", "/bin/launchctl", "/usr/bin/codesign",
    ]

    struct PreparedSpawn { let child: pid_t; let stdout: Int32; let stderr: Int32 }
    enum PreparedSpawnResult { case success(PreparedSpawn), failure(SetupStage, String) }
    enum ReapAttempt: Equatable { case reaped, noChild, pending, interrupted, fatal }
    enum ReapDecision: Equatable { case release, transfer }

    /// All OS-facing orchestration enters `run` through this value.  Fixtures
    /// can provide a scripted adapter; `.system` is the sole Darwin binding.
    /// Adapter closures are invoked synchronously by one `run` invocation.
    /// Test fixtures deliberately capture mutable, single-threaded scripts, so
    /// requiring `@Sendable` closures here would incorrectly promise that
    /// those fixtures may be called concurrently.  The production instance
    /// contains only Darwin/static bindings; callers must not share a fixture
    /// adapter across concurrent invocations.
    struct RunnerSystemAdapter: @unchecked Sendable {
        let reserve: () -> DeferredChildReaper.Reservation?
        let bind: (DeferredChildReaper.Reservation, pid_t) -> Bool
        let release: (DeferredChildReaper.Reservation) -> Bool
        let transfer: (DeferredChildReaper.Reservation, pid_t) -> Bool
        let prepareSpawn: (CommandSpec) -> PreparedSpawnResult
        let close: (Int32) -> Void
        let makeNonblocking: (Int32) -> Bool
        let observe: (pid_t, inout Int32) -> LeaderObservation
        let group: (pid_t, Bool) -> RunnerMachine.Group
        let signal: (pid_t, Int32, Bool) -> Bool
        let poll: (UnsafeMutablePointer<pollfd>?, nfds_t, Int32) -> Int32
        let errno: () -> Int32
        let drain: (Int32, BoundedProcessOutput) -> DrainObservation
        let reapAttempt: (pid_t, inout Int32) -> ReapAttempt
        let pause: (useconds_t) -> Void
        let now: @Sendable () -> UInt64

        static let system = RunnerSystemAdapter(
            reserve: { DeferredChildReaper.reserve() },
            bind: { DeferredChildReaper.bind($0, to: $1) },
            release: { DeferredChildReaper.release($0) },
            transfer: { DeferredChildReaper.transfer($0, child: $1) },
            prepareSpawn: { prepareSystemSpawn($0) }, close: { Darwin.close($0) },
            makeNonblocking: { setNonblocking($0) }, observe: { child, status in observeLeaderWithoutReaping(child, status: &status) },
            group: { stableGroupObservation($0, leaderExited: $1) }, signal: { signalStableGroup($0, signal: $1, groupQuiescent: $2) },
            poll: { Darwin.poll($0, $1, $2) }, errno: { Darwin.errno }, drain: { drainAvailable(descriptor: $0, output: $1) },
            reapAttempt: { child, status in classifyReapAttempt(child, status: &status) },
            pause: { usleep($0) },
            now: { DispatchTime.now().uptimeNanoseconds }
        )
    }

    @discardableResult
    static func run(_ spec: CommandSpec,
                    system: RunnerSystemAdapter = .system) -> ProcessResult {
        let monotonicNow = system.now
        let executable = spec.executable; let arguments = spec.arguments
        let timeout = spec.timeout; let commandClass = spec.commandClass
        let maximumOutputBytes = spec.maximumOutputBytes
        BenchmarkProbe.record("child_process")
        guard executable.hasPrefix("/") else {
            return ProcessResult(stdout: "", stderr: "Executable path must be absolute.", exitCode: 127, outcome: .rejected)
        }
        let interpreterExecutables: Set<String> = ["/bin/sh", "/bin/zsh", "/bin/bash", "/usr/bin/env"]
        guard !interpreterExecutables.contains(executable), !arguments.contains("-c") else {
            return ProcessResult(stdout: "", stderr: "Interpreter and shell command contracts are forbidden.", exitCode: 127, outcome: .rejected)
        }
        guard commandClass != .privilegedMutation || executable == "/usr/bin/osascript" else {
            return ProcessResult(stdout: "", stderr: "Privileged command class is restricted to osascript.", exitCode: 127, outcome: .rejected)
        }
        do {
            guard timeout.isFinite, timeout >= 0, timeout <= 60 else {
                return ProcessResult(stdout: "", stderr: "Timeout must be finite and between zero and sixty seconds.", exitCode: 125, outcome: .rejected)
            }
            let allowedTimed = (commandClass == .observation && timedObservationAllowed(executable, arguments)) ||
                (commandClass == .reversibleMutation && spec.reconcileAfterTimeout != nil) ||
                commandClass == .privilegedMutation
            guard allowedTimed else {
                return ProcessResult(stdout: "", stderr: "Timed execution requires an allowlisted observation or durable reconciler.", exitCode: 125, outcome: .rejected)
            }
        }
        let output = BoundedProcessOutput(maximumBytes: max(1, maximumOutputBytes))
        let errorOutput = BoundedProcessOutput(maximumBytes: max(1, maximumOutputBytes))
        guard let reapReservation = system.reserve() else {
            return setupFailure(.reaperReservation, message: "No bounded deferred-reaper capacity is available.")
        }
        var reservationActive = true
        defer { if reservationActive { _ = system.release(reapReservation) } }
        let prepared: PreparedSpawn
        switch system.prepareSpawn(spec) {
        case let .failure(stage, message): return setupFailure(stage, message: message)
        case let .success(value): prepared = value
        }
        let child = prepared.child
        let stdoutRead = prepared.stdout
        let stderrRead = prepared.stderr
        guard system.bind(reapReservation, child) else {
            // Spawning succeeded, so a failed bookkeeping bind is itself a
            // post-spawn containment event. Never trap with a live child and
            // never let the pre-spawn defer falsely release its reservation.
            reservationActive = false
            let stdoutUsable = system.makeNonblocking(stdoutRead)
            let stderrUsable = system.makeNonblocking(stderrRead)
            return boundedPostSpawnFailure(
                child: child, stdout: stdoutRead, stderr: stderrRead,
                stdoutUsable: stdoutUsable, stderrUsable: stderrUsable,
                output: output, errorOutput: errorOutput, monotonicNow: monotonicNow,
                system: system, reservation: reapReservation,
                reason: "Could not bind spawned child to its deferred-reaper reservation."
            )
        }
        // Parent owns only the read ends. They are nonblocking and a single
        // poll state machine drains both streams, including bytes beyond the
        // retained cap, so descendants cannot deadlock a background reader.
        let stdoutUsable = system.makeNonblocking(stdoutRead)
        let stderrUsable = system.makeNonblocking(stderrRead)
        guard stdoutUsable, stderrUsable else {
            reservationActive = false
            return boundedPostSpawnFailure(child: child, stdout: stdoutRead, stderr: stderrRead,
                                           stdoutUsable: stdoutUsable, stderrUsable: stderrUsable,
                                           output: output, errorOutput: errorOutput, monotonicNow: monotonicNow,
                                           system: system,
                                           reservation: reapReservation,
                                           reason: "Could not make parent pipes nonblocking.")
        }
        let timeoutDeadline = monotonicNow() &+ UInt64(max(0, timeout) * 1_000_000_000)
        var status: Int32 = 0
        var leaderExited = false
        var stdoutEOF = false; var stderrEOF = false
        var machine = RunnerMachine(commandDeadline: timeoutDeadline)
        var groupQuiescent = false
        var fatalObservation = false
        while fixtureOutcome(.init(directChildReaped: leaderExited, processGroupQuiescent: groupQuiescent,
                                   stdoutEOF: stdoutEOF, stderrEOF: stderrEOF,
                                   cleanupDeadlineExpired: false)) != .complete {
            let now = monotonicNow()
            switch system.observe(child, &status) {
            case .exited: leaderExited = true
            case .fatal: fatalObservation = true
            case .running: break
            }
            let group = system.group(child, leaderExited)
            if group == .goneESRCH { groupQuiescent = true }
            if fatalObservation { machine.forceCleanup(now: now) }
            switch machine.advance(now: now, childReaped: leaderExited, group: group,
                                   stdout: stdoutEOF ? .eof : .open, stderr: stderrEOF ? .eof : .open) {
            case .completed: break
            case .containmentFailed:
                system.close(stdoutRead); system.close(stderrRead)
                reservationActive = false
                let ownership = finishOrTransferReap(child, reservation: reapReservation, status: &status, monotonicNow: monotonicNow, system: system)
                return ProcessResult(stdout: output.text(), stderr: errorOutput.text() + "\ncontainmentFailed: cleanup deadline expired\n\(ownership.evidence)", exitCode: 125, outcome: .containmentFailed)
            case let .wait(signal):
                switch signal {
                case .none: break
                case .term: groupQuiescent = system.signal(child, SIGTERM, groupQuiescent)
                case .kill: groupQuiescent = system.signal(child, SIGKILL, groupQuiescent)
                }
            }
            var descriptors = [pollfd(fd: stdoutEOF ? -1 : stdoutRead, events: Int16(POLLIN | POLLHUP), revents: 0),
                               pollfd(fd: stderrEOF ? -1 : stderrRead, events: Int16(POLLIN | POLLHUP), revents: 0)]
            let polled = descriptors.withUnsafeMutableBufferPointer {
                system.poll($0.baseAddress, nfds_t($0.count), 20)
            }
            if polled >= 0 || system.errno() == EINTR {
                let stdoutDrain = system.drain(stdoutRead, output)
                let stderrDrain = system.drain(stderrRead, errorOutput)
                stdoutEOF = stdoutEOF || stdoutDrain == .eof
                stderrEOF = stderrEOF || stderrDrain == .eof
                fatalObservation = fatalObservation || stdoutDrain == .fatal || stderrDrain == .fatal
            } else {
                fatalObservation = true
            }
        }
        // Only after the leader's PID keeps the numeric group identity reserved
        // through all membership/drain work may this invocation reap it.
        reservationActive = false
        let ownership = finishOrTransferReap(child, reservation: reapReservation, status: &status, monotonicNow: monotonicNow, system: system)
        system.close(stdoutRead); system.close(stderrRead)
        guard ownership.terminalOperationSucceeded, ownership.completedSynchronously else {
            return ProcessResult(stdout: output.text(), stderr: errorOutput.text() + "\ncontainmentFailed: \(ownership.evidence)", exitCode: 125, outcome: .containmentFailed)
        }
        let stderr = errorOutput.text()
        let reconciliation = reconciliationOutcome(timedOut: machine.didTimeOut, commandClass: commandClass,
                                                    reconcile: spec.reconcileAfterTimeout)
        return ProcessResult(
            stdout: output.text(),
            stderr: !machine.didTimeOut ? stderr : (stderr.isEmpty ? "Command timed out after containment." : stderr),
            exitCode: !machine.didTimeOut ? normalizedExitStatus(status) : 124,
            outcome: !machine.didTimeOut ? .completed : (commandClass == .privilegedMutation ? .timedOut : .timedOut),
            reconciliation: reconciliation
        )
    }

    enum DrainObservation: Equatable { case open, eof, fatal }

    /// `drainAvailable` calls this adapter synchronously.  Keep fixture
    /// closures usable for deterministic read scripts while making the static
    /// Darwin binding safe to store under Swift 6's global-state checks.
    struct DrainAdapter: @unchecked Sendable {
        let read: (Int32, UnsafeMutableRawPointer?, Int) -> Int
        let errno: () -> Int32

        static let system = DrainAdapter(
            read: { descriptor, buffer, count in Darwin.read(descriptor, buffer, count) },
            errno: { Darwin.errno }
        )
    }

    static func drainAvailable(descriptor: Int32, output: BoundedProcessOutput,
                               adapter: DrainAdapter = .system) -> DrainObservation {
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { adapter.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.withUnsafeBytes { output.append(UnsafeRawBufferPointer(rebasing: $0.prefix(Int(count)))) }
                continue
            }
            let error = adapter.errno()
            if count < 0, error == EINTR { continue }
            if count < 0, error == EAGAIN || error == EWOULDBLOCK { return .open }
            if count == 0 { return .eof }
            return .fatal
        }
    }

    private static func boundedPostSpawnFailure(
        child: pid_t,
        stdout: Int32,
        stderr: Int32,
        stdoutUsable: Bool,
        stderrUsable: Bool,
        output: BoundedProcessOutput,
        errorOutput: BoundedProcessOutput,
        monotonicNow: @escaping @Sendable () -> UInt64,
        system: RunnerSystemAdapter,
        reservation: DeferredChildReaper.Reservation,
        reason: String
    ) -> ProcessResult {
        let started = monotonicNow(); let termDeadline = started &+ 500_000_000
        let cleanupDeadline = started &+ 3_000_000_000
        var sentTerm = false; var sentKill = false; var groupQuiescent = false
        var leaderExited = false; var status: Int32 = 0
        var stdoutEOF = false; var stderrEOF = false
        defer {
            system.close(stdout)
            if stderr != stdout { system.close(stderr) }
        }
        // An unusable descriptor can never prove EOF, so containment remains
        // bounded but cannot report the ordinary spawn-failure completion.
        while true {
            let now = monotonicNow()
            guard now < cleanupDeadline else { break }
            if case .exited = system.observe(child, &status) { leaderExited = true }
            if system.group(child, leaderExited) == .goneESRCH { groupQuiescent = true }
            if !sentTerm {
                sentTerm = true
                groupQuiescent = system.signal(child, SIGTERM, groupQuiescent)
            } else if !sentKill, now >= termDeadline {
                sentKill = true
                groupQuiescent = system.signal(child, SIGKILL, groupQuiescent)
            }
            if stdoutUsable && !stdoutEOF { stdoutEOF = system.drain(stdout, output) == .eof }
            if stderrUsable && !stderrEOF { stderrEOF = system.drain(stderr, errorOutput) == .eof }
            if leaderExited && groupQuiescent && stdoutUsable && stderrUsable && stdoutEOF && stderrEOF {
                let ownership = finishOrTransferReap(child, reservation: reservation, status: &status, monotonicNow: monotonicNow, system: system)
                guard ownership.terminalOperationSucceeded, ownership.completedSynchronously else {
                    return ProcessResult(stdout: output.text(), stderr: reason + "\ncontainmentFailed: \(ownership.evidence)", exitCode: 125, outcome: .containmentFailed)
                }
                return ProcessResult(stdout: output.text(), stderr: reason, exitCode: 127, outcome: .spawnFailed)
            }
            system.pause(10_000)
        }
        let ownership = finishOrTransferReap(child, reservation: reservation, status: &status, monotonicNow: monotonicNow, system: system)
        return ProcessResult(stdout: output.text(), stderr: errorOutput.text() + "\ncontainmentFailed: \(reason)\n\(ownership.evidence)",
                             exitCode: 125, outcome: .containmentFailed)
    }

    private static func prepareSystemSpawn(_ spec: CommandSpec) -> PreparedSpawnResult {
        guard !spec.executable.utf8.contains(0), !spec.arguments.contains(where: { $0.utf8.contains(0) }) else {
            return .failure(.argv, "NUL is forbidden in command arguments.")
        }
        var out = [Int32](repeating: -1, count: 2), err = [Int32](repeating: -1, count: 2)
        guard pipe(&out) == 0, pipe(&err) == 0 else { closeIfOpen(out); closeIfOpen(err); return .failure(.pipe, "Could not create output pipes.") }
        defer { closeIfOpen(out); closeIfOpen(err) }
        guard normalizePipeDescriptors(&out), normalizePipeDescriptors(&err) else { return .failure(.descriptorNormalization, "Could not reserve pipe descriptors above standard streams.") }
        guard (out + err).allSatisfy({ fcntl($0, F_SETFD, FD_CLOEXEC) == 0 }) else { return .failure(.closeOnExec, "Could not mark pipe close-on-exec.") }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return .failure(.fileActions, "Could not initialize spawn file actions.") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return .failure(.attributes, "Could not initialize spawn attributes.") }
        defer { posix_spawnattr_destroy(&attributes) }
        let actionStatus = [
            posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO), posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, out[0]), posix_spawn_file_actions_addclose(&actions, err[0]),
            posix_spawn_file_actions_addclose(&actions, out[1]), posix_spawn_file_actions_addclose(&actions, err[1])
        ]
        guard actionStatus.allSatisfy({ $0 == 0 }) else { return .failure(.fileActions, "Could not configure spawn file actions.") }
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attributes, flags) == 0, posix_spawnattr_setpgroup(&attributes, 0) == 0 else { return .failure(.processGroup, "Could not isolate child process group.") }
        var argv: [UnsafeMutablePointer<CChar>?] = ([spec.executable] + spec.arguments).map { strdup($0) }; argv.append(nil)
        defer { argv.forEach { if let value = $0 { free(value) } } }
        guard argv.dropLast().allSatisfy({ $0 != nil }) else { return .failure(.argv, "Could not allocate command arguments.") }
        var child: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer { buffer in spec.executable.withCString { posix_spawn(&child, $0, &actions, &attributes, buffer.baseAddress, environ) } }
        guard result == 0 else { return .failure(.spawn, String(cString: strerror(result))) }
        close(out[1]); out[1] = -1; close(err[1]); err[1] = -1
        let prepared = PreparedSpawn(child: child, stdout: out[0], stderr: err[0]); out[0] = -1; err[0] = -1
        return .success(prepared)
    }

    private static func setNonblocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 &&
            fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0
    }

    /// Move every pipe endpoint away from 0/1/2 before file actions.  This is
    /// fail-atomic for the pair: a failed duplicate closes the replacement and
    /// lets the caller close the original pair without leaking descriptors.
    /// Descriptor normalization is synchronous and never retains this seam
    /// beyond the call.  Fixtures can therefore use mutable local scripts
    /// without claiming cross-task closure safety.
    struct DescriptorAdapter: @unchecked Sendable {
        let duplicateAboveStandardStreams: (Int32) -> Int32
        let close: (Int32) -> Void

        static let system = DescriptorAdapter(
            duplicateAboveStandardStreams: { fcntl($0, F_DUPFD_CLOEXEC, STDERR_FILENO + 1) },
            close: { Darwin.close($0) }
        )
    }

    static func normalizePipeDescriptors(_ descriptors: inout [Int32],
                                         adapter: DescriptorAdapter = .system) -> Bool {
        var normalized: [Int32] = []
        for descriptor in descriptors {
            let replacement = adapter.duplicateAboveStandardStreams(descriptor)
            guard replacement >= 0 else {
                normalized.forEach(adapter.close)
                return false
            }
            normalized.append(replacement)
        }
        descriptors.filter { $0 >= 0 }.forEach(adapter.close)
        descriptors = normalized
        return true
    }

    enum LeaderObservation { case running, exited, fatal }

    /// WNOWAIT preserves the leader PID/PGID reservation. Any failure other
    /// than EINTR becomes a bounded-cleanup trigger; it is never ignored.
    private static func observeLeaderWithoutReaping(_ child: pid_t, status: inout Int32) -> LeaderObservation {
        while true {
            var info = siginfo_t()
            if waitid(P_PID, id_t(child), &info, WEXITED | WNOHANG | WNOWAIT) == 0 {
                if info.si_pid == 0 { return .running }
                status = info.si_status
                return .exited
            }
            if errno == EINTR { continue }
            return .fatal
        }
    }

    enum ReapTerminalOperation: Equatable { case release, transfer }

    struct ReapOwnership: Equatable {
        let terminalOperation: ReapTerminalOperation
        let terminalOperationSucceeded: Bool
        let completedSynchronously: Bool
        let evidence: String
    }

    static func classifyReapAttempt(_ child: pid_t, status: inout Int32) -> ReapAttempt {
        let result = waitpid(child, &status, WNOHANG)
        if result == child { return .reaped }
        if result == 0 { return .pending }
        if errno == ECHILD { return .noChild }
        if errno == EINTR { return .interrupted }
        return .fatal
    }

    static func reapDecision(for attempt: ReapAttempt) -> ReapDecision {
        switch attempt { case .reaped, .noChild: .release; case .pending, .interrupted, .fatal: .transfer }
    }

    /// The containment-failure path cannot wait forever on the caller's
    /// thread. It first makes bounded nonblocking attempts, then transfers the
    /// unreaped child to the single durable owner before the caller returns.
    static func finishOrTransferReap(_ child: pid_t, reservation: DeferredChildReaper.Reservation, status: inout Int32,
                                     monotonicNow: @escaping @Sendable () -> UInt64, system: RunnerSystemAdapter) -> ReapOwnership {
        let deadline = monotonicNow() &+ 50_000_000
        var interruptedAttempts = 0
        while true {
            let attempt = system.reapAttempt(child, &status)
            switch reapDecision(for: attempt) {
            case .release:
                let succeeded = system.release(reservation)
                let successEvidence = attempt == .reaped ? "childReaped;reservationReleased" : "childAlreadyReaped;reservationReleased"
                return ReapOwnership(
                    terminalOperation: .release,
                    terminalOperationSucceeded: succeeded,
                    completedSynchronously: succeeded,
                    evidence: succeeded ? successEvidence : "reservationReleaseFailedAfter\(attempt)"
                )
            case .transfer:
                if attempt == .interrupted {
                    interruptedAttempts += 1
                    if interruptedAttempts < 3, monotonicNow() < deadline { continue }
                }
                let succeeded = system.transfer(reservation, child)
                return ReapOwnership(
                    terminalOperation: .transfer,
                    terminalOperationSucceeded: succeeded,
                    completedSynchronously: false,
                    evidence: succeeded
                        ? "childReapOwnershipTransferredAfter\(attempt)"
                        : "childReapOwnershipTransferFailedAfter\(attempt)"
                )
            }
        }
    }

    struct ReapOwnershipLedger: Equatable {
        enum State: Equatable { case reserved, bound(pid_t), transferred(pid_t) }
        let maximumPending: Int
        private(set) var entries: [UUID: State] = [:]

        init(maximumPending: Int = 32) { self.maximumPending = maximumPending }
        mutating func reserve(generateID: () -> UUID = { UUID() }) -> UUID? {
            guard entries.count < maximumPending else { return nil }
            // UUID generation is probabilistic, but reservation identity is
            // not: a collision must never overwrite a live owner. A bounded
            // collision run fails closed as capacity unavailable.
            for _ in 0..<64 {
                let id = generateID()
                guard entries[id] == nil else { continue }
                entries[id] = .reserved
                return id
            }
            return nil
        }
        mutating func bind(_ id: UUID, child: pid_t) -> Bool {
            guard entries[id] == .reserved, !owns(child: child, excluding: id) else { return false }
            entries[id] = .bound(child); return true
        }
        mutating func transfer(_ id: UUID, child: pid_t) -> Bool {
            guard let state = entries[id], !owns(child: child, excluding: id) else { return false }
            switch state {
            case .reserved: break
            case let .bound(boundChild) where boundChild == child: break
            default: return false
            }
            entries[id] = .transferred(child); return true
        }
        mutating func release(_ id: UUID) -> Bool { entries.removeValue(forKey: id) != nil }
        var transferred: [(UUID, pid_t)] { entries.compactMap { key, value in if case let .transferred(pid) = value { (key, pid) } else { nil } } }

        private func owns(child: pid_t, excluding excludedID: UUID) -> Bool {
            entries.contains { id, state in
                guard id != excludedID else { return false }
                switch state {
                case let .bound(ownedChild), let .transferred(ownedChild):
                    return ownedChild == child
                default:
                    return false
                }
            }
        }
    }

    /// Lock-protected mutable reaper state lives in this explicit reference
    /// owner; static members themselves are immutable in Swift 6.
    private final class DeferredReaperState: @unchecked Sendable {
        let lock = NSLock()
        var ledger = ReapOwnershipLedger(maximumPending: 32)
        var pollScheduled = false
        var consecutiveFatalWaitErrors = 0
    }

    enum DeferredWaitOutcome: Equatable { case reaped, pending, interrupted, fatal }
    /// Deferred reaper polling invokes this adapter serially.  The unchecked
    /// conformance is confined to the synchronous fixture seam; `.system`
    /// itself captures no mutable state.
    struct DeferredWaitAdapter: @unchecked Sendable {
        let waitNoHang: (pid_t) -> Int32
        let errno: () -> Int32
        static let system = DeferredWaitAdapter(
            waitNoHang: { child in
                var status: Int32 = 0
                return waitpid(child, &status, WNOHANG)
            },
            errno: { Darwin.errno }
        )
    }
    static func deferredWaitOutcome(_ child: pid_t, adapter: DeferredWaitAdapter = .system) -> DeferredWaitOutcome {
        let result = adapter.waitNoHang(child)
        if result == child { return .reaped }
        if result == 0 { return .pending }
        let error = adapter.errno()
        if result < 0 && error == ECHILD { return .reaped }
        if result < 0 && error == EINTR { return .interrupted }
        return .fatal
    }

    static func deferredPollDelayMilliseconds(consecutiveFatalWaitErrors: Int) -> Int {
        min(1_000, 25 << min(max(0, consecutiveFatalWaitErrors), 6))
    }

    /// One nonblocking poller owns every transferred child. It never blocks a
    /// serial queue on one non-exiting process, so each pending child advances
    /// independently and reservations remain bounded from pre-spawn onward.
    enum DeferredChildReaper {
        struct Reservation: Hashable { let id: UUID }
        private static let state = DeferredReaperState()
        private static let queue = DispatchQueue(label: "LidSwitch.Shell.deferred-reaper")

        static func reserve() -> Reservation? {
            state.lock.lock(); defer { state.lock.unlock() }
            return state.ledger.reserve().map { Reservation(id: $0) }
        }
        static func bind(_ reservation: Reservation, to child: pid_t) -> Bool {
            state.lock.lock(); defer { state.lock.unlock() }
            return state.ledger.bind(reservation.id, child: child)
        }
        static func release(_ reservation: Reservation) -> Bool {
            state.lock.lock(); defer { state.lock.unlock() }
            return state.ledger.release(reservation.id)
        }
        static func transfer(_ reservation: Reservation, child: pid_t) -> Bool {
            state.lock.lock()
            let accepted = state.ledger.transfer(reservation.id, child: child)
            let shouldSchedule = accepted && !state.pollScheduled
            if shouldSchedule { state.pollScheduled = true }
            state.lock.unlock()
            if shouldSchedule { schedulePoll(after: .milliseconds(25)) }
            return accepted
        }
        private static func schedulePoll(after delay: DispatchTimeInterval) {
            queue.asyncAfter(deadline: .now() + delay) { pollOnce() }
        }
        private static func pollOnce() {
            state.lock.lock()
            let pending = state.ledger.transferred
            state.lock.unlock()
            var observedFatal = false
            for (id, child) in pending {
                switch deferredWaitOutcome(child) {
                case .reaped:
                    state.lock.lock(); _ = state.ledger.release(id); state.lock.unlock()
                case .fatal:
                    observedFatal = true
                    BenchmarkProbe.record("child_reap_waitpid_fatal")
                case .pending, .interrupted:
                    break
                }
            }
            state.lock.lock()
            let hasPending = !state.ledger.transferred.isEmpty
            state.pollScheduled = hasPending
            state.consecutiveFatalWaitErrors = observedFatal ? min(state.consecutiveFatalWaitErrors + 1, 6) : 0
            let backoff = deferredPollDelayMilliseconds(consecutiveFatalWaitErrors: state.consecutiveFatalWaitErrors)
            state.lock.unlock()
            if hasPending { schedulePoll(after: .milliseconds(backoff)) }
        }
    }

    /// `proc_listpgrppids` is public libproc membership
    /// evidence. The unreaped zombie leader is excluded, so zero remaining
    /// members means no descendant can hold a group-owned pipe endpoint.
    private static func stableGroupObservation(_ group: pid_t, leaderExited: Bool,
                                               adapter: GroupMembershipAdapter = .system) -> RunnerMachine.Group {
        guard let members = stableGroupMembers(group, adapter: adapter) else { return .unknown }
        let liveMember = members.contains { $0 != group }
        if liveMember { return .live }
        // Before the leader exits, it is a live owned member. After it exits,
        // the only possible member is its retained zombie, which is quiescent.
        return leaderExited ? .goneESRCH : .live
    }

    private static func timedObservationAllowed(_ executable: String, _ arguments: [String]) -> Bool {
        guard timedObservationAllowlist.contains(executable) else { return false }
        switch executable {
        case "/bin/launchctl":
            // `launchctl` is mutable by subcommand; only the two inspection
            // forms used by this app may have a generic deadline.
            return arguments.first == "print" || arguments.first == "print-disabled"
        case "/usr/bin/codesign":
            return arguments.first == "--verify" || arguments.first == "-v"
        case "/bin/cat":
            return arguments.count == 1 && arguments[0].hasPrefix("/")
        default:
            return false
        }
    }

    @discardableResult
    private static func signalStableGroup(_ group: pid_t, signal: Int32, groupQuiescent: Bool) -> Bool {
        guard !groupQuiescent else { return true }
        // The leader remains unreaped through every signal attempt, retaining
        // the numeric PGID. Callers never invoke this after `reapLeader`.
        while true {
            if kill(-group, signal) == 0 { return false }
            if errno == EINTR { continue }
            return errno == ESRCH
        }
    }

    private static func normalizedExitStatus(_ status: Int32) -> Int32 {
        // Darwin's WIF*/W*STATUS helpers are C function-like macros and are
        // not imported as Swift-callable symbols.  `waitpid` encodes the low
        // seven bits as the terminating signal and the next byte as an
        // ordinary exit code.
        let terminatingSignal = status & 0x7f
        if terminatingSignal == 0 { return (status >> 8) & 0xff }
        if terminatingSignal != 0x7f { return 128 + terminatingSignal }
        return 125
    }

    private static func closeIfOpen(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 { close(descriptor) }
    }
}
