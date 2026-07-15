import Darwin
import Foundation
import IOKit.ps
@testable import LidSwitchCore
import XCTest
@testable import LidSwitch
@testable import LidSwitchHelper

private func waitForSemaphore(_ semaphore: DispatchSemaphore) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            semaphore.wait()
            continuation.resume()
        }
    }
}

private func waitForSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTimeInterval
) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + timeout))
        }
    }
}

private func captureBenchmarkProbe<T>(_ operation: () -> T) -> (result: T, counters: [String: Int]) {
    let counters = LockedBox([String: Int]())
    let result = BenchmarkProbe.withRecorder(
        { operation, count in
            counters.withValue { $0[operation, default: 0] += count }
        },
        { operation() }
    )
    return (result, counters.value)
}

@MainActor
private func waitForRefresh(_ controller: PowerController) async {
    for _ in 0..<200 where controller.isChecking {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

// Historical in-process host inspection is intentionally excluded from the
// test binary. The safe wrapper owns the only production pre/post observation;
// XCTest itself runs with production support roots unreadable. This block is
// retained temporarily as migration evidence until the release branch freezes.
#if LIDSWITCH_OBSOLETE_IN_PROCESS_LIVE_GUARD
private struct ImmutableArtifactPolicy {
    let path: String
    let maximumBytes: Int
    let expectedOwner: uid_t
    let expectedMode: mode_t
    let safeParentDepth: Int
    let expectedParentOwner: uid_t
}

private struct ImmutableArtifactMetadata: Equatable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let owner: uid_t
    let group: gid_t
    let links: nlink_t
    let size: off_t
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
        mode = status.st_mode
        owner = status.st_uid
        group = status.st_gid
        links = status.st_nlink
        size = status.st_size
        modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        changedSeconds = Int64(status.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
    }
}

private struct ImmutableArtifactFingerprint: Equatable {
    let metadata: ImmutableArtifactMetadata
    let bytes: Data
}

private enum ImmutableArtifactRead: Equatable {
    case absent
    case success(ImmutableArtifactFingerprint)
    case unsafeOrChanged
}

private enum AnchoredParentResult {
    case descriptor(Int32)
    case missing
    case unsafe
}

private enum AnchoredLeafResult {
    case descriptor(Int32)
    case missing
    case unsafe
}

private func anchoredParentDescriptor(
    path: String,
    safeParentDepth: Int,
    expectedOwner: uid_t
) -> AnchoredParentResult {
    guard safeParentDepth > 0 else { return .unsafe }
    let fileURL = URL(fileURLWithPath: path)
    var inspectedParents: [URL] = []
    var directory = fileURL.deletingLastPathComponent()
    for _ in 0..<safeParentDepth {
        inspectedParents.append(directory)
        let parent = directory.deletingLastPathComponent()
        guard parent.path != directory.path else { return .unsafe }
        directory = parent
    }
    guard let topmost = inspectedParents.last else { return .unsafe }
    var descriptor = open(topmost.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return .unsafe }
    guard anchoredDirectoryIsSafe(descriptor, expectedOwner: expectedOwner) else {
        close(descriptor)
        return .unsafe
    }
    for child in inspectedParents.reversed().dropFirst() {
        let next = openat(descriptor, child.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if next < 0, errno == ENOENT {
            close(descriptor)
            return .missing
        }
        guard next >= 0, anchoredDirectoryIsSafe(next, expectedOwner: expectedOwner) else {
            if next >= 0 { close(next) }
            close(descriptor)
            return .unsafe
        }
        close(descriptor)
        descriptor = next
    }
    return .descriptor(descriptor)
}

private func anchoredDirectoryIsSafe(_ descriptor: Int32, expectedOwner: uid_t) -> Bool {
    var status = stat()
    return fstat(descriptor, &status) == 0
        && status.st_mode & S_IFMT == S_IFDIR
        && status.st_uid == expectedOwner
        && status.st_mode & (S_IWGRP | S_IWOTH) == 0
}

private func anchoredLeafDescriptor(
    path: String,
    safeParentDepth: Int,
    expectedParentOwner: uid_t
) -> AnchoredLeafResult {
    let parentResult = anchoredParentDescriptor(
        path: path,
        safeParentDepth: safeParentDepth,
        expectedOwner: expectedParentOwner
    )
    switch parentResult {
    case .missing: return .missing
    case .unsafe: return .unsafe
    case let .descriptor(parent):
    defer { close(parent) }
    let descriptor = openat(
        parent,
        URL(fileURLWithPath: path).lastPathComponent,
        O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    )
    if descriptor < 0, errno == ENOENT { return .missing }
    return descriptor >= 0 ? .descriptor(descriptor) : .unsafe
    }
}

private func readImmutableArtifact(_ policy: ImmutableArtifactPolicy) -> ImmutableArtifactRead {
    let leaf = anchoredLeafDescriptor(
        path: policy.path,
        safeParentDepth: policy.safeParentDepth,
        expectedParentOwner: policy.expectedParentOwner
    )
    let descriptor: Int32
    switch leaf {
    case .missing: return .absent
    case .unsafe: return .unsafeOrChanged
    case let .descriptor(value): descriptor = value
    }
    defer { close(descriptor) }

    var initialStatus = stat()
    guard fstat(descriptor, &initialStatus) == 0 else { return .unsafeOrChanged }
    let initial = ImmutableArtifactMetadata(initialStatus)
    guard initial.mode & S_IFMT == S_IFREG,
          initial.owner == policy.expectedOwner,
          initial.mode & 0o777 == policy.expectedMode,
          initial.links == 1,
          initial.size >= 0,
          initial.size <= off_t(policy.maximumBytes)
    else { return .unsafeOrChanged }

    var bytes = [UInt8](repeating: 0, count: Int(initial.size))
    var offset = 0
    while offset < bytes.count {
        let remaining = bytes.count - offset
        let count = bytes.withUnsafeMutableBytes { buffer in
            Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), remaining)
        }
        if count > 0 { offset += count; continue }
        if count < 0, errno == EINTR { continue }
        return .unsafeOrChanged
    }
    var trailing: UInt8 = 0
    while true {
        let count = Darwin.read(descriptor, &trailing, 1)
        if count == 0 { break }
        if count < 0, errno == EINTR { continue }
        return .unsafeOrChanged
    }
    var finalStatus = stat()
    guard fstat(descriptor, &finalStatus) == 0 else { return .unsafeOrChanged }
    let final = ImmutableArtifactMetadata(finalStatus)
    guard final == initial else { return .unsafeOrChanged }
    return .success(ImmutableArtifactFingerprint(metadata: initial, bytes: Data(bytes)))
}

private struct LeaseSecurityLineage: Equatable {
    let fileType: mode_t
    let mode: mode_t
    let owner: uid_t
    let group: gid_t
    let links: nlink_t
}

private func readLeaseSecurityLineage() -> LeaseSecurityLineage? {
    let leaf = anchoredLeafDescriptor(
        path: AppPaths.activationLeaseFile.path,
        safeParentDepth: 2,
        expectedParentOwner: getuid()
    )
    guard case let .descriptor(descriptor) = leaf else { return nil }
    defer { close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0,
          status.st_mode & S_IFMT == S_IFREG,
          status.st_uid == getuid(),
          status.st_mode & 0o777 == 0o600,
          status.st_nlink == 1
    else { return nil }
    return LeaseSecurityLineage(
        fileType: status.st_mode & S_IFMT,
        mode: status.st_mode & 0o777,
        owner: status.st_uid,
        group: status.st_gid,
        links: status.st_nlink
    )
}

private struct RootArtifactLineage: Equatable {
    let helper: ImmutableArtifactRead
    let version: ImmutableArtifactRead
    let daemon: ImmutableArtifactRead

    var allPresentAndSecure: Bool {
        if case .success = helper, case .success = version, case .success = daemon { return true }
        return false
    }

    var allAbsent: Bool {
        if case .absent = helper, case .absent = version, case .absent = daemon { return true }
        return false
    }

    var isConsistent: Bool { allPresentAndSecure || allAbsent }
}

private enum SecureTerminalLedger: Equatable {
    case success(entries: [UUID], fingerprint: ImmutableArtifactFingerprint)
    case absent
    case malformed
}

private enum SecureHelperStatus: Equatable {
    case absent
    case record(HelperStatusRecord)
    case malformed
}

private enum SecureLeaseSeed: Equatable {
    case absent
    case record(ActivationLease)
    case malformed
}

/// Read-only guard inputs only. This deliberately excludes the app inspector's
/// helper/artifact/cache path so per-test preservation checks do not spawn
/// child processes or repeat bundled-helper inspection.
private struct LiveSafetyObservation {
    let source: HelperPowerSource
    let sleepDisabled: Bool?
    let acIdleSleepMinutes: Int?
    let rawLease: SecureLeaseSeed
    let validatedLease: ActivationLease?
    let helperStatus: SecureHelperStatus
    let checkedAt: Date
}

private enum SessionHistoryAnchor: Equatable {
    case empty
    case entry(SessionDiagnosticEntry)
}

private enum SecureDiagnosticHistory: Equatable {
    case absent
    case success(entries: [SessionDiagnosticEntry], fingerprint: ImmutableArtifactFingerprint)
    case malformed

    var security: LeaseSecurityLineage? {
        guard case let .success(_, fingerprint) = self else { return nil }
        return LeaseSecurityLineage(
            fileType: fingerprint.metadata.mode & S_IFMT,
            mode: fingerprint.metadata.mode & 0o777,
            owner: fingerprint.metadata.owner,
            group: fingerprint.metadata.group,
            links: fingerprint.metadata.links
        )
    }
}

private struct ActiveLiveControllerSession {
    let lease: ActivationLease
    let leaseSecurity: LeaseSecurityLineage
    let appliedState: AppliedState
    let appliedFingerprint: ImmutableArtifactFingerprint
    let helperStatus: HelperStatusRecord
    let artifacts: RootArtifactLineage
    let terminalLedger: SecureTerminalLedger
    let history: SecureDiagnosticHistory
    let historyAnchor: SessionHistoryAnchor
}

private struct IdleLiveControllerState {
    let helperStatus: SecureHelperStatus
    let artifacts: RootArtifactLineage
    let terminalLedger: SecureTerminalLedger
    let history: SecureDiagnosticHistory
    let historyAnchor: SessionHistoryAnchor
}

private enum LiveControllerSessionGuard {
    case active(ActiveLiveControllerSession)
    case idle(IdleLiveControllerState)
    case unsafeOrIndeterminate(String)

    var preflightAllowsFixtureExercise: Bool {
        if case .unsafeOrIndeterminate = self { return false }
        return true
    }

    var preflightFailureReason: String? {
        guard case let .unsafeOrIndeterminate(reason) = self else { return nil }
        return reason
    }

    static func capture() -> Self {
        let observation = safetyObservation()
        guard observation.source != .unknown else {
            return .unsafeOrIndeterminate("native AC/battery source is unavailable")
        }
        guard observation.rawLease != .malformed else {
            return .unsafeOrIndeterminate("activation lease is malformed, unsafe, or changed during read")
        }
        let artifacts = RootArtifactLineage(
            helper: readImmutableArtifact(.init(path: AppPaths.rootHelperPath, maximumBytes: 2 * 1_024 * 1_024, expectedOwner: 0, expectedMode: 0o755, safeParentDepth: 2, expectedParentOwner: 0)),
            version: readImmutableArtifact(.init(path: AppPaths.rootHelperVersionPath, maximumBytes: 4_096, expectedOwner: 0, expectedMode: 0o644, safeParentDepth: 2, expectedParentOwner: 0)),
            daemon: readImmutableArtifact(.init(path: AppPaths.launchDaemonPath, maximumBytes: 64 * 1_024, expectedOwner: 0, expectedMode: 0o644, safeParentDepth: 1, expectedParentOwner: 0))
        )
        guard artifacts.isConsistent else {
            return .unsafeOrIndeterminate("root helper artifact lineage is mixed, unsafe, or changed during read")
        }
        let terminalLedger = terminalLedger()
        let history = diagnosticHistory()
        let historyAnchor: SessionHistoryAnchor
        switch history {
        case let .success(entries, _): historyAnchor = entries.last.map(SessionHistoryAnchor.entry) ?? .empty
        case .absent: historyAnchor = .empty
        case .malformed: return .unsafeOrIndeterminate("session diagnostic history is malformed or unsafe")
        }

        if let active = activeState(
            observation: observation,
            artifacts: artifacts,
            terminalLedger: terminalLedger,
            history: history,
            historyAnchor: historyAnchor
        ) {
            return .active(active)
        }
        return idleState(
            observation: observation,
            artifacts: artifacts,
            terminalLedger: terminalLedger,
            history: history,
            historyAnchor: historyAnchor
        )
    }

    private static func safetyObservation() -> LiveSafetyObservation {
        let checkedAt = Date()
        let power = SystemPowerSystem()
        let rawLease = secureLeaseSeed()
        let validatedLease: ActivationLease?
        if case let .record(lease) = rawLease,
           let bootID = BootIdentity.current(),
           let systemBuild = SystemBuild.current(),
           lease.validationFailure(
                now: checkedAt,
                nowMonotonic: MonotonicClock.seconds(),
                currentBootID: bootID,
                expectedOwnerUID: getuid(),
                currentSystemBuild: systemBuild
           ) == nil
        {
            validatedLease = lease
        } else {
            validatedLease = nil
        }
        return LiveSafetyObservation(
            source: power.powerSource(),
            sleepDisabled: power.sleepDisabled(),
            acIdleSleepMinutes: power.acSleepMinutes(),
            rawLease: rawLease,
            validatedLease: validatedLease,
            helperStatus: helperStatus(),
            checkedAt: checkedAt
        )
    }

    private static func activeState(
        observation: LiveSafetyObservation,
        artifacts: RootArtifactLineage,
        terminalLedger: SecureTerminalLedger,
        history: SecureDiagnosticHistory,
        historyAnchor: SessionHistoryAnchor
    ) -> ActiveLiveControllerSession? {
        guard let lease = observation.validatedLease,
              case let .record(rawLease) = observation.rawLease,
              rawLease.sessionID == lease.sessionID,
              observation.source == .ac,
              observation.sleepDisabled == true,
              observation.acIdleSleepMinutes == 0,
              case let .record(secureStatus) = observation.helperStatus,
              secureStatus.state == "active",
              secureStatus.sessionID == lease.sessionID,
              secureStatus.isFresh(at: observation.checkedAt),
              let leaseSecurity = readLeaseSecurityLineage(),
              artifacts.allPresentAndSecure,
              case let .success(entries: terminalEntries, fingerprint: _) = terminalLedger,
              terminalLedgerAllowsActiveSession(terminalEntries, sessionID: lease.sessionID),
              secureStatus.reason == "verified" || secureStatus.reason == "verified-after-override-recovery",
              case .entry = historyAnchor,
              case .success(entries: _, fingerprint: _) = history,
              case let .success(appliedFingerprint) = readImmutableArtifact(
                  .init(path: AppPaths.rootAppliedStatePath, maximumBytes: 4_096, expectedOwner: 0, expectedMode: 0o644, safeParentDepth: 2, expectedParentOwner: 0)
              ),
              let appliedRaw = String(data: appliedFingerprint.bytes, encoding: .utf8),
              let appliedState = AppliedState.parse(appliedRaw),
              appliedState.sessionID == lease.sessionID,
              case let .success(loadedAppliedState) = AppliedStateStore.load(
                  path: AppPaths.rootAppliedStatePath,
                  expectedOwnerUID: 0
              ),
              loadedAppliedState == appliedState
        else { return nil }
        return ActiveLiveControllerSession(
            lease: lease,
            leaseSecurity: leaseSecurity,
            appliedState: appliedState,
            appliedFingerprint: appliedFingerprint,
            helperStatus: secureStatus,
            artifacts: artifacts,
            terminalLedger: terminalLedger,
            history: history,
            historyAnchor: historyAnchor
        )
    }

    private static func idleState(
        observation: LiveSafetyObservation,
        artifacts: RootArtifactLineage,
        terminalLedger: SecureTerminalLedger,
        history: SecureDiagnosticHistory,
        historyAnchor: SessionHistoryAnchor
    ) -> Self {
        guard observation.sleepDisabled == false,
              observation.validatedLease == nil,
              observation.rawLease == .absent,
              case .missing = AppliedStateStore.load(path: AppPaths.rootAppliedStatePath, expectedOwnerUID: 0),
              case .absent = readImmutableArtifact(
                  .init(path: AppPaths.rootAppliedStatePath, maximumBytes: 4_096, expectedOwner: 0, expectedMode: 0o644, safeParentDepth: 2, expectedParentOwner: 0)
              )
        else {
            return .unsafeOrIndeterminate("live state is neither a coherent active session nor verified idle")
        }

        if artifacts.allAbsent,
           observation.helperStatus == .absent,
           terminalLedger == .absent {
            switch history {
            case .absent, .success(entries: _, fingerprint: _):
                return .idle(IdleLiveControllerState(
                    helperStatus: observation.helperStatus,
                    artifacts: artifacts,
                    terminalLedger: terminalLedger,
                    history: history,
                    historyAnchor: historyAnchor
                ))
            case .malformed:
                return .unsafeOrIndeterminate("uninstalled idle state has unexpected diagnostic history")
            }
        }
        guard artifacts.allPresentAndSecure,
              case let .record(status) = observation.helperStatus,
              status.state == "inactive",
              case let .success(entries: terminalGenerations, fingerprint: _) = terminalLedger,
              status.sessionID == nil || terminalGenerations.contains(status.sessionID!)
        else {
            return .unsafeOrIndeterminate("idle helper/status/terminal lineage is malformed, blocked, active, or nonterminal")
        }
        guard case .success(entries: _, fingerprint: _) = history else {
            return .unsafeOrIndeterminate("installed idle helper requires securely readable diagnostic history")
        }
        return .idle(IdleLiveControllerState(
            helperStatus: observation.helperStatus,
            artifacts: artifacts,
            terminalLedger: terminalLedger,
            history: history,
            historyAnchor: historyAnchor
        ))
    }

    func assertPreserved() {
        switch self {
        case let .active(before):
            guard case let .active(after) = Self.capture() else {
                return XCTFail("fixture controller test replaced, revoked, stopped, or otherwise ended the active live session")
            }
            XCTAssertEqual(after.lease.sessionID, before.lease.sessionID)
            XCTAssertEqual(after.lease.ownerUID, before.lease.ownerUID)
            XCTAssertEqual(after.lease.bootID, before.lease.bootID)
            XCTAssertEqual(after.lease.systemBuild, before.lease.systemBuild)
            XCTAssertGreaterThanOrEqual(after.lease.issuedMonotonic, before.lease.issuedMonotonic)
            XCTAssertGreaterThanOrEqual(after.lease.expiresMonotonic, before.lease.expiresMonotonic)
            XCTAssertGreaterThanOrEqual(after.lease.expiresAt, before.lease.expiresAt)
            XCTAssertEqual(after.leaseSecurity, before.leaseSecurity)
            XCTAssertEqual(after.appliedState, before.appliedState)
            XCTAssertEqual(after.appliedFingerprint, before.appliedFingerprint)
            XCTAssertEqual(after.helperStatus.state, before.helperStatus.state)
            XCTAssertEqual(after.helperStatus.reason, before.helperStatus.reason)
            XCTAssertEqual(after.helperStatus.sessionID, before.helperStatus.sessionID)
            XCTAssertGreaterThanOrEqual(after.helperStatus.updatedAt, before.helperStatus.updatedAt)
            XCTAssertEqual(after.artifacts, before.artifacts)
            XCTAssertEqual(after.terminalLedger, before.terminalLedger)
            XCTAssertEqual(after.history.security, before.history.security)
            assertHistoryTail(history: after.history, anchor: before.historyAnchor, sessionID: before.lease.sessionID)
        case let .idle(before):
            guard case let .idle(after) = Self.capture() else {
                return XCTFail("fixture controller test started or altered the previously idle live session")
            }
            XCTAssertEqual(after.helperStatus, before.helperStatus)
            XCTAssertEqual(after.artifacts, before.artifacts)
            XCTAssertEqual(after.terminalLedger, before.terminalLedger)
            XCTAssertEqual(after.history, before.history)
            assertHistoryTail(history: after.history, anchor: before.historyAnchor, sessionID: nil)
        case let .unsafeOrIndeterminate(reason):
            XCTFail("fixture controller test must not run from unsafe or indeterminate state: \(reason)")
        }
    }

    private func assertHistoryTail(history: SecureDiagnosticHistory, anchor: SessionHistoryAnchor, sessionID: UUID?) {
        let after: [SessionDiagnosticEntry]
        switch history {
        case let .success(entries, _): after = entries
        case .absent:
            if case .empty = anchor { return }
            return XCTFail("diagnostic history disappeared after fixture exercise")
        case .malformed:
            return XCTFail("diagnostic history became malformed or unsafe")
        }
        switch anchor {
        case .empty:
            XCTAssertTrue(after.isEmpty, "new diagnostics without a stable pre-state anchor are indeterminate")
        case let .entry(anchor):
            guard let index = after.lastIndex(of: anchor) else {
                return XCTFail("diagnostic history anchor rotated out; live-state preservation is indeterminate")
            }
            let tail = after.dropFirst(index + 1)
            guard let sessionID else {
                return XCTAssertTrue(tail.isEmpty, "idle state gained new diagnostic events")
            }
            XCTAssertTrue(tail.allSatisfy {
                $0.sessionID == sessionID.uuidString.lowercased()
                    && ($0.event == "renew" || $0.event == "renew-summary")
            })
        }
    }

    private static func helperStatus() -> SecureHelperStatus {
        let policy = BoundedFileReadPolicy(
            maximumBytes: 4_096,
            expectedOwnerUID: 0,
            requireSingleLink: true,
            rejectGroupOrWorldWritable: true,
            requireNonEmpty: false,
            safeParentDepth: 1
        )
        switch BoundedFileReader.readUTF8(path: AppPaths.rootHelperStatusPath, policy: policy) {
        case .failure(.missing): return .absent
        case let .success(raw):
            return HelperStatusRecord.parse(raw).map(SecureHelperStatus.record) ?? .malformed
        default: return .malformed
        }
    }

    private static func secureLeaseSeed() -> SecureLeaseSeed {
        switch readImmutableArtifact(.init(
            path: AppPaths.activationLeaseFile.path,
            maximumBytes: 4_096,
            expectedOwner: getuid(),
            expectedMode: 0o600,
            safeParentDepth: 2,
            expectedParentOwner: getuid()
        )) {
        case .absent: return .absent
        case let .success(fingerprint):
            guard let raw = String(data: fingerprint.bytes, encoding: .utf8),
                  let lease = ActivationLease.parse(raw)
            else { return .malformed }
            return .record(lease)
        case .unsafeOrChanged: return .malformed
        }
    }

    private static func diagnosticHistory() -> SecureDiagnosticHistory {
        switch readImmutableArtifact(.init(
            path: AppPaths.sessionHistoryFile.path,
            maximumBytes: 128 * 1_024,
            expectedOwner: getuid(),
            expectedMode: 0o600,
            safeParentDepth: 2,
            expectedParentOwner: getuid()
        )) {
        case .absent: return .absent
        case let .success(fingerprint):
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let entries = try? decoder.decode([SessionDiagnosticEntry].self, from: fingerprint.bytes),
                  entries.count <= 200,
                  entries.allSatisfy(validDiagnosticEntry)
            else { return .malformed }
            return .success(entries: entries, fingerprint: fingerprint)
        case .unsafeOrChanged: return .malformed
        }
    }

    private static func validDiagnosticEntry(_ entry: SessionDiagnosticEntry) -> Bool {
        guard UUID(uuidString: entry.sessionID) != nil,
              entry.timestamp.timeIntervalSinceReferenceDate.isFinite,
              !entry.reason.isEmpty,
              !entry.appVersion.isEmpty,
              !entry.appBuild.isEmpty
        else { return false }
        if entry.schema == 2 {
            return entry.event == "renew-summary" && (entry.renewalCount ?? 0) > 0
        }
        return entry.schema == 1
            && entry.renewalCount == nil
            && ["start", "acknowledged", "recovered", "end", "renew"].contains(entry.event)
    }

    private static func terminalLedger() -> SecureTerminalLedger {
        switch readImmutableArtifact(.init(
            path: AppPaths.rootTerminalGenerationsPath,
            maximumBytes: TerminalGenerationLedger.maximumBytes,
            expectedOwner: 0,
            expectedMode: 0o644,
            safeParentDepth: 2,
            expectedParentOwner: 0
        )) {
        case .absent: return .absent
        case let .success(fingerprint):
            guard let raw = String(data: fingerprint.bytes, encoding: .utf8),
                  let entries = TerminalGenerationLedger.parse(raw)
            else { return .malformed }
            return .success(entries: entries, fingerprint: fingerprint)
        case .unsafeOrChanged: return .malformed
        }
    }
}

private func terminalLedgerAllowsActiveSession(_ entries: [UUID], sessionID: UUID) -> Bool {
    !entries.contains(sessionID)
}

/// Per-test live-state envelope shared by controller and benchmark tests. Its
/// capture is read-only and fail-closed: an unsafe or partial live lineage
/// prevents the test body from starting, while teardown always compares the
/// post-state even when that body already reported a failure.
struct LiveStatePreservationToken {
    private let guardState: LiveControllerSessionGuard

    static func capture() throws -> LiveStatePreservationToken {
        let guardState = LiveControllerSessionGuard.capture()
        guard guardState.preflightAllowsFixtureExercise else {
            throw NSError(
                domain: "LiveStatePreservationToken",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: guardState.preflightFailureReason ?? "live state is unsafe or indeterminate"]
            )
        }
        return LiveStatePreservationToken(guardState: guardState)
    }

    func assertPreserved() {
        guardState.assertPreserved()
    }
}
#endif

