import Darwin
import Foundation
import XCTest
@testable import LidSwitch

private final class BarrierBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&storage)
        lock.unlock()
    }
}

final class HeartbeatComparatorBarrierTests: XCTestCase {
    func testComparatorRejectsUnsafeOperandsAndReadFaultsWithoutBlocking() throws {
        let root = try TestSandbox.makeDirectory(label: "heartbeat-compare").url
        let installed = root.appendingPathComponent("installed")
        let bundled = root.appendingPathComponent("bundled")
        try Data("same-bytes".utf8).write(to: installed)
        try Data("same-bytes".utf8).write(to: bundled)
        XCTAssertEqual(chmod(installed.path, 0o600), 0)
        XCTAssertEqual(chmod(bundled.path, 0o600), 0)
        XCTAssertTrue(BoundedHelperComparator.matches(
            installed: installed.path, bundled: bundled.path, maximumBytes: 128, expectedInstalledOwner: getuid()
        ))

        let empty = root.appendingPathComponent("empty")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        XCTAssertFalse(BoundedHelperComparator.matches(
            installed: empty.path, bundled: bundled.path, maximumBytes: 128, expectedInstalledOwner: getuid()
        ))

        let link = root.appendingPathComponent("link")
        XCTAssertEqual(symlink(installed.path, link.path), 0)
        XCTAssertFalse(BoundedHelperComparator.matches(
            installed: link.path, bundled: bundled.path, maximumBytes: 128, expectedInstalledOwner: getuid()
        ))

        let directory = root.appendingPathComponent("directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertFalse(BoundedHelperComparator.matches(
            installed: directory.path, bundled: bundled.path, maximumBytes: 128, expectedInstalledOwner: getuid()
        ))

        let fifo = root.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertFalse(BoundedHelperComparator.matches(
            installed: fifo.path, bundled: bundled.path, maximumBytes: 128, expectedInstalledOwner: getuid()
        ))

        XCTAssertFalse(BoundedHelperComparator.regularMetadataIsSafe(
            mode: mode_t(S_IFREG) | 0o600,
            ownerUID: getuid(),
            linkCount: 2,
            size: 10,
            allowedOwners: [getuid()],
            maximumBytes: 128
        ))
        try Data(repeating: 0x5A, count: 129).write(to: installed)
        try Data(repeating: 0x5A, count: 129).write(to: bundled)
        XCTAssertFalse(BoundedHelperComparator.matches(
            installed: installed.path, bundled: bundled.path, maximumBytes: 128, expectedInstalledOwner: getuid()
        ))
        try Data("same-bytes".utf8).write(to: installed)
        try Data("same-bytes".utf8).write(to: bundled)
        let equalLengthDifferentBytes = Data("other-data".utf8)
        XCTAssertEqual(equalLengthDifferentBytes.count, Data("same-bytes".utf8).count)
        try equalLengthDifferentBytes.write(to: bundled)
        XCTAssertFalse(BoundedHelperComparator.matches(
            installed: installed.path, bundled: bundled.path, maximumBytes: 128, expectedInstalledOwner: getuid()
        ))
        try Data("same-bytes".utf8).write(to: bundled)

        let interrupted = BarrierBox(false)
        let interruptedControls = BoundedHelperComparatorControls(readDirective: { operand, phase in
            guard operand == .installed, phase == .body, !interrupted.value else { return .system }
            interrupted.mutate { $0 = true }
            return .interrupted
        })
        XCTAssertTrue(BoundedHelperComparator.matches(
            installed: installed.path, bundled: bundled.path, maximumBytes: 128,
            expectedInstalledOwner: getuid(), controls: interruptedControls
        ))
        XCTAssertTrue(interrupted.value)

        let descriptorMutation = BoundedHelperComparatorControls(beforeFinalMetadata: {
            let descriptor = open(installed.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            _ = ftruncate(descriptor, 0)
        })
        XCTAssertFalse(BoundedHelperComparator.matches(
            installed: installed.path, bundled: bundled.path, maximumBytes: 128,
            expectedInstalledOwner: getuid(), controls: descriptorMutation
        ))
        try Data("same-bytes".utf8).write(to: installed)

        let earlyEOF = BoundedHelperComparatorControls(readDirective: { operand, phase in
            operand == .bundled && phase == .body ? .endOfFile : .system
        })
        XCTAssertFalse(BoundedHelperComparator.matches(
            installed: installed.path, bundled: bundled.path, maximumBytes: 128,
            expectedInstalledOwner: getuid(), controls: earlyEOF
        ))
    }