private struct InspectionFixtureClock {
    var now: Date
    var validationCalls = 0
    var helperLoadedCalls = 0
    var legacyLoginLoadedCalls = 0
    var legacyLoginLoaded = false
    var statusSequence = 0
    var sourceCalls = 0
    var sleepDisabledCalls = 0
    var acPreferenceCalls = 0
    var desiredStateCalls = 0
    var leaseCalls = 0
    var helperStatusCalls = 0
}

/// An isolated file-system seam for the inspection cache. All metadata
/// closures reject paths outside this TestSandbox fixture, so a behavioral
/// cache test can never fall through to AppPaths or the live helper state.
private final class InspectionFixture: @unchecked Sendable {
    let root: URL
    let staticPaths: [String]
    let appliedState: URL
    let helperStatus: URL
    let originalAC: URL
    let originalBattery: URL
    let legacyRoot: URL
    let legacyLogin: URL
    let clock: LockedBox<InspectionFixtureClock>
    let engine: PowerInspector.InspectionEngine
    let dynamicEngine: PowerInspector.DynamicSnapshotEngine

    init() throws {
        root = try TestSandbox.makeDirectory(label: "inspection-cache").url
        let helper = root.appendingPathComponent("helper")
        let version = root.appendingPathComponent("helper-version")
        let daemon = root.appendingPathComponent("daemon.plist")
        let generations = root.appendingPathComponent("terminal-generations")
        let bundled = root.appendingPathComponent("bundled-helper")
        let staticURLs = [helper, version, daemon, generations, bundled]
        for (index, path) in staticURLs.enumerated() {
            try Data("static-\(index)".utf8).write(to: path)
        }
        let staticPathStrings = staticURLs.map(\.path)
        staticPaths = staticPathStrings

        appliedState = root.appendingPathComponent("applied-state")
        helperStatus = root.appendingPathComponent("helper-status")
        originalAC = root.appendingPathComponent("original-ac")
        originalBattery = root.appendingPathComponent("original-battery")
        legacyRoot = root.appendingPathComponent("legacy-root")
        legacyLogin = root.appendingPathComponent("legacy-login")
        try Data("applied".utf8).write(to: appliedState)

        let state = LockedBox(InspectionFixtureClock(now: Date(timeIntervalSince1970: 1_700_000_000)))
        clock = state
        let dynamic = (
            appliedState.path,
            helperStatus.path,
            originalAC.path,
            originalBattery.path,
            legacyRoot.path,
            legacyLogin.path
        )
        let staticPathSet = Set(staticPathStrings)
        let dynamicPathSet = Set([dynamic.0, dynamic.1, dynamic.2, dynamic.3, dynamic.4, dynamic.5])
        engine = PowerInspector.InspectionEngine(dependencies: .init(
            fingerprintPaths: staticPathStrings,
            now: { state.value.now },
            staticMetadata: { Self.fullMetadata(path: $0, allowed: staticPathSet) },
            collect: { fingerprint in
                let legacyLoaded = state.withValue { value in
                    value.validationCalls += 1
                    value.helperLoadedCalls += 1
                    value.legacyLoginLoadedCalls += 1
                    return value.legacyLoginLoaded
                }
                return PowerInspector.InstallationInventoryCollection(
                    staticArtifactsPresent: fingerprint.contains { !$0.hasSuffix(":missing") },
                    staticValidationValid: true,
                    helperLaunchd: .present,
                    legacyLaunchd: legacyLoaded ? .present : .absent,
                    bundleValidation: .init(integrity: true, version: true, codesignExitCode: 0)
                )
            }
        ))
        dynamicEngine = PowerInspector.DynamicSnapshotEngine(dependencies: .init(
            dynamicPaths: (
                appliedState: dynamic.0,
                helperStatus: dynamic.1,
                originalAC: dynamic.2,
                originalBattery: dynamic.3,
                legacyRoot: dynamic.4,
                legacyLogin: dynamic.5
            ),
            source: {
                state.withValue { $0.sourceCalls += 1 }
                return .ac
            },
            sleepDisabled: {
                state.withValue { $0.sleepDisabledCalls += 1 }
                return false
            },
            acIdleSleep: {
                state.withValue { $0.acPreferenceCalls += 1 }
                return 5
            },
            preferences: {
                state.withValue { $0.desiredStateCalls += 1 }
                return .value(.disabled)
            },
            systemBuild: { "25F84" },
            activationLease: { _ in
                state.withValue { $0.leaseCalls += 1 }
                return .missing("fixture")
            },
            helperStatus: {
                state.withValue { $0.helperStatusCalls += 1 }
                return PowerInspector.helperStatus(path: dynamic.1, expectedOwnerUID: getuid())
            },
            dynamicMetadata: { Self.structuralMetadata(path: $0, allowed: dynamicPathSet) },
            now: { state.value.now }
        ))
        try writeStatus(reason: "initial")
    }

    func writeStatus(reason: String) throws {
        let updated = clock.withValue { state -> Int in
            state.statusSequence += 1
            state.now = state.now.addingTimeInterval(1)
            return Int(state.now.timeIntervalSince1970)
        }
        let raw = "state=active\nreason=\(reason)\nsession=none\nupdated=\(updated)\n"
        try Data(raw.utf8).write(to: helperStatus)
    }

    func advance(_ seconds: TimeInterval) {
        clock.withValue { $0.now = $0.now.addingTimeInterval(seconds) }
    }

    func mutateStaticArtifact() throws {
        try Data("static-mutated".utf8).write(to: URL(fileURLWithPath: staticPaths[0]))
    }

    func setLegacyRootPresent(_ present: Bool) throws {
        try setFile(at: legacyRoot, present: present)
    }

    func setLegacyLoginPresent(_ present: Bool) throws {
        try setFile(at: legacyLogin, present: present)
    }

    func setLegacyLoginLoaded(_ loaded: Bool) {
        clock.withValue { $0.legacyLoginLoaded = loaded }
    }

    private func setFile(at url: URL, present: Bool) throws {
        if present {
            try Data("legacy".utf8).write(to: url)
        } else {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func fullMetadata(path: String, allowed: Set<String>) -> String {
        precondition(allowed.contains(path), "fixture static metadata escaped its sandbox")
        var status = stat()
        guard lstat(path, &status) == 0 else { return "\(path):missing" }
        return [
            path, "present", String(status.st_dev), String(status.st_ino), String(status.st_mode & S_IFMT), String(status.st_mode),
            String(status.st_uid), String(status.st_gid), String(status.st_nlink), String(status.st_size),
            String(status.st_mtimespec.tv_sec), String(status.st_mtimespec.tv_nsec),
            String(status.st_ctimespec.tv_sec), String(status.st_ctimespec.tv_nsec),
        ].joined(separator: ":")
    }

    private static func structuralMetadata(path: String, allowed: Set<String>) -> String {
        precondition(allowed.contains(path), "fixture dynamic metadata escaped its sandbox")
        var status = stat()
        guard lstat(path, &status) == 0 else { return "\(path):missing" }
        return [
            path, "present", String(status.st_dev), String(status.st_mode & S_IFMT), String(status.st_mode), String(status.st_uid),
            String(status.st_gid), String(status.st_nlink),
        ].joined(separator: ":")
    }
}

final class SessionSafetyTests: XCTestCase {
    func testNativeCleanupProofSourceIsGenerationBoundAndPreservesACIdleValue() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/LidSwitch/Services/PowerController.swift"),
            encoding: .utf8
        )
        let proofStart = try XCTUnwrap(controller.range(of: "func provesFullRollback"))
        let proofEnd = try XCTUnwrap(controller.range(of: "var hasAuthenticatedTerminalProof", range: proofStart.upperBound..<controller.endIndex))
        let proof = String(controller[proofStart.lowerBound..<proofEnd.lowerBound])
        XCTAssertTrue(proof.contains("snapshot.acIdleSleepMinutes == originalACIdleSleepMinutes"))
        XCTAssertTrue(proof.contains("status.sessionID == sessionID"))
        XCTAssertTrue(proof.contains("status.isFresh(at: snapshot.checkedAt)"))
        XCTAssertTrue(proof.contains("status.state == \"inactive\" || status.state == \"terminal\""))
        XCTAssertFalse(proof.contains("helperStatus?.state != \"active\""))
        XCTAssertTrue(controller.contains("guard let originalACIdleSleepMinutes = freshSnapshot.acIdleSleepMinutes"))
        XCTAssertTrue(controller.contains("reply.sessionID == sessionID"))
        XCTAssertTrue(controller.contains("no power rollback was claimed"))
    }
    func testSystemPowerSystemReadsLiveOverrideAndNativePowerPreferencesWithoutPMSet() {
        let values: [String: Any] = [
            "AC Power": ["System Sleep Timer": NSNumber(value: 0)],
        ]
        let power = SystemPowerSystem(
            liveSleepDisabledValue: { NSNumber(value: true) },
            preferenceValue: { values[$0] }
        )

        XCTAssertEqual(power.sleepDisabled(), true)
        XCTAssertEqual(power.acSleepMinutes(), 0)
    }

    func testSystemPowerSystemRejectsMalformedNativePowerPreferences() {
        let values: [String: Any] = [
            "AC Power": ["System Sleep Timer": NSNumber(value: 0.5)],
        ]
        let power = SystemPowerSystem(
            liveSleepDisabledValue: { NSNumber(value: 2) },
            preferenceValue: { values[$0] }
        )

        XCTAssertNil(power.sleepDisabled())
        XCTAssertNil(power.acSleepMinutes())
    }

    func testRecurringRuntimeProvidersUseNativeReadsAndReservePMSetForMutations() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let inspector = try String(contentsOf: root.appendingPathComponent("Sources/LidSwitch/Services/PowerInspector.swift"), encoding: .utf8)
        let helperRuntime = try String(contentsOf: root.appendingPathComponent("Sources/LidSwitchHelper/HelperRuntime.swift"), encoding: .utf8)
        let powerSystem = try String(contentsOf: root.appendingPathComponent("Sources/LidSwitchHelper/PowerSystem.swift"), encoding: .utf8)
        XCTAssertTrue(inspector.contains("kCFPreferencesAnyUser") && inspector.contains("kCFPreferencesCurrentHost"))
        XCTAssertTrue(powerSystem.contains("kCFPreferencesAnyUser") && powerSystem.contains("kCFPreferencesCurrentHost"))
        XCTAssertFalse(inspector.contains("/usr/bin/pmset"))
        XCTAssertFalse(helperRuntime.contains("/usr/bin/pmset"))
        // Recurring inspection and helper reconciliation now use native power
        // APIs exclusively.  `pmset` is intentionally absent rather than a
        // mutation fallback that would reintroduce shell startup/timeout risk.
        XCTAssertEqual(powerSystem.components(separatedBy: "/usr/bin/pmset").count - 1, 0)
    }

    func testInspectionEngineStatusChurnKeepsStaticValidationAndLaunchdCached() throws {
        let fixture = try InspectionFixture()
        let warm = captureBenchmarkProbe { fixture.engine.inspect(policy: .reuseIfFresh) }
        XCTAssertEqual(warm.counters["inspection_artifact_validation"], 1)
        XCTAssertEqual(warm.counters["installation_inventory_static_miss_cold"], 1)
        XCTAssertTrue(warm.result.state.isValid)

        var previousUpdatedAt = Date.distantPast
        for reason in ["first", "second", "newest"] {
            try fixture.writeStatus(reason: reason)
            let snapshot = fixture.dynamicEngine.snapshot(ownedSessionID: nil, inventory: warm.result)
            let parsed = try XCTUnwrap(snapshot.helperStatus)
            XCTAssertEqual(parsed.reason, reason)
            XCTAssertGreaterThan(parsed.updatedAt, previousUpdatedAt)
            previousUpdatedAt = parsed.updatedAt

            let hit = captureBenchmarkProbe { fixture.engine.inspect(policy: .reuseIfFresh) }
            XCTAssertEqual(hit.counters["installation_inventory_static_hit"], 1)
            XCTAssertEqual(hit.counters["inspection_artifact_validation", default: 0], 0)
            XCTAssertEqual(hit.counters["helper_byte_comparison", default: 0], 0)
            XCTAssertEqual(hit.counters["child_process", default: 0], 0)
            XCTAssertTrue(hit.result.state.isValid)
        }
        XCTAssertEqual(fixture.clock.value.validationCalls, 1)
        XCTAssertEqual(fixture.clock.value.helperLoadedCalls, 1)
    }

    func testInspectionEngineStaticMutationRevalidatesAndForcesLaunchdReinspection() throws {
        let fixture = try InspectionFixture()
        _ = fixture.engine.inspect(policy: .reuseIfFresh)
        try fixture.mutateStaticArtifact()

        let changed = captureBenchmarkProbe { fixture.engine.inspect(policy: .reuseIfFresh) }
        XCTAssertEqual(changed.counters["installation_inventory_static_miss_drift"], 1)
        XCTAssertEqual(changed.counters["inspection_artifact_validation"], 1)
        XCTAssertTrue(changed.result.state.isValid)
        XCTAssertEqual(fixture.clock.value.validationCalls, 2)
        XCTAssertEqual(fixture.clock.value.helperLoadedCalls, 2)
    }

    func testInspectionEngineLaunchdExpiryAndForcedRefreshKeepStaticValidationCached() throws {
        let fixture = try InspectionFixture()
        _ = fixture.engine.inspect(policy: .reuseIfFresh)
        fixture.advance(60)
        let expired = captureBenchmarkProbe { fixture.engine.inspect(policy: .reuseIfFresh) }
        XCTAssertEqual(expired.counters["installation_inventory_static_miss_expired"], 1)
        XCTAssertEqual(expired.counters["inspection_artifact_validation"], 1)

        let forced = captureBenchmarkProbe { fixture.engine.inspect(policy: .forceFresh) }
        XCTAssertEqual(forced.counters["installation_inventory_force_fresh"], 1)
        XCTAssertEqual(forced.counters["inspection_artifact_validation"], 1)
        XCTAssertEqual(fixture.clock.value.validationCalls, 3)
        XCTAssertEqual(fixture.clock.value.helperLoadedCalls, 3)
    }

    func testInstallationInventoryRejectsOlderCompletionAfterNewerForceRequest() {
        let firstValidationStarted = DispatchSemaphore(value: 0)
        let releaseFirstValidation = DispatchSemaphore(value: 0)
        let generation = LockedBox("old")
        let validations = LockedBox([String]())
        let engine = PowerInspector.InspectionEngine(dependencies: .init(
            fingerprintPaths: ["helper", "bundle"],
            now: Date.init,
            staticMetadata: { path in "\(path)-\(generation.value)" },
            collect: { fingerprint in
                let value = generation.value
                validations.withValue { $0.append(value) }
                if value == "old" {
                    firstValidationStarted.signal()
                    _ = releaseFirstValidation.wait(timeout: .now() + 1)
                }
                return .init(
                    staticArtifactsPresent: true,
                    staticValidationValid: true,
                    helperLaunchd: .present,
                    legacyLaunchd: .absent,
                    bundleValidation: .init(integrity: true, version: true, codesignExitCode: 0)
                )
            }
        ))
        let firstResult = LockedBox<PowerInspector.InstallationInventoryRequestResult?>(nil)
        let secondResult = LockedBox<PowerInspector.InstallationInventoryRequestResult?>(nil)
        let firstCompleted = DispatchSemaphore(value: 0)
        let secondCompleted = DispatchSemaphore(value: 0)
        engine.request(policy: .forceFresh) { result in
            firstResult.value = result
            firstCompleted.signal()
        }
        XCTAssertEqual(firstValidationStarted.wait(timeout: .now() + 1), .success)
        generation.value = "new"
        engine.request(policy: .forceFresh) { result in
            secondResult.value = result
            secondCompleted.signal()
        }
        releaseFirstValidation.signal()
        XCTAssertEqual(firstCompleted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(secondCompleted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(firstResult.value?.accepted, false)
        XCTAssertEqual(firstResult.value?.rejection, .superseded)
        XCTAssertEqual(secondResult.value?.accepted, true)
        XCTAssertNil(secondResult.value?.rejection)
        XCTAssertEqual(secondResult.value?.inventory.fingerprint, ["helper-new", "bundle-new"])
        XCTAssertEqual(validations.value, ["old", "new"])
    }

    func testDynamicSnapshotDistinguishesActiveResidueFromLegacyLaunchResidue() throws {
        let fixture = try InspectionFixture()
        let inventory = fixture.engine.inspect(policy: .reuseIfFresh)
        let activeResidue = fixture.dynamicEngine.snapshot(ownedSessionID: nil, inventory: inventory)
        XCTAssertTrue(activeResidue.helperArtifactsPresent)
        XCTAssertTrue(activeResidue.helperLoaded)
        XCTAssertFalse(activeResidue.helperNeedsUpdate)

        try fixture.setLegacyRootPresent(true)
        let legacyRoot = fixture.dynamicEngine.snapshot(ownedSessionID: nil, inventory: inventory)
        XCTAssertTrue(legacyRoot.helperNeedsUpdate)

        try fixture.setLegacyRootPresent(false)
        try fixture.setLegacyLoginPresent(true)
        let legacyLogin = fixture.dynamicEngine.snapshot(ownedSessionID: nil, inventory: inventory)
        XCTAssertTrue(legacyLogin.legacyLoginItemPresent)
        XCTAssertFalse(legacyLogin.legacyLoginItemLoaded)
        XCTAssertTrue(legacyLogin.helperNeedsUpdate)

        try fixture.setLegacyLoginPresent(false)
        fixture.setLegacyLoginLoaded(true)
        let legacyInventory = fixture.engine.inspect(policy: .forceFresh)
        let loadedWithoutPlist = fixture.dynamicEngine.snapshot(ownedSessionID: nil, inventory: legacyInventory)
        XCTAssertFalse(loadedWithoutPlist.legacyLoginItemPresent)
        XCTAssertTrue(loadedWithoutPlist.legacyLoginItemLoaded)
        XCTAssertTrue(loadedWithoutPlist.helperNeedsUpdate)
    }

    func testBlockedInstallationCollectorDoesNotBlockFastDynamicSnapshot() throws {
        let fixture = try InspectionFixture()
        let collectorStarted = DispatchSemaphore(value: 0)
        let releaseCollector = DispatchSemaphore(value: 0)
        let completion = DispatchSemaphore(value: 0)
        let engine = PowerInspector.InstallationInventoryEngine(dependencies: .init(
            fingerprintPaths: ["fixture-static"],
            now: Date.init,
            staticMetadata: { "\($0):present" },
            collect: { _ in
                collectorStarted.signal()
                _ = releaseCollector.wait(timeout: .now() + 1)
                return .init(
                    staticArtifactsPresent: true,
                    staticValidationValid: true,
                    helperLaunchd: .present,
                    legacyLaunchd: .absent,
                    bundleValidation: .init(integrity: true, version: true, codesignExitCode: 0)
                )
            }
        ))
        engine.request(policy: .forceFresh) { _ in completion.signal() }
        XCTAssertEqual(collectorStarted.wait(timeout: .now() + 1), .success)

        let fast = captureBenchmarkProbe {
            fixture.dynamicEngine.snapshot(ownedSessionID: nil, inventory: engine.current())
        }
        XCTAssertTrue(fast.result.installationInventoryPending)
        XCTAssertEqual(fast.result.source, .ac)
        XCTAssertEqual(fast.counters["child_process", default: 0], 0)
        XCTAssertEqual(fast.counters["helper_byte_comparison", default: 0], 0)
        XCTAssertEqual(fast.counters["inspection_artifact_validation", default: 0], 0)

        releaseCollector.signal()
        XCTAssertEqual(completion.wait(timeout: .now() + 1), .success)
    }

    func testDynamicSnapshotReadsEveryLiveProviderOnEveryCall() throws {
        let fixture = try InspectionFixture()
        let inventory = fixture.engine.inspect(policy: .reuseIfFresh)
        _ = fixture.dynamicEngine.snapshot(ownedSessionID: nil, inventory: inventory)
        _ = fixture.dynamicEngine.snapshot(ownedSessionID: nil, inventory: inventory)
        let counters = fixture.clock.value
        XCTAssertEqual(counters.sourceCalls, 2)
        XCTAssertEqual(counters.sleepDisabledCalls, 2)
        XCTAssertEqual(counters.acPreferenceCalls, 2)
        XCTAssertEqual(counters.desiredStateCalls, 2)
        XCTAssertEqual(counters.leaseCalls, 2)
        XCTAssertEqual(counters.helperStatusCalls, 2)
    }

    func testMissingAndIndeterminateInstallationInventoryFailClosed() {
        func inventory(helper: PowerInspector.LaunchdPresence) -> PowerInspector.InstallationInventory {
            let engine = PowerInspector.InstallationInventoryEngine(dependencies: .init(
                fingerprintPaths: ["installed-helper"],
                now: Date.init,
                staticMetadata: { "\($0):missing" },
                collect: { _ in
                    .init(
                        staticArtifactsPresent: false,
                        staticValidationValid: false,
                        helperLaunchd: helper,
                        legacyLaunchd: .absent,
                        bundleValidation: .init(integrity: true, version: true, codesignExitCode: 0)
                    )
                }
            ))
            return engine.inspect(policy: .forceFresh)
        }

        let missing = inventory(helper: .absent)
        XCTAssertEqual(missing.state, .invalid("The helper is not installed."))
        let indeterminate = inventory(helper: .indeterminate)
        guard case .indeterminate = indeterminate.state else { return XCTFail("unknown launchd state must remain indeterminate") }
    }

    func testInstallationFingerprintDriftRejectsCandidatePublication() {
        let fingerprint = LockedBox("before")
        let engine = PowerInspector.InstallationInventoryEngine(dependencies: .init(
            fingerprintPaths: ["helper"],
            now: Date.init,
            staticMetadata: { "\($0):\(fingerprint.value)" },
            collect: { _ in
                fingerprint.value = "after"
                return .init(
                    staticArtifactsPresent: true,
                    staticValidationValid: true,
                    helperLaunchd: .present,
                    legacyLaunchd: .absent,
                    bundleValidation: .init(integrity: true, version: true, codesignExitCode: 0)
                )
            }
        ))

        let inventory = engine.inspect(policy: .forceFresh)
        guard case .indeterminate = inventory.state else {
            return XCTFail("a fingerprint-changing collection must not publish valid")
        }
        XCTAssertFalse(inventory.state.isValid)
        XCTAssertEqual(inventory.helperLaunchd, .indeterminate)
    }

    func testAsyncInstallationFingerprintDriftIsRejectedWithoutPublication() {
        let fingerprint = LockedBox("before")
        let engine = PowerInspector.InstallationInventoryEngine(dependencies: .init(
            fingerprintPaths: ["helper"],
            now: Date.init,
            staticMetadata: { "\($0):\(fingerprint.value)" },
            collect: { _ in
                fingerprint.value = "after"
                return .init(
                    staticArtifactsPresent: true,
                    staticValidationValid: true,
                    helperLaunchd: .present,
                    legacyLaunchd: .absent,
                    bundleValidation: .init(integrity: true, version: true, codesignExitCode: 0)
                )
            }
        ))
        let result = LockedBox<PowerInspector.InstallationInventoryRequestResult?>(nil)
        let completed = DispatchSemaphore(value: 0)
        engine.request(policy: .forceFresh) { value in
            result.value = value
            completed.signal()
        }
        XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(result.value?.accepted, false)
        XCTAssertEqual(result.value?.rejection, .drift)
        XCTAssertTrue(result.value?.inventory.state.isPending == true)
        XCTAssertFalse(engine.current().state.isValid)
    }

    func testQueuedStaticHitIsRejectedAfterInvalidate() {
        let callbackQueue = DispatchQueue(label: "fixture.inventory-hit-callback")
        let queueBlocked = DispatchSemaphore(value: 0)
        let releaseQueue = DispatchSemaphore(value: 0)
        callbackQueue.async {
            queueBlocked.signal()
            _ = releaseQueue.wait(timeout: .now() + 1)
        }
        XCTAssertEqual(queueBlocked.wait(timeout: .now() + 1), .success)

        let engine = PowerInspector.InstallationInventoryEngine(
            dependencies: .init(
                fingerprintPaths: ["helper"],
                now: Date.init,
                staticMetadata: { "\($0):present" },
                collect: { _ in
                    .init(
                        staticArtifactsPresent: true,
                        staticValidationValid: true,
                        helperLaunchd: .present,
                        legacyLaunchd: .absent,
                        bundleValidation: .init(integrity: true, version: true, codesignExitCode: 0)
                    )
                }
            ),
            queue: callbackQueue
        )
        _ = engine.inspect(policy: .reuseIfFresh)
        let result = LockedBox<PowerInspector.InstallationInventoryRequestResult?>(nil)
        let completed = DispatchSemaphore(value: 0)
        engine.request(policy: .reuseIfFresh) { value in
            result.value = value
            completed.signal()
        }
        engine.invalidate()
        releaseQueue.signal()
        XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(result.value?.accepted, false)
        XCTAssertEqual(result.value?.rejection, .superseded)
        XCTAssertTrue(result.value?.inventory.state.isPending == true)
    }

    func testQueuedStaticHitIsRejectedAfterNewerForceRequest() {
        let callbackQueue = DispatchQueue(label: "fixture.inventory-force-race")
        let queueBlocked = DispatchSemaphore(value: 0)
        let releaseQueue = DispatchSemaphore(value: 0)
        callbackQueue.async {
            queueBlocked.signal()
            _ = releaseQueue.wait(timeout: .now() + 1)
        }
        XCTAssertEqual(queueBlocked.wait(timeout: .now() + 1), .success)
        let engine = PowerInspector.InstallationInventoryEngine(
            dependencies: .init(
                fingerprintPaths: ["helper"],
                now: Date.init,
                staticMetadata: { "\($0):present" },
                collect: { _ in
                    .init(
                        staticArtifactsPresent: true,
                        staticValidationValid: true,
                        helperLaunchd: .present,
                        legacyLaunchd: .absent,
                        bundleValidation: .init(integrity: true, version: true, codesignExitCode: 0)
                    )
                }
            ),
            queue: callbackQueue
        )
        _ = engine.inspect(policy: .reuseIfFresh)
        let oldResult = LockedBox<PowerInspector.InstallationInventoryRequestResult?>(nil)
        let freshResult = LockedBox<PowerInspector.InstallationInventoryRequestResult?>(nil)
        let oldCompleted = DispatchSemaphore(value: 0)
        let freshCompleted = DispatchSemaphore(value: 0)
        engine.request(policy: .reuseIfFresh) { value in
            oldResult.value = value
            oldCompleted.signal()
        }
        engine.request(policy: .forceFresh) { value in
            freshResult.value = value
            freshCompleted.signal()
        }
        releaseQueue.signal()
        XCTAssertEqual(oldCompleted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(freshCompleted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(oldResult.value?.accepted, false)
        XCTAssertEqual(oldResult.value?.rejection, .superseded)
        XCTAssertEqual(freshResult.value?.accepted, true)
        XCTAssertNil(freshResult.value?.rejection)
        XCTAssertTrue(freshResult.value?.inventory.state.isValid == true)
    }

    func testExpiredInventoryCurrentFailsClosedBeforeAsyncRefreshStarts() throws {
        let fixture = try InspectionFixture()
        XCTAssertTrue(fixture.engine.inspect(policy: .reuseIfFresh).state.isValid)
        fixture.advance(60)
        let current = fixture.engine.current()
        XCTAssertTrue(current.state.isPending)
        XCTAssertFalse(current.state.isValid)
    }

    func testInventoryAndRollbackSourcesExcludePrivateRecoveryLedgerContentReads() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let inspector = try String(
            contentsOf: root.appendingPathComponent("Sources/LidSwitch/Services/PowerInspector.swift"),
            encoding: .utf8
        )
        let productionStart = try XCTUnwrap(inspector.range(of: "private static let productionInstallationInventoryEngine"))
        let productionEnd = try XCTUnwrap(inspector.range(of: "static func snapshot", range: productionStart.upperBound..<inspector.endIndex))
        let staticValidationStart = try XCTUnwrap(inspector.range(of: "private static func staticArtifactValidation"))
        let staticValidationEnd = try XCTUnwrap(inspector.range(of: "static func terminalGenerationsValid", range: staticValidationStart.upperBound..<inspector.endIndex))
        let appInventory = String(inspector[productionStart.lowerBound..<productionEnd.lowerBound])
            + String(inspector[staticValidationStart.lowerBound..<staticValidationEnd.lowerBound])
        XCTAssertFalse(appInventory.contains("rootTerminalGenerationsPath"))
        XCTAssertFalse(appInventory.contains("rootRecoveryReservationsPath"))
        XCTAssertFalse(appInventory.contains("rootEnrollmentPolicyPath"))

        let rollbackStart = try XCTUnwrap(inspector.range(of: "static func rollbackDynamicSnapshot"))
        let rollbackEnd = try XCTUnwrap(inspector.range(of: "@discardableResult", range: rollbackStart.upperBound..<inspector.endIndex))
        let rollback = String(inspector[rollbackStart.lowerBound..<rollbackEnd.lowerBound])
        XCTAssertFalse(rollback.contains("requestInstallationInventory"))
        XCTAssertFalse(rollback.contains("inspect(policy:"))
        XCTAssertFalse(rollback.contains("Shell.run"))

        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/LidSwitch/Services/PowerController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(controller.contains("snapshotProviders.invalidateInventory()"))
        XCTAssertTrue(controller.contains("prepareConvergence"))
        XCTAssertTrue(controller.contains("uninstallConvergence"))
    }

    func testHelperUpdateIsDistinctFromLegacyStartupResidue() {
        let update = makeSnapshot(source: .ac, sleepDisabled: false, sleepDisabledVerified: true, helperNeedsUpdate: true)
        XCTAssertFalse(update.legacyResiduePresent)
        XCTAssertEqual(update.statusTitle, "Helper update required")
        XCTAssertTrue(update.statusDetail.contains("newer crash-safe helper"))

        let legacy = makeSnapshot(source: .ac, sleepDisabled: false, sleepDisabledVerified: true, legacyLoginPresent: true)
        XCTAssertTrue(legacy.legacyResiduePresent)
        XCTAssertEqual(legacy.statusTitle, "Old startup files found")
    }

    func testStaleCanonicalLegacyLeaseRoutesPrepareWithoutSessionAuthority() {
        let stale = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true,
            activationLeaseTruth: .invalid,
            staleCanonicalLegacyLeasePresent: true
        )
        XCTAssertNil(stale.activationLease)
        XCTAssertTrue(stale.staleCanonicalLegacyLeasePresent)
        XCTAssertTrue(stale.legacyResiduePresent)
        XCTAssertFalse(stale.canStartSession)
        XCTAssertEqual(stale.statusTitle, "Legacy lease needs reconciliation")
        XCTAssertTrue(stale.statusDetail.contains("Prepare Safe Helper"))
        XCTAssertEqual(PowerControllerPrimaryAction.resolve(snapshot: stale, operationPhase: .idle), .prepareHelper)

        let genericResidue = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true,
            activationLeaseTruth: .retainedResidue
        )
        XCTAssertFalse(genericResidue.canStartSession)
        XCTAssertFalse(genericResidue.staleCanonicalLegacyLeasePresent)
        XCTAssertNotEqual(PowerControllerPrimaryAction.resolve(snapshot: genericResidue, operationPhase: .idle), .prepareHelper)
    }

    func testPendingInventoryUsesCheckingTruthAndBlocksStartWithoutFalseBuildFailure() {
        let pending = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true,
            inventoryState: .pending
        )
        XCTAssertEqual(pending.statusTitle, "Checking installation")
        XCTAssertTrue(pending.statusDetail.contains("exact check finishes"))
        XCTAssertFalse(pending.canStartSession)
        XCTAssertFalse(pending.statusTitle.contains("Build verification failed"))
    }

    @MainActor
    func testControllerInventoryDriftRetriesExactlyOnceThenPublishesValidResult() async {
        let calls = LockedBox([Bool]())
        let pending = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true,
            inventoryState: .pending
        )
        let valid = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true
        )
        let controller = PowerController(
            bootstrap: false,
            inventoryResultProvider: { _, force in
                let call = calls.withValue { values -> Int in
                    values.append(force)
                    return values.count
                }
                return call == 1
                    ? PowerControllerInventoryFixtureResult(snapshot: pending, rejection: .drift)
                    : PowerControllerInventoryFixtureResult(snapshot: valid, rejection: nil)
            },
            sideEffects: .fixture
        )

        controller.refreshManually()
        await waitForRefresh(controller)

        XCTAssertEqual(calls.value, [true, true])
        XCTAssertEqual(controller.snapshot, valid)
        XCTAssertFalse(controller.isChecking)
        XCTAssertFalse(controller.refreshCompletionOutstandingForTesting)
    }

    @MainActor
    func testControllerSupersededInventoryRetriesExactlyOnceThenPublishesValidResult() async {
        let calls = LockedBox([Bool]())
        let pending = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true,
            inventoryState: .pending
        )
        let valid = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true
        )
        let controller = PowerController(
            bootstrap: false,
            inventoryResultProvider: { _, force in
                let call = calls.withValue { values -> Int in
                    values.append(force)
                    return values.count
                }
                return call == 1
                    ? PowerControllerInventoryFixtureResult(snapshot: pending, rejection: .superseded)
                    : PowerControllerInventoryFixtureResult(snapshot: valid, rejection: nil)
            },
            sideEffects: .fixture
        )

        controller.refreshManually()
        await waitForRefresh(controller)

        XCTAssertEqual(calls.value, [true, true])
        XCTAssertEqual(controller.snapshot, valid)
        XCTAssertFalse(controller.isChecking)
        XCTAssertFalse(controller.refreshCompletionOutstandingForTesting)
    }

    @MainActor
    func testPersistentInventoryDriftTerminalizesAndFailsStartWithoutRetryLoop() async {
        let calls = LockedBox([Bool]())
        let sideEffectEvents = LockedBox([String]())
        let pending = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true,
            inventoryState: .pending
        )
        let controller = PowerController(
            bootstrap: false,
            inventoryResultProvider: { _, force in
                calls.withValue { $0.append(force) }
                return PowerControllerInventoryFixtureResult(snapshot: pending, rejection: .drift)
            },
            sideEffects: .recordingFixture { event in
                sideEffectEvents.withValue { $0.append(event) }
            }
        )

        controller.startSession()
        await waitForRefresh(controller)

        XCTAssertEqual(calls.value, [true, true])
        XCTAssertTrue(sideEffectEvents.value.isEmpty)
        XCTAssertFalse(controller.isStarting)
        XCTAssertFalse(controller.isBusy)
        XCTAssertFalse(controller.isChecking)
        XCTAssertFalse(controller.refreshCompletionOutstandingForTesting)
        XCTAssertTrue(controller.snapshot.installationInventoryIndeterminate)
        guard case let .indeterminate(reason) = controller.snapshot.installationInventoryState else {
            return XCTFail("persistent drift must publish a typed terminal inventory result")
        }
        XCTAssertTrue(reason.contains("both bounded attempts"))
        XCTAssertTrue(controller.snapshot.statusDetail.contains("could not stabilize"))
        XCTAssertTrue(controller.errorMessage?.contains("Session did not start") == true)
    }

    @MainActor
    func testPersistentSupersededInventoryTerminalizesAndFailsStartWithoutRetryLoop() async {
        let calls = LockedBox([Bool]())
        let sideEffectEvents = LockedBox([String]())
        let pending = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true,
            inventoryState: .pending
        )
        let controller = PowerController(
            bootstrap: false,
            inventoryResultProvider: { _, force in
                calls.withValue { $0.append(force) }
                return PowerControllerInventoryFixtureResult(snapshot: pending, rejection: .superseded)
            },
            sideEffects: .recordingFixture { event in
                sideEffectEvents.withValue { $0.append(event) }
            }
        )

        controller.startSession()
        await waitForRefresh(controller)

        XCTAssertEqual(calls.value, [true, true])
        XCTAssertTrue(sideEffectEvents.value.isEmpty)
        XCTAssertFalse(controller.isStarting)
        XCTAssertFalse(controller.isBusy)
        XCTAssertFalse(controller.isChecking)
        XCTAssertFalse(controller.refreshCompletionOutstandingForTesting)
        XCTAssertTrue(controller.snapshot.installationInventoryIndeterminate)
        guard case let .indeterminate(reason) = controller.snapshot.installationInventoryState else {
            return XCTFail("persistent supersession must publish a typed terminal inventory result")
        }
        XCTAssertTrue(reason.contains("both bounded attempts"))
        XCTAssertTrue(controller.snapshot.statusDetail.contains("could not stabilize"))
        XCTAssertTrue(controller.errorMessage?.contains("Session did not start") == true)
    }

    @MainActor
    func testPersistentInventoryDriftFailsPrepareConvergenceWithoutRetryLoop() async {
        let calls = LockedBox([Bool]())
        let pending = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true,
            inventoryState: .pending
        )
        let valid = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true
        )
        let controller = PowerController(
            bootstrap: false,
            inventoryResultProvider: { _, force in
                calls.withValue { $0.append(force) }
                return force
                    ? PowerControllerInventoryFixtureResult(snapshot: pending, rejection: .drift)
                    : PowerControllerInventoryFixtureResult(snapshot: valid, rejection: nil)
            },
            sideEffects: .fixture
        )

        controller.refresh()
        await waitForRefresh(controller)
        controller.prepareHelper()
        for _ in 0..<200 where controller.isBusy || controller.isChecking {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(calls.value, [false, true, true])
        XCTAssertFalse(controller.isBusy)
        XCTAssertFalse(controller.isChecking)
        XCTAssertFalse(controller.refreshCompletionOutstandingForTesting)
        XCTAssertTrue(controller.snapshot.installationInventoryIndeterminate)
        XCTAssertTrue(controller.errorMessage?.contains("exact safe ready state") == true)
    }

    @MainActor
    func testStaleControllerGenerationCannotConsumeNewGenerationDriftRetry() async {
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let calls = LockedBox([Bool]())
        let pending = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true,
            inventoryState: .pending
        )
        let valid = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true
        )
        let controller = PowerController(
            bootstrap: false,
            inventoryResultProvider: { _, force in
                let call = calls.withValue { values -> Int in
                    values.append(force)
                    return values.count
                }
                if call == 1 {
                    firstStarted.signal()
                    _ = releaseFirst.wait(timeout: .now() + 1)
                }
                if call < 3 {
                    return PowerControllerInventoryFixtureResult(snapshot: pending, rejection: .drift)
                }
                return PowerControllerInventoryFixtureResult(snapshot: valid, rejection: nil)
            },
            sideEffects: .fixture
        )

        controller.refreshManually()
        XCTAssertEqual(firstStarted.wait(timeout: .now() + 1), .success)
        controller.refresh()
        releaseFirst.signal()
        await waitForRefresh(controller)

        XCTAssertEqual(calls.value, [true, true, true])
        XCTAssertEqual(controller.snapshot, valid)
        XCTAssertFalse(controller.isChecking)
        XCTAssertFalse(controller.refreshCompletionOutstandingForTesting)
    }

    @MainActor
    func testStaleControllerEpochRejectsDriftWithoutRetryOrStartSideEffect() async {
        let requestStarted = DispatchSemaphore(value: 0)
        let releaseRequest = DispatchSemaphore(value: 0)
        let calls = LockedBox(0)
        let sideEffectEvents = LockedBox([String]())
        let pending = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true,
            inventoryState: .pending
        )
        let controller = PowerController(
            bootstrap: false,
            inventoryResultProvider: { _, _ in
                calls.withValue { $0 += 1 }
                requestStarted.signal()
                _ = releaseRequest.wait(timeout: .now() + 1)
                return PowerControllerInventoryFixtureResult(snapshot: pending, rejection: .drift)
            },
            sideEffects: .recordingFixture { event in
                sideEffectEvents.withValue { $0.append(event) }
            }
        )

        controller.startSession()
        XCTAssertEqual(requestStarted.wait(timeout: .now() + 1), .success)
        controller.invalidateStartRequestForTesting()
        releaseRequest.signal()
        await waitForRefresh(controller)

        XCTAssertEqual(calls.value, 1)
        XCTAssertTrue(sideEffectEvents.value.isEmpty)
        XCTAssertEqual(controller.snapshot, .empty)
        XCTAssertFalse(controller.isStarting)
        XCTAssertFalse(controller.isBusy)
        XCTAssertFalse(controller.isChecking)
        XCTAssertFalse(controller.refreshCompletionOutstandingForTesting)
    }

    @MainActor
    func testPrepareHelperInvalidatesInventoryBeforeMutationAndBeforeExactConvergence() async {
        let safe = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true
        )
        let invalidations = LockedBox(0)
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in safe },
            forceFreshSnapshotProvider: { _ in safe },
            inventoryInvalidator: { invalidations.withValue { $0 += 1 } },
            sideEffects: .fixture
        )
        controller.refresh()
        await waitForRefresh(controller)
        controller.prepareHelper()
        for _ in 0..<200 where controller.isBusy || controller.isChecking {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(invalidations.value, 2)
        XCTAssertFalse(controller.isBusy)
        XCTAssertTrue(controller.snapshot.helperReady)
    }

    func testBoundedHelperComparisonRejectsOversizeAndMidReadMutation() throws {
        let root = try temporaryDirectory()
        let installed = root.appendingPathComponent("installed")
        let bundled = root.appendingPathComponent("bundled")
        try Data(repeating: 0x5A, count: 128 * 1_024).write(to: installed)
        try Data(repeating: 0x5A, count: 128 * 1_024).write(to: bundled)
        XCTAssertFalse(BoundedHelperComparator.matches(
            installed: installed.path, bundled: bundled.path, maximumBytes: 64 * 1_024,
            expectedInstalledOwner: getuid()
        ))
        XCTAssertFalse(BoundedHelperComparator.matches(
            installed: installed.path, bundled: bundled.path, maximumBytes: 256 * 1_024,
            expectedInstalledOwner: getuid(),
            beforeFinalMetadata: { try? FileHandle(forWritingTo: installed).truncate(atOffset: 0) }
        ))
    }

    func testShellRejectsUntrustedTimedAndInterpreterContractsBeforeSpawn() {
        let untrusted = Shell.run(.fixture(executable: "/usr/bin/yes", arguments: ["fixture"], timeout: 0.02))
        XCTAssertEqual(untrusted.exitCode, 125)
        XCTAssertEqual(untrusted.outcome, .rejected)
        XCTAssertTrue(untrusted.stderr.contains("allowlisted"))

        let interpreter = Shell.run(.fixture(executable: "/bin/sh", arguments: ["-c", "sleep 30 & wait"], timeout: 0.02))
        XCTAssertEqual(interpreter.exitCode, 127)
        XCTAssertEqual(interpreter.outcome, .rejected)
        XCTAssertTrue(interpreter.stderr.contains("forbidden"))
    }

    func testShellRunnerFixtureRequiresReapGroupQuiescenceAndBothEOFs() {
        let base = Shell.RunnerFixtureState(directChildReaped: true, processGroupQuiescent: true,
                                            stdoutEOF: true, stderrEOF: true, cleanupDeadlineExpired: false)
        XCTAssertEqual(Shell.fixtureOutcome(base), .complete)
        XCTAssertEqual(Shell.fixtureOutcome(.init(directChildReaped: true, processGroupQuiescent: false,
                                                   stdoutEOF: true, stderrEOF: true, cleanupDeadlineExpired: false)), .wait)
        XCTAssertEqual(Shell.fixtureOutcome(.init(directChildReaped: true, processGroupQuiescent: true,
                                                   stdoutEOF: false, stderrEOF: true, cleanupDeadlineExpired: false)), .wait)
        XCTAssertEqual(Shell.fixtureOutcome(.init(directChildReaped: false, processGroupQuiescent: false,
                                                   stdoutEOF: false, stderrEOF: false, cleanupDeadlineExpired: true)), .containmentFailed(childReapFailed: true))
    }

    func testShellRunnerMachineScriptsTermKillESRCHAndPipeEdgesWithoutSpawn() {
        var machine = Shell.RunnerMachine(commandDeadline: 10, termBudget: 2, cleanupBudget: 3)
        XCTAssertEqual(machine.advance(now: 9, childReaped: false, group: .live, stdout: .wouldBlock, stderr: .wouldBlock), .wait(.none))
        XCTAssertEqual(machine.advance(now: 10, childReaped: false, group: .live, stdout: .wouldBlock, stderr: .wouldBlock), .wait(.term))
        XCTAssertEqual(machine.advance(now: 12, childReaped: false, group: .live, stdout: .interrupted, stderr: .wouldBlock), .wait(.kill))
        // ESRCH is latched: later deadline transitions never reuse this PGID.
        XCTAssertEqual(machine.advance(now: 13, childReaped: true, group: .goneESRCH, stdout: .eof, stderr: .wouldBlock), .wait(.none))
        XCTAssertEqual(machine.advance(now: 14, childReaped: true, group: .unknown, stdout: .eof, stderr: .eof), .completed)

        // A reaped leader with a live group member/held descriptor is not done.
        var descendant = Shell.RunnerMachine(commandDeadline: 20)
        XCTAssertEqual(descendant.advance(now: 1, childReaped: true, group: .live, stdout: .open, stderr: .wouldBlock), .wait(.none))

        var deadline = Shell.RunnerMachine(commandDeadline: 1, termBudget: 1, cleanupBudget: 1)
        XCTAssertEqual(deadline.advance(now: 1, childReaped: false, group: .live, stdout: .open, stderr: .open), .wait(.term))
        XCTAssertEqual(deadline.advance(now: 2, childReaped: false, group: .live, stdout: .open, stderr: .open), .wait(.kill))
        XCTAssertEqual(deadline.advance(now: 3, childReaped: false, group: .unknown, stdout: .open, stderr: .open), .containmentFailed)
    }

    func testShellSetupAndOutputFixturesCoverPartialFailureTruncationAndReconciliation() {
        for stage in Shell.SetupStage.allCases {
            let result = Shell.setupFailure(stage)
            XCTAssertEqual(result.outcome, .spawnFailed)
            XCTAssertTrue(result.stderr.contains("[\(stage)]"))
        }
        let output = BoundedProcessOutput(maximumBytes: 3)
        let stdout = Array("abcdef".utf8)
        let stderr = Array("UVWXYZ".utf8)
        stdout.withUnsafeBytes { output.append($0) }
        stderr.withUnsafeBytes { output.append($0) }
        XCTAssertEqual(output.text(), "abc\n[output truncated]")
        XCTAssertEqual(Shell.reconciliationOutcome(timedOut: true, commandClass: .reversibleMutation, reconcile: { false }), .failed)
        XCTAssertEqual(Shell.reconciliationOutcome(timedOut: true, commandClass: .reversibleMutation, reconcile: { true }), .passed)
        XCTAssertEqual(Shell.reconciliationOutcome(timedOut: false, commandClass: .reversibleMutation, reconcile: { false }), .notRequired)
    }

    @MainActor
    func testHeartbeatTerminationInvalidatesDetachedSnapshotBeforeRollbackPublishes() async {
        let refreshStarted = DispatchSemaphore(value: 0)
        let releaseRefresh = DispatchSemaphore(value: 0)
        let stale = makeSnapshot(source: .ac, sleepDisabled: true, sleepDisabledVerified: true)
        let refreshCalls = LockedBox(0)
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in
                let call = refreshCalls.withValue { value -> Int in
                    value += 1
                    return value
                }
                guard call == 1 else { return .empty }
                refreshStarted.signal()
                _ = releaseRefresh.wait(timeout: .now() + 1)
                return stale
            },
            sideEffects: .fixture,
            safeRollbackWaiter: { .empty }
        )
        controller.refresh()
        XCTAssertEqual(refreshStarted.wait(timeout: .now() + 1), .success)
        controller.simulateHeartbeatEndForTesting(sessionID: UUID(), reason: "power-disconnected")
        releaseRefresh.signal()
        for _ in 0..<200 where controller.isBusy || controller.isChecking {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(controller.snapshot, .empty)
        XCTAssertEqual(refreshCalls.value, 2)
    }

    func testV5RawXPCReleaseValidationRequiresImmutableCandidateAndRejectsWatchPaths() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let release = try String(contentsOf: root.appendingPathComponent("script/release.env"), encoding: .utf8)
        let bundleValidator = try String(contentsOf: root.appendingPathComponent("script/validate_bundle.sh"), encoding: .utf8)
        let liveValidator = try String(contentsOf: root.appendingPathComponent("script/validate_live_state.sh"), encoding: .utf8)

        XCTAssertTrue(release.contains("LIDSWITCH_HELPER_VERSION=\"5\""))
        XCTAssertTrue(bundleValidator.contains("immutable-candidate-required"))
        XCTAssertTrue(bundleValidator.contains("legacy-validator-retired"))
        XCTAssertTrue(bundleValidator.contains("exit 65"))
        XCTAssertTrue(release.contains("/Current/enrollment-policy"))
        XCTAssertTrue(liveValidator.contains("Print :MachServices:$MACH_SERVICE"))
    }

    func testStrictNativeNumberParsingRejectsBooleanFractionalAndOutOfDomainValues() {
        XCTAssertEqual(PowerInspector.strictBool(NSNumber(value: false)), false)
        XCTAssertEqual(PowerInspector.strictBool(NSNumber(value: true)), true)
        XCTAssertNil(PowerInspector.strictBool(NSNumber(value: 0)))
        XCTAssertNil(PowerInspector.strictBool(NSNumber(value: 1)))
        XCTAssertNil(PowerInspector.strictBool(NSNumber(value: 2)))
        XCTAssertNil(PowerInspector.strictBool(NSNumber(value: 0.5)))
        XCTAssertEqual(PowerInspector.strictInt(NSNumber(value: 7)), 7)
        XCTAssertNil(PowerInspector.strictInt(NSNumber(value: true)))
        XCTAssertNil(PowerInspector.strictInt(NSNumber(value: 0.5)))
        XCTAssertNil(PowerInspector.strictInt(NSNumber(value: -1)))
        XCTAssertNil(PowerInspector.strictInt(NSNumber(value: Double(Int.max))))
        XCTAssertNil(PowerInspector.strictInt(NSNumber(value: Double(Int32.max) + 1)))
    }

    func testNativeBatteryParserSelectsAndAggregatesOnlyValidInternalBatteries() {
        let descriptions: [[String: Any]] = [
            [kIOPSTypeKey: "UPS", kIOPSCurrentCapacityKey: 100, kIOPSMaxCapacityKey: 100],
            [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 20, kIOPSMaxCapacityKey: 40],
            [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 30, kIOPSMaxCapacityKey: 60],
            [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 101, kIOPSMaxCapacityKey: 100],
        ]

        XCTAssertEqual(PowerInspector.internalBatteryPercent(from: descriptions), 50)
        XCTAssertNil(PowerInspector.internalBatteryPercent(from: []))
        XCTAssertNil(PowerInspector.internalBatteryPercent(from: [[
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSCurrentCapacityKey: Double.greatestFiniteMagnitude,
            kIOPSMaxCapacityKey: Double.greatestFiniteMagnitude,
        ], [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSCurrentCapacityKey: Double.greatestFiniteMagnitude,
            kIOPSMaxCapacityKey: Double.greatestFiniteMagnitude,
        ]]))
    }

    @MainActor
    func testActiveRefreshCannotTerminateSessionFromUnreadableInspection() async {
        let unreadable = makeSnapshot(
            source: .unknown("inspection unavailable"),
            sleepDisabled: false,
            sleepDisabledVerified: false,
            lease: nil,
            status: nil
        )
        let controller = PowerController(bootstrap: false, snapshotProvider: { _ in unreadable }, sideEffects: .fixture)
        controller.simulateNewSessionForTesting(UUID())

        controller.refresh()
        await waitForRefresh(controller)

        XCTAssertTrue(controller.requiresTerminationCleanup)
        XCTAssertEqual(controller.snapshot, unreadable)
    }

    @MainActor
    func testNativeConfirmationPresenterMapsConfirmedActionsExactlyOnce() {
        var actions: [NativeConfirmationAction] = []
        let presenter = NativeConfirmationPresenter(responseProvider: { _ in .confirm })

        for action in NativeConfirmationAction.allCases {
            XCTAssertTrue(presenter.present(action) { actions.append(action) })
        }

        XCTAssertEqual(actions, [.startSession, .removeHelper, .quit])
        XCTAssertEqual(NativeConfirmationAction.startSession.confirmTitle, "Start and Verify")
        XCTAssertTrue(NativeConfirmationAction.removeHelper.isDestructive)
        XCTAssertTrue(NativeConfirmationAction.allCases.allSatisfy(\.confirmsWithReturn))
        XCTAssertTrue(NativeConfirmationAction.allCases.allSatisfy(\.cancelsWithEscape))
    }

    @MainActor
    func testNativeConfirmationPresenterIgnoresCancelAndNestedDuplicatePresentation() {
        var presenter: NativeConfirmationPresenter!
        var actions: [NativeConfirmationAction] = []
        presenter = NativeConfirmationPresenter(responseProvider: { action in
            if action == .startSession {
                XCTAssertFalse(presenter.present(.quit) { actions.append(.quit) })
            }
            return .cancel
        })

        for action in NativeConfirmationAction.allCases {
            XCTAssertTrue(presenter.present(action) { actions.append(action) })
        }
        XCTAssertTrue(actions.isEmpty)
    }

    @MainActor
    func testControllerStartingStatePublishesBeforeFreshPreconditionFailure() {
        let snapshotCalls = LockedBox(0)
        let controller = PowerController(bootstrap: false, snapshotProvider: { _ in
            snapshotCalls.withValue { $0 += 1 }
            return .empty
        }, sideEffects: .fixture)

        controller.startSession()
        XCTAssertTrue(controller.isStarting)
        XCTAssertTrue(controller.isBusy)
        XCTAssertTrue(controller.isChecking)
        controller.startSession() // duplicate click cannot enqueue a second request
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(snapshotCalls.value, 1)
        XCTAssertFalse(controller.isStarting)
        XCTAssertFalse(controller.isBusy)
        XCTAssertTrue(controller.errorMessage?.contains("Session did not start.") == true)
        XCTAssertTrue(controller.errorMessage?.contains("Protection remains off.") == true)
    }

    @MainActor
    func testControllerInvalidatedStartRequestCannotCommitStalePreflight() {
        let snapshotCalls = LockedBox(0)
        let controller = PowerController(bootstrap: false, snapshotProvider: { _ in
            snapshotCalls.withValue { $0 += 1 }
            return .empty
        }, sideEffects: .fixture)

        controller.startSession()
        controller.invalidateStartRequestForTesting()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertLessThanOrEqual(snapshotCalls.value, 1)
        XCTAssertFalse(controller.isStarting)
        XCTAssertFalse(controller.isBusy)
    }

    @MainActor
    func testForcedRefreshCompletionSurvivesBackgroundThenTimerSupersession() {
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let calls = LockedBox(0)
        let provider: @Sendable (UUID?) -> PowerSnapshot = { _ in
            let call = calls.withValue { value -> Int in
                value += 1
                return value
            }
            if call == 1 {
                firstStarted.signal()
                _ = releaseFirst.wait(timeout: .now() + 1)
            }
            return .empty
        }
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: provider,
            forceFreshSnapshotProvider: provider,
            sideEffects: .fixture
        )

        controller.refresh() // gen 1 background, held off-main
        XCTAssertEqual(firstStarted.wait(timeout: .now() + 1), .success)
        controller.requestStartRefreshForTesting(UUID()) // gen 2 force
        controller.refresh() // gen 3 timer/power background; must carry gen-2 completion
        releaseFirst.signal()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(calls.value, 2)
        XCTAssertFalse(controller.refreshCompletionOutstandingForTesting)
        XCTAssertFalse(controller.isChecking)
    }

    @MainActor
    func testActiveForcedPurposeSurvivesCoalescedTimerRefreshWithoutPublishingStaleResult() async {
        let forceStarted = DispatchSemaphore(value: 0)
        let releaseForce = DispatchSemaphore(value: 0)
        let rerunStarted = DispatchSemaphore(value: 0)
        let releaseRerun = DispatchSemaphore(value: 0)
        let calls = LockedBox(0)
        let staleStartable = makeSnapshot(source: .ac, sleepDisabled: false, sleepDisabledVerified: true)
        let provider: @Sendable (UUID?) -> PowerSnapshot = { _ in
            let call = calls.withValue { value -> Int in
                value += 1
                return value
            }
            if call == 1 {
                forceStarted.signal()
                _ = releaseForce.wait(timeout: .now() + 1)
            } else if call == 2 {
                rerunStarted.signal()
                _ = releaseRerun.wait(timeout: .now() + 1)
            }
            return call == 1 ? staleStartable : .empty
        }
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: provider,
            forceFreshSnapshotProvider: provider,
            sideEffects: .fixture
        )

        // This directly exercises the Start-class force-fresh purpose without
        // calling startSession(), so even a scheduler regression cannot write a
        // lease, invoke the helper, or alter the user-owned live power session.
        controller.requestStartRefreshForTesting(UUID())
        XCTAssertEqual(forceStarted.wait(timeout: .now() + 1), .success)
        controller.refresh() // newer native truth invalidates result 1 and carries the purpose into result 2
        controller.refresh()
        controller.refresh()
        releaseForce.signal()
        let rerunResult = await waitForSemaphore(rerunStarted, timeout: .seconds(1))
        XCTAssertEqual(rerunResult, .success)

        // The first AC/startable result must neither publish nor authorize the
        // carried completion while the only valid rerun is still blocked.
        XCTAssertEqual(controller.snapshot, .empty)
        XCTAssertTrue(controller.isChecking)
        releaseRerun.signal()
        await waitForRefresh(controller)

        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(controller.snapshot, .empty)
        XCTAssertFalse(controller.refreshCompletionOutstandingForTesting)
        XCTAssertFalse(controller.isChecking)
    }

    @MainActor
    func testInitialCheckingMenuBarSymbolDoesNotClaimCriticalEmptySnapshot() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let controller = PowerController(bootstrap: false, snapshotProvider: { _ in
            started.signal()
            _ = release.wait(timeout: .now() + 1)
            return .empty
        }, sideEffects: .fixture)
        controller.refresh()
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(controller.menuBarSymbol, "arrow.triangle.2.circlepath")
        release.signal()
    }

    @MainActor
    func testCoalescedStartRefreshIssuesExactlyOneFixtureLeaseForItsCurrentRequest() async {
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let rerunStarted = DispatchSemaphore(value: 0)
        let releaseRerun = DispatchSemaphore(value: 0)
        let calls = LockedBox(0)
        let issuedLeases = LockedBox(0)
        let startable = makeSnapshot(source: .ac, sleepDisabled: false, sleepDisabledVerified: true)
        let provider: @Sendable (UUID?) -> PowerSnapshot = { _ in
            let call = calls.withValue { value -> Int in
                value += 1
                return value
            }
            if call == 1 {
                firstStarted.signal()
                _ = releaseFirst.wait(timeout: .now() + 1)
            } else if call == 2 {
                rerunStarted.signal()
                _ = releaseRerun.wait(timeout: .now() + 1)
            }
            return startable
        }
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: provider,
            forceFreshSnapshotProvider: provider,
            sideEffects: .recordingFixture { event in
                if event == "lease-issue" { issuedLeases.withValue { $0 += 1 } }
            }
        )

        controller.startSession()
        XCTAssertEqual(firstStarted.wait(timeout: .now() + 1), .success)
        controller.refresh() // carries the one current Start purpose into the rerun
        releaseFirst.signal()
        let rerunResult = await waitForSemaphore(rerunStarted, timeout: .seconds(1))
        XCTAssertEqual(rerunResult, .success)
        releaseRerun.signal()
        await waitForRefresh(controller)

        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(issuedLeases.value, 1)
    }

    @MainActor
    func testCancelledStartRefreshIssuesNoFixtureLeaseAfterStaleCompletion() async {
        let preflightStarted = DispatchSemaphore(value: 0)
        let releasePreflight = DispatchSemaphore(value: 0)
        let issuedLeases = LockedBox(0)
        let safe = makeSnapshot(source: .ac, sleepDisabled: false, sleepDisabledVerified: true)
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in
                preflightStarted.signal()
                _ = releasePreflight.wait(timeout: .now() + 1)
                return safe
            },
            sideEffects: .recordingFixture { event in
                if event == "lease-issue" { issuedLeases.withValue { $0 += 1 } }
            },
            safeRollbackWaiter: { safe }
        )

        controller.startSession()
        XCTAssertEqual(preflightStarted.wait(timeout: .now() + 1), .success)
        controller.cancelPendingStart()
        releasePreflight.signal()
        for _ in 0..<200 where controller.isBusy {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(issuedLeases.value, 0)
        XCTAssertFalse(controller.isStarting)
        XCTAssertFalse(controller.isBusy)
    }

    @MainActor
    func testCancelPendingStartInvalidatesStalePreflightAndRestoresTruthfulIdleState() async {
        let preflightStarted = DispatchSemaphore(value: 0)
        let releasePreflight = DispatchSemaphore(value: 0)
        let announcements = LockedBox([String]())
        let safe = makeSnapshot(
            source: .ac, sleepDisabled: false, sleepDisabledVerified: true, lease: nil,
            status: HelperStatusRecord(state: "inactive", reason: "verified", sessionID: nil, updatedAt: Date())
        )
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in
                preflightStarted.signal()
                _ = releasePreflight.wait(timeout: .now() + 1)
                return safe
            },
            sideEffects: .fixture,
            safeRollbackWaiter: { safe },
            announcementHandler: { message in announcements.withValue { $0.append(message) } }
        )

        controller.startSession()
        XCTAssertEqual(preflightStarted.wait(timeout: .now() + 1), .success)
        controller.cancelPendingStart()
        releasePreflight.signal()
        for _ in 0..<200 where controller.isBusy {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertFalse(controller.isStarting)
        XCTAssertFalse(controller.isBusy)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.snapshot, safe)
        XCTAssertTrue(announcements.value.contains("Session canceled. Protection off. System sleep restored."))
    }

    @MainActor
    func testFixtureControllerUsesOnlyInjectedSideEffects() async {
        let effects = LockedBox([String]())
        let safe = makeSnapshot(source: .ac, sleepDisabled: false, sleepDisabledVerified: true, lease: nil, status: nil)
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in safe },
            sideEffects: .recordingFixture { event in effects.withValue { $0.append(event) } },
            safeRollbackWaiter: { safe }
        )

        controller.startSession()
        await waitForRefresh(controller)
        controller.cancelPendingStart()
        for _ in 0..<200 where controller.isBusy {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(
            effects.value,
            ["desired-state-disabled", "lease-issue", "activity-begin", "heartbeat", "lease-revoke", "activity-end"]
        )
        XCTAssertFalse(controller.isBusy)
        XCTAssertFalse(controller.isStarting)
    }

    @MainActor
    func testIdleQuitSkipsAdministratorRestoreAfterTerminalMigrationAgesOut() async throws {
        let events = LockedBox([String]())
        let waits = LockedBox(0)
        let now = Date()
        let status = HelperStatusRecord(
            state: "terminal",
            reason: "legacy-migration",
            sessionID: UUID(),
            updatedAt: now.addingTimeInterval(-60),
            bootID: BootIdentity.current() ?? "test-boot",
            updatedMonotonic: max(0, MonotonicClock.seconds() - 60)
        )
        let idle = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true,
            lease: nil,
            status: status,
            checkedAt: now
        )
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in idle },
            sideEffects: .recordingFixture(
                { event in events.withValue { $0.append(event) } },
                administratorResult: { operation in
                    .completionIndeterminate(
                        transactionID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
                        operation: operation,
                        reason: "administrator-wait-timed-out"
                    )
                }
            ),
            safeRollbackWaiter: {
                waits.withValue { $0 += 1 }
                return idle
            }
        )

        controller.refresh()
        await waitForRefresh(controller)
        XCTAssertEqual(controller.displayedStatus.title, "Ready for monitored session")
        XCTAssertFalse(try XCTUnwrap(controller.snapshot.helperStatus).isFresh(at: now))
        XCTAssertFalse(controller.requiresTerminationCleanup)

        controller.quitSafely()

        XCTAssertEqual(waits.value, 0)
        XCTAssertEqual(events.value.filter { $0 == "restore-sleep" }.count, 0)
        XCTAssertEqual(events.value.filter { $0 == "terminate" }, ["terminate"])
        XCTAssertTrue(controller.consumeAuthorizedTermination())
        XCTAssertFalse(controller.consumeAuthorizedTermination())
        XCTAssertNil(controller.errorMessage)
    }

    @MainActor
    func testQuitFallsBackToOneAdministratorRestoreAndTerminatesOnlyAfterSafeIdle() async {
        let events = LockedBox([String]())
        let waits = LockedBox(0)
        let unsafe = makeSnapshot(source: .ac, sleepDisabled: true, sleepDisabledVerified: true)
        let safe = makeSnapshot(
            source: .ac, sleepDisabled: false, sleepDisabledVerified: true,
            status: HelperStatusRecord(state: "inactive", reason: "verified", sessionID: nil, updatedAt: Date())
        )
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in unsafe },
            inventoryInvalidator: { events.withValue { $0.append("inventory-invalidated") } },
            sideEffects: .recordingFixture { event in
                events.withValue { $0.append(event) }
            },
            safeRollbackWaiter: {
                waits.withValue { count in
                    count += 1
                    return count == 1 ? unsafe : safe
                }
            }
        )

        controller.refresh()
        await waitForRefresh(controller)
        XCTAssertTrue(controller.requiresTerminationCleanup)

        controller.quitSafely()
        for _ in 0..<200 where controller.isBusy {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let recorded = events.value
        XCTAssertEqual(recorded.filter { $0 == "restore-sleep" }.count, 1)
        guard let restore = recorded.firstIndex(of: "restore-sleep"),
              let terminate = recorded.firstIndex(of: "terminate") else {
            return XCTFail("restore and termination events were not both recorded")
        }
        XCTAssertLessThan(restore, terminate)
        XCTAssertGreaterThanOrEqual(recorded.filter { $0 == "inventory-invalidated" }.count, 1)
        XCTAssertEqual(waits.value, 2)
        XCTAssertTrue(controller.consumeAuthorizedTermination())
    }

    @MainActor
    func testQuitNeverTerminatesOnRecoveryRequiredAdministratorReceipt() async {
        let events = LockedBox([String]())
        let transaction = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let required = AdministratorOperationResult.recoveryRequired(.init(
            transactionID: transaction,
            operation: .userRestore,
            state: .terminal,
            outcome: .recoveryRequired,
            sessionID: nil,
            reason: "restore-unverified"
        ))
        let unsafe = makeSnapshot(source: .ac, sleepDisabled: true, sleepDisabledVerified: true)
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in unsafe },
            sideEffects: .recordingFixture(
                { event in events.withValue { $0.append(event) } },
                administratorResult: { _ in required }
            ),
            safeRollbackWaiter: { unsafe }
        )

        controller.refresh()
        await waitForRefresh(controller)
        XCTAssertTrue(controller.requiresTerminationCleanup)

        controller.quitSafely()
        for _ in 0..<200 where controller.isBusy {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(events.value.filter { $0 == "restore-sleep" }.count, 1)
        XCTAssertFalse(events.value.contains("terminate"))
        XCTAssertFalse(controller.consumeAuthorizedTermination())
        XCTAssertNotNil(controller.errorMessage)
    }

    @MainActor
    func testProductionSideEffectsFailClosedForInjectedXCTestDetector() throws {
        let executable = ProcessInfo.processInfo.arguments.first ?? ""
        guard PowerControllerSideEffects.isXCTestRuntimeForTesting(
            executable: executable,
            environment: ProcessInfo.processInfo.environment
        ) else {
            XCTFail("refusing to construct production side effects outside XCTest")
            return
        }
        let sideEffects = PowerControllerSideEffects.production()
        let sessionID = UUID()
        let expected = PowerControllerSideEffectError.productionMutationBlockedInTest
        XCTAssertThrowsError(try sideEffects.writeDesiredStateDisabled()) { XCTAssertEqual($0 as? PowerControllerSideEffectError, expected) }
        XCTAssertThrowsError(try sideEffects.issueLease(sessionID)) { XCTAssertEqual($0 as? PowerControllerSideEffectError, expected) }
        XCTAssertThrowsError(try sideEffects.revokeLease()) { XCTAssertEqual($0 as? PowerControllerSideEffectError, expected) }
        XCTAssertThrowsError(try sideEffects.prepareHelper()) { XCTAssertEqual($0 as? PowerControllerSideEffectError, expected) }
        XCTAssertThrowsError(try sideEffects.restoreSleep()) { XCTAssertEqual($0 as? PowerControllerSideEffectError, expected) }
        XCTAssertThrowsError(try sideEffects.uninstallHelper()) { XCTAssertEqual($0 as? PowerControllerSideEffectError, expected) }
        XCTAssertTrue(PowerControllerSideEffects.isXCTestRuntimeForTesting(executable: "/tmp/LidSwitchTests.xctest/Contents/MacOS/LidSwitchTests", environment: [:]))
        XCTAssertTrue(PowerControllerSideEffects.isXCTestRuntimeForTesting(executable: "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest", environment: [:]))
        XCTAssertTrue(PowerControllerSideEffects.isXCTestRuntimeForTesting(executable: "/tmp/test-host", environment: ["XCTestConfigurationFilePath": "/tmp/config"]))
        XCTAssertFalse(PowerControllerSideEffects.isXCTestRuntimeForTesting(executable: "/Applications/LidSwitch.app/Contents/MacOS/LidSwitch", environment: [:]))
        XCTAssertThrowsError(
            try PowerControllerSideEffects.guardedHeartbeatRenewalForTesting(
                testRuntimeDetector: { true },
                renew: { XCTFail("blocked heartbeat renewal invoked its operation"); return 0 }
            )
        ) { XCTAssertEqual($0 as? PowerControllerSideEffectError, expected) }
        XCTAssertFalse(PowerControllerSideEffects.guardedHeartbeatRevocationForTesting(
            testRuntimeDetector: { true },
            revoke: { XCTFail("blocked heartbeat revocation invoked its operation") }
        ))
        XCTAssertEqual(
            try PowerControllerSideEffects.guardedHeartbeatRenewalForTesting(
                testRuntimeDetector: { false },
                renew: { 42 }
            ),
            42
        )
        XCTAssertTrue(PowerControllerSideEffects.guardedHeartbeatRevocationForTesting(
            testRuntimeDetector: { false },
            revoke: {}
        ))
        XCTAssertNil(sideEffects.makeHeartbeat(sessionID, { _ in }, { _, _ in }, { true }))
        let activity = sideEffects.beginActivity()
        sideEffects.endActivity(activity)
        sideEffects.terminateApplication()
    }

    @MainActor
    func testHeartbeatEndWaitsForSafeRollbackAndClearsTransientRecoveryAlert() async {
        let waiterEntered = DispatchSemaphore(value: 0)
        let releaseWaiter = DispatchSemaphore(value: 0)
        let checkedAt = Date()
        let safe = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true,
            lease: nil,
            status: HelperStatusRecord(
                state: "inactive",
                reason: "verified",
                sessionID: nil,
                updatedAt: checkedAt
            ),
            checkedAt: checkedAt
        )
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in .empty },
            sideEffects: .fixture,
            safeRollbackWaiter: {
                waiterEntered.signal()
                releaseWaiter.wait()
                return safe
            }
        )
        controller.simulateHeartbeatEndForTesting(sessionID: UUID(), reason: "helper-recovery-required-override-lost-restore-pending")
        await waitForSemaphore(waiterEntered)
        XCTAssertTrue(controller.isBusy)
        XCTAssertNil(controller.errorMessage)
        releaseWaiter.signal()
        for _ in 0..<200 where controller.isBusy {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertFalse(controller.isBusy)
        XCTAssertNil(controller.errorMessage)
        XCTAssertTrue(controller.snapshot.sleepDisabledVerified)
        XCTAssertFalse(controller.snapshot.sleepDisabled)
        XCTAssertFalse(controller.snapshot.helperRecoveryRequired)
    }

    @MainActor
    func testHeartbeatEndRetainsRecoveryAlertWhenBoundedRollbackVerificationFails() async {
        let waiterEntered = DispatchSemaphore(value: 0)
        let releaseWaiter = DispatchSemaphore(value: 0)
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in .empty },
            sideEffects: .fixture,
            safeRollbackWaiter: {
                waiterEntered.signal()
                releaseWaiter.wait()
                return .empty
            }
        )

        controller.simulateHeartbeatEndForTesting(sessionID: UUID(), reason: "helper-recovery-required-override-lost-restore-pending")
        await waitForSemaphore(waiterEntered)
        XCTAssertTrue(controller.isBusy)
        XCTAssertNil(controller.errorMessage)
        releaseWaiter.signal()
        for _ in 0..<200 where controller.isBusy {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertFalse(controller.isBusy)
        XCTAssertTrue(
            controller.errorMessage?.contains("could not verify a complete rollback") == true,
            "unexpected error: \(controller.errorMessage ?? "nil")"
        )
    }

    @MainActor
    func testAuthoritativeSafeRefreshClearsOnlyProvenancedRollbackFailureAndAnnouncesOnce() async {
        let safe = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true,
            lease: nil,
            status: HelperStatusRecord(state: "inactive", reason: "verified", sessionID: nil, updatedAt: Date())
        )
        let current = LockedBox(safe)
        let announcements = LockedBox([String]())
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in current.value },
            sideEffects: .fixture,
            safeRollbackWaiter: { .empty },
            announcementHandler: { message in announcements.withValue { $0.append(message) } }
        )

        controller.simulateHeartbeatEndForTesting(sessionID: UUID(), reason: "rollback-timeout")
        for _ in 0..<200 where controller.isBusy || controller.isChecking {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertNil(controller.alert)
        XCTAssertEqual(controller.snapshot, safe)
        XCTAssertEqual(
            announcements.value.filter { $0 == "System sleep restored. Protection off." },
            ["System sleep restored. Protection off."]
        )

        controller.refresh()
        await waitForRefresh(controller)
        XCTAssertEqual(
            announcements.value.filter { $0 == "System sleep restored. Protection off." }.count,
            1
        )
    }

    @MainActor
    func testAuthoritativeUnsafeAndUnreadableRefreshRetainRollbackFailure() async {
        let recoveryRequired = HelperStatusRecord(
            state: "recovery-required",
            reason: "restore-unverified",
            sessionID: nil,
            updatedAt: Date()
        )
        let current = LockedBox(makeSnapshot(
            source: .ac,
            sleepDisabled: true,
            sleepDisabledVerified: true,
            lease: nil,
            status: recoveryRequired
        ))
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in current.value },
            sideEffects: .fixture,
            safeRollbackWaiter: { .empty }
        )

        controller.simulateHeartbeatEndForTesting(sessionID: UUID(), reason: "rollback-timeout")
        for _ in 0..<200 where controller.isBusy {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let recoveryAlert = PowerControllerAlert.rollbackVerificationFailure(reason: "rollback-timeout")
        XCTAssertEqual(controller.alert, recoveryAlert)
        controller.refresh()
        await waitForRefresh(controller)
        XCTAssertEqual(controller.alert, recoveryAlert)
        XCTAssertTrue(controller.snapshot.restoreRequired)

        current.value = .empty
        controller.refresh()
        await waitForRefresh(controller)
        XCTAssertEqual(controller.alert, recoveryAlert)
        XCTAssertFalse(controller.snapshot.sleepDisabledVerified)
        XCTAssertTrue(controller.snapshot.restoreRequired == false)
        XCTAssertTrue(controller.snapshot.hasCriticalSafetyIssue)
    }

    @MainActor
    func testAuthoritativeSafeRefreshDoesNotClearUnrelatedOperationFailure() async throws {
        let safe = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true,
            lease: nil,
            status: nil
        )
        let current = LockedBox(PowerSnapshot.empty)
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in current.value },
            sideEffects: .fixture
        )

        controller.startSession()
        for _ in 0..<200 where controller.isBusy {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let operationAlert = try XCTUnwrap(controller.alert)
        guard case .operationFailure = operationAlert else {
            return XCTFail("expected unrelated operation failure, got \(operationAlert)")
        }

        current.value = safe
        controller.refresh()

        XCTAssertEqual(controller.alert, operationAlert)
        XCTAssertEqual(controller.errorMessage, operationAlert.message)
    }

    @MainActor
    func testStaleRollbackWaiterCannotDisturbNewSession() async {
        let waiterEntered = DispatchSemaphore(value: 0)
        let releaseWaiter = DispatchSemaphore(value: 0)
        let safe = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true,
            lease: nil,
            status: nil
        )
        let controller = PowerController(
            bootstrap: false,
            snapshotProvider: { _ in .empty },
            sideEffects: .fixture,
            safeRollbackWaiter: {
                waiterEntered.signal()
                releaseWaiter.wait()
                return safe
            }
        )

        controller.simulateHeartbeatEndForTesting(sessionID: UUID(), reason: "rollback-timeout")
        await waitForSemaphore(waiterEntered)
        let newSessionID = UUID()
        controller.simulateNewSessionForTesting(newSessionID)
        releaseWaiter.signal()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(controller.isBusy)
        XCTAssertNil(controller.alert)
        XCTAssertEqual(controller.snapshot, .empty)
    }

    @MainActor
    func testFreshControllerRefreshDerivesTruthfulSafeAndUnsafeStateWithoutCachedAlert() async {
        let safe = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true,
            lease: nil,
            status: nil
        )
        let recoveryRequired = HelperStatusRecord(
            state: "recovery-required",
            reason: "restore-unverified",
            sessionID: nil,
            updatedAt: Date()
        )
        let unsafe = makeSnapshot(
            source: .ac,
            sleepDisabled: true,
            sleepDisabledVerified: true,
            lease: nil,
            status: recoveryRequired
        )
        let current = LockedBox(safe)
        let controller = PowerController(bootstrap: false, snapshotProvider: { _ in current.value }, sideEffects: .fixture)

        controller.refresh()
        await waitForRefresh(controller)
        XCTAssertNil(controller.alert)
        XCTAssertEqual(controller.snapshot.statusTitle, "Ready for monitored session")

        current.value = unsafe
        controller.refresh()
        await waitForRefresh(controller)
        XCTAssertNil(controller.alert)
        XCTAssertTrue(controller.snapshot.restoreRequired)
        XCTAssertEqual(controller.snapshot.statusTitle, "Recovery required")
    }

    func testHelperRollbackVerificationTimeoutHasSafetyMarginWithinAcceptanceLimit() {
        XCTAssertEqual(PowerController.helperRollbackVerificationTimeoutForTesting, 30)
        XCTAssertGreaterThan(PowerController.helperRollbackVerificationTimeoutForTesting, 18.4)
        XCTAssertLessThanOrEqual(PowerController.helperRollbackVerificationTimeoutForTesting, 45)
    }

    func testExternalHDMIClamshellDoesNotChangePluggedInStartEligibility() {
        // Display topology is intentionally absent from the safety contract:
        // a single external HDMI display must not change an AC helper/session check.
        let now = Date()
        let snapshot = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true,
            lease: nil,
            status: nil,
            checkedAt: now
        )

        XCTAssertTrue(snapshot.source.isAC)
        XCTAssertTrue(snapshot.canStartSession)
    }

    func testHeartbeatRenewsFourTimesDuringFortySecondInspectionDelay() throws {
        let root = try temporaryDirectory()
        let sessionID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let clock = LockedBox(startedAt)
        let monotonic = LockedBox<TimeInterval>(0)
        let renewals = LockedBox([Date]())
        let acknowledgements = LockedBox(0)
        let diagnostics = SessionDiagnosticStore(file: root.appendingPathComponent("history.json"))
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 3_600,
            renewalInterval: 8,
            acknowledgementTimeout: 20,
            now: { clock.value },
            monotonicNow: { monotonic.value },
            observe: { _ in
                let current = clock.value
                return SessionHeartbeatObservation(
                    power: .ac,
                    leaseIsValid: true,
                    helperStatus: HelperStatusRecord(
                        state: "active", reason: "verified", sessionID: sessionID, updatedAt: current
                    )
                )
            },
            renew: { _, commitGuard in
                guard commitGuard() else { throw TestError.commitRejected }
                renewals.withValue { $0.append(clock.value) }
                return monotonic.value + 30
            },
            revoke: {},
            diagnostics: diagnostics,
            onAcknowledged: { _ in acknowledgements.withValue { $0 += 1 } },
            onEnded: { _, _ in }
        )
        coordinator.start(sessionID: sessionID, initialLeaseExpiresMonotonic: 30)
        defer { coordinator.stop(reason: "test-complete") }

        coordinator.evaluateForTesting()
        for second in [8, 16, 24, 32, 40] {
            clock.value = startedAt.addingTimeInterval(TimeInterval(second))
            monotonic.value = TimeInterval(second)
            coordinator.evaluateForTesting()
        }

        XCTAssertGreaterThanOrEqual(renewals.value.count, 4)
        XCTAssertEqual(renewals.value.map { Int($0.timeIntervalSince(startedAt)) }, [8, 16, 24, 32, 40])
        XCTAssertEqual(acknowledgements.value, 1)
        XCTAssertTrue(diagnostics.entries().contains { $0.event == "acknowledged" })
    }

    func testHeartbeatAcknowledgementJustOutsideTimeoutFailsClosed() throws {
        let root = try temporaryDirectory()
        let sessionID = UUID()
        let startedAt = Date(timeIntervalSince1970: 2_000)
        let clock = LockedBox(startedAt)
        let monotonic = LockedBox<TimeInterval>(0)
        let revoked = LockedBox(0)
        let endedReason = LockedBox<String?>(nil)
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 3_600,
            renewalInterval: 8,
            acknowledgementTimeout: 20,
            now: { clock.value },
            monotonicNow: { monotonic.value },
            observe: { _ in SessionHeartbeatObservation(power: .ac, leaseIsValid: true, helperStatus: nil) },
            renew: { _, commitGuard in
                guard commitGuard() else { throw TestError.commitRejected }
                return monotonic.value + 30
            },
            revoke: { revoked.withValue { $0 += 1 } },
            diagnostics: SessionDiagnosticStore(file: root.appendingPathComponent("history.json")),
            onAcknowledged: { _ in },
            onEnded: { _, reason in endedReason.value = reason }
        )
        coordinator.start(sessionID: sessionID, initialLeaseExpiresMonotonic: 30)
        clock.value = startedAt.addingTimeInterval(20)
        monotonic.value = 20
        coordinator.evaluateForTesting()

        XCTAssertEqual(revoked.value, 1)
        XCTAssertEqual(endedReason.value, "acknowledgement-timeout")
    }

    func testHeartbeatTerminalCleanupChoosesOneRemoteOperationAndPreservesReason() throws {
        let root = try temporaryDirectory()
        let sessionID = UUID()
        let remoteEnds = LockedBox([(UUID, String)]())
        let restores = LockedBox(0)
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 3_600,
            observe: { _ in SessionHeartbeatObservation(power: .disconnected, leaseIsValid: false, helperStatus: nil) },
            renew: { _, _ in 30 },
            revoke: { restores.withValue { $0 += 1 } },
            endRemote: { id, reason in remoteEnds.withValue { $0.append((id, reason)) } },
            diagnostics: SessionDiagnosticStore(file: root.appendingPathComponent("history.json")),
            onAcknowledged: { _ in }, onEnded: { _, _ in }
        )
        coordinator.start(sessionID: sessionID, initialLeaseExpiresMonotonic: 30)
        coordinator.evaluateForTesting()
        coordinator.evaluateForTesting()
        XCTAssertEqual(restores.value, 1)
        XCTAssertTrue(remoteEnds.value.isEmpty)

        let userEnd = SessionHeartbeatCoordinator(
            observationInterval: 3_600,
            observe: { _ in SessionHeartbeatObservation(power: .ac, leaseIsValid: true, helperStatus: nil) },
            renew: { _, _ in 30 }, revoke: { restores.withValue { $0 += 100 } },
            endRemote: { id, reason in
                remoteEnds.withValue { $0.append((id, reason)) }
            },
            diagnostics: SessionDiagnosticStore(file: root.appendingPathComponent("history-user-end.json")),
            onAcknowledged: { _ in }, onEnded: { _, _ in }
        )
        userEnd.start(sessionID: sessionID, initialLeaseExpiresMonotonic: 30)
        userEnd.stop(reason: "user-end")
        XCTAssertEqual(remoteEnds.value.count, 1)
        XCTAssertEqual(remoteEnds.value.first?.0, sessionID)
        XCTAssertEqual(remoteEnds.value.first?.1, "user-end")
        XCTAssertEqual(restores.value, 1)
    }

    func testDiagnosticFilesystemWriterCannotBlockHeartbeatEventHandoff() throws {
        let root = try temporaryDirectory()
        let enteredWriter = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        let store = SessionDiagnosticStore(
            file: root.appendingPathComponent("history.json"),
            writeObserver: {
                enteredWriter.signal()
                _ = releaseWriter.wait(timeout: .now() + 1)
            }
        )
        store.record(event: "start", reason: "lease-issued", sessionID: UUID())
        XCTAssertEqual(enteredWriter.wait(timeout: .now() + 1), .success)
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            store.recordRenewal(reason: "safety-probes-valid", sessionID: UUID())
            returned.signal()
        }
        XCTAssertEqual(returned.wait(timeout: .now() + 0.1), .success)
        releaseWriter.signal()
    }

    func testHeartbeatAcknowledgementJustInsideTimeoutCanRenew() throws {
        let root = try temporaryDirectory()
        let sessionID = UUID()
        let base = Date(timeIntervalSince1970: 2_500)
        let clock = LockedBox(base)
        let monotonic = LockedBox<TimeInterval>(0)
        let status = LockedBox<HelperStatusRecord?>(nil)
        let acknowledged = LockedBox(0)
        let renewed = LockedBox(0)
        let revoked = LockedBox(0)
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 3_600,
            renewalInterval: 8,
            acknowledgementTimeout: 20,
            now: { clock.value },
            monotonicNow: { monotonic.value },
            observe: { _ in SessionHeartbeatObservation(power: .ac, leaseIsValid: true, helperStatus: status.value) },
            renew: { _, commitGuard in
                guard commitGuard() else { throw TestError.commitRejected }
                renewed.withValue { $0 += 1 }
                return monotonic.value + 30
            },
            revoke: { revoked.withValue { $0 += 1 } },
            diagnostics: SessionDiagnosticStore(file: root.appendingPathComponent("history.json")),
            onAcknowledged: { _ in acknowledged.withValue { $0 += 1 } },
            onEnded: { _, _ in }
        )
        coordinator.start(sessionID: sessionID, initialLeaseExpiresMonotonic: 30)
        monotonic.value = 8
        clock.value = base.addingTimeInterval(8)
        coordinator.evaluateForTesting()
        XCTAssertEqual(renewed.value, 0)
        XCTAssertEqual(revoked.value, 0)

        monotonic.value = 19.9
        clock.value = base.addingTimeInterval(19.9)
        status.value = HelperStatusRecord(
            state: "active", reason: "verified", sessionID: sessionID, updatedAt: clock.value
        )
        coordinator.evaluateForTesting()
        defer { coordinator.stop(reason: "test-complete") }

        XCTAssertEqual(acknowledged.value, 1)
        XCTAssertEqual(renewed.value, 1)
    }

    func testHeartbeatRecoveryAcknowledgementIsOncePerFreshStatusAndResetsForNewGeneration() throws {
        let root = try temporaryDirectory()
        let first = UUID()
        let second = UUID()
        let base = Date(timeIntervalSince1970: 2_600)
        let clock = LockedBox(base)
        let monotonic = LockedBox<TimeInterval>(0)
        let status = LockedBox(HelperStatusRecord(state: "active", reason: "verified", sessionID: first, updatedAt: base))
        let acknowledgements = LockedBox(0)
        let renewals = LockedBox(0)
        let diagnostics = SessionDiagnosticStore(file: root.appendingPathComponent("history.json"))
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 3_600,
            renewalInterval: 8,
            acknowledgementTimeout: 20,
            now: { clock.value },
            monotonicNow: { monotonic.value },
            observe: { _ in SessionHeartbeatObservation(power: .ac, leaseIsValid: true, helperStatus: status.value) },
            renew: { _, commitGuard in
                guard commitGuard() else { throw TestError.commitRejected }
                renewals.withValue { $0 += 1 }
                return monotonic.value + 30
            },
            revoke: {},
            diagnostics: diagnostics,
            onAcknowledged: { _ in acknowledgements.withValue { $0 += 1 } },
            onEnded: { _, _ in }
        )
        coordinator.start(sessionID: first, initialLeaseExpiresMonotonic: 30)
        coordinator.evaluateForTesting() // normal initial acknowledgement
        status.value = HelperStatusRecord(state: "active", reason: "override-recovered", sessionID: first, updatedAt: clock.value)
        coordinator.evaluateForTesting()
        coordinator.evaluateForTesting()
        XCTAssertEqual(acknowledgements.value, 2)
        XCTAssertEqual(diagnostics.entries().filter { $0.event == "recovered" }.count, 1)
        XCTAssertEqual(renewals.value, 0)

        monotonic.value = 8
        clock.value = base.addingTimeInterval(8)
        coordinator.evaluateForTesting()
        XCTAssertEqual(renewals.value, 1)

        coordinator.start(sessionID: second, initialLeaseExpiresMonotonic: 38)
        status.value = HelperStatusRecord(state: "active", reason: "verified", sessionID: second, updatedAt: clock.value)
        coordinator.evaluateForTesting()
        status.value = HelperStatusRecord(state: "active", reason: "override-recovered", sessionID: second, updatedAt: clock.value)
        coordinator.evaluateForTesting()
        XCTAssertEqual(diagnostics.entries().filter { $0.event == "recovered" }.count, 2)
        XCTAssertEqual(acknowledgements.value, 4)
    }

    func testCommitBoundaryTerminalTransitionCannotPublishFreshLease() throws {
        let root = try temporaryDirectory()
        let sessionID = UUID()
        let base = Date(timeIntervalSince1970: 2_750)
        let clock = LockedBox(base)
        let monotonic = LockedBox<TimeInterval>(0)
        let status = LockedBox(HelperStatusRecord(
            state: "active", reason: "verified", sessionID: sessionID, updatedAt: base
        ))
        let committed = LockedBox(0)
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 3_600,
            renewalInterval: 8,
            acknowledgementTimeout: 20,
            now: { clock.value },
            monotonicNow: { monotonic.value },
            observe: { _ in SessionHeartbeatObservation(power: .ac, leaseIsValid: true, helperStatus: status.value) },
            renew: { _, commitGuard in
                status.value = HelperStatusRecord(
                    state: "terminal",
                    reason: "override-lost",
                    sessionID: sessionID,
                    updatedAt: clock.value
                )
                guard commitGuard() else { throw TestError.commitRejected }
                committed.withValue { $0 += 1 }
                return monotonic.value + 30
            },
            revoke: {},
            diagnostics: SessionDiagnosticStore(file: root.appendingPathComponent("history.json")),
            onAcknowledged: { _ in },
            onEnded: { _, _ in }
        )
        coordinator.start(sessionID: sessionID, initialLeaseExpiresMonotonic: 30)
        coordinator.evaluateForTesting()
        monotonic.value = 8
        clock.value = base.addingTimeInterval(8)
        coordinator.evaluateForTesting()

        XCTAssertEqual(committed.value, 0)
    }

    func testHeartbeatRunsOffMainThreadWithoutRunLoopTimer() throws {
        let root = try temporaryDirectory()
        let sessionID = UUID()
        let renewedOffMain = LockedBox(false)
        let signal = DispatchSemaphore(value: 0)
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 0.005,
            renewalInterval: 0.01,
            acknowledgementTimeout: 1,
            observe: { _ in
                SessionHeartbeatObservation(
                    power: .ac,
                    leaseIsValid: true,
                    helperStatus: HelperStatusRecord(
                        state: "active",
                        reason: "verified",
                        sessionID: sessionID,
                        updatedAt: Date()
                    )
                )
            },
            renew: { _, commitGuard in
                guard commitGuard() else { throw TestError.commitRejected }
                renewedOffMain.value = !Thread.isMainThread
                signal.signal()
                return MonotonicClock.seconds() + 30
            },
            revoke: {},
            diagnostics: SessionDiagnosticStore(file: root.appendingPathComponent("history.json")),
            onAcknowledged: { _ in },
            onEnded: { _, _ in }
        )
        coordinator.start(
            sessionID: sessionID,
            initialLeaseExpiresMonotonic: MonotonicClock.seconds() + 30
        )
        XCTAssertEqual(signal.wait(timeout: .now() + 1), .success)
        coordinator.stop(reason: "test-complete")
        XCTAssertTrue(renewedOffMain.value)
    }

    func testObservedUnplugAndReconnectCannotRearmGeneration() throws {
        let root = try temporaryDirectory()
        let sessionID = UUID()
        let clock = LockedBox(Date(timeIntervalSince1970: 3_000))
        let monotonic = LockedBox<TimeInterval>(0)
        let power = LockedBox(SessionHeartbeatObservation.Power.ac)
        let renewals = LockedBox(0)
        let revocations = LockedBox(0)
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 3_600,
            renewalInterval: 8,
            acknowledgementTimeout: 20,
            now: { clock.value },
            monotonicNow: { monotonic.value },
            observe: { _ in
                SessionHeartbeatObservation(
                    power: power.value,
                    leaseIsValid: true,
                    helperStatus: HelperStatusRecord(
                        state: "active", reason: "verified", sessionID: sessionID, updatedAt: clock.value
                    )
                )
            },
            renew: { _, commitGuard in
                guard commitGuard() else { throw TestError.commitRejected }
                renewals.withValue { $0 += 1 }
                return monotonic.value + 30
            },
            revoke: { revocations.withValue { $0 += 1 } },
            diagnostics: SessionDiagnosticStore(file: root.appendingPathComponent("history.json")),
            onAcknowledged: { _ in },
            onEnded: { _, _ in }
        )
        coordinator.start(sessionID: sessionID, initialLeaseExpiresMonotonic: 30)
        coordinator.evaluateForTesting()
        power.value = .disconnected
        coordinator.evaluateForTesting()
        power.value = .ac
        clock.withValue { $0 = $0.addingTimeInterval(40) }
        monotonic.value = 40
        coordinator.evaluateForTesting()

        XCTAssertEqual(revocations.value, 1)
        XCTAssertEqual(renewals.value, 0)
    }

    func testNonterminalStatusMismatchStaysDiagnosticAndHeartbeatContinues() throws {
        for drift in ["override-lost", "lease-expired-or-invalid"] {
            let root = try temporaryDirectory()
            let sessionID = UUID()
            let clock = LockedBox(Date(timeIntervalSince1970: 4_000))
            let monotonic = LockedBox<TimeInterval>(0)
            let status = LockedBox(HelperStatusRecord(
                state: "active", reason: "verified", sessionID: sessionID, updatedAt: clock.value
            ))
            let renewals = LockedBox(0)
            let endedReason = LockedBox<String?>(nil)
            let coordinator = SessionHeartbeatCoordinator(
                observationInterval: 3_600,
                renewalInterval: 8,
                acknowledgementTimeout: 20,
                now: { clock.value },
                monotonicNow: { monotonic.value },
                observe: { _ in SessionHeartbeatObservation(power: .ac, leaseIsValid: true, helperStatus: status.value) },
                renew: { _, commitGuard in
                    guard commitGuard() else { throw TestError.commitRejected }
                    renewals.withValue { $0 += 1 }
                    return monotonic.value + 30
                },
                revoke: {},
                diagnostics: SessionDiagnosticStore(file: root.appendingPathComponent("history.json")),
                onAcknowledged: { _ in },
                onEnded: { _, reason in endedReason.value = reason }
            )
            coordinator.start(sessionID: sessionID, initialLeaseExpiresMonotonic: 30)
            coordinator.evaluateForTesting()
            status.value = HelperStatusRecord(state: "inactive", reason: drift, sessionID: sessionID, updatedAt: clock.value)
            clock.withValue { $0 = $0.addingTimeInterval(8) }
            monotonic.value = 8
            coordinator.evaluateForTesting()
            status.value = HelperStatusRecord(state: "active", reason: "verified", sessionID: sessionID, updatedAt: clock.value)
            coordinator.evaluateForTesting()

            XCTAssertEqual(renewals.value, 1, "\(drift) is projection-only and cannot block authenticated renewal")
            XCTAssertNil(endedReason.value)
        }
    }

    func testSessionDiagnosticsAreBoundedStructuredOwnerOnlyAndSanitized() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("history.json")
        let store = SessionDiagnosticStore(file: file, maximumEntries: 3, maximumBytes: 2_048)
        for index in 0..<8 {
            store.record(event: "renew", reason: "reason-\(index)", sessionID: UUID())
        }
        store.record(event: "end", reason: "token=secret/value", sessionID: UUID())

        let entries = store.entries()
        XCTAssertLessThanOrEqual(entries.count, 3)
        XCTAssertTrue(entries.allSatisfy { $0.schema == 1 && !$0.sessionID.isEmpty })
        XCTAssertEqual(entries.last?.reason, "redacted")
        XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 2_048)
        var metadata = stat()
        XCTAssertEqual(lstat(file.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("secret/value"))
    }

    func testSessionDiagnosticRenewalsCoalesceAndPreserveStructuralEvidence() throws {
        let root = try temporaryDirectory()
        let clock = LockedBox(Date(timeIntervalSince1970: 1_000))
        let writes = LockedBox(0)
        let store = SessionDiagnosticStore(
            file: root.appendingPathComponent("history.json"),
            renewalFlushInterval: 300,
            now: { clock.value },
            writeObserver: { writes.withValue { $0 += 1 } }
        )
        let sessionID = UUID()
        store.record(event: "start", reason: "lease-issued", sessionID: sessionID)
        for _ in 0..<38 {
            store.recordRenewal(reason: "safety-probes-valid", sessionID: sessionID)
            clock.withValue { $0 = $0.addingTimeInterval(8) }
        }
        store.record(event: "acknowledged", reason: "helper-active", sessionID: sessionID)

        let entries = store.entries()
        // The asynchronous writer may publish the initial start before the
        // later summary/acknowledgement boundary. Routine renewals still
        // collapse into one summary, so this sequence needs at most two writes.
        XCTAssertGreaterThanOrEqual(writes.value, 1)
        XCTAssertLessThanOrEqual(writes.value, 2)
        XCTAssertTrue(entries.contains { $0.event == "start" })
        XCTAssertTrue(entries.contains { $0.event == "acknowledged" })
        XCTAssertEqual(entries.first { $0.event == "renew-summary" }?.renewalCount, 38)
        XCTAssertLessThan(1.0 / 38.0, 0.03)
    }

    func testSessionDiagnosticsPublishOwnerOnlyUnderPermissiveUmask() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("history.json")
        let previousUmask = umask(0)
        defer { _ = umask(previousUmask) }
        let store = SessionDiagnosticStore(file: file)
        store.record(event: "start", reason: "lease-issued", sessionID: UUID())

        // `record` publishes asynchronously; `entries` is the supported
        // synchronous drain boundary before inspecting the durable artifact.
        XCTAssertEqual(store.entries().count, 1)

        var metadata = stat()
        XCTAssertEqual(lstat(file.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(metadata.st_uid, getuid())
        XCTAssertEqual(metadata.st_nlink, 1)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
    }

    func testFreshManualSessionRequiresVerifiedCurrentAcknowledgement() {
        let now = Date()
        let lease = makeLease(sessionID: UUID(), lifetime: 30)
        let status = HelperStatusRecord(
            state: "active",
            reason: "verified",
            sessionID: lease.sessionID,
            updatedAt: now
        )
        let snapshot = makeSnapshot(
            source: .ac,
            sleepDisabled: true,
            sleepDisabledVerified: true,
            lease: lease,
            status: status,
            checkedAt: now
        )

        XCTAssertTrue(snapshot.sessionActive)
        XCTAssertEqual(snapshot.statusTitle, "Protection active — plugged in")
        XCTAssertFalse(snapshot.canStartSession)
    }

    func testStaleAcknowledgementCannotClaimActive() {
        let now = Date()
        let lease = makeLease(sessionID: UUID(), lifetime: 30)
        let status = HelperStatusRecord(
            state: "active",
            reason: "verified",
            sessionID: lease.sessionID,
            updatedAt: now.addingTimeInterval(-30)
        )
        let snapshot = makeSnapshot(
            source: .ac,
            sleepDisabled: true,
            sleepDisabledVerified: true,
            lease: lease,
            status: status,
            checkedAt: now
        )

        XCTAssertFalse(snapshot.sessionActive)
        XCTAssertEqual(snapshot.statusTitle, "Restore required")
    }

    func testRecoveryRequiredBlocksReadyAndNewSessionsEvenWhenSleepDisabledIsOff() {
        let snapshot = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true,
            status: HelperStatusRecord(
                state: "recovery-required",
                reason: "restore-unverified",
                sessionID: UUID(),
                updatedAt: Date()
            )
        )

        XCTAssertTrue(snapshot.restoreRequired)
        XCTAssertTrue(snapshot.helperRecoveryRequired)
        XCTAssertFalse(snapshot.canStartSession)
        XCTAssertEqual(snapshot.statusTitle, "Recovery required")
    }

    func testOrphanedLeaseCannotClaimProtectionAfterAppRelaunch() {
        let now = Date()
        let lease = makeLease(sessionID: UUID(), lifetime: 30)
        let snapshot = makeSnapshot(
            source: .ac,
            sleepDisabled: true,
            sleepDisabledVerified: true,
            lease: lease,
            status: HelperStatusRecord(
                state: "active",
                reason: "verified",
                sessionID: lease.sessionID,
                updatedAt: now
            ),
            checkedAt: now,
            ownsLease: false
        )

        XCTAssertFalse(snapshot.sessionActive)
        XCTAssertTrue(snapshot.orphanedLeasePresent)
        XCTAssertEqual(snapshot.statusTitle, "Restore required")
    }

    func testUnpluggedSnapshotNeverClaimsProtectionOrRearminess() {
        let now = Date()
        let lease = makeLease(sessionID: UUID(), lifetime: 30)
        let snapshot = makeSnapshot(
            source: .battery(percent: 80),
            sleepDisabled: true,
            sleepDisabledVerified: true,
            lease: lease,
            status: HelperStatusRecord(
                state: "active",
                reason: "verified",
                sessionID: lease.sessionID,
                updatedAt: now
            ),
            checkedAt: now
        )

        XCTAssertFalse(snapshot.sessionActive)
        XCTAssertFalse(snapshot.canStartSession)
        XCTAssertEqual(snapshot.statusTitle, "Restore required")
    }

    func testUnknownLivePowerStateFailsClosed() {
        let snapshot = makeSnapshot(
            source: .unknown("pmset failed"),
            sleepDisabled: false,
            sleepDisabledVerified: false
        )

        XCTAssertFalse(snapshot.canStartSession)
        XCTAssertEqual(snapshot.statusTitle, "Power status unavailable")
    }

    func testOldLoginItemLoadedIsDistinctLegacyResidue() {
        let snapshot = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true,
            legacyLoginItemLoaded: true
        )

        XCTAssertTrue(snapshot.legacyResiduePresent)
        XCTAssertFalse(snapshot.canStartSession)
        XCTAssertEqual(snapshot.statusTitle, "Old startup files found")
    }

    func testSleepDisabledParserRejectsMissingAndMalformedValues() {
        XCTAssertEqual(
            PowerInspector.parseSleepDisabled(from: "SleepDisabled 1\n"),
            true
        )
        XCTAssertEqual(
            PowerInspector.parseSleepDisabled(from: "SleepDisabled 0\n"),
            false
        )
        XCTAssertNil(PowerInspector.parseSleepDisabled(from: "SleepDisabled maybe\n"))
        XCTAssertNil(PowerInspector.parseSleepDisabled(from: "sleep 0\n"))
    }

    func testPowerAndACSleepParsing() {
        XCTAssertEqual(
            PowerInspector.parsePowerSource(from: "Now drawing from 'AC Power'\n"),
            .ac
        )
        XCTAssertEqual(
            PowerInspector.parsePowerSource(from: "Now drawing from 'Battery Power'\n -InternalBattery-0\t35%; discharging;\n"),
            .battery(percent: 35)
        )
        XCTAssertEqual(
            PowerInspector.parseACIdleSleep(from: "Battery Power:\n sleep 7\nAC Power:\n sleep 3\n"),
            3
        )
    }

    func testHelperStatusRequiresTimestampAndRejectsDuplicates() {
        XCTAssertNil(HelperStatusRecord.parse("state=active\nreason=verified\nsession=none\n"))
        XCTAssertNil(HelperStatusRecord.parse("state=active\nstate=active\nreason=verified\nsession=none\nupdated=1\n"))
        XCTAssertNotNil(HelperStatusRecord.parse("state=inactive\nreason=restored\nsession=none\nupdated=1\n"))
    }

    func testHelperStatusProjectionIsCanonicalAndParserCompatible() throws {
        let root = try temporaryDirectory()
        let path = root.appendingPathComponent("helper-status").path
        let sessionID = UUID()
        XCTAssertTrue(HelperStatusFixture.write(
            state: "active",
            reason: "verified",
            sessionID: sessionID,
            path: path
        ))
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(raw.split(separator: "\n").filter { $0.hasPrefix("state=") }.count, 1)
        XCTAssertTrue(raw.contains("state=active"))
        XCTAssertTrue(raw.contains("reason=verified"))
        XCTAssertTrue(raw.contains("session=\(sessionID.uuidString.lowercased())"))
        XCTAssertTrue(raw.contains("projection_generation=1"))
        XCTAssertTrue(raw.contains("projection_authority="))
        XCTAssertFalse(raw.contains("recovery_budget="))
        XCTAssertNotNil(HelperStatusRecord.parse(raw))
        XCTAssertNotNil(HelperStatusTombstone.read(path: path))
    }

    func testLeaseParserRejectsDuplicateAndUnknownFields() {
        let lease = makeLease(sessionID: UUID(), lifetime: 30)
        XCTAssertNotNil(ActivationLease.parse(lease.storagePayload))
        XCTAssertNil(ActivationLease.parse(lease.storagePayload + "session=\(UUID())\n"))
        XCTAssertNil(ActivationLease.parse(lease.storagePayload + "unexpected=value\n"))
    }

    func testTerminalGenerationLedgerParserMatchesBoundedHelperSemantics() {
        let first = UUID()
        let second = UUID()
        XCTAssertEqual(TerminalGenerationLedger.parse(""), [])
        XCTAssertEqual(
            TerminalGenerationLedger.parse("\(first.uuidString)\n\(second.uuidString)\n"),
            [first, second]
        )
        XCTAssertNil(TerminalGenerationLedger.parse("not-a-uuid\n"))
        XCTAssertNil(TerminalGenerationLedger.parse("\(first.uuidString)\n\(first.uuidString)\n"))
        let tooMany = (0...TerminalGenerationLedger.maximumEntries)
            .map { _ in UUID().uuidString }
            .joined(separator: "\n") + "\n"
        XCTAssertNil(TerminalGenerationLedger.parse(tooMany))
    }

    func testAppLedgerReadinessRejectsMalformedDuplicateWritableAndSymlinkState() throws {
        let root = try temporaryDirectory()
        let ledger = root.appendingPathComponent("terminal-generations")
        let first = UUID()
        let second = UUID()
        try "\(first.uuidString)\n\(second.uuidString)\n".write(to: ledger, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(ledger.path, 0o644), 0)
        XCTAssertTrue(PowerInspector.terminalGenerationsValid(path: ledger.path, expectedOwnerUID: getuid()))

        try "\(first.uuidString)\n\(first.uuidString.lowercased())\n".write(to: ledger, atomically: true, encoding: .utf8)
        XCTAssertFalse(PowerInspector.terminalGenerationsValid(path: ledger.path, expectedOwnerUID: getuid()))
        try "malformed\n".write(to: ledger, atomically: true, encoding: .utf8)
        XCTAssertFalse(PowerInspector.terminalGenerationsValid(path: ledger.path, expectedOwnerUID: getuid()))

        try "\(first.uuidString)\n".write(to: ledger, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(ledger.path, 0o622), 0)
        XCTAssertFalse(PowerInspector.terminalGenerationsValid(path: ledger.path, expectedOwnerUID: getuid()))
        XCTAssertEqual(unlink(ledger.path), 0)
        XCTAssertEqual(symlink("missing-target", ledger.path), 0)
        XCTAssertFalse(PowerInspector.terminalGenerationsValid(path: ledger.path, expectedOwnerUID: getuid()))
        XCTAssertEqual(unlink(ledger.path), 0)
        XCTAssertEqual(mkfifo(ledger.path, 0o644), 0)
        XCTAssertFalse(PowerInspector.terminalGenerationsValid(path: ledger.path, expectedOwnerUID: getuid()))
        XCTAssertEqual(unlink(ledger.path), 0)
        try String(repeating: "x", count: Int(TerminalGenerationLedger.maximumBytes) + 1)
            .write(to: ledger, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(ledger.path, 0o644), 0)
        XCTAssertFalse(PowerInspector.terminalGenerationsValid(path: ledger.path, expectedOwnerUID: getuid()))
        try "\(first.uuidString)\n".write(to: ledger, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(ledger.path, 0o644), 0)
        let ledgerPolicy = BoundedFileReadPolicy(
            maximumBytes: Int(TerminalGenerationLedger.maximumBytes),
            expectedOwnerUID: getuid(),
            requireSingleLink: true,
            rejectGroupOrWorldWritable: true,
            requireNonEmpty: false,
            safeParentDepth: 1
        )
        XCTAssertFalse(BoundedFileReader.fileMetadataIsSafe(
            mode: mode_t(S_IFREG) | 0o644,
            ownerUID: getuid(),
            linkCount: 2,
            size: off_t("\(first.uuidString)\n".utf8.count),
            policy: ledgerPolicy
        ))
        XCTAssertFalse(PowerInspector.terminalGenerationsValid(path: ledger.path, expectedOwnerUID: getuid() &+ 1))
    }

    func testTerminalGenerationStorePublishesAppReadableNonWritableLedger() throws {
        let root = try temporaryDirectory()
        let ledger = root.appendingPathComponent("terminal-generations")
        let sessionID = UUID()

        try Data().write(to: ledger, options: .withoutOverwriting)
        XCTAssertEqual(chmod(ledger.path, 0o644), 0)
        XCTAssertTrue(TerminalGenerationStore.record(sessionID: sessionID, path: ledger.path))
        var metadata = stat()
        XCTAssertEqual(lstat(ledger.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o644)
        XCTAssertEqual(TerminalGenerationLedger.parse(try String(contentsOf: ledger)), [sessionID])
        XCTAssertTrue(PowerInspector.terminalGenerationsValid(path: ledger.path, expectedOwnerUID: getuid()))
    }

    func testBootIdentityMatchesStableKernelBootSessionUUID() throws {
        var size = 0
        XCTAssertEqual(sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0), 0)
        XCTAssertGreaterThan(size, 1)
        var buffer = [CChar](repeating: 0, count: size)
        XCTAssertEqual(sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0), 0)
        if let terminator = buffer.firstIndex(of: 0) {
            buffer.removeSubrange(terminator...)
        }
        let raw = String(decoding: buffer.map(UInt8.init(bitPattern:)), as: UTF8.self)
        let expected = try XCTUnwrap(BootIdentity.normalizeBootSessionUUID(raw))

        XCTAssertEqual(BootIdentity.current(), expected)
        XCTAssertEqual(BootIdentity.current(), expected)
        XCTAssertEqual(UUID(uuidString: expected)?.uuidString.lowercased(), expected)
    }

    func testBootIdentityNormalizerCanonicalizesAndRejectsMalformedValues() {
        let uuid = "5D7D39F9-B485-44D9-87DE-422B1BF64F60"
        XCTAssertEqual(
            BootIdentity.normalizeBootSessionUUID(" \n\(uuid)\0\t"),
            uuid.lowercased()
        )
        XCTAssertNil(BootIdentity.normalizeBootSessionUUID(""))
        XCTAssertNil(BootIdentity.normalizeBootSessionUUID("\0\n"))
        XCTAssertNil(BootIdentity.normalizeBootSessionUUID("1783623794.587307"))
        XCTAssertNil(BootIdentity.normalizeBootSessionUUID("not-a-boot-session"))
    }

    func testLeaseRejectsRebootExpiryAndExcessiveLifetime() {
        let now = Date()
        let mono = MonotonicClock.seconds()
        let lease = makeLease(sessionID: UUID(), lifetime: 30, now: now, monotonic: mono)

        XCTAssertEqual(
            lease.validationFailure(
                now: now,
                nowMonotonic: mono,
                currentBootID: "different-boot",
                expectedOwnerUID: getuid(),
                currentSystemBuild: lease.systemBuild
            ),
            .bootMismatch
        )

        let expired = ActivationLease(
            sessionID: lease.sessionID,
            bootID: lease.bootID,
            expiresAt: now.addingTimeInterval(-1),
            issuedMonotonic: mono - 20,
            expiresMonotonic: mono - 1,
            ownerUID: getuid(),
            systemBuild: lease.systemBuild
        )
        XCTAssertEqual(
            expired.validationFailure(
                now: now,
                nowMonotonic: mono,
                currentBootID: lease.bootID,
                expectedOwnerUID: getuid(),
                currentSystemBuild: lease.systemBuild
            ),
            .expired
        )

        let excessive = ActivationLease(
            sessionID: lease.sessionID,
            bootID: lease.bootID,
            expiresAt: now.addingTimeInterval(60),
            issuedMonotonic: mono,
            expiresMonotonic: mono + 60,
            ownerUID: getuid(),
            systemBuild: lease.systemBuild
        )
        XCTAssertEqual(
            excessive.validationFailure(
                now: now,
                nowMonotonic: mono,
                currentBootID: lease.bootID,
                expectedOwnerUID: getuid(),
                currentSystemBuild: lease.systemBuild
            ),
            .excessiveLifetime
        )
    }

    func testLeaseCommitGuardRejectsPublicationAndPreservesPriorLease() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("activation-lease")
        let prior = makeLease(sessionID: UUID(), lifetime: 30)
        let replacement = makeLease(sessionID: UUID(), lifetime: 30)
        let policy = try UserStateFileCapability.AncestryPolicy.testSandbox(root: root)
        try ActivationLeaseStore.write(prior, to: file, ancestryPolicy: policy)
        let priorBytes = try Data(contentsOf: file)

        XCTAssertThrowsError(try ActivationLeaseStore.write(
            replacement,
            to: file,
            commitGuard: { false },
            ancestryPolicy: policy
        )) { error in
            guard case ActivationLeaseStore.StoreError.commitRejected = error else {
                return XCTFail("Expected commitRejected, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: file), priorBytes)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".activation-lease.") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testSecureLeaseReaderRejectsSymlinkWritableAndMalformedFiles() throws {
        let root = try temporaryDirectory()
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        let real = support.appendingPathComponent("real-lease")
        let link = support.appendingPathComponent("activation-lease")
        let lease = makeLease(sessionID: UUID(), lifetime: 30)
        try lease.storagePayload.write(to: real, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(real.path, 0o600), 0)
        XCTAssertEqual(symlink(real.path, link.path), 0)

        assertLeaseFailure(
            SecureLeaseReader.load(path: link.path, expectedOwnerUID: getuid()),
            equals: .unsafeFile
        )

        XCTAssertEqual(unlink(link.path), 0)
        try lease.storagePayload.write(to: link, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(link.path, 0o666), 0)
        assertLeaseFailure(
            SecureLeaseReader.load(path: link.path, expectedOwnerUID: getuid()),
            equals: .unsafeFile
        )

        try "not-a-lease\n".write(to: link, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(link.path, 0o600), 0)
        assertLeaseFailure(
            SecureLeaseReader.load(path: link.path, expectedOwnerUID: getuid()),
            equals: .malformed
        )
    }

    func testAppliedStateRejectsStaleZeroBaselineAndUnsafeFile() throws {
        XCTAssertNil(AppliedState.parse("session=\(UUID())\nchanged_sleep_disabled=1\nchanged_ac_sleep=1\noriginal_ac_sleep=0\n"))

        let root = try temporaryDirectory()
        let statePath = root.appendingPathComponent("applied-state").path
        let state = AppliedState(
            sessionID: UUID(),
            changedSleepDisabled: true,
            changedACSleep: true,
            originalACSleep: 5
        )
        try AppliedStateStore.write(state, path: statePath)
        XCTAssertEqual(AppliedStateStore.load(path: statePath), .success(state))
        XCTAssertEqual(chmod(statePath, 0o666), 0)
        XCTAssertEqual(AppliedStateStore.load(path: statePath), .invalid)
    }

    func testAppliedStateDurabilityBarriersFailClosedAndRetainPublishedRecoveryRecord() throws {
        let root = try temporaryDirectory()
        let path = root.appendingPathComponent("applied-state").path
        let state = AppliedState(sessionID: UUID(), changedSleepDisabled: true, changedACSleep: true, originalACSleep: 5)

        for stage in [
            AppliedStateStore.DurabilityStage.fileBarrier,
            .rename,
            .directoryBarrier,
            .finalVerification,
        ] {
            let operations = AppliedStateStore.DurabilityOperations(
                fileBarrier: { descriptor in stage != .fileBarrier && AppliedStateStore.DurabilityOperations.system.fileBarrier(descriptor) },
                rename: { source, destination in stage != .rename && AppliedStateStore.DurabilityOperations.system.rename(source, destination) },
                directoryBarrier: { directory in stage != .directoryBarrier && AppliedStateStore.DurabilityOperations.system.directoryBarrier(directory) },
                verify: { file, payload, expected, owner in
                    stage != .finalVerification
                        && AppliedStateStore.DurabilityOperations.system.verify(file, payload, expected, owner)
                }
            )
            XCTAssertThrowsError(try AppliedStateStore.write(state, path: path, operations: operations)) { error in
                XCTAssertEqual(error as? AppliedStateStore.StoreError, .durability(stage))
            }
            if stage == .directoryBarrier || stage == .finalVerification {
                XCTAssertEqual(AppliedStateStore.load(path: path), .success(state))
                XCTAssertEqual(unlink(path), 0)
            } else {
                XCTAssertEqual(AppliedStateStore.load(path: path), .missing)
            }
        }
    }

    func testActivationDoesNotMutatePowerWhenDurablePublicationFails() throws {
        for stage in [
            AppliedStateStore.DurabilityStage.fileBarrier,
            .rename,
            .directoryBarrier,
            .finalVerification,
        ] {
            let power = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5)
            let harness = try makeRuntimeHarness(
                lifetime: 5,
                power: power,
                appliedStateWrite: { _, _ in throw AppliedStateStore.StoreError.durability(stage) }
            )
            XCTAssertEqual(harness.runtime.run(), 0, "stage=\(stage)")
            XCTAssertEqual(power.sleepDisabledMutationCalls, 0, "stage=\(stage)")
            XCTAssertEqual(power.acSleepMutationCalls, 0, "stage=\(stage)")
            XCTAssertEqual(power.currentACSleep, 5, "stage=\(stage)")
            XCTAssertEqual(power.currentSleepDisabled, false, "stage=\(stage)")
        }
    }

    func testAppliedStateFinalVerificationRequiresExactPublishedBytes() throws {
        let root = try temporaryDirectory()
        let path = root.appendingPathComponent("applied-state").path
        let state = AppliedState(sessionID: UUID(), changedSleepDisabled: true, changedACSleep: true, originalACSleep: 5)
        let reorderedPayload = [
            "changed_ac_sleep=1",
            "session=\(state.sessionID.uuidString.lowercased())",
            "original_ac_sleep=5",
            "changed_sleep_disabled=1",
            "",
        ].joined(separator: "\n")
        // The durability boundary binds exact canonical bytes.  A semantically
        // equivalent reordering is intentionally not accepted after a
        // final-verification mutation.
        XCTAssertNil(AppliedState.parse(reorderedPayload))

        let operations = AppliedStateStore.DurabilityOperations(
            fileBarrier: AppliedStateStore.DurabilityOperations.system.fileBarrier,
            rename: AppliedStateStore.DurabilityOperations.system.rename,
            directoryBarrier: AppliedStateStore.DurabilityOperations.system.directoryBarrier,
            verify: { file, payload, expected, owner in
                try? reorderedPayload.write(toFile: file, atomically: false, encoding: .utf8)
                return AppliedStateStore.DurabilityOperations.system.verify(file, payload, expected, owner)
            }
        )
        XCTAssertThrowsError(try AppliedStateStore.write(state, path: path, operations: operations)) { error in
            XCTAssertEqual(error as? AppliedStateStore.StoreError, .durability(.finalVerification))
        }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), reorderedPayload)
        XCTAssertEqual(AppliedStateStore.load(path: path), .invalid)
    }

    func testBoundedFileReaderRejectsUnsafeAndMalformedControlsWithoutBlocking() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("record")
        let policy = BoundedFileReadPolicy(
            maximumBytes: 16, expectedOwnerUID: getuid(), requireSingleLink: true,
            rejectGroupOrWorldWritable: true, requireNonEmpty: true, safeParentDepth: 1
        )
        try "valid\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        XCTAssertEqual(BoundedFileReader.readUTF8(path: file.path, policy: policy), .success("valid\n"))
        XCTAssertEqual(chmod(file.path, 0o666), 0)
        XCTAssertEqual(BoundedFileReader.readUTF8(path: file.path, policy: policy), .failure(.unsafeFile))
        XCTAssertEqual(unlink(file.path), 0)
        if symlink("missing", file.path) == 0 {
            XCTAssertEqual(BoundedFileReader.readUTF8(path: file.path, policy: policy), .failure(.unsafeFile))
            XCTAssertEqual(unlink(file.path), 0)
        } else {
            // The held XCTest profile forbids link creation; the production
            // reader's no-follow behavior is exercised in the raw capability
            // fixtures that use synthetic metadata.
            XCTAssertEqual(errno, EPERM)
        }
        if mkfifo(file.path, 0o600) == 0 {
            XCTAssertEqual(BoundedFileReader.readUTF8(path: file.path, policy: policy), .failure(.unsafeFile))
            XCTAssertEqual(unlink(file.path), 0)
        } else {
            XCTAssertEqual(errno, EPERM)
        }
        try String(repeating: "x", count: 17).write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        XCTAssertEqual(BoundedFileReader.readUTF8(path: file.path, policy: policy), .failure(.tooLarge))
        try Data([0xFF]).write(to: file)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        XCTAssertEqual(BoundedFileReader.readUTF8(path: file.path, policy: policy), .failure(.invalidUTF8))
        let secondLink = root.appendingPathComponent("second-link")
        if link(file.path, secondLink.path) == 0 {
            XCTAssertEqual(BoundedFileReader.readUTF8(path: file.path, policy: policy), .failure(.unsafeFile))
            XCTAssertEqual(unlink(secondLink.path), 0)
        } else {
            XCTAssertEqual(errno, EPERM)
        }
        XCTAssertEqual(unlink(file.path), 0)
        try "before\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        let sameLengthPath = file.path
        let replacement = Array("after!\n".utf8)
        let mutationControls = BoundedFileReadControls(beforeFinalMetadata: {
            let descriptor = open(sameLengthPath, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            _ = replacement.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress, buffer.count)
            }
            _ = fsync(descriptor)
        })
        XCTAssertEqual(
            BoundedFileReader.readUTF8(path: file.path, policy: policy, controls: mutationControls),
            .failure(.changedDuringRead)
        )

        let inspected = root.appendingPathComponent("inspected", isDirectory: true)
        let replacementDirectory = root.appendingPathComponent("replacement", isDirectory: true)
        let moved = root.appendingPathComponent("inspected-moved", isDirectory: true)
        try FileManager.default.createDirectory(at: inspected, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: replacementDirectory, withIntermediateDirectories: false)
        let anchoredFile = inspected.appendingPathComponent("record")
        try "anchored\n".write(to: anchoredFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(anchoredFile.path, 0o600), 0)
        try "replacement\n".write(to: replacementDirectory.appendingPathComponent("record"), atomically: true, encoding: .utf8)
        let parentControls = BoundedFileReadControls(beforeLeafOpen: {
            _ = rename(inspected.path, moved.path)
            _ = symlink(replacementDirectory.path, inspected.path)
        })
        XCTAssertEqual(
            BoundedFileReader.readUTF8(path: anchoredFile.path, policy: policy, controls: parentControls),
            .success("anchored\n")
        )
        XCTAssertEqual(try String(contentsOf: inspected.appendingPathComponent("record")), "replacement\n")
    }

    func testDisabledLegacyBatteryResidueIsDetectedAndMigratesToInertStorage() throws {
        let preferences = PowerPreferences.parse("mode=disabled\nbattery=enabled\n")
        XCTAssertFalse(preferences.keepAwakeEnabled)
        XCTAssertTrue(preferences.legacyBatteryResidueDetected)
        XCTAssertFalse(preferences.allowBatteryKeepAwake)
        XCTAssertEqual(preferences.storagePayload, "mode=disabled\nbattery=disabled\n")

        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("desired-state")
        try "mode=disabled\nbattery=enabled\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        XCTAssertEqual(
            DesiredStateStore.readPreferences(
                from: file, ancestorPolicy: .testTemporaryDirectory,
                capabilityPolicy: try UserStateFileCapability.AncestryPolicy.testSandbox(root: root)
            ),
            .invalid(file.path)
        )
        try DesiredStateStore.write(
            preferences, supportDirectory: root, stateFile: file,
            ancestryPolicy: try UserStateFileCapability.AncestryPolicy.testSandbox(root: root)
        )
        XCTAssertEqual(
            DesiredStateStore.readPreferences(
                from: file,
                capabilityPolicy: try UserStateFileCapability.AncestryPolicy.testSandbox(root: root)
            ),
            .value(.disabled)
        )
    }

    func testDesiredStateZeroByteWriteFailsWithEIORatherThanRetrying() {
        XCTAssertThrowsError(
            try DesiredStateStore.acceptedWriteCount(0, path: "/tmp/desired-state", errorCode: 0)
        ) { error in
            guard case let DesiredStateStore.StoreError.writeFailed(path, code) = error else {
                return XCTFail("expected typed desired-state write failure")
            }
            XCTAssertEqual(path, "/tmp/desired-state")
            XCTAssertEqual(code, EIO)
        }
    }

    func testNativeHelperExpiresLeaseAndRestoresOwnedChanges() throws {
        let harness = try makeRuntimeHarness(lifetime: 1)
        let code = harness.runtime.run()

        XCTAssertEqual(code, 0)
        XCTAssertEqual(harness.power.currentSleepDisabled, false)
        XCTAssertEqual(harness.power.currentACSleep, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
        XCTAssertEqual(
            fixtureRecoveryBudgetRecord(supportDirectory: harness.configuration.supportDirectory),
            .absent,
            "normal expiry restores and terminalizes; it must not mint drift-recovery authority"
        )
    }

    func testNativeHelperUnplugRestoresAndDoesNotRearmOnReconnect() throws {
        let harness = try makeRuntimeHarness(lifetime: 10)
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
            harness.power.setSource(.battery)
        }
        let code = harness.runtime.run()
        let activationCalls = harness.power.enableSleepOverrideCalls
        harness.power.setSource(.ac)

        XCTAssertEqual(code, 0)
        XCTAssertEqual(harness.power.currentSleepDisabled, false)
        XCTAssertEqual(harness.power.currentACSleep, 5)
        XCTAssertEqual(activationCalls, 1)
        XCTAssertEqual(harness.power.enableSleepOverrideCalls, 1)
    }

    func testNativeHelperRecoversOwnedSleepDisabledDriftWithSameSessionWithinDeadline() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5)
        let harness = try makeRuntimeHarness(lifetime: 5, power: power, reconciliationInterval: 0.2)
        let recoveredStatus = LockedBox<String?>(nil)
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in power.forceSleepDisabled(false) }
        Timer.scheduledTimer(withTimeInterval: 0.23, repeats: false) { _ in
            recoveredStatus.value = try? String(contentsOfFile: harness.configuration.statusPath, encoding: .utf8)
        }
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in power.setSource(.battery) }

        XCTAssertEqual(harness.runtime.run(), 0)
        let recovered = try XCTUnwrap(recoveredStatus.value)
        XCTAssertEqual(power.enableSleepOverrideCalls, 2)
        XCTAssertTrue(recovered.contains("state=active"))
        XCTAssertTrue(recovered.contains("reason=override-recovered"))
        XCTAssertTrue(recovered.contains("session=\(harness.lease.sessionID.uuidString.lowercased())"))
        XCTAssertEqual(power.currentSleepDisabled, false)
    }

    func testNativeHelperSecondOwnedSleepDisabledDriftTerminalizesWithoutRearm() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5)
        let harness = try makeRuntimeHarness(lifetime: 5, power: power, reconciliationInterval: 0.2)
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in power.forceSleepDisabled(false) }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { _ in power.forceSleepDisabled(false) }

        XCTAssertEqual(harness.runtime.run(), 0)
        let status = try String(contentsOfFile: harness.configuration.statusPath, encoding: .utf8)
        XCTAssertEqual(power.enableSleepOverrideCalls, 2)
        XCTAssertEqual(power.currentSleepDisabled, false)
        XCTAssertTrue(status.contains("state=inactive"))
        XCTAssertTrue(status.contains("reason=override-lost"))
    }

    func testHelperRestartAfterObservedDriftFailsClosedWithoutReactivation() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 0)
        let harness = try makeRuntimeHarness(lifetime: 5, power: power, preapplyState: true)
        XCTAssertTrue(publishFixtureRecoveryBudget(.init(sessionID: harness.lease.sessionID, phase: .reserved), supportDirectory: harness.configuration.supportDirectory))
        HelperStatusFixture.write(
            state: "active",
            reason: "override-drift-observed",
            sessionID: harness.lease.sessionID,
            path: harness.configuration.statusPath
        )

        XCTAssertEqual(harness.runtime.run(), 0)
        XCTAssertEqual(power.enableSleepOverrideCalls, 0)
        XCTAssertEqual(power.currentSleepDisabled, false)
        XCTAssertEqual(power.currentACSleep, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
        XCTAssertTrue(try String(contentsOfFile: harness.configuration.statusPath).contains("state=inactive"))
    }

    func testHelperRestartAfterRecoveryRetainsSpentBudgetAndTerminalizesSecondDrift() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: true, acSleep: 0)
        let harness = try makeRuntimeHarness(
            lifetime: 5,
            power: power,
            preapplyState: true,
            reconciliationInterval: 0.02
        )
        XCTAssertTrue(publishFixtureRecoveryBudget(.init(sessionID: harness.lease.sessionID, phase: .spent), supportDirectory: harness.configuration.supportDirectory))
        HelperStatusFixture.write(
            state: "active",
            reason: "override-recovered",
            sessionID: harness.lease.sessionID,
            path: harness.configuration.statusPath
        )
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in power.forceSleepDisabled(false) }

        XCTAssertEqual(harness.runtime.run(), 0)
        XCTAssertEqual(power.enableSleepOverrideCalls, 0)
        XCTAssertEqual(power.currentSleepDisabled, false)
        XCTAssertEqual(
            fixtureRecoveryBudgetRecord(supportDirectory: harness.configuration.supportDirectory),
            .valid(.init(sessionID: harness.lease.sessionID, phase: .spent))
        )
    }

    func testFreshGenerationIgnoresSpentBudgetForDifferentSessionAndCanRecover() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5)
        let harness = try makeRuntimeHarness(lifetime: 5, power: power, reconciliationInterval: 0.2)
        XCTAssertTrue(publishFixtureRecoveryBudget(.init(sessionID: UUID(), phase: .spent), supportDirectory: harness.configuration.supportDirectory))
        HelperStatusFixture.write(
            state: "active",
            reason: "override-recovered",
            sessionID: UUID(),
            path: harness.configuration.statusPath
        )
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in power.forceSleepDisabled(false) }
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in power.setSource(.battery) }

        XCTAssertEqual(harness.runtime.run(), 0)
        XCTAssertEqual(power.enableSleepOverrideCalls, 2)
    }

    func testNativeHelperACSleepDriftTerminalizesWithoutOverwritingExternalValue() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5)
        let harness = try makeRuntimeHarness(lifetime: 5, power: power, reconciliationInterval: 0.02)
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in power.forceACSleep(7) }

        XCTAssertEqual(harness.runtime.run(), 0)
        let status = try String(contentsOfFile: harness.configuration.statusPath, encoding: .utf8)
        XCTAssertEqual(power.currentSleepDisabled, false)
        XCTAssertEqual(power.currentACSleep, 7)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
        XCTAssertTrue(status.contains("state=inactive"))
        XCTAssertTrue(status.contains("reason=override-lost"))
    }

    func testNativeHelperPersistentRecoveryFailureTerminalizesWithoutRearm() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5)
        let harness = try makeRuntimeHarness(lifetime: 5, power: power, reconciliationInterval: 0.02)
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in
            power.failSleepEnable = true
            power.forceSleepDisabled(false)
        }

        XCTAssertEqual(harness.runtime.run(), 0)
        XCTAssertEqual(power.enableSleepOverrideCalls, 2)
        XCTAssertEqual(power.currentSleepDisabled, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
        XCTAssertTrue(try String(contentsOfFile: harness.configuration.statusPath).contains("state=inactive"))
    }

    func testNativeHelperUnreadableOverrideFailsClosedWithoutReapply() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5)
        let harness = try makeRuntimeHarness(lifetime: 5, power: power, reconciliationInterval: 0.02)
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in power.forceSleepDisabledUnknown() }

        XCTAssertEqual(harness.runtime.run(), 0)
        let status = try String(contentsOfFile: harness.configuration.statusPath, encoding: .utf8)
        XCTAssertEqual(power.enableSleepOverrideCalls, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
        XCTAssertTrue(status.contains("state=recovery-required"))
        XCTAssertTrue(status.contains("reason=override-lost-restore-unverified"))
    }

    func testNativeHelperTransientUnreadableSleepDisabledRetriesAndStaysActive() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5)
        let harness = try makeRuntimeHarness(lifetime: 5, power: power, reconciliationInterval: 0.05)
        let statusWhileActive = LockedBox<String?>(nil)
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in
            power.setSleepDisabledReadSequence([nil, true])
        }
        Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { _ in
            statusWhileActive.value = try? String(contentsOfFile: harness.configuration.statusPath, encoding: .utf8)
            power.setSource(.battery)
        }

        XCTAssertEqual(harness.runtime.run(), 0)
        let active = try XCTUnwrap(statusWhileActive.value)
        XCTAssertTrue(active.contains("state=active"))
        XCTAssertTrue(active.contains("reason=verified"))
        XCTAssertEqual(power.enableSleepOverrideCalls, 1)
        XCTAssertGreaterThanOrEqual(power.sleepDisabledReadCalls, 2)
    }

    func testNativeHelperUnreadableThenExplicitOwnedLossUsesNormalRecovery() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5)
        let harness = try makeRuntimeHarness(lifetime: 5, power: power, reconciliationInterval: 0.05)
        let recoveredStatus = LockedBox<String?>(nil)
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in
            power.forceSleepDisabled(false)
            power.setSleepDisabledReadSequence([nil, false])
        }
        Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { _ in
            recoveredStatus.value = try? String(contentsOfFile: harness.configuration.statusPath, encoding: .utf8)
            power.setSource(.battery)
        }

        XCTAssertEqual(harness.runtime.run(), 0)
        let recovered = try XCTUnwrap(recoveredStatus.value)
        XCTAssertTrue(recovered.contains("state=active"))
        XCTAssertTrue(recovered.contains("reason=override-recovered"))
        XCTAssertEqual(power.enableSleepOverrideCalls, 2)
    }

    func testNativeHelperTransientUnreadableACSleepRetriesAndStaysActive() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5)
        let harness = try makeRuntimeHarness(lifetime: 5, power: power, reconciliationInterval: 0.05)
        let statusWhileActive = LockedBox<String?>(nil)
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in
            power.setACSleepReadSequence([nil, 0])
        }
        Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { _ in
            statusWhileActive.value = try? String(contentsOfFile: harness.configuration.statusPath, encoding: .utf8)
            power.setSource(.battery)
        }

        XCTAssertEqual(harness.runtime.run(), 0)
        let active = try XCTUnwrap(statusWhileActive.value)
        XCTAssertTrue(active.contains("state=active"))
        XCTAssertTrue(active.contains("reason=verified"))
        XCTAssertEqual(power.enableSleepOverrideCalls, 1)
        XCTAssertGreaterThanOrEqual(power.acSleepReadCalls, 2)
    }

    func testNativeHelperPersistentUnreadableACSleepFailsClosed() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5)
        let harness = try makeRuntimeHarness(lifetime: 5, power: power, reconciliationInterval: 0.02)
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in
            power.forceACSleepUnknown()
        }

        XCTAssertEqual(harness.runtime.run(), 0)
        let status = try String(contentsOfFile: harness.configuration.statusPath, encoding: .utf8)
        XCTAssertEqual(power.enableSleepOverrideCalls, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
        XCTAssertTrue(status.contains("state=recovery-required"))
        XCTAssertTrue(status.contains("reason=override-lost-restore-unverified"))
    }

    func testNativeHelperRecoveryUnplugRaceTerminatesWithoutRearm() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5)
        power.unplugOnEnableAfterCall = 2
        let harness = try makeRuntimeHarness(lifetime: 5, power: power, reconciliationInterval: 0.02)
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in power.forceSleepDisabled(false) }

        XCTAssertEqual(harness.runtime.run(), 0)
        let calls = power.enableSleepOverrideCalls
        power.setSource(.ac)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(power.enableSleepOverrideCalls, 2)
        XCTAssertEqual(power.currentSleepDisabled, false)
    }

    func testNativeHelperTerminalGenerationTombstoneBlocksSameSessionReplay() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5)
        let harness = try makeRuntimeHarness(
            lifetime: 5,
            power: power,
            reconciliationInterval: 0.02,
            terminalGenerationAllows: { _, _ in true },
            terminalGenerationRecord: { _, _ in false }
        )
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in
            power.setSource(.battery)
        }
        XCTAssertEqual(harness.runtime.run(), 0)
        XCTAssertEqual(power.enableSleepOverrideCalls, 1)
        let terminalStatus = try String(contentsOfFile: harness.configuration.statusPath, encoding: .utf8)
        XCTAssertTrue(terminalStatus.contains("state=inactive"))
        XCTAssertTrue(terminalStatus.contains("reason=power-source-changed"))
        XCTAssertTrue(terminalStatus.contains("session=\(harness.lease.sessionID.uuidString.lowercased())"))

        XCTAssertEqual(unlink(harness.configuration.leasePath), 0)
        let noLeaseRuntime = HelperRuntime(
            configuration: harness.configuration,
            power: power,
            currentBootID: { harness.lease.bootID },
            currentSystemBuild: { "25F84" },
            reconciliationInterval: 0.02,
            terminalGenerationAllows: { _, _ in true },
            terminalGenerationRecord: { _, _ in false },
            statusProjectionWrite: harness.statusProjectionWrite,
            statusProjectionRead: harness.statusProjectionRead
        )
        XCTAssertEqual(noLeaseRuntime.run(), 0)
        let afterNoLease = try String(contentsOfFile: harness.configuration.statusPath, encoding: .utf8)
        XCTAssertTrue(afterNoLease.contains("session=\(harness.lease.sessionID.uuidString.lowercased())"))

        power.setSource(.ac)
        let replay = makeLease(sessionID: harness.lease.sessionID, lifetime: 5)
        try replay.storagePayload.write(toFile: harness.configuration.leasePath, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(harness.configuration.leasePath, 0o600), 0)
        let replayRuntime = HelperRuntime(
            configuration: harness.configuration,
            power: power,
            currentBootID: { replay.bootID },
            currentSystemBuild: { "25F84" },
            reconciliationInterval: 0.02,
            terminalGenerationAllows: { _, _ in true },
            terminalGenerationRecord: { _, _ in false },
            statusProjectionWrite: harness.statusProjectionWrite,
            statusProjectionRead: harness.statusProjectionRead
        )

        XCTAssertEqual(replayRuntime.run(), 0)
        XCTAssertEqual(power.enableSleepOverrideCalls, 1)
        XCTAssertEqual(power.currentSleepDisabled, false)
        XCTAssertEqual(power.currentACSleep, 5)
    }

    func testTerminalGenerationCannotSuppressOwnedStateRestoration() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: true, acSleep: 0)
        let recordedAfterRestore = LockedBox(false)
        let statusWasPendingBeforeRestore = LockedBox(false)
        let harness = try makeRuntimeHarness(
            lifetime: 5,
            power: power,
            preapplyState: true,
            terminalGenerationAllows: { _, _ in false },
            terminalGenerationRecord: { _, ledgerPath in
                let appliedStatePath = URL(fileURLWithPath: ledgerPath)
                    .deletingLastPathComponent()
                    .appendingPathComponent("applied-state")
                    .path
                recordedAfterRestore.value = power.currentSleepDisabled == false
                    && power.currentACSleep == 5
                    && !FileManager.default.fileExists(atPath: appliedStatePath)
                return true
            }
        )
        power.onSleepRestore = {
            statusWasPendingBeforeRestore.value = (
                try? String(contentsOfFile: harness.configuration.statusPath)
            )?.contains("reason=terminal-session-recovery-restore-pending") == true
        }

        XCTAssertEqual(harness.runtime.run(), 0)
        XCTAssertTrue(statusWasPendingBeforeRestore.value)
        XCTAssertTrue(recordedAfterRestore.value)
        XCTAssertEqual(power.currentSleepDisabled, false)
        XCTAssertEqual(power.currentACSleep, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
        XCTAssertTrue(
            try String(contentsOfFile: harness.configuration.statusPath)
                .contains("reason=terminal-session-recovery")
        )
    }

    func testTerminalGenerationRetriesRecoveryRequiredRestoreOnRestart() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: true, acSleep: 0)
        power.failSleepRestore = true
        let recordCalls = LockedBox(0)
        let harness = try makeRuntimeHarness(
            lifetime: 5,
            power: power,
            preapplyState: true,
            terminalGenerationAllows: { _, _ in false },
            terminalGenerationRecord: { _, _ in
                recordCalls.withValue { $0 += 1 }
                return true
            }
        )

        XCTAssertEqual(harness.runtime.run(), 0)
        XCTAssertEqual(recordCalls.value, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
        XCTAssertTrue(
            try String(contentsOfFile: harness.configuration.statusPath)
                .contains("state=recovery-required")
        )

        power.failSleepRestore = false
        let restartedRuntime = HelperRuntime(
            configuration: harness.configuration,
            power: power,
            currentBootID: { harness.lease.bootID },
            currentSystemBuild: { "25F84" },
            terminalGenerationAllows: { _, _ in false },
            terminalGenerationRecord: { _, _ in
                recordCalls.withValue { $0 += 1 }
                return true
            },
            statusProjectionWrite: harness.statusProjectionWrite,
            statusProjectionRead: harness.statusProjectionRead
        )

        XCTAssertEqual(restartedRuntime.run(), 0)
        XCTAssertEqual(recordCalls.value, 1)
        XCTAssertEqual(power.currentSleepDisabled, false)
        XCTAssertEqual(power.currentACSleep, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
        XCTAssertTrue(
            try String(contentsOfFile: harness.configuration.statusPath)
                .contains("state=inactive")
        )
    }

    func testTerminalStatusCannotSuppressOwnedStateRestoration() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: true, acSleep: 0)
        let recordCalls = LockedBox(0)
        let harness = try makeRuntimeHarness(
            lifetime: 5,
            power: power,
            preapplyState: true,
            terminalGenerationAllows: { _, _ in true },
            terminalGenerationRecord: { _, _ in
                recordCalls.withValue { $0 += 1 }
                return true
            }
        )
        HelperStatusFixture.write(
            state: "recovery-required",
            reason: "interrupted-restore",
            sessionID: harness.lease.sessionID,
            path: harness.configuration.statusPath
        )

        XCTAssertEqual(harness.runtime.run(), 0)
        XCTAssertEqual(recordCalls.value, 1)
        XCTAssertEqual(power.currentSleepDisabled, false)
        XCTAssertEqual(power.currentACSleep, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
        XCTAssertTrue(
            try String(contentsOfFile: harness.configuration.statusPath)
                .contains("reason=terminal-session-recovery")
        )
    }

    func testRestorePendingRestartDoesNotReactivateAfterPowerWasAlreadyRestored() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5)
        let harness = try makeRuntimeHarness(
            lifetime: 5,
            power: power,
            preapplyState: true,
            terminalGenerationAllows: { _, _ in true }
        )
        HelperStatusFixture.write(
            state: "recovery-required",
            reason: "signal-restore-pending",
            sessionID: harness.lease.sessionID,
            path: harness.configuration.statusPath
        )

        XCTAssertEqual(harness.runtime.run(), 0)
        XCTAssertEqual(power.enableSleepOverrideCalls, 0)
        XCTAssertEqual(power.currentSleepDisabled, false)
        XCTAssertEqual(power.currentACSleep, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
        XCTAssertTrue(
            try String(contentsOfFile: harness.configuration.statusPath)
                .contains("state=inactive")
        )
    }

    func testNoValidLeaseRecordsTerminalOnlyAfterOwnedStateRestoration() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: true, acSleep: 0)
        let recordedAfterRestore = LockedBox(false)
        let harness = try makeRuntimeHarness(
            lifetime: 5,
            power: power,
            preapplyState: true,
            terminalGenerationRecord: { _, ledgerPath in
                let appliedStatePath = URL(fileURLWithPath: ledgerPath)
                    .deletingLastPathComponent()
                    .appendingPathComponent("applied-state")
                    .path
                recordedAfterRestore.value = power.currentSleepDisabled == false
                    && power.currentACSleep == 5
                    && !FileManager.default.fileExists(atPath: appliedStatePath)
                return true
            }
        )
        XCTAssertEqual(unlink(harness.configuration.leasePath), 0)
        HelperStatusFixture.write(
            state: "active",
            reason: "verified",
            sessionID: harness.lease.sessionID,
            path: harness.configuration.statusPath
        )

        XCTAssertEqual(harness.runtime.run(), 0)
        XCTAssertTrue(recordedAfterRestore.value)
        XCTAssertEqual(power.currentSleepDisabled, false)
        XCTAssertEqual(power.currentACSleep, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
        XCTAssertTrue(
            try String(contentsOfFile: harness.configuration.statusPath)
                .contains("reason=no-valid-lease")
        )
    }

    func testNoValidLeaseTerminalizesActiveStatusWhenLedgerRecordFails() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5)
        let harness = try makeRuntimeHarness(
            lifetime: 5,
            power: power,
            reconciliationInterval: 0.02,
            terminalGenerationAllows: { _, _ in true },
            terminalGenerationRecord: { _, _ in false }
        )
        XCTAssertEqual(unlink(harness.configuration.leasePath), 0)
        HelperStatusFixture.write(
            state: "active",
            reason: "verified",
            sessionID: harness.lease.sessionID,
            path: harness.configuration.statusPath
        )

        XCTAssertEqual(harness.runtime.run(), 0)
        let terminalized = try String(contentsOfFile: harness.configuration.statusPath, encoding: .utf8)
        XCTAssertTrue(terminalized.contains("state=inactive"))
        XCTAssertTrue(terminalized.contains("reason=no-valid-lease"))
        XCTAssertTrue(terminalized.contains("session=\(harness.lease.sessionID.uuidString.lowercased())"))

        let replay = makeLease(sessionID: harness.lease.sessionID, lifetime: 5)
        try replay.storagePayload.write(toFile: harness.configuration.leasePath, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(harness.configuration.leasePath, 0o600), 0)
        let replayRuntime = HelperRuntime(
            configuration: harness.configuration,
            power: power,
            currentBootID: { replay.bootID },
            currentSystemBuild: { "25F84" },
            reconciliationInterval: 0.02,
            terminalGenerationAllows: { _, _ in true },
            terminalGenerationRecord: { _, _ in false },
            statusProjectionWrite: harness.statusProjectionWrite,
            statusProjectionRead: harness.statusProjectionRead
        )

        XCTAssertEqual(replayRuntime.run(), 0)
        XCTAssertEqual(power.enableSleepOverrideCalls, 0)
        XCTAssertEqual(power.currentSleepDisabled, false)
    }

    func testNativeHelperBlockedPreflightGenerationCannotReplayAfterReconnect() throws {
        let power = FakePowerSystem(source: .battery, sleepDisabled: false, acSleep: 5)
        let harness = try makeRuntimeHarness(
            lifetime: 5,
            power: power,
            reconciliationInterval: 0.02,
            terminalGenerationAllows: { _, _ in true },
            terminalGenerationRecord: { _, _ in false }
        )

        XCTAssertEqual(harness.runtime.run(), 0)
        XCTAssertEqual(power.enableSleepOverrideCalls, 0)
        let blockedStatus = try String(contentsOfFile: harness.configuration.statusPath, encoding: .utf8)
        XCTAssertTrue(blockedStatus.contains("session=\(harness.lease.sessionID.uuidString.lowercased())"))

        power.setSource(.ac)
        let replay = makeLease(sessionID: harness.lease.sessionID, lifetime: 5)
        try replay.storagePayload.write(toFile: harness.configuration.leasePath, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(harness.configuration.leasePath, 0o600), 0)
        let replayRuntime = HelperRuntime(
            configuration: harness.configuration,
            power: power,
            currentBootID: { replay.bootID },
            currentSystemBuild: { "25F84" },
            reconciliationInterval: 0.02,
            terminalGenerationAllows: { _, _ in true },
            terminalGenerationRecord: { _, _ in false },
            statusProjectionWrite: harness.statusProjectionWrite,
            statusProjectionRead: harness.statusProjectionRead
        )

        XCTAssertEqual(replayRuntime.run(), 0)
        XCTAssertEqual(power.enableSleepOverrideCalls, 0)
        XCTAssertEqual(power.currentSleepDisabled, false)
    }

    func testNativeHelperRetainsAppliedStateAndExitsCleanlyWhenRestoreCannotBeVerified() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5)
        power.failSleepRestore = true
        let harness = try makeRuntimeHarness(lifetime: 1, power: power)
        let code = harness.runtime.run()

        XCTAssertEqual(code, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
        XCTAssertTrue(try String(contentsOfFile: harness.configuration.statusPath).contains("state=recovery-required"))
    }

    func testNativeHelperRollsBackWhenPowerChangesDuringActivation() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5)
        power.unplugWhenEnablingSleepOverride = true
        let harness = try makeRuntimeHarness(lifetime: 5, power: power)

        let code = harness.runtime.run()

        XCTAssertEqual(code, 0)
        XCTAssertEqual(power.currentSleepDisabled, false)
        XCTAssertEqual(power.currentACSleep, 5)
        XCTAssertEqual(power.enableSleepOverrideCalls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
        XCTAssertTrue(try String(contentsOfFile: harness.configuration.statusPath).contains("state=inactive"))
    }

    func testNativeHelperRecoversMatchingAppliedSessionAfterAbnormalExit() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: true, acSleep: 0)
        let harness = try makeRuntimeHarness(lifetime: 1, power: power, preapplyState: true)
        let code = harness.runtime.run()

        XCTAssertEqual(code, 0)
        XCTAssertEqual(power.enableSleepOverrideCalls, 0)
        XCTAssertEqual(power.currentSleepDisabled, false)
        XCTAssertEqual(power.currentACSleep, 5)
    }

    func testUnknownPowerSourceNeverActivatesHelper() throws {
        let power = FakePowerSystem(source: .unknown, sleepDisabled: false, acSleep: 5)
        let harness = try makeRuntimeHarness(lifetime: 5, power: power)
        let code = harness.runtime.run()

        XCTAssertEqual(code, 0)
        XCTAssertEqual(power.enableSleepOverrideCalls, 0)
        XCTAssertEqual(power.currentSleepDisabled, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
    }

    func testLaunchDaemonIsEventDrivenAndCrashOnly() throws {
        let plist = PrivilegedHelperManager.diagnosticLaunchDaemonPlist()
        let data = try XCTUnwrap(plist.data(using: .utf8))
        let decoded = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let keepAlive = try XCTUnwrap(decoded["KeepAlive"] as? [String: Any])

        XCTAssertFalse(plist.contains("StartInterval"))
        XCTAssertNil(decoded["WatchPaths"])
        let machServices = try XCTUnwrap(decoded["MachServices"] as? [String: Any])
        XCTAssertEqual(machServices.count, 1)
        XCTAssertEqual(machServices[AppPaths.helperMachService] as? Bool, true)
        XCTAssertNil(decoded["StandardOutPath"])
        XCTAssertNil(decoded["StandardErrorPath"])
        XCTAssertFalse(plist.contains("--lease-path"))
        XCTAssertEqual(keepAlive["SuccessfulExit"] as? Bool, false)
        XCTAssertEqual(decoded["ThrottleInterval"] as? Int, 10)
    }

    func testAdministratorPathsUseOnlyVerifiedHelperOneShotsAndProofBeforeDeletion() throws {
        let install = PrivilegedHelperManager.diagnosticInstallScript()
        let uninstall = PrivilegedHelperManager.diagnosticUninstallScript()
        let restore = PrivilegedHelperManager.diagnosticRestoreScript()

        for script in [install, uninstall, restore] {
            XCTAssertTrue(script.contains("provision-root-state-lock"))
            XCTAssertTrue(script.contains("recover-once"))
            XCTAssertTrue(script.contains("administrator-receipt-v1"))
            XCTAssertFalse(script.contains("lidswitch_parse_applied_state"))
            XCTAssertFalse(script.contains("lidswitch_restore_owned_state"))
            XCTAssertFalse(script.contains("/usr/bin/pmset"))
            XCTAssertFalse(script.contains("terminal-generations recovery-reservations"))
            XCTAssertFalse(script.contains("original-ac-sleep"))
            XCTAssertFalse(script.contains("original-battery-sleep"))
            XCTAssertTrue(script.contains(".LidSwitch-administrator-"))
            XCTAssertTrue(script.contains("stage_parent="))
            XCTAssertTrue(script.contains("0:80:755:$(/usr/bin/stat -f '%d' \"$root\")"))
            XCTAssertFalse(script.contains("0:0:755:$(/usr/bin/stat -f '%d' \"$root\")"))
            XCTAssertTrue(script.contains("legacy_target="))
            XCTAssertTrue(script.contains("cleanup_verified_stage"))
        }

        let stageVerify = try XCTUnwrap(install.range(of: "/usr/bin/codesign --verify"))
        let bootout = try XCTUnwrap(install.range(of: "/bin/launchctl bootout"))
        let provision = try XCTUnwrap(install.range(of: "provision_output="))
        let recovery = try XCTUnwrap(install.range(of: "recovery_payload="))
        let deletePrevious = try XCTUnwrap(install.range(of: "/bin/rm -rf \"$previous\""))
        let publishCurrent = try XCTUnwrap(install.range(of: "/bin/mv \"$stage_current\" \"$current\""))
        let bootstrap = try XCTUnwrap(install.range(of: "/bin/launchctl bootstrap system \"$plist\"", options: [], range: publishCurrent.upperBound..<install.endIndex))
        XCTAssertLessThan(stageVerify.lowerBound, bootout.lowerBound)
        XCTAssertLessThan(bootout.lowerBound, provision.lowerBound)
        XCTAssertLessThan(provision.lowerBound, recovery.lowerBound)
        XCTAssertLessThan(recovery.lowerBound, deletePrevious.lowerBound)
        XCTAssertLessThan(deletePrevious.lowerBound, publishCurrent.lowerBound)
        XCTAssertLessThan(publishCurrent.lowerBound, bootstrap.lowerBound)

        let uninstallRecovery = try XCTUnwrap(uninstall.range(of: "recovery_payload="))
        let uninstallDeletion = try XCTUnwrap(uninstall.range(of: "/bin/rm -f \"$plist\"", options: .backwards))
        XCTAssertLessThan(uninstallRecovery.lowerBound, uninstallDeletion.lowerBound)
        XCTAssertEqual(
            AppPaths.legacyV4RootHelperVersionPath,
            "/Library/Application Support/LidSwitch/helper-version"
        )
        let legacyArtifacts = [
            AppPaths.legacyV4RootHelperPath,
            AppPaths.legacyRootHelperPath,
            AppPaths.legacyV4RootHelperVersionPath
        ].map { "'\($0)'" }.joined(separator: " ")
        let installLegacyCleanup = "/bin/rm -f \(legacyArtifacts)"
        let uninstallLegacyCleanup = "/bin/rm -f \"$plist\" \(legacyArtifacts)"
        let installLegacyMarkerDeletion = try XCTUnwrap(install.range(of: installLegacyCleanup))
        let uninstallLegacyMarkerDeletion = try XCTUnwrap(uninstall.range(of: uninstallLegacyCleanup))
        XCTAssertLessThan(bootstrap.lowerBound, installLegacyMarkerDeletion.lowerBound)
        XCTAssertLessThan(uninstallRecovery.lowerBound, uninstallLegacyMarkerDeletion.lowerBound)
        XCTAssertFalse(restore.contains(AppPaths.legacyV4RootHelperVersionPath))
        XCTAssertTrue(uninstall.contains("recovery-proof" ) == false, "private proof is helper-owned, never shell-deleted")
        XCTAssertFalse(restore.contains("/bin/rm -rf \"$current\" \"$previous\""))
    }

    func testAdministratorCommandSkipsUserZshStartupFiles() {
        let command = PrivilegedHelperManager.diagnosticAdministratorCommand(
            "/usr/bin/true\n"
        )
        XCTAssertTrue(command.hasSuffix("| /bin/zsh -f"))
        XCTAssertTrue(command.contains("/bin/zsh -f"))
        XCTAssertFalse(command.contains("/bin/zsh -l"))
    }

    func testHelperConfigurationRejectsMissingAndDuplicateArguments() {
        let valid = [
            "LidSwitchHelper", "--lease-path", "/tmp/lease", "--owner-uid", "501",
            "--qualified-build", "25F84", "--support-directory", "/tmp/support",
            "--applied-state", "/tmp/support/state", "--status-path", "/tmp/support/status",
        ]
        XCTAssertNotNil(HelperConfiguration.parse(arguments: valid))
        XCTAssertNil(HelperConfiguration.parse(arguments: Array(valid.dropLast())))
        XCTAssertNil(HelperConfiguration.parse(arguments: valid + ["--lease-path", "/tmp/other"]))
    }

    private func makeSnapshot(
        source: PowerSource,
        sleepDisabled: Bool,
        sleepDisabledVerified: Bool,
        helperNeedsUpdate: Bool = false,
        legacyLoginPresent: Bool = false,
        legacyLoginItemLoaded: Bool = false,
        lease: ActivationLease? = nil,
        status: HelperStatusRecord? = nil,
        checkedAt: Date = Date(),
        ownsLease: Bool = true,
        inventoryState: PowerInspector.InstallationInventoryState? = nil,
        activationLeaseTruth: UserStatePersistenceTruth? = nil,
        staleCanonicalLegacyLeasePresent: Bool = false
    ) -> PowerSnapshot {
        PowerSnapshot(
            source: source,
            sleepDisabled: sleepDisabled,
            sleepDisabledVerified: sleepDisabledVerified,
            acIdleSleepMinutes: 5,
            preferences: .disabled,
            desiredStateTruth: .valid,
            helperArtifactsPresent: true,
            helperLoaded: true,
            helperNeedsUpdate: helperNeedsUpdate,
            legacyLoginItemPresent: legacyLoginPresent,
            legacyLoginItemLoaded: legacyLoginItemLoaded,
            activationLease: lease,
            activationLeaseTruth: activationLeaseTruth ?? (lease == nil ? .missing : .valid),
            staleCanonicalLegacyLeasePresent: staleCanonicalLegacyLeasePresent,
            ownedSessionID: ownsLease ? lease?.sessionID : nil,
            helperStatus: status,
            systemBuild: "25F84",
            systemBuildQualified: true,
            bundleIntegrityValid: true,
            bundleVersionValid: true,
            checkedAt: checkedAt,
            installationInventoryState: inventoryState
        )
    }

    private func makeLease(
        sessionID: UUID,
        lifetime: TimeInterval,
        now: Date = Date(),
        monotonic: TimeInterval = MonotonicClock.seconds()
    ) -> ActivationLease {
        ActivationLease(
            sessionID: sessionID,
            bootID: BootIdentity.current() ?? "test-boot",
            expiresAt: now.addingTimeInterval(lifetime),
            issuedMonotonic: monotonic,
            expiresMonotonic: monotonic + lifetime,
            ownerUID: getuid(),
            systemBuild: "25F84"
        )
    }

    private func assertLeaseFailure(
        _ result: Result<ActivationLease, LeaseValidationFailure>,
        equals expected: LeaseValidationFailure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success:
            XCTFail("Expected lease failure", file: file, line: line)
        case let .failure(actual):
            XCTAssertEqual(actual, expected, file: file, line: line)
        }
    }

    private func temporaryDirectory() throws -> URL {
        try TestSandbox.makeDirectory(label: "power-inspector").url
    }

    private struct RuntimeHarness {
        let root: URL
        let configuration: HelperConfiguration
        let lease: ActivationLease
        let power: FakePowerSystem
        let heldRootSupport: HeldDirectory
        let statusProjectionWrite: (String, String, UUID?, String, [String: String]) -> Bool
        let statusProjectionRead: (String) -> HelperStatusTombstone?
        let runtime: HelperRuntime
    }

    private final class HeldDirectory {
        let descriptor: Int32

        init(_ descriptor: Int32) { self.descriptor = descriptor }
        deinit { Darwin.close(descriptor) }
    }

    private func makeRuntimeHarness(
        lifetime: TimeInterval,
        power: FakePowerSystem = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5),
        preapplyState: Bool = false,
        reconciliationInterval: TimeInterval = 2,
        terminalGenerationAllows: @escaping (UUID, String) -> Bool = { sessionID, path in
            TerminalGenerationStore.allowsActivation(sessionID: sessionID, path: path)
        },
        terminalGenerationRecord: @escaping (UUID, String) -> Bool = { sessionID, path in
            TerminalGenerationStore.record(sessionID: sessionID, path: path)
        },
        appliedStateWrite: @escaping (AppliedState, String) throws -> Void = { state, path in
            try AppliedStateStore.write(state, path: path)
        }
    ) throws -> RuntimeHarness {
        let root = try temporaryDirectory()
        let userSupport = root.appendingPathComponent("user", isDirectory: true)
        // Keep the status projection root as a direct fixture child so the
        // harness can retain TestSandbox's descriptor instead of reopening a
        // nested /private/tmp pathname from the sandboxed runtime.
        let rootSupport = try temporaryDirectory()
        try FileManager.default.createDirectory(at: userSupport, withIntermediateDirectories: false)
        let leasePath = userSupport.appendingPathComponent("activation-lease").path
        let statePath = rootSupport.appendingPathComponent("applied-state").path
        let statusPath = rootSupport.appendingPathComponent("helper-status").path
        let lease = makeLease(sessionID: UUID(), lifetime: lifetime)
        try lease.storagePayload.write(toFile: leasePath, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(leasePath, 0o600), 0)
        XCTAssertEqual(chmod(rootSupport.path, 0o755), 0)
        let authorityStore = try XCTUnwrap(
            RecoveryAuthorityStore(
                supportDirectory: rootSupport.path,
                expectations: .init(ownerUID: getuid(), groupID: getgid(), mode: 0o755),
                ancestorPolicy: .testTemporaryDirectory
            )
        )
        XCTAssertEqual(authorityStore.provision(), .ready)
        let heldRootSupport = HeldDirectory(try TestSandbox.openManagedDirectory(at: rootSupport))
        let statusExpectations = VerifiedRootStateDirectory.Expectations(
            ownerUID: getuid(), groupID: getgid(), mode: 0o755
        )
        let statusGeneration = LockedBox<UInt64>(0)
        let statusProjectionWrite: (String, String, UUID?, String, [String: String]) -> Bool = {
            state, reason, sessionID, _, evidence in
            _ = evidence
            let generation = statusGeneration.withValue { value -> UInt64 in
                value += 1
                return value
            }
            let now = UInt64(max(1, MonotonicClock.seconds() * 1_000_000_000))
            guard let task = StatusProjectionTask(
                generation: generation,
                state: state,
                reason: reason,
                sessionID: sessionID,
                deadlineNanoseconds: now &+ 60_000_000_000
            ) else { return false }
            return HelperStatusStore.write(
                task: task,
                heldDirectoryDescriptor: heldRootSupport.descriptor,
                expectations: statusExpectations
            )
        }
        let statusProjectionRead: (String) -> HelperStatusTombstone? = { _ in
            HelperStatusStore.read(
                heldDirectoryDescriptor: heldRootSupport.descriptor,
                expectations: statusExpectations
            )
        }

        if preapplyState {
            try AppliedStateStore.write(
                AppliedState(
                    sessionID: lease.sessionID,
                    changedSleepDisabled: true,
                    changedACSleep: true,
                    originalACSleep: 5
                ),
                path: statePath
            )
        }

        let configuration = HelperConfiguration(
            leasePath: leasePath,
            expectedOwnerUID: getuid(),
            qualifiedBuild: "25F84",
            supportDirectory: rootSupport.path,
            appliedStatePath: statePath,
            statusPath: statusPath
        )
        return RuntimeHarness(
            root: root,
            configuration: configuration,
            lease: lease,
            power: power,
            heldRootSupport: heldRootSupport,
            statusProjectionWrite: statusProjectionWrite,
            statusProjectionRead: statusProjectionRead,
            runtime: HelperRuntime(
                configuration: configuration,
                power: power,
                currentBootID: { lease.bootID },
                currentSystemBuild: { "25F84" },
                reconciliationInterval: reconciliationInterval,
                terminalGenerationAllows: terminalGenerationAllows,
                terminalGenerationRecord: terminalGenerationRecord,
                appliedStateWrite: appliedStateWrite,
                powerNotificationInstall: { true },
                statusProjectionWrite: statusProjectionWrite,
                statusProjectionRead: statusProjectionRead
            )
        )
    }

    /// Replacement for the retired public `recovery_budget` evidence field.
    /// It uses the production root-private store and transaction seam, so the
    /// restart tests prove the session-bound authority record instead of a
    /// mutable diagnostic projection.
    private func publishFixtureRecoveryBudget(
        _ budget: RecoveryBudgetState,
        supportDirectory: String
    ) -> Bool {
        guard let store = RecoveryAuthorityStore(
            supportDirectory: supportDirectory,
            expectations: .init(ownerUID: getuid(), groupID: getgid(), mode: 0o755),
            ancestorPolicy: .testTemporaryDirectory
        ) else { return false }
        return store.withTransaction { transaction in
            store.publishRecoveryBudget(budget, transaction).isVerified
        } ?? false
    }

    private func fixtureRecoveryBudgetRecord(
        supportDirectory: String
    ) -> RecoveryAuthorityStore.BudgetRecord? {
        RecoveryAuthorityStore(
            supportDirectory: supportDirectory,
            expectations: .init(ownerUID: getuid(), groupID: getgid(), mode: 0o755),
            ancestorPolicy: .testTemporaryDirectory
        )?.recoveryBudgetRecord()
    }
}