    func testComparatorRejectsSameSizeLeafReplacementAfterExactRead() throws {
        let root = try TestSandbox.makeDirectory(label: "compare-replace").url
        let installed = root.appendingPathComponent("installed")
        let bundled = root.appendingPathComponent("bundled")
        let replacement = root.appendingPathComponent("replacement")
        try Data("same-bytes".utf8).write(to: installed)
        try Data("same-bytes".utf8).write(to: bundled)
        try Data("other-data".utf8).write(to: replacement)
        XCTAssertEqual(chmod(installed.path, 0o600), 0)
        XCTAssertEqual(chmod(bundled.path, 0o600), 0)
        XCTAssertEqual(chmod(replacement.path, 0o600), 0)
        let controls = BoundedHelperComparatorControls(beforeFinalMetadata: {
            _ = rename(replacement.path, installed.path)
        })
        XCTAssertFalse(BoundedHelperComparator.matches(
            installed: installed.path, bundled: bundled.path, maximumBytes: 128,
            expectedInstalledOwner: getuid(), controls: controls
        ))
    }

    func testTerminalBarrierBlocksAuthorizedStopAndSafetyCallbackUntilDirectlyDecodedEvidenceIsDurable() throws {
        try assertTerminalBarrier(reason: "user-end", safetyEnd: false)
        try assertTerminalBarrier(reason: "power-disconnected", safetyEnd: true)
    }

    func testFailedStructuralPublicationRemainsQueuedAndFlushResultIsObservable() throws {
        let root = try TestSandbox.makeDirectory(label: "queued-diagnostics").url
        let file = root.appendingPathComponent("history.json")
        let publisherMaySucceed = BarrierBox(false)
        let initialFailure = DispatchSemaphore(value: 0)
        let sessionID = UUID()
        let store = SessionDiagnosticStore(
            file: file,
            publisher: { data in
                guard publisherMaySucceed.value else {
                    initialFailure.signal()
                    throw POSIXError(.EIO)
                }
                try data.write(to: file)
                guard chmod(file.path, 0o600) == 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
            }
        )
        store.record(event: "start", reason: "lease-issued", sessionID: sessionID)
        XCTAssertEqual(initialFailure.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(store.flushStructuralSynchronously())

        publisherMaySucceed.mutate { $0 = true }
        XCTAssertTrue(store.flushStructuralSynchronously())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([SessionDiagnosticEntry].self, from: Data(contentsOf: file))
        XCTAssertEqual(entries.map(\.event), ["start"])
        XCTAssertEqual(entries.map(\.sessionID), [sessionID.uuidString.lowercased()])
    }

    func testCoordinatorStopReconcilesWriteThenThrowWithoutDuplicatingTerminalRecords() throws {
        let root = try TestSandbox.makeDirectory(label: "stop-flush-failure").url
        let file = root.appendingPathComponent("history.json")
        let throwAfterCommit = BarrierBox(false)
        let remoteEnds = BarrierBox(0)
        let sessionID = UUID()
        let store = SessionDiagnosticStore(
            file: file,
            publisher: { data in
                let temporary = file.deletingLastPathComponent().appendingPathComponent("post-commit-\(UUID().uuidString)")
                try data.write(to: temporary)
                guard chmod(temporary.path, 0o600) == 0,
                      rename(temporary.path, file.path) == 0
                else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                if throwAfterCommit.value { throw POSIXError(.EIO) }
            }
        )
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 3_600,
            observe: { _ in SessionHeartbeatObservation(power: .ac, leaseIsValid: true, helperStatus: nil) },
            renew: { _, _ in 30 },
            revoke: {},
            endRemote: { _, _ in remoteEnds.mutate { $0 += 1 } },
            diagnostics: store,
            onAcknowledged: { _ in },
            onEnded: { _, _ in XCTFail("explicit stop must not emit a safety callback") }
        )
        coordinator.start(sessionID: sessionID, initialLeaseExpiresMonotonic: 30, initiallyAcknowledged: true)
        XCTAssertTrue(store.flushStructuralSynchronously())
        throwAfterCommit.mutate { $0 = true }
        XCTAssertFalse(coordinator.stop(reason: "user-end"))
        XCTAssertEqual(remoteEnds.value, 1)

        throwAfterCommit.mutate { $0 = false }
        XCTAssertTrue(store.flushStructuralSynchronously())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([SessionDiagnosticEntry].self, from: Data(contentsOf: file))
        let sameSession = entries.filter { $0.sessionID == sessionID.uuidString.lowercased() }
        XCTAssertEqual(sameSession.map(\.event), ["start", "end"])
        XCTAssertEqual(sameSession.map(\.reason), ["lease-issued", "user-end"])
    }

    func testSafetyEndCallsRestoreAndCallbackDespiteFailedDiagnosticsThenLaterPersistsOneTerminalPair() throws {
        let root = try TestSandbox.makeDirectory(label: "safety-flush-failure").url
        let file = root.appendingPathComponent("history.json")
        let publisherMaySucceed = BarrierBox(false)
        let initialFailure = DispatchSemaphore(value: 0)
        let restores = BarrierBox(0)
        let callbackObserved = BarrierBox(false)
        let sessionID = UUID()
        let store = SessionDiagnosticStore(
            file: file,
            publisher: { data in
                guard publisherMaySucceed.value else {
                    initialFailure.signal()
                    throw POSIXError(.EIO)
                }
                try data.write(to: file)
                guard chmod(file.path, 0o600) == 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
            }
        )
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 3_600,
            observe: { _ in SessionHeartbeatObservation(power: .disconnected, leaseIsValid: false, helperStatus: nil) },
            renew: { _, _ in 30 },
            revoke: { restores.mutate { $0 += 1 } },
            diagnostics: store,
            onAcknowledged: { _ in },
            onEnded: { _, _ in callbackObserved.mutate { $0 = true } }
        )
        coordinator.start(sessionID: sessionID, initialLeaseExpiresMonotonic: 30, initiallyAcknowledged: true)
        XCTAssertEqual(initialFailure.wait(timeout: .now() + 1), .success)
        coordinator.evaluateForTesting()
        XCTAssertEqual(restores.value, 1)
        XCTAssertTrue(callbackObserved.value)
        XCTAssertFalse(store.flushStructuralSynchronously())