private final class FakePowerSystem: HelperPowerSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var source: HelperPowerSource
    private var sleepDisabledValue: Bool?
    private var acSleepValue: Int?
    private var enableCalls = 0
    private var sleepDisabledMutationCount = 0
    private var acSleepMutationCount = 0
    private var failRestoreValue = false
    private var failEnableValue = false
    private var unplugOnEnableValue = false
    private var unplugOnEnableAfterCallValue: Int?
    private var sleepRestoreObserver: (() -> Void)?
    private var sleepDisabledSequence: [Bool?] = []
    private var acSleepSequence: [Int?] = []
    private var sleepReadCalls = 0
    private var acReadCalls = 0

    init(source: HelperPowerSource, sleepDisabled: Bool?, acSleep: Int?) {
        self.source = source
        sleepDisabledValue = sleepDisabled
        acSleepValue = acSleep
    }

    var currentSleepDisabled: Bool? { withLock { sleepDisabledValue } }
    var currentACSleep: Int? { withLock { acSleepValue } }
    var enableSleepOverrideCalls: Int { withLock { enableCalls } }
    var sleepDisabledMutationCalls: Int { withLock { sleepDisabledMutationCount } }
    var acSleepMutationCalls: Int { withLock { acSleepMutationCount } }
    var sleepDisabledReadCalls: Int { withLock { sleepReadCalls } }
    var acSleepReadCalls: Int { withLock { acReadCalls } }
    var failSleepRestore: Bool {
        get { withLock { failRestoreValue } }
        set { withLock { failRestoreValue = newValue } }
    }
    var failSleepEnable: Bool {
        get { withLock { failEnableValue } }
        set { withLock { failEnableValue = newValue } }
    }
    var unplugWhenEnablingSleepOverride: Bool {
        get { withLock { unplugOnEnableValue } }
        set { withLock { unplugOnEnableValue = newValue } }
    }
    var unplugOnEnableAfterCall: Int? {
        get { withLock { unplugOnEnableAfterCallValue } }
        set { withLock { unplugOnEnableAfterCallValue = newValue } }
    }
    var onSleepRestore: (() -> Void)? {
        get { withLock { sleepRestoreObserver } }
        set { withLock { sleepRestoreObserver = newValue } }
    }

    func setSource(_ source: HelperPowerSource) {
        withLock { self.source = source }
    }

    func forceSleepDisabled(_ enabled: Bool) {
        withLock { sleepDisabledValue = enabled }
    }

    func forceSleepDisabledUnknown() {
        withLock { sleepDisabledValue = nil }
    }

    func setSleepDisabledReadSequence(_ values: [Bool?]) {
        withLock { sleepDisabledSequence = values }
    }

    func forceACSleep(_ minutes: Int) {
        withLock { acSleepValue = minutes }
    }

    func forceACSleepUnknown() {
        withLock { acSleepValue = nil }
    }

    func setACSleepReadSequence(_ values: [Int?]) {
        withLock { acSleepSequence = values }
    }

    func powerSource() -> HelperPowerSource { withLock { source } }
    func sleepDisabled() -> Bool? {
        withLock {
            sleepReadCalls += 1
            if !sleepDisabledSequence.isEmpty {
                return sleepDisabledSequence.removeFirst()
            }
            return sleepDisabledValue
        }
    }
    func acSleepMinutes() -> Int? {
        withLock {
            acReadCalls += 1
            if !acSleepSequence.isEmpty {
                return acSleepSequence.removeFirst()
            }
            return acSleepValue
        }
    }

    func setSleepDisabled(_ enabled: Bool) throws {
        try withLock {
            sleepDisabledMutationCount += 1
            if !enabled, failRestoreValue {
                throw NSError(domain: "FakePowerSystem", code: 1)
            }
            if !enabled {
                sleepRestoreObserver?()
            }
            if enabled {
                enableCalls += 1
                if failEnableValue {
                    throw NSError(domain: "FakePowerSystem", code: 2)
                }
                if unplugOnEnableValue || unplugOnEnableAfterCallValue == enableCalls {
                    source = .battery
                }
            }
            sleepDisabledValue = enabled
        }
    }

    func setACSleepMinutes(_ minutes: Int) throws {
        withLock {
            acSleepMutationCount += 1
            acSleepValue = minutes
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get { withValue { $0 } }
        set { withValue { $0 = newValue } }
    }

    @discardableResult
    func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&storage)
    }
}

private enum TestError: Error {
    case commitRejected
}