        publisherMaySucceed.mutate { $0 = true }
        XCTAssertTrue(store.flushStructuralSynchronously())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([SessionDiagnosticEntry].self, from: Data(contentsOf: file))
        let sameSession = entries.filter { $0.sessionID == sessionID.uuidString.lowercased() }
        XCTAssertEqual(sameSession.map(\.event), ["start", "end"])
        XCTAssertEqual(sameSession.map(\.reason), ["lease-issued", "power-disconnected"])
    }

    func testRenewalSummaryPrecedesNextStructuralEventAndFailureRetriesDoNotMaterializeFreshRenewals() throws {
        let root = try TestSandbox.makeDirectory(label: "renewal-order").url
        let file = root.appendingPathComponent("history.json")
        let clock = BarrierBox(Date(timeIntervalSince1970: 1_000))
        let sessionID = UUID()
        let store = SessionDiagnosticStore(
            file: file,
            renewalFlushInterval: 300,
            now: { clock.value },
            publisher: { data in
                try data.write(to: file)
                guard chmod(file.path, 0o600) == 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
            }
        )
        store.record(event: "start", reason: "lease-issued", sessionID: sessionID)
        XCTAssertTrue(store.flushStructuralSynchronously())
        store.recordRenewal(reason: "safety-probes-valid", sessionID: sessionID)
        clock.mutate { $0 = $0.addingTimeInterval(8) }
        store.recordRenewal(reason: "safety-probes-valid", sessionID: sessionID)
        XCTAssertTrue(store.flushForTesting(), "test flush materializes the pending renewal aggregate")
        store.record(event: "end", reason: "user-end", sessionID: sessionID)
        XCTAssertTrue(store.flushStructuralSynchronously())

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ordered = try decoder.decode([SessionDiagnosticEntry].self, from: Data(contentsOf: file))
        XCTAssertEqual(ordered.map(\.event), ["start", "renew-summary", "end"])
        XCTAssertEqual(ordered.map(\.renewalCount), [nil, 2, nil])

        let failedFile = root.appendingPathComponent("failed-history.json")
        let publisherMaySucceed = BarrierBox(false)
        let initialFailure = DispatchSemaphore(value: 0)
        let attemptedPayloads = BarrierBox([Data]())
        let retryClock = BarrierBox(Date(timeIntervalSince1970: 2_000))
        let retryStore = SessionDiagnosticStore(
            file: failedFile,
            renewalFlushInterval: 300,
            now: { retryClock.value },
            publisher: { data in
                attemptedPayloads.mutate { $0.append(data) }
                guard publisherMaySucceed.value else {
                    initialFailure.signal()
                    throw POSIXError(.EIO)
                }
                try data.write(to: failedFile)
                guard chmod(failedFile.path, 0o600) == 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
            }
        )
        retryStore.recordRenewal(reason: "safety-probes-valid", sessionID: sessionID)
        retryClock.mutate { $0 = $0.addingTimeInterval(300) }
        retryStore.recordRenewal(reason: "safety-probes-valid", sessionID: sessionID)
        XCTAssertEqual(initialFailure.wait(timeout: .now() + 1), .success)
        retryClock.mutate { $0 = $0.addingTimeInterval(8) }
        retryStore.recordRenewal(reason: "safety-probes-valid", sessionID: sessionID)
        XCTAssertFalse(retryStore.flushStructuralSynchronously())
        let retryPayload = try XCTUnwrap(attemptedPayloads.value.last)
        let retryEntries = try decoder.decode([SessionDiagnosticEntry].self, from: retryPayload)
        XCTAssertEqual(retryEntries.map(\.event), ["renew-summary"])
        XCTAssertEqual(retryEntries.map(\.renewalCount), [2])
        publisherMaySucceed.mutate { $0 = true }
        retryStore.record(event: "end", reason: "user-end", sessionID: sessionID)
        XCTAssertTrue(retryStore.flushStructuralSynchronously())
        let retried = try decoder.decode([SessionDiagnosticEntry].self, from: Data(contentsOf: failedFile))
        XCTAssertEqual(retried.map(\.event), ["renew-summary", "renew-summary", "end"])
        XCTAssertEqual(retried.map(\.renewalCount), [2, 1, nil])
    }

    func testWriterLifetimeRetainsAcceptedWorkButCancelsNonSharedRetriesAfterExternalRelease() throws {
        let root = try TestSandbox.makeDirectory(label: "writer-lifetime").url
        let file = root.appendingPathComponent("history.json")
        let preDrainEntered = DispatchSemaphore(value: 0)
        let releasePreDrain = DispatchSemaphore(value: 0)
        let writerEntered = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        let published = DispatchSemaphore(value: 0)
        let releasedAfterSuccess = DispatchSemaphore(value: 0)
        weak var weakStore: SessionDiagnosticStore?
        var store: SessionDiagnosticStore? = SessionDiagnosticStore(
            file: file,
            publisher: { data in
                writerEntered.signal()
                _ = releaseWriter.wait(timeout: .now() + 2)
                try data.write(to: file)
                guard chmod(file.path, 0o600) == 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                published.signal()
            },
            beforeDrain: {
                preDrainEntered.signal()
                _ = releasePreDrain.wait(timeout: .now() + 2)
            },
            onDeinit: { releasedAfterSuccess.signal() }
        )
        weakStore = store
        store?.record(event: "start", reason: "lease-issued", sessionID: UUID())
        XCTAssertEqual(preDrainEntered.wait(timeout: .now() + 1), .success)
        store = nil
        XCTAssertNotNil(weakStore, "accepted work retains the store before writer execution")
        releasePreDrain.signal()
        XCTAssertEqual(writerEntered.wait(timeout: .now() + 1), .success)
        XCTAssertNotNil(weakStore, "active publication retains the store")
        releaseWriter.signal()
        XCTAssertEqual(published.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(releasedAfterSuccess.wait(timeout: .now() + 2), .success)
        XCTAssertNil(weakStore)
        XCTAssertFalse(try Data(contentsOf: file).isEmpty)

        let failedFile = root.appendingPathComponent("failed-history.json")
        let initialFailure = DispatchSemaphore(value: 0)
        let releaseInitialFailure = DispatchSemaphore(value: 0)
        let retryObserved = DispatchSemaphore(value: 0)
        let releasedAfterFailure = DispatchSemaphore(value: 0)
        let attempts = BarrierBox(0)
        weak var weakFailedStore: SessionDiagnosticStore?
        var failedStore: SessionDiagnosticStore? = SessionDiagnosticStore(
            file: failedFile,
            publisher: { _ in
                let attempt = attempts.value
                attempts.mutate { $0 += 1 }
                if attempt == 0 {
                    initialFailure.signal()
                    _ = releaseInitialFailure.wait(timeout: .now() + 2)
                } else {
                    retryObserved.signal()
                }
                throw POSIXError(.EIO)
            },
            onDeinit: { releasedAfterFailure.signal() }
        )
        weakFailedStore = failedStore
        failedStore?.record(event: "start", reason: "lease-issued", sessionID: UUID())
        XCTAssertEqual(initialFailure.wait(timeout: .now() + 1), .success)
        failedStore = nil
        releaseInitialFailure.signal()
        XCTAssertEqual(releasedAfterFailure.wait(timeout: .now() + 2), .success)
        XCTAssertNil(weakFailedStore)
        XCTAssertEqual(retryObserved.wait(timeout: .now() + 0.2), .timedOut)
    }

    private func assertTerminalBarrier(reason: String, safetyEnd: Bool) throws {
        let root = try TestSandbox.makeDirectory(label: "terminal-barrier").url
        let file = root.appendingPathComponent("history.json")
        let writerEntered = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        let callbackObserved = BarrierBox(false)
        let terminalReturned = DispatchSemaphore(value: 0)
        let remoteTermination = DispatchSemaphore(value: 0)
        let sessionID = UUID()
        let store = SessionDiagnosticStore(
            file: file,
            publisher: { data in
                let payload = String(decoding: data, as: UTF8.self)
                if payload.contains("\"event\":\"end\"") {
                    writerEntered.signal()
                    _ = releaseWriter.wait(timeout: .now() + 2)
                }
                try data.write(to: file)
                guard chmod(file.path, 0o600) == 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
            }
        )
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 3_600,
            observe: { _ in
                safetyEnd
                    ? SessionHeartbeatObservation(power: .disconnected, leaseIsValid: false, helperStatus: nil)
                    : SessionHeartbeatObservation(power: .ac, leaseIsValid: true, helperStatus: nil)
            },
            renew: { _, _ in 30 },
            revoke: { remoteTermination.signal() },
            endRemote: { _, _ in remoteTermination.signal() },
            diagnostics: store,
            onAcknowledged: { _ in },
            onEnded: { _, _ in callbackObserved.mutate { $0 = true } }
        )
        coordinator.start(sessionID: sessionID, initialLeaseExpiresMonotonic: 30, initiallyAcknowledged: true)
        XCTAssertTrue(store.flushStructuralSynchronously(), "start must be durable before terminal publication blocks")

        DispatchQueue.global().async {
            if safetyEnd {
                coordinator.evaluateForTesting()
            } else {
                coordinator.stop(reason: reason)
            }
            terminalReturned.signal()
        }
        XCTAssertEqual(remoteTermination.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(writerEntered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(terminalReturned.wait(timeout: .now() + 0.1), .timedOut)
        XCTAssertFalse(callbackObserved.value)

        releaseWriter.signal()
        XCTAssertEqual(terminalReturned.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(callbackObserved.value, safetyEnd)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([SessionDiagnosticEntry].self, from: Data(contentsOf: file))
        let sameSession = entries.filter { $0.sessionID == sessionID.uuidString.lowercased() }
        XCTAssertEqual(sameSession.map(\.event), ["start", "end"])
        XCTAssertEqual(sameSession.map(\.reason), ["lease-issued", reason])
    }
}
