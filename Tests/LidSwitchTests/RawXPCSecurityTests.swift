import Darwin
import Foundation
import LidSwitchXPCBridge
import XCTest
@testable import LidSwitch
@testable import LidSwitchCore
@testable import LidSwitchHelper

final class RawXPCSecurityTests: XCTestCase {
    private static let fixtureBootID = "00000000-0000-4000-8000-000000000001"

    func testAuthorityFixtureBootIdentityIsNormalizedSchemaTwoUUID() {
        XCTAssertEqual(BootIdentity.normalizeBootSessionUUID(Self.fixtureBootID), Self.fixtureBootID)
    }

    func testEnrollmentPolicyRejectsUnknownDuplicateAndMalformedPins() throws {
        let policy = fixturePolicy()
        XCTAssertEqual(EnrollmentPolicy.parse(policy.storagePayload), policy)
        XCTAssertNil(EnrollmentPolicy.parse(policy.storagePayload + "unknown=value\n"))
        XCTAssertNil(EnrollmentPolicy.parse(policy.storagePayload + "owner_uid=501\n"))
        XCTAssertNil(EnrollmentPolicy.parse(policy.storagePayload.replacingOccurrences(of: "app_cdhash=", with: "app_cdhash=zz")))
        XCTAssertNil(EnrollmentPolicy.parse(String(repeating: "x", count: EnrollmentPolicy.maximumBytes + 1)))
    }

    func testMissingTerminalLedgerDeniesActivation() throws {
        let directory = try TestSandbox.makeDirectory(label: "missing-terminal")
        let missing = directory.url.appendingPathComponent("missing-ledger").path
        XCTAssertFalse(TerminalGenerationStore.allowsActivation(sessionID: UUID(), path: missing))
        XCTAssertFalse(TerminalGenerationStore.allowsNewSessions(path: missing))
    }

    func testTerminalLedgerFailsClosedAtEveryDurabilityStage() throws {
        for failed in 0..<5 {
            let directory = try TestSandbox.makeDirectory(label: "terminal-stage").url
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent("terminal-generations").path
            XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o644]))
            let operations = TerminalGenerationStore.DurabilityOperations(
                fileBarrier: { _ in failed != 0 },
                rename: { source, destination in failed != 1 && Darwin.rename(source, destination) == 0 },
                directoryBarrier: { _ in failed != 2 },
                finalFileBarrier: { _ in failed != 3 },
                verify: { _, _ in failed != 4 }
            )
            XCTAssertFalse(TerminalGenerationStore.record(sessionID: UUID(), path: path, operations: operations))
        }
    }

    func testAuthorityRejectsSecondConnectionStaleRenewalAndTerminalReplay() throws {
        let fixture = try AuthorityFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let authority = HelperSessionAuthority(configuration: fixture.configuration, power: fixture.power,
                                               recoveryStoreFactory: fixture.recoveryStoreFactory,
                                               statusProjectionWriter: fixture.statusProjectionWriter)
        XCTAssertEqual(authority.prepareBeforeListening(), .ready)
        let session = UUID()
        XCTAssertEqual(authority.handle(connection: 1, operation: 1, sessionID: session).result, 0)
        XCTAssertNotEqual(authority.handle(connection: 2, operation: 4, sessionID: session).result, 0)
        let stale = authority.handle(connection: 1, operation: 2, sessionID: UUID())
        XCTAssertNotEqual(stale.result, 0)
        XCTAssertEqual(stale.reason, "stale-renewal")
        XCTAssertEqual(authority.handle(connection: 1, operation: 3, sessionID: session).result, 0)
        let userSession = UUID()
        XCTAssertEqual(authority.handle(connection: 1, operation: 1, sessionID: userSession).result, 0)
        let ended = authority.handle(connection: 1, operation: 3, sessionID: userSession)
        XCTAssertEqual(ended.result, 0)
        XCTAssertEqual(ended.reason, "user-end")
        let terminalSnapshot = authority.handle(connection: 1, operation: 4, sessionID: userSession)
        XCTAssertEqual(terminalSnapshot.state, 2)
        XCTAssertEqual(terminalSnapshot.reason, "user-end")
        XCTAssertNotEqual(authority.handle(connection: 1, operation: 1, sessionID: userSession).result, 0)
    }

    func testRenewalPublishesExactReconnectExpiry() throws {
        let fixture = try AuthorityFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let authority = HelperSessionAuthority(configuration: fixture.configuration, power: fixture.power,
                                               recoveryStoreFactory: fixture.recoveryStoreFactory,
                                               statusProjectionWriter: fixture.statusProjectionWriter)
        XCTAssertEqual(authority.prepareBeforeListening(), .ready)
        let session = UUID()
        XCTAssertEqual(authority.handle(connection: 1, operation: UInt32(LS_OPERATION_BEGIN.rawValue), sessionID: session).result, 0)
        let before = try XCTUnwrap(fixture.privateApplied())
        let renewed = authority.handle(connection: 1, operation: UInt32(LS_OPERATION_RENEW.rawValue), sessionID: session)
        let after = try XCTUnwrap(fixture.privateApplied())
        XCTAssertEqual(renewed.result, 0)
        XCTAssertEqual(after.leaseExpiryMonotonic, renewed.expiryMonotonic)
        XCTAssertGreaterThanOrEqual(after.leaseExpiryMonotonic ?? 0, before.leaseExpiryMonotonic ?? 0)
        XCTAssertTrue(after.isReconnectable)
    }

    func testFailedRenewalPublicationNeverExtendsAuthority() throws {
        let fixture = try AuthorityFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let writes = SecurityBox(0)
        let authority = HelperSessionAuthority(configuration: fixture.configuration, power: fixture.power,
                                               appliedStatePublish: { state, store, transaction in
            let shouldFail = writes.withValue { count -> Bool in count += 1; return count > 1 }
            return shouldFail ? .notPublished(.finalMetadata) : store.publishApplied(state, transaction)
        }, recoveryStoreFactory: fixture.recoveryStoreFactory,
           statusProjectionWriter: fixture.statusProjectionWriter)
        XCTAssertEqual(authority.prepareBeforeListening(), .ready)
        let session = UUID()
        let begin = authority.handle(connection: 1, operation: UInt32(LS_OPERATION_BEGIN.rawValue), sessionID: session)
        let renewal = authority.handle(connection: 1, operation: UInt32(LS_OPERATION_RENEW.rawValue), sessionID: session)
        XCTAssertEqual(begin.result, 0)
        XCTAssertNotEqual(renewal.result, 0)
        XCTAssertNotEqual(renewal.state, 1)
    }

    func testRestartAfterMultipleRenewalsBindsLatestDurableExpiry() throws {
        let fixture = try AuthorityFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let clock = SecurityBox<TimeInterval>(100)
        var peer = ls_peer_identity_t()
        XCTAssertTrue(ls_peer_identity_for_current_process(&peer))
        let session = UUID()
        let authority = HelperSessionAuthority(configuration: fixture.configuration, power: fixture.power,
                                               recoveryStoreFactory: fixture.recoveryStoreFactory,
                                               statusProjectionWriter: fixture.statusProjectionWriter,
                                               monotonicNow: { clock.value }, peerIsLive: { _ in true }, bootIdentity: { Self.fixtureBootID })
        XCTAssertEqual(authority.prepareBeforeListening(), .ready)
        XCTAssertEqual(authority.handle(connection: 1, peer: peer, operation: UInt32(LS_OPERATION_BEGIN.rawValue), sessionID: session).result, 0)
        clock.withValue { $0 = 108 }
        XCTAssertEqual(authority.handle(connection: 1, peer: peer, operation: UInt32(LS_OPERATION_RENEW.rawValue), sessionID: session).result, 0)
        clock.withValue { $0 = 116 }
        let latest = authority.handle(connection: 1, peer: peer, operation: UInt32(LS_OPERATION_RENEW.rawValue), sessionID: session)
        XCTAssertEqual(latest.result, 0)
        XCTAssertEqual(try XCTUnwrap(fixture.privateApplied()).leaseExpiryMonotonic, latest.expiryMonotonic)

        clock.withValue { $0 = 120 }
        let restarted = HelperSessionAuthority(configuration: fixture.configuration, power: fixture.power,
                                               recoveryStoreFactory: fixture.recoveryStoreFactory,
                                               statusProjectionWriter: fixture.statusProjectionWriter,
                                               monotonicNow: { clock.value }, peerIsLive: { _ in true }, bootIdentity: { Self.fixtureBootID })
        XCTAssertEqual(restarted.prepareBeforeListening(), .ready)
        let reconnect = restarted.handle(connection: 2, peer: peer, operation: UInt32(LS_OPERATION_RECONNECT.rawValue), sessionID: session)
        XCTAssertEqual(reconnect.result, 0)
        XCTAssertEqual(reconnect.expiryMonotonic, latest.expiryMonotonic)
    }

    func testLegacyLeaseIsAbsentFromProductionAuthorityAndPlist() throws {
        let plist = PrivilegedHelperManager.diagnosticLaunchDaemonPlist()
        XCTAssertTrue(plist.contains("<key>MachServices</key>"))
        XCTAssertFalse(plist.contains("WatchPaths"))
        XCTAssertFalse(plist.contains("--lease-path"))
        XCTAssertFalse(plist.contains("StandardOutPath"))
        XCTAssertFalse(plist.contains("StandardErrorPath"))
        let main = try source("Sources/LidSwitchHelper/main.swift")
        XCTAssertTrue(main.contains("HelperControlService.execute"))
        XCTAssertFalse(main.contains("HelperRuntime(configuration:"))
    }

    func testSafeEnvelopeBindsCandidateLivenessToCanonicalRenewalNotLegacyResidue() throws {
        let envelope = try source("script/live_state_envelope.sh")
        let candidate = try XCTUnwrap(envelope.range(of: "candidate-status-renewal"))
        let legacy = try XCTUnwrap(envelope.range(of: "legacy-user-lease"))
        XCTAssertLessThan(candidate.lowerBound, legacy.lowerBound)
        XCTAssertTrue(envelope.contains("LIDSWITCH_CANDIDATE_STEADY_REASONS=\"verified renewed reconnected override-recovered\""))
        XCTAssertTrue(envelope.contains("LIDSWITCH_TRANSITIONAL_REASONS=\"reconnect-pending override-drift-observed\""))
        XCTAssertTrue(envelope.contains("live_envelope_capture_idle_lease \"$real_home\""))
        XCTAssertTrue(envelope.contains("live_envelope_capture_legacy_lease"))
        XCTAssertTrue(envelope.contains("\"${phase}.expired\" \"$real_home\" none expired"))
        XCTAssertTrue(envelope.contains("\"$LIVE_LEASE_EXPIRES\" -le \"$now\""))
        XCTAssertTrue(envelope.contains("expires <= current"))
        XCTAssertTrue(envelope.contains("live_envelope_numeric_strictly_increased"))
        XCTAssertTrue(envelope.contains("$right\" == \"renewed\" || \"$right\" == \"override-recovered"))
        XCTAssertTrue(envelope.contains("renewal-did-not-advance"))
        XCTAssertFalse(envelope.contains("reconnect-pending renewed"))
    }

    func testRestoreAfterTerminalPreservesOriginalSessionAndReasonAcrossRestart() throws {
        let fixture = try AuthorityFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let authority = HelperSessionAuthority(configuration: fixture.configuration, power: fixture.power,
                                               recoveryStoreFactory: fixture.recoveryStoreFactory,
                                               statusProjectionWriter: fixture.statusProjectionWriter)
        XCTAssertEqual(authority.prepareBeforeListening(), .ready)
        let session = UUID()
        XCTAssertEqual(authority.handle(connection: 7, operation: 1, sessionID: session).result, 0)
        fixture.power.source = .battery
        let disconnected = authority.handle(connection: 7, operation: 2, sessionID: session)
        XCTAssertEqual(disconnected.reason, "ac-disconnect")
        let retry = authority.handle(connection: 7, operation: 5, sessionID: UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)))
        XCTAssertEqual(retry.state, 2)
        XCTAssertEqual(retry.sessionID, session)
        XCTAssertEqual(retry.reason, "ac-disconnect")

        let restarted = HelperSessionAuthority(configuration: fixture.configuration, power: fixture.power,
                                               recoveryStoreFactory: fixture.recoveryStoreFactory,
                                               statusProjectionWriter: fixture.statusProjectionWriter)
        XCTAssertEqual(restarted.prepareBeforeListening(), .ready)
        let afterRestart = restarted.handle(connection: 7, operation: 4, sessionID: session)
        XCTAssertEqual(afterRestart.sessionID, session)
        XCTAssertEqual(afterRestart.reason, "ac-disconnect")
    }

    func testClientRejectsOperationReplyBindingAndUnsafeExpiryBeforeAuthorityCanUseIt() throws {
        let session = UUID()
        XCTAssertNoThrow(try RawHelperControlClient.validateSuccessfulReply(
            operation: UInt32(LS_OPERATION_RENEW.rawValue), requestedSessionID: session,
            replySessionID: session, state: .active, expiryMonotonic: MonotonicClock.seconds() + 1
        ))
        XCTAssertThrowsError(try RawHelperControlClient.validateSuccessfulReply(
            operation: UInt32(LS_OPERATION_RENEW.rawValue), requestedSessionID: session,
            replySessionID: UUID(), state: .active, expiryMonotonic: MonotonicClock.seconds() + 1
        ))
    }

    func testRawReplyValidatorsBoundActiveLeaseAndExposeReasonsOnlyAfterBinding() throws {
        let session = UUID()
        let other = UUID()
        let now = MonotonicClock.seconds()
        XCTAssertTrue(RawHelperControlClient.validActiveExpiry(now + 1, now: now))
        for expiry in [TimeInterval.nan, .infinity, now, now - 1,
                       now + RawHelperControlClient.maximumLeaseLifetime + 3] {
            XCTAssertFalse(RawHelperControlClient.validActiveExpiry(expiry, now: now))
        }
        let cases: [(UInt32, UUID, HelperControlReply.State, TimeInterval, Bool)] = [
            // An active connection-mismatch truthfully returns its existing
            // generation rather than the rejected request's UUID.
            (UInt32(LS_OPERATION_RENEW.rawValue), other, .active, now + 1, true),
            // A RESTORE may name a prior terminal generation.
            (UInt32(LS_OPERATION_RESTORE.rawValue), other, .terminal, 0, true),
            (UInt32(LS_OPERATION_RENEW.rawValue), other, .terminal, 0, false),
            (999, session, .idle, 0, false),
        ]
        for (operation, reply, state, expiry, accepted) in cases {
            let acceptedByValidator = (try? RawHelperControlClient.validateRejectedReply(
                operation: operation, requestedSessionID: session, replySessionID: reply,
                state: state, expiryMonotonic: expiry
            )) != nil
            XCTAssertEqual(acceptedByValidator, accepted, "operation=\(operation)")
        }
        let source = try source("Sources/LidSwitch/Services/RawHelperControlClient.swift")
        let validation = try XCTUnwrap(source.range(of: "validateSuccessfulReply"))
        let reason = try XCTUnwrap(source.range(of: "let reason = String(cString: reasonPointer)"))
        XCTAssertLessThan(validation.lowerBound, reason.lowerBound)
    }

    func testOnlyIndeterminateBridgeStatusesPermitReconnectRecovery() {
        XCTAssertTrue(ls_xpc_status_is_indeterminate(Int32(bitPattern: LS_XPC_STATUS_INDETERMINATE_TIMEOUT.rawValue)))
        XCTAssertTrue(ls_xpc_status_is_indeterminate(Int32(bitPattern: LS_XPC_STATUS_INDETERMINATE_INTERRUPTED.rawValue)))
        XCTAssertFalse(ls_xpc_status_is_indeterminate(Int32(bitPattern: LS_XPC_STATUS_AUTHENTICATION_OR_PROTOCOL_FAILURE.rawValue)))
        XCTAssertFalse(ls_xpc_status_is_indeterminate(Int32(bitPattern: LS_XPC_STATUS_INVALID_ARGUMENT.rawValue)))
    }

    func testCRequestLifecycleOwnershipHarnessBalancesEveryTerminalBranch() {
        XCTAssertTrue(ls_xpc_request_lifecycle_harness())
    }

    func testRawXPCHeartbeatAuthorityUsesNativeACAndPreservesTerminalProjection() {
        let session = UUID()
        let now = Date(timeIntervalSince1970: 10_000)
        let fresh = HelperStatusRecord(state: "active", reason: "verified", sessionID: session, updatedAt: now)
        // `native.authority == .indeterminate` models the expected absence of
        // the old ActivationLeaseStore record after raw-XPC BEGIN.
        let noLegacyLease = PowerControllerSideEffects.rawXPCHeartbeatObservation(
            sessionID: session,
            native: SessionHeartbeatObservation(power: .ac, authority: .indeterminate, helperStatus: fresh), now: now
        )
        XCTAssertEqual(noLegacyLease.authority, .verified)

        // Once BEGIN/RENEW established the exact in-memory generation, active
        // projection defects are diagnostic-only: neither a legacy lease nor a
        // missing/stale/wrong-session active row can manufacture or revoke it.
        let invalidStatuses: [HelperStatusRecord?] = [nil,
            HelperStatusRecord(state: "active", reason: "verified", sessionID: UUID(), updatedAt: now),
            HelperStatusRecord(state: "active", reason: "verified", sessionID: session, updatedAt: now.addingTimeInterval(-13))]
        for status in invalidStatuses {
            let residue = PowerControllerSideEffects.rawXPCHeartbeatObservation(
                sessionID: session,
                native: SessionHeartbeatObservation(power: .ac, authority: .verified, helperStatus: status), now: now
            )
            XCTAssertEqual(residue.authority, .verified)
            XCTAssertEqual(residue.helperStatus?.sessionID, status?.sessionID)
        }
        let nonAC = PowerControllerSideEffects.rawXPCHeartbeatObservation(
            sessionID: session,
            native: SessionHeartbeatObservation(power: .unknown, authority: .verified, helperStatus: fresh), now: now
        )
        XCTAssertEqual(nonAC.authority, .indeterminate, "native AC is the RENEW prerequisite")
        let terminal = HelperStatusRecord(state: "terminal", reason: "ac-disconnect", sessionID: session, updatedAt: now)
        let terminalObservation = PowerControllerSideEffects.rawXPCHeartbeatObservation(
            sessionID: session,
            native: SessionHeartbeatObservation(power: .ac, authority: .indeterminate, helperStatus: terminal), now: now
        )
        XCTAssertEqual(terminalObservation.authority, .verified)
        XCTAssertEqual(terminalObservation.helperStatus?.state, "terminal", "fresh matching terminal projection remains visible to the coordinator fail-fast path")
    }

    func testExactPeerReconnectAtomicallyRebindsBeforeOldInvalidation() throws {
        let fixture = try AuthorityFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let clock = SecurityBox<TimeInterval>(100)
        let authority = HelperSessionAuthority(configuration: fixture.configuration, power: fixture.power,
                                               recoveryStoreFactory: fixture.recoveryStoreFactory,
                                               statusProjectionWriter: fixture.statusProjectionWriter,
                                               monotonicNow: { clock.value }, peerIsLive: { _ in true },
                                               bootIdentity: { Self.fixtureBootID })
        XCTAssertEqual(authority.prepareBeforeListening(), .ready)
        var peer = ls_peer_identity_t()
        XCTAssertTrue(ls_peer_identity_for_current_process(&peer))
        let session = UUID()
        XCTAssertEqual(authority.handle(connection: 1, peer: peer, operation: UInt32(LS_OPERATION_BEGIN.rawValue), sessionID: session).result, 0)
        let rebound = authority.handle(connection: 2, peer: peer, operation: UInt32(LS_OPERATION_RECONNECT.rawValue), sessionID: session)
        XCTAssertEqual(rebound.result, 0)
        XCTAssertEqual(rebound.reason, "reconnected")
        XCTAssertNotEqual(authority.handle(connection: 1, peer: peer, operation: UInt32(LS_OPERATION_RECONNECT.rawValue), sessionID: session).result, 0)
        authority.connectionInvalidated(1) // old invalidation cannot unbind 2
        XCTAssertNotEqual(authority.handle(connection: 1, peer: peer, operation: UInt32(LS_OPERATION_RENEW.rawValue), sessionID: session).result, 0)
        XCTAssertEqual(authority.handle(connection: 2, peer: peer, operation: UInt32(LS_OPERATION_RENEW.rawValue), sessionID: session).result, 0)
        for connection in UInt64(3)...UInt64(12) {
            XCTAssertEqual(authority.handle(connection: connection, peer: peer, operation: UInt32(LS_OPERATION_RECONNECT.rawValue), sessionID: session).result, 0)
        }
    }

    func testChangedTupleAndSessionAreRejectOnlyNotTerminalization() throws {
        let fixture = try AuthorityFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let authority = HelperSessionAuthority(configuration: fixture.configuration, power: fixture.power,
                                               recoveryStoreFactory: fixture.recoveryStoreFactory,
                                               statusProjectionWriter: fixture.statusProjectionWriter,
                                               peerIsLive: { _ in true }, bootIdentity: { Self.fixtureBootID })
        XCTAssertEqual(authority.prepareBeforeListening(), .ready)
        var peer = ls_peer_identity_t()
        XCTAssertTrue(ls_peer_identity_for_current_process(&peer))
        let session = UUID()
        XCTAssertEqual(authority.handle(connection: 1, peer: peer, operation: UInt32(LS_OPERATION_BEGIN.rawValue), sessionID: session).result, 0)
        var secondProcess = peer; secondProcess.pid += 1
        XCTAssertNotEqual(authority.handle(connection: 2, peer: secondProcess, operation: UInt32(LS_OPERATION_RECONNECT.rawValue), sessionID: session).result, 0)
        var changedASID = peer; changedASID.asid &+= 1
        XCTAssertNotEqual(authority.handle(connection: 2, peer: changedASID, operation: UInt32(LS_OPERATION_RECONNECT.rawValue), sessionID: session).result, 0)
        var changedEUID = peer; changedEUID.euid &+= 1
        XCTAssertNotEqual(authority.handle(connection: 2, peer: changedEUID, operation: UInt32(LS_OPERATION_RECONNECT.rawValue), sessionID: session).result, 0)
        XCTAssertNotEqual(authority.handle(connection: 2, peer: peer, operation: UInt32(LS_OPERATION_RECONNECT.rawValue), sessionID: UUID()).result, 0)
        XCTAssertEqual(authority.handle(connection: 1, peer: peer, operation: UInt32(LS_OPERATION_RENEW.rawValue), sessionID: session).result, 0)
    }

    func testHistoricalRecoveryReservationDoesNotBlockNextSessionLifecycle() throws {
        let fixture = try AuthorityFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let authority = HelperSessionAuthority(
            configuration: fixture.configuration,
            power: fixture.power,
            recoveryStoreFactory: fixture.recoveryStoreFactory,
            statusProjectionWriter: fixture.statusProjectionWriter,
            timerStarter: { _ in NSObject() }
        )
        XCTAssertEqual(authority.prepareBeforeListening(), .ready)
        let sessionA = UUID()
        XCTAssertEqual(authority.handle(connection: 1, operation: UInt32(LS_OPERATION_BEGIN.rawValue), sessionID: sessionA).result, 0)
        fixture.power.disabled = false
        // The connected reconciliation tick is the sole production path that
        // may spend the one-time owned repair budget. RENEW only observes
        // native truth and must never introduce a second setter authority.
        authority.reconcileForTesting()
        XCTAssertEqual(fixture.power.disabled, true)
        XCTAssertEqual(authority.handle(connection: 1, operation: UInt32(LS_OPERATION_RENEW.rawValue), sessionID: sessionA).result, 0)
        XCTAssertTrue(fixture.store.privateLedger(RecoveryAuthorityStore.reservationBasename)?.contains(sessionA) == true)
        XCTAssertEqual(authority.handle(connection: 1, operation: UInt32(LS_OPERATION_END.rawValue), sessionID: sessionA).result, 0)

        let sessionB = UUID()
        let secondBegin = authority.handle(connection: 1, operation: UInt32(LS_OPERATION_BEGIN.rawValue), sessionID: sessionB)
        XCTAssertEqual(secondBegin.result, 0, secondBegin.reason)
        XCTAssertEqual(authority.handle(connection: 1, operation: UInt32(LS_OPERATION_RENEW.rawValue), sessionID: sessionB).result, 0)
        XCTAssertEqual(authority.handle(connection: 1, operation: UInt32(LS_OPERATION_END.rawValue), sessionID: sessionB).result, 0)
        XCTAssertEqual(fixture.store.privateLedger(RecoveryAuthorityStore.terminalBasename)?.last, sessionB)
        XCTAssertEqual(fixture.store.privateLedger(RecoveryAuthorityStore.reservationBasename), [sessionA])
    }

    func testCooperativeRecoveryWinsBeforeReconnectRenewAndRearm() throws {
        let fixture = try AuthorityFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let authority = HelperSessionAuthority(
            configuration: fixture.configuration,
            power: fixture.power,
            recoveryStoreFactory: fixture.recoveryStoreFactory,
            statusProjectionWriter: fixture.statusProjectionWriter,
            timerStarter: { _ in NSObject() }
        )
        XCTAssertEqual(authority.prepareBeforeListening(), .ready)
        let session = UUID()
        XCTAssertEqual(authority.handle(connection: 1, operation: UInt32(LS_OPERATION_BEGIN.rawValue), sessionID: session).result, 0)
        let coordinator = RecoveryCoordinator(
            configuration: fixture.configuration,
            power: fixture.power,
            storeFactory: fixture.recoveryStoreFactory,
            quiescenceProbe: .fixtureQuiesced,
            statusProjectionWriter: fixture.statusProjectionWriter
        )
        XCTAssertEqual(
            coordinator.recover(intent: .userRestore, allowReconnect: false, terminalReason: "operator-recovery"),
            .terminalIdle(session, "operator-recovery")
        )
        XCTAssertEqual(fixture.power.disabled, false)
        XCTAssertEqual(fixture.power.ac, 10)

        let terminalSnapshot = authority.handle(
            connection: 1,
            operation: UInt32(LS_OPERATION_SNAPSHOT.rawValue),
            sessionID: session
        )
        XCTAssertNotEqual(terminalSnapshot.result, 0)
        XCTAssertEqual(terminalSnapshot.state, 2)
        XCTAssertEqual(terminalSnapshot.sessionID, session)
        XCTAssertEqual(terminalSnapshot.reason, "operator-recovery")
        XCTAssertNotEqual(authority.handle(connection: 2, operation: UInt32(LS_OPERATION_RECONNECT.rawValue), sessionID: session).result, 0)
        XCTAssertNotEqual(authority.handle(connection: 1, operation: UInt32(LS_OPERATION_RENEW.rawValue), sessionID: session).result, 0)
        XCTAssertEqual(fixture.power.disabled, false)
        XCTAssertEqual(fixture.power.ac, 10)
        XCTAssertEqual(fixture.store.appliedRecord(), .missing)
        XCTAssertEqual(fixture.store.privateLedger(RecoveryAuthorityStore.terminalBasename)?.last, session)
    }

    func testRollbackStoreAndLockFailuresExhaustAtSixBeforeTickBecomesNoOp() throws {
        try assertRollbackExhaustion(blockedByLock: false)
        try assertRollbackExhaustion(blockedByLock: true)
    }

    func testIdleLockFailureIsTransientAndDoesNotPoisonLaterBegin() throws {
        let fixture = try AuthorityFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let selectedStore = SecurityBox<RecoveryAuthorityStore?>(fixture.store)
        let authority = HelperSessionAuthority(
            configuration: fixture.configuration,
            power: fixture.power,
            recoveryStoreFactory: { _ in selectedStore.value },
            statusProjectionWriter: fixture.statusProjectionWriter,
            timerStarter: { _ in NSObject() }
        )
        XCTAssertEqual(authority.prepareBeforeListening(), .ready)

        let blocked = try XCTUnwrap(RecoveryAuthorityStore(
            supportDirectory: fixture.directory.path,
            expectations: .init(ownerUID: getuid(), groupID: getgid(), mode: 0o755),
            ancestorPolicy: .testTemporaryDirectory,
            lockTimeout: 0
        ))
        var heldLock = Darwin.open(
            fixture.directory.appendingPathComponent(RootStateLock.authorizationBasename).path,
            O_RDWR | O_NOFOLLOW | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(heldLock, 0)
        XCTAssertEqual(flock(heldLock, LOCK_EX | LOCK_NB), 0)
        defer {
            if heldLock >= 0 {
                _ = flock(heldLock, LOCK_UN)
                Darwin.close(heldLock)
            }
        }
        selectedStore.withValue { $0 = blocked }

        let session = UUID()
        let proofBefore = fixture.store.proofRecord()
        let failed = authority.handle(
            connection: 1,
            operation: UInt32(LS_OPERATION_BEGIN.rawValue),
            sessionID: session
        )
        XCTAssertNotEqual(failed.result, 0)
        XCTAssertEqual(failed.reason, "root-state-lock-unavailable")
        XCTAssertNotEqual(failed.state, 3)
        XCTAssertEqual(fixture.store.proofRecord(), proofBefore)
        XCTAssertEqual(fixture.store.appliedRecord(), .missing)
        XCTAssertEqual(fixture.store.evidenceState(for: "helper-status"), .absent)
        XCTAssertEqual(fixture.power.setCalls, [])

        XCTAssertEqual(flock(heldLock, LOCK_UN), 0)
        Darwin.close(heldLock)
        heldLock = -1
        selectedStore.withValue { $0 = fixture.store }

        let begun = authority.handle(
            connection: 1,
            operation: UInt32(LS_OPERATION_BEGIN.rawValue),
            sessionID: session
        )
        XCTAssertEqual(begun.result, 0)
        XCTAssertEqual(begun.state, 1)
        XCTAssertEqual(begun.reason, "verified")
        XCTAssertEqual(fixture.privateApplied()?.sessionID, session)
    }

    func testReconnectFallbackHydratesTerminalAndContinuesOneTimerAndListener() throws {
        let fixture = try AuthorityFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = HelperSessionAuthority(
            configuration: fixture.configuration,
            power: fixture.power,
            recoveryStoreFactory: fixture.recoveryStoreFactory,
            statusProjectionWriter: fixture.statusProjectionWriter,
            timerStarter: { _ in NSObject() }
        )
        XCTAssertEqual(original.prepareBeforeListening(), .ready)
        let session = UUID()
        XCTAssertEqual(original.handle(connection: 1, operation: UInt32(LS_OPERATION_BEGIN.rawValue), sessionID: session).result, 0)

        let timerCount = SecurityBox(0)
        let listenerCount = SecurityBox(0)
        let livenessChecks = SecurityBox(0)
        let restarted = HelperSessionAuthority(
            configuration: fixture.configuration,
            power: fixture.power,
            recoveryStoreFactory: fixture.recoveryStoreFactory,
            statusProjectionWriter: fixture.statusProjectionWriter,
            peerIsLive: { _ in
                let ordinal = livenessChecks.withValue { $0 += 1; return $0 }
                return ordinal > 1
            },
            timerStarter: { _ in timerCount.withValue { $0 += 1 }; return NSObject() },
            recoveryCoordinatorFactory: {
                RecoveryCoordinator(configuration: fixture.configuration, power: fixture.power,
                                    storeFactory: fixture.recoveryStoreFactory,
                                    statusProjectionWriter: fixture.statusProjectionWriter)
            }
        )
        XCTAssertEqual(HelperControlService.runPreparedDaemon(authority: restarted) {
            listenerCount.withValue { $0 += 1 }
            return 0
        }, 0)
        XCTAssertEqual(timerCount.value, 1)
        XCTAssertEqual(listenerCount.value, 1)
        let snapshot = restarted.handle(connection: 2, operation: UInt32(LS_OPERATION_SNAPSHOT.rawValue), sessionID: session)
        XCTAssertEqual(snapshot.sessionID, session)
        XCTAssertEqual(snapshot.reason, "helper-restart")
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        let restored = restarted.handle(connection: 2, operation: UInt32(LS_OPERATION_RESTORE.rawValue), sessionID: zero)
        XCTAssertEqual(restored.sessionID, session)
        XCTAssertEqual(restored.reason, "helper-restart")
    }

    func testFailedBeginPublicationConvergesAndRestartHydratesTerminalIdle() throws {
        let fixture = try AuthorityFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let authority = HelperSessionAuthority(
            configuration: fixture.configuration,
            power: fixture.power,
            appliedStatePublish: { state, store, transaction in
                let durable = store.publishApplied(state, transaction)
                return durable.isVerified ? .publishedButUnverified(.finalMetadata) : durable
            },
            recoveryStoreFactory: fixture.recoveryStoreFactory,
            statusProjectionWriter: fixture.statusProjectionWriter,
            timerStarter: { _ in NSObject() }
        )
        XCTAssertEqual(authority.prepareBeforeListening(), .ready)
        let session = UUID()
        XCTAssertNotEqual(authority.handle(connection: 1, operation: UInt32(LS_OPERATION_BEGIN.rawValue), sessionID: session).result, 0)
        XCTAssertEqual(fixture.store.appliedRecord(), .missing)
        XCTAssertEqual(fixture.store.privateLedger(RecoveryAuthorityStore.terminalBasename)?.last, session)

        let restarted = HelperSessionAuthority(
            configuration: fixture.configuration,
            power: fixture.power,
            recoveryStoreFactory: fixture.recoveryStoreFactory,
            statusProjectionWriter: fixture.statusProjectionWriter,
            timerStarter: { _ in NSObject() }
        )
        XCTAssertEqual(restarted.prepareBeforeListening(), .ready)
        let snapshot = restarted.handle(connection: 2, operation: UInt32(LS_OPERATION_SNAPSHOT.rawValue), sessionID: session)
        XCTAssertEqual(snapshot.state, 2)
        XCTAssertEqual(snapshot.sessionID, session)
        XCTAssertEqual(snapshot.reason, "activation-publication-failed")
    }

    func testBeginRechecksPeerLivenessInsideRootLockBeforePublishingAuthority() throws {
        let fixture = try AuthorityFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let livenessChecks = SecurityBox(0)
        let authority = HelperSessionAuthority(
            configuration: fixture.configuration,
            power: fixture.power,
            recoveryStoreFactory: fixture.recoveryStoreFactory,
            statusProjectionWriter: fixture.statusProjectionWriter,
            peerIsLive: { _ in
                let ordinal = livenessChecks.withValue { $0 += 1; return $0 }
                return ordinal == 1
            },
            timerStarter: { _ in NSObject() }
        )
        XCTAssertEqual(authority.prepareBeforeListening(), .ready)
        livenessChecks.withValue { $0 = 0 }

        var peer = ls_peer_identity_t()
        XCTAssertTrue(ls_peer_identity_for_current_process(&peer))
        let proofBefore = fixture.store.proofRecord()
        let terminalBefore = fixture.store.privateLedger(RecoveryAuthorityStore.terminalBasename)
        let reservationBefore = fixture.store.privateLedger(RecoveryAuthorityStore.reservationBasename)
        let powerBefore = (fixture.power.source, fixture.power.disabled, fixture.power.ac, fixture.power.setCalls)
        let denied = authority.handle(
            connection: 1,
            peer: peer,
            operation: UInt32(LS_OPERATION_BEGIN.rawValue),
            sessionID: UUID()
        )

        XCTAssertEqual(livenessChecks.value, 2)
        XCTAssertNotEqual(denied.result, 0)
        XCTAssertEqual(denied.reason, "peer-process-unavailable")
        XCTAssertEqual(fixture.store.appliedRecord(), .missing)
        XCTAssertEqual(fixture.store.proofRecord(), proofBefore)
        XCTAssertEqual(fixture.store.privateLedger(RecoveryAuthorityStore.terminalBasename), terminalBefore)
        XCTAssertEqual(fixture.store.privateLedger(RecoveryAuthorityStore.reservationBasename), reservationBefore)
        XCTAssertEqual(fixture.store.evidenceState(for: "helper-status"), .absent)
        XCTAssertEqual(fixture.power.source, powerBefore.0)
        XCTAssertEqual(fixture.power.disabled, powerBefore.1)
        XCTAssertEqual(fixture.power.ac, powerBefore.2)
        XCTAssertEqual(fixture.power.setCalls, powerBefore.3)
    }

    func testReconnectNearExpiryImmediatelyPerformsNormalRenewalOnlyWhenObservedSafe() throws {
        let root = try TestSandbox.makeDirectory(label: "reconnect-near-expiry").url
        let monotonic = SecurityBox<TimeInterval>(0)
        let calls = SecurityBox(0)
        let observations = SecurityBox(0)
        let diagnostics = SessionDiagnosticStore(file: root.appendingPathComponent("history.json"))
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 1, renewalInterval: 8, monotonicNow: { monotonic.value },
            observe: { _ in
                observations.withValue { $0 += 1 }
                return SessionHeartbeatObservation(power: .ac, authority: .verified, helperStatus: nil)
            }, renew: { _, commit in
                XCTAssertTrue(commit())
                let count = calls.withValue { $0 += 1; return $0 }
                return count == 1 ? .reconnected(originalExpiryMonotonic: 8.1) : .renewed(expiryMonotonic: 38)
            }, revoke: {}, diagnostics: diagnostics, onAcknowledged: { _ in }, onEnded: { _, _ in })
        let session = UUID()
        coordinator.start(sessionID: session, initialLeaseExpiresMonotonic: 8.1, initiallyAcknowledged: true)
        monotonic.withValue { $0 = 8 }
        coordinator.evaluateForTesting()
        coordinator.stop(reason: "test-complete")
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(observations.value, 4) // exact prewrite, re-observe, and commit rechecks

        let unsafeCalls = SecurityBox(0)
        let unsafeObservations = SecurityBox(0)
        let unsafe = SessionHeartbeatCoordinator(
            observationInterval: 1, renewalInterval: 8, monotonicNow: { monotonic.value },
            observe: { _ in
                let ordinal = unsafeObservations.withValue { $0 += 1; return $0 }
                return SessionHeartbeatObservation(power: ordinal == 1 ? .ac : .unknown,
                                                   authority: ordinal == 1 ? .verified : .indeterminate,
                                                   helperStatus: nil)
            }, renew: { _, _ in
                unsafeCalls.withValue { $0 += 1 }
                return .reconnected(originalExpiryMonotonic: 8.1)
            }, revoke: {}, diagnostics: SessionDiagnosticStore(file: root.appendingPathComponent("unsafe.json")),
            onAcknowledged: { _ in }, onEnded: { _, _ in })
        monotonic.withValue { $0 = 0 }
        unsafe.start(sessionID: UUID(), initialLeaseExpiresMonotonic: 8.1, initiallyAcknowledged: true)
        monotonic.withValue { $0 = 8 }
        unsafe.evaluateForTesting()
        unsafe.stop(reason: "test-complete")
        XCTAssertEqual(unsafeCalls.value, 1)
    }

    func testRestartRestoresAndTerminalizesWithoutResume() throws {
        let fixture = try AuthorityFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let session = UUID()
        let original = HelperSessionAuthority(
            configuration: fixture.configuration,
            power: fixture.power,
            recoveryStoreFactory: fixture.recoveryStoreFactory,
            statusProjectionWriter: fixture.statusProjectionWriter,
            timerStarter: { _ in NSObject() }
        )
        XCTAssertEqual(original.prepareBeforeListening(), .ready)
        XCTAssertEqual(
            original.handle(connection: 1, operation: UInt32(LS_OPERATION_BEGIN.rawValue), sessionID: session).result,
            0
        )
        XCTAssertEqual(fixture.power.disabled, true)
        XCTAssertEqual(fixture.power.ac, 0)
        let restarted = HelperSessionAuthority(configuration: fixture.configuration, power: fixture.power,
                                               recoveryStoreFactory: fixture.recoveryStoreFactory,
                                               statusProjectionWriter: fixture.statusProjectionWriter,
                                               peerIsLive: { _ in false },
                                               timerStarter: { _ in NSObject() })
        XCTAssertEqual(restarted.prepareBeforeListening(), .ready)
        XCTAssertEqual(fixture.power.disabled, false)
        XCTAssertEqual(fixture.power.ac, 10)
        XCTAssertTrue(fixture.store.privateLedger(RecoveryAuthorityStore.terminalBasename)?.contains(session) == true)
        let snapshot = restarted.handle(connection: 1, operation: 4, sessionID: session)
        XCTAssertEqual(snapshot.state, 2)
        XCTAssertEqual(snapshot.reason, "helper-restart")
    }

    func testBridgeAuthenticatesBeforeDecodeAndReplyBeforeFields() throws {
        let bridge = try source("Sources/LidSwitchXPCBridge/LidSwitchXPCBridge.c")
        let identity = try XCTUnwrap(bridge.range(of: "ls_validate_message_identity(message"))
        let decode = try XCTUnwrap(bridge.range(of: "ls_decode_request(message"))
        XCTAssertLessThan(identity.lowerBound, decode.lowerBound)
        let replyIdentity = try XCTUnwrap(bridge.range(of: "ls_validate_message_identity(reply"))
        let replyDecode = try XCTUnwrap(bridge.range(of: "ls_decode_reply(reply"))
        XCTAssertLessThan(replyIdentity.lowerBound, replyDecode.lowerBound)
        XCTAssertFalse(bridge.contains("proc_pidpath"))
        XCTAssertFalse(bridge.contains("audit_token"))
        XCTAssertTrue(bridge.contains("SecCodeCreateWithXPCMessage"))
        XCTAssertTrue(bridge.contains("const au_asid_t asid"))
        XCTAssertTrue(bridge.contains("if (asid < 0) return false"))
        XCTAssertTrue(bridge.contains("_Static_assert(sizeof(au_asid_t) <= sizeof(uint32_t)"))
        XCTAssertTrue(bridge.contains("if (euid != expected_euid) return false"))
        XCTAssertTrue(bridge.contains("peer_euid != policy->expected_euid"))
        XCTAssertTrue(bridge.contains("memcmp(actual.cdhash, policy->cdhash"))
        XCTAssertTrue(bridge.contains("xpc_dictionary_get_count(dictionary) != count"))
        XCTAssertTrue(bridge.contains("xpc_get_type(schema) != XPC_TYPE_UINT64"))
        XCTAssertTrue(bridge.contains("LS_XPC_PROTOCOL_VERSION"))
        XCTAssertTrue(bridge.contains("XPC_ERROR_CONNECTION_INVALID"))
        XCTAssertTrue(bridge.contains("LS_AC_SLEEP_MINUTES_MAX = 1440"))
        XCTAssertTrue(bridge.contains("raw_ac < -1 || raw_ac > LS_AC_SLEEP_MINUTES_MAX"))
    }

    func testInstallerFreezesAndNeverReopensSourceAfterCopy() {
        let script = SecureHelperInstaller.diagnosticScript(for: .install)
        XCTAssertTrue(script.contains("shasum -a 256 \"$helper\""))
        XCTAssertTrue(script.contains("CDHash"))
        XCTAssertTrue(script.contains("provision-root-state-lock"))
        XCTAssertTrue(script.contains("recover-once"))
        XCTAssertTrue(script.contains("S_ISREG"))
        XCTAssertTrue(script.contains("$final[3] == 1"))
        XCTAssertTrue(script.contains("expected_size <= 16777216"))
        XCTAssertTrue(script.contains("O_NOFOLLOW"))
        XCTAssertTrue(script.contains("/Library/Application Support/LidSwitch/Previous"))
        XCTAssertTrue(script.contains("/bin/mv \"$stage_current\" \"$current\""))
        XCTAssertTrue(script.contains("/bin/launchctl bootstrap system \"$plist\""))
        XCTAssertFalse(script.contains("lidswitch_parse_applied_state"))
        XCTAssertFalse(script.contains("/usr/bin/pmset"))
    }

    func testTerminalReasonsPreserveUnsolicitedSafetyClassification() throws {
        let source = try source("Sources/LidSwitchHelper/HelperControlService.swift")
        for reason in ["user-end", "ac-disconnect", "native-state-indeterminate",
                       "expired", "drift", "replay-or-durability-denial", "helper-restart"] {
            XCTAssertTrue(source.contains("\"\(reason)\""), "missing bounded terminal reason \(reason)")
        }
        XCTAssertFalse(source.contains("\"client-end\""))
        XCTAssertFalse(source.contains("\"confirmed-power-unknown\""))
        XCTAssertTrue(try self.source("Sources/LidSwitch/Services/PowerController.swift").contains("\"install-migration\""))
    }

    private func fixturePolicy() -> EnrollmentPolicy {
        EnrollmentPolicy(ownerUID: 501, profile: .manualExact, appIdentifier: "com.example.App",
                         appCDHash: Data(repeating: 1, count: 20), helperIdentifier: "com.example.Helper",
                         helperCDHash: Data(repeating: 2, count: 20), helperSHA256: Data(repeating: 3, count: 32),
                         helperSize: 1234, qualifiedBuild: "25F84", teamIdentifier: nil)
    }

    private func assertRollbackExhaustion(blockedByLock: Bool) throws {
        let fixture = try AuthorityFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let clock = SecurityBox<TimeInterval>(100)
        let selectedStore = SecurityBox<RecoveryAuthorityStore?>(fixture.store)
        let authority = HelperSessionAuthority(
            configuration: fixture.configuration,
            power: fixture.power,
            recoveryStoreFactory: { _ in selectedStore.value },
            statusProjectionWriter: fixture.statusProjectionWriter,
            monotonicNow: { clock.value },
            timerStarter: { _ in NSObject() }
        )
        XCTAssertEqual(authority.prepareBeforeListening(), .ready)
        let session = UUID()
        XCTAssertEqual(authority.handle(connection: 1, operation: UInt32(LS_OPERATION_BEGIN.rawValue), sessionID: session).result, 0)
        let proofBefore = try String(contentsOf: fixture.directory.appendingPathComponent(RecoveryAuthorityStore.proofBasename), encoding: .utf8)
        let statusBefore = try projectedStatus(at: fixture.directory.appendingPathComponent("helper-status"))
        let appliedBefore = fixture.privateApplied()
        let powerCallsBefore = fixture.power.setCalls

        var heldLock: Int32 = -1
        if blockedByLock {
            let blocked = try XCTUnwrap(RecoveryAuthorityStore(
                supportDirectory: fixture.directory.path,
                expectations: .init(ownerUID: getuid(), groupID: getgid(), mode: 0o755),
                ancestorPolicy: .testTemporaryDirectory,
                lockTimeout: 0,
                lockNow: { clock.value }
            ))
            heldLock = Darwin.open(
                fixture.directory.appendingPathComponent(RootStateLock.authorizationBasename).path,
                O_RDWR | O_NOFOLLOW | O_CLOEXEC
            )
            XCTAssertGreaterThanOrEqual(heldLock, 0)
            XCTAssertEqual(flock(heldLock, LOCK_EX | LOCK_NB), 0)
            selectedStore.withValue { $0 = blocked }
        } else {
            selectedStore.withValue { $0 = nil }
        }
        defer {
            if heldLock >= 0 {
                _ = flock(heldLock, LOCK_UN)
                Darwin.close(heldLock)
            }
        }

        let attemptTimes: [TimeInterval] = [100, 102, 106, 114, 130, 162]
        let nextAttemptTimes: [TimeInterval] = [102, 106, 114, 130, 162, 222]
        for (ordinal, now) in attemptTimes.enumerated() {
            clock.withValue { $0 = now }
            authority.reconcileForTesting()
            XCTAssertEqual(authority.rollbackAttemptCountForTesting, ordinal + 1)
            XCTAssertEqual(authority.tickStoreAttemptCountForTesting, ordinal + 1)
            XCTAssertEqual(authority.rollbackNextAttemptForTesting, nextAttemptTimes[ordinal])
        }
        clock.withValue { $0 = 1_000 }
        authority.reconcileForTesting()
        authority.reconcileForTesting()
        XCTAssertEqual(authority.rollbackAttemptCountForTesting, 6)
        XCTAssertEqual(authority.tickStoreAttemptCountForTesting, 6)
        XCTAssertEqual(fixture.power.disabled, true)
        XCTAssertEqual(fixture.power.ac, 0)
        XCTAssertEqual(fixture.power.setCalls, powerCallsBefore)
        XCTAssertEqual(fixture.privateApplied(), appliedBefore)
        XCTAssertEqual(
            try String(contentsOf: fixture.directory.appendingPathComponent(RecoveryAuthorityStore.proofBasename), encoding: .utf8),
            proofBefore
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.directory.appendingPathComponent("helper-status"), encoding: .utf8),
            statusBefore
        )
    }

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func projectedStatus(at url: URL, timeout: TimeInterval = 1) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let status = try? String(contentsOf: url, encoding: .utf8) { return status }
            usleep(1_000)
        } while Date() < deadline
        return try String(contentsOf: url, encoding: .utf8)
    }
}

final class SafeEnvelopeRevision4SourceTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func pythonFunction(_ name: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: "def \(name)("))
        let suffix = source[start.lowerBound...]
        let end = suffix.dropFirst().range(of: "\ndef ")?.lowerBound ?? source.endIndex
        return String(source[start.lowerBound..<end])
    }

    private func shellWords(_ name: String, in source: String) throws -> Set<String> {
        let prefix = name + "=\""
        let line = try XCTUnwrap(source.split(separator: "\n").map(String.init).first { $0.hasPrefix(prefix) && $0.hasSuffix("\"") })
        return Set(line.dropFirst(prefix.count).dropLast().split(separator: " ").map(String.init))
    }

    private func statusBranches(in source: String) throws -> Set<String> {
        let start = try XCTUnwrap(source.range(of: "live_envelope_status_matrix()"))
        let end = try XCTUnwrap(source.range(of: "live_envelope_capture_status()", range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.lowerBound]
        return Set(body.split(separator: "\n").flatMap { raw -> [String] in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard (line.hasPrefix("true:") || line.hasPrefix("false:")), line.hasSuffix(")") else { return [] }
            return line.dropLast().split(separator: "|").map(String.init)
        })
    }

    private func pythonStringSet(_ name: String, in source: String) throws -> Set<String> {
        let start = try XCTUnwrap(source.range(of: name + " = {"))
        let end = try XCTUnwrap(source.range(of: "\n}", range: start.upperBound..<source.endIndex))
        let components = source[start.upperBound..<end.lowerBound].components(separatedBy: "\"")
        return Set(components.enumerated().compactMap { index, value in index.isMultiple(of: 2) ? nil : value })
    }

    func testDefaultDenySnapshotAndNoAliasContract() throws {
        let profile = try source("script/swift_test_sandbox.sb.in")
        let common = try source("script/swift_sandbox_common.sh")
        XCTAssertTrue(profile.contains("(deny default)"))
        XCTAssertTrue(profile.contains("(allow file-read-data (literal \"/\"))"))
        XCTAssertTrue(profile.contains("(allow file-read-metadata (literal \"/\"))"))
        XCTAssertTrue(profile.contains("(allow file-read-metadata (literal \"/usr\"))"))
        XCTAssertTrue(profile.contains("(allow file-read* (subpath \"@EXEC_ROOT@\"))"))
        XCTAssertTrue(profile.contains("(allow file-read* (literal \"@XCODE_XCTEST_TOOL@\"))"))
        XCTAssertTrue(profile.contains("(allow process-exec (literal \"@XCODE_XCTEST_TOOL@\"))"))
        XCTAssertTrue(profile.contains("(allow sysctl-read)"))
        XCTAssertTrue(profile.contains("(deny file-link)"))
        XCTAssertTrue(profile.contains("(deny file-clone)"))
        XCTAssertFalse(profile.contains("(deny file-rename)"))
        XCTAssertTrue(profile.contains("(subpath \"@SOURCE_ROOT@\")"))
        XCTAssertTrue(profile.contains("(deny file-write* (subpath \"@SOURCE_ROOT@\"))"))
        XCTAssertFalse(profile.contains("(allow default)"))
        XCTAssertEqual(profile.components(separatedBy: "(version 1)").count - 1, 1)
        XCTAssertFalse(profile.contains("(allow process-exec (subpath \"/usr/bin\"))"))
        XCTAssertTrue(common.contains("swift_subcommand\" --disable-sandbox --package-path"))
        XCTAssertTrue(common.contains("LIDSWITCH_SWIFT_XCODE_TOOL_xctest"))
        XCTAssertTrue(common.contains("%d:%i:%u:%g:%Lp:%l"))
        let fileHelper = try source("script/safe_file_capability.py")
        let copyNode = try pythonFunction("copy_snapshot_node", in: fileHelper)
        let metadata = try pythonFunction("verified_source_metadata", in: fileHelper)
        let digest = try pythonFunction("snapshot_digest", in: fileHelper)
        XCTAssertTrue(metadata.contains("metadata.st_nlink != 1"))
        XCTAssertTrue(metadata.contains("elif not stat.S_ISDIR"))
        XCTAssertTrue(copyNode.contains("os.O_EXCL | os.O_NOFOLLOW"))
        XCTAssertTrue(copyNode.contains("stable(source_before) != stable(source_after)"))
        XCTAssertTrue(digest.contains("stat.S_IMODE(metadata.st_mode) != 0o444"))
        let inventory = try pythonFunction("snapshot_manifest_list", in: fileHelper)
        XCTAssertTrue(inventory.contains("source manifest metadata is unsafe"))
        XCTAssertTrue(inventory.contains("entries != sorted(entries)"))
        XCTAssertTrue(inventory.contains("snapshot inventory lacks required build, source, test, policy, or cleanup inputs"))
        XCTAssertTrue(common.contains("snapshot-verify"))
    }

    func testControlRecheckAndNoInheritedStdioContract() throws {
        let common = try source("script/swift_sandbox_common.sh")
        let supervisor = try source("script/safe_process_supervisor.py")
        let envelope = try source("script/live_state_envelope.sh")
        XCTAssertTrue(common.contains("swift_sandbox_assert_sealed_control_file"))
        // The envelope owns its preflight receipt and its exact seal; the
        // common setup owns only the control root and its generic reassertion.
        XCTAssertTrue(envelope.contains("LIDSWITCH_SWIFT_PREFLIGHT_SEAL"))
        XCTAssertTrue(supervisor.contains("stdin=subprocess.DEVNULL"))
        XCTAssertTrue(supervisor.contains("--stdout"))
        XCTAssertTrue(supervisor.contains("O_EXCL | os.O_NOFOLLOW"))
        XCTAssertTrue(supervisor.contains("OUTPUT_LIMIT_BYTES"))
        XCTAssertTrue(envelope.contains("swift_sandbox_assert_sealed_control_file"))
        XCTAssertTrue(envelope.contains("LIDSWITCH_SWIFT_PREFLIGHT_SHA256"))
    }

    func testMacSessionAndPublisherHardeningContract() throws {
        let supervisor = try source("script/safe_process_supervisor.py")
        let files = try source("script/safe_file_capability.py")
        XCTAssertTrue(supervisor.contains("pid=,ppid=,pgid="))
        XCTAssertFalse(supervisor.contains("pid=,ppid=,pgid=,sess="))
        XCTAssertTrue(supervisor.contains("session_reader: Callable[[int], int] = os.getsid"))
        XCTAssertTrue(supervisor.contains("PROC_PIDTBSDINFO"))
        XCTAssertTrue(supervisor.contains("pbi_start_tvsec"))
        XCTAssertTrue(supervisor.contains("STARTUP_GATE_BOOTSTRAP"))
        XCTAssertTrue(supervisor.contains("pass_fds=(gate_read,)"))
        let processParser = try pythonFunction("parse_process_table", in: supervisor)
        XCTAssertTrue(processParser.contains("len(fields) != 3"))
        XCTAssertFalse(processParser.contains("session"))
        XCTAssertTrue(supervisor.contains(#"lidswitch-swift\.[A-Za-z0-9_]{6,32}"#))
        let main = try pythonFunction("main", in: supervisor)
        let install = try XCTUnwrap(main.range(of: "install_interruption_handlers()"))
        let spawn = try XCTUnwrap(main.range(of: "subprocess.Popen"))
        XCTAssertLessThan(install.lowerBound, spawn.lowerBound)
        let gateRelease = try pythonFunction("release_startup_gate", in: supervisor)
        XCTAssertTrue(gateRelease.contains("startup_gate_identity_is_exact"))
        XCTAssertTrue(gateRelease.contains("\"blocked\""))
        XCTAssertTrue(gateRelease.contains("\"ambiguous\""))
        let gateReap = try pythonFunction("reap_blocked_startup_gate", in: supervisor)
        XCTAssertTrue(gateReap.contains("except InterruptedError"))
        let handler = try pythonFunction("record_interruption", in: supervisor)
        XCTAssertTrue(handler.contains("_INTERRUPT_SIGNAL"))
        XCTAssertFalse(handler.contains("session_members"))
        XCTAssertFalse(handler.contains("signal_members"))
        let cleanup = try pythonFunction("run_cleanup_state_machine", in: supervisor)
        XCTAssertTrue(cleanup.contains("signal.SIGTERM"))
        XCTAssertTrue(cleanup.contains("signal.SIGKILL"))
        XCTAssertTrue(cleanup.contains("wait_leader"))
        XCTAssertTrue(cleanup.contains("stable_absence_proved"))
        XCTAssertTrue(cleanup.contains("return False"))
        let direct = try pythonFunction("direct_containment_signal", in: supervisor)
        XCTAssertTrue(direct.contains("signal_process_identity"))
        XCTAssertTrue(direct.contains("identity_reader(leader.pid) != leader"))
        XCTAssertTrue(direct.contains("group_records"))
        XCTAssertTrue(direct.contains("group_killer(leader.pid"))
        XCTAssertFalse(direct.contains("os.kill("))
        let spawnPlan = try pythonFunction("durable_cleanup_spawn_plan", in: supervisor)
        XCTAssertTrue(spawnPlan.contains("\"/usr/bin/python3\", \"-I\", \"-S\", \"-B\", \"-c\", CLEANUP_BOOTSTRAP"))
        let durable = try pythonFunction("start_durable_cleanup_owner", in: supervisor)
        XCTAssertTrue(durable.contains("os.posix_spawn"))
        XCTAssertTrue(durable.contains("os.POSIX_SPAWN_CLOSE"))
        XCTAssertTrue(durable.contains("setsigmask=CLEANUP_SIGNALS"))
        XCTAssertTrue(durable.contains("durable_cleanup_spawn_plan"))
        XCTAssertTrue(durable.contains("os.POSIX_SPAWN_DUP2"))
        XCTAssertTrue(supervisor.contains("CLEANUP_BOOTSTRAP"))
        XCTAssertTrue(supervisor.contains("verify_inherited_cleanup_script_fd"))
        XCTAssertTrue(supervisor.contains("CLEANUP_SOURCE_ROOT_FD"))
        XCTAssertTrue(supervisor.contains("verify_cleanup_owner_snapshot(CLEANUP_SOURCE_ROOT_FD, source_seal)"))
        let tokenTable = try pythonFunction("process_table", in: supervisor)
        XCTAssertTrue(tokenTable.contains("identity_reader(pid)"))
        XCTAssertTrue(tokenTable.contains("supervised PID was reused"))
        XCTAssertTrue(supervisor.contains("supervised descendant escaped its initial session"))
        let identity = try pythonFunction("identity6", in: files)
        let identityLines = identity.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let tupleStart = try XCTUnwrap(identityLines.firstIndex(of: "return (")) + 1
        let tupleEnd = try XCTUnwrap(identityLines[tupleStart...].firstIndex(of: ")"))
        let fields = identityLines[tupleStart..<tupleEnd].joined().split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        XCTAssertEqual(fields, ["metadata.st_dev", "metadata.st_ino", "metadata.st_uid", "metadata.st_gid", "stat.S_IMODE(metadata.st_mode)", "metadata.st_nlink"])
        let destination = try pythonFunction("open_private_destination", in: files)
        let expected = try XCTUnwrap(destination.range(of: "expected = parse_identity"))
        let observed = try XCTUnwrap(destination.range(of: "observed = identity6(metadata)"))
        let comparison = try XCTUnwrap(destination.range(of: "observed != expected"))
        let success = try XCTUnwrap(destination.range(of: "return parent_fd, name"))
        XCTAssertLessThan(expected.lowerBound, observed.lowerBound)
        XCTAssertLessThan(observed.lowerBound, comparison.lowerBound)
        XCTAssertLessThan(comparison.lowerBound, success.lowerBound)
        XCTAssertTrue(files.contains("F_FULLFSYNC"))
        let publisher = try pythonFunction("copy_new", in: files)
        XCTAssertLessThan(try XCTUnwrap(publisher.range(of: "validate_benchmark_jsonl")).lowerBound,
                          try XCTUnwrap(publisher.range(of: "open_private_destination")).lowerBound)
        XCTAssertTrue(try pythonFunction("validate_benchmark_jsonl", in: files).contains("canonical != text"))
    }

    func testBenchmarkPublicationSchemaIsClosedAndBounded() throws {
        let files = try source("script/safe_file_capability.py")
        let keys = try pythonStringSet("BENCHMARK_ALLOWED_KEYS", in: files)
        XCTAssertEqual(keys, Set([
            "record_type", "schema_version", "warm_samples", "fixture_root",
            "artifact_scenarios_included", "snapshot_core_context", "snapshot_core_limitations",
            "app_bundle", "installed_helper_path", "artifact_validation", "helper_comparison",
            "operating_system", "architecture", "scenario", "scenario_kind", "classification",
            "sample_index", "elapsed_nanoseconds", "main_thread_elapsed_nanoseconds", "counters",
            "bundle_integrity_valid", "bundle_version_valid", "codesign_exit_code",
            "bundled_helper_path", "helper_bytes_match", "sample_count", "median_nanoseconds",
            "p95_nanoseconds", "sample_standard_deviation_nanoseconds", "quantile",
        ]))
        let record = try pythonFunction("validate_benchmark_record", in: files)
        let declaredTypes = Set(record.split(separator: "\n").compactMap { raw -> String? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            let markers = ["if record_type == \"", "elif record_type == \""]
            guard let marker = markers.first(where: { line.hasPrefix($0) }) else { return nil }
            return line.dropFirst(marker.count).split(separator: "\"").first.map(String.init)
        })
        XCTAssertEqual(declaredTypes, Set(["run", "methodology", "environment", "sample", "summary"]))
        XCTAssertTrue(record.contains("unknown key"))
        XCTAssertTrue(record.contains("not bounded_int"))
        XCTAssertTrue(record.contains("set(record) !="))
        let jsonl = try pythonFunction("validate_benchmark_jsonl", in: files)
        XCTAssertTrue(jsonl.contains("len(lines) > 4096"))
        XCTAssertTrue(jsonl.contains("len(line) > 65536"))
        XCTAssertTrue(jsonl.contains("validate_benchmark_corpus(records, args)"))
        let corpus = try pythonFunction("validate_benchmark_corpus", in: files)
        XCTAssertTrue(corpus.contains("[\"run\", \"methodology\", \"environment\"]"))
        XCTAssertTrue(corpus.contains("benchmark sample order, scenario, classification, or index is not canonical"))
        XCTAssertTrue(corpus.contains("benchmark summary statistics do not equal canonical samples"))
        XCTAssertTrue(corpus.contains("record[\"fixture_root\"] != run[\"fixture_root\"]"))
    }

    func testSemanticNegativeFixturesBindCaptureAndCorpusTruth() throws {
        struct Capture: Equatable {
            let device: Int; let inode: Int; let uid: Int; let gid: Int
            let mode: Int; let links: Int; let size: Int; let digest: String
        }
        let sealed = Capture(device: 7, inode: 11, uid: 501, gid: 20, mode: 0o600, links: 1, size: 3, digest: "abc")
        let attacks = [
            Capture(device: 7, inode: 12, uid: 501, gid: 20, mode: 0o600, links: 1, size: 3, digest: "abc"), // unlink/recreate/substitution
            Capture(device: 7, inode: 11, uid: 501, gid: 20, mode: 0o600, links: 2, size: 3, digest: "abc"),  // added hard link
            Capture(device: 7, inode: 11, uid: 501, gid: 20, mode: 0o600, links: 1, size: 4, digest: "abc"),  // size mutation
            Capture(device: 7, inode: 11, uid: 501, gid: 20, mode: 0o600, links: 1, size: 3, digest: "def"),  // content mutation
        ]
        XCTAssertTrue(attacks.allSatisfy { $0 != sealed })

        let canonical = ["run", "methodology", "environment", "cold:0:A", "cold:0:B", "warm:1:A", "warm:1:B", "summary:A", "summary:B"]
        let negativeCorpora = [
            ["methodology", "run"] + Array(canonical.dropFirst(2)), // reordered control
            canonical.filter { $0 != "warm:1:B" },                    // missing sample
            canonical + ["summary:A"],                                 // duplicate summary
            canonical.enumerated().map { $0.offset == 5 ? "warm:2:A" : $0.element }, // index gap
        ]
        XCTAssertTrue(negativeCorpora.allSatisfy { $0 != canonical })

        let supervisor = try source("script/safe_process_supervisor.py")
        let files = try source("script/safe_file_capability.py")
        let common = try source("script/swift_sandbox_common.sh")
        let seal = try pythonFunction("create_capture_seal", in: supervisor)
        let reopen = try pythonFunction("open_sealed_capture", in: files)
        let corpus = try pythonFunction("validate_benchmark_corpus", in: files)
        let counter = try pythonFunction("validate_benchmark_counter_invariants", in: files)
        XCTAssertTrue(seal.contains("stable_capture_metadata"))
        XCTAssertTrue(seal.contains("verify_capture_name"))
        XCTAssertTrue(seal.contains("capture_digest"))
        XCTAssertTrue(reopen.contains("os.O_NOFOLLOW"))
        XCTAssertTrue(reopen.contains("capture no-follow reopen identity does not match host seal"))
        XCTAssertTrue(corpus.contains("missing, duplicated, or oversized"))
        XCTAssertTrue(corpus.contains("fixture root drifted"))
        XCTAssertTrue(corpus.contains("validate_benchmark_counter_invariants(record)"))
        XCTAssertTrue(counter.contains("benchmark scenario counter invariant is not exact"))
        XCTAssertTrue(common.contains("swift_sandbox_reassert_before_sensitive_host_action"))
    }

    func testRevision13AuthenticationArtifactReceiptAndCleanupContract() throws {
        let supervisor = try source("script/safe_process_supervisor.py")
        let files = try source("script/safe_file_capability.py")
        let common = try source("script/swift_sandbox_common.sh")
        let tests = try source("script/run_swift_tests_safely.sh")
        let build = try source("script/run_swift_build_safely.sh")
        XCTAssertTrue(supervisor.contains("read_authentication_key"))
        XCTAssertTrue(supervisor.contains("import re"))
        XCTAssertTrue(supervisor.contains("hmac.new"))
        XCTAssertTrue(supervisor.contains("create_supervisor_result"))
        XCTAssertTrue(supervisor.contains("supervisor_result_state_is_valid"))
        XCTAssertTrue(supervisor.contains("start_durable_cleanup_owner"))
        XCTAssertTrue(supervisor.contains("os.posix_spawn"))
        XCTAssertTrue(supervisor.contains("cleanup_script_receipt"))
        XCTAssertTrue(supervisor.contains("open_cleanup_source_root"))
        XCTAssertTrue(supervisor.contains("open_verified_cleanup_script"))
        XCTAssertTrue(supervisor.contains("CLEANUP_INHERITED_FD"))
        XCTAssertTrue(supervisor.contains("CLEANUP_SOURCE_ROOT_FD"))
        XCTAssertFalse(supervisor.contains("os.path.abspath(__file__)"))
        XCTAssertTrue(files.contains("hmac.compare_digest"))
        XCTAssertTrue(files.contains("host_artifact_truth"))
        XCTAssertTrue(files.contains("ArtifactTreeCapability"))
        XCTAssertTrue(files.contains("InstalledHelperCapability"))
        XCTAssertTrue(files.contains("open_sticky_private_tmp_chain"))
        XCTAssertTrue(files.contains("capture_authentication_key_from_bytes"))
        XCTAssertTrue(files.contains("open_supervisor_result"))
        XCTAssertTrue(files.contains("supervisor_wrapper_mapping"))
        XCTAssertTrue(files.contains("BENCHMARK_COUNTER_CONTRACTS"))
        XCTAssertTrue(common.contains("swift_sandbox_capture_key_pipe"))
        XCTAssertTrue(common.contains("swift_sandbox_read_supervisor_result"))
        XCTAssertTrue(common.contains("child_command_exit="))
        XCTAssertTrue(common.contains("LIDSWITCH_SWIFT_SUPERVISOR_COMPLETED"))
        XCTAssertTrue(common.contains("--result"))
        XCTAssertFalse(common.contains("export LIDSWITCH_SWIFT_CAPTURE_AUTH_KEY"))
        // Documentation remains outside the immutable Swift source snapshot:
        // the descriptor-loaded Python safety gate validates its exact command
        // without creating a docs -> manifest -> self-test -> docs hash cycle.
        for wrapper in [tests, build] {
            let emit = try XCTUnwrap(wrapper.range(of: "swift_sandbox_emit_captured_output", options: .backwards))
            let receipt = try XCTUnwrap(
                wrapper.range(
                    of: "live_envelope_finalize_terminal_receipt",
                    range: emit.upperBound..<wrapper.endIndex
                )
            )
            XCTAssertLessThan(emit.lowerBound, receipt.lowerBound)
            XCTAssertTrue(wrapper.contains("trap - EXIT HUP INT TERM\nexit \"$status\""))
        }
        let receiptEnvelope = try source("script/live_state_envelope.sh")
        XCTAssertTrue(receiptEnvelope.contains("case \"$outcome\" in"))
        XCTAssertTrue(receiptEnvelope.contains("preserved)"))
        XCTAssertTrue(receiptEnvelope.contains("command-failed-host-preserved)"))
        XCTAssertTrue(receiptEnvelope.contains("host_preserved=true"))
        XCTAssertFalse(receiptEnvelope.contains("benchmark-publication-failed-host-preserved"))
        XCTAssertTrue(receiptEnvelope.contains("live_envelope_finalize_terminal_receipt"))
        XCTAssertTrue(receiptEnvelope.contains("schema=3"))
        XCTAssertTrue(receiptEnvelope.contains("child_command_exit="))
        XCTAssertTrue(receiptEnvelope.contains("wrapper_exit="))
    }

    func testCanonicalLiveTruthAndInvocationFormsContract() throws {
        let envelope = try source("script/live_state_envelope.sh")
        let testWrapper = try source("script/run_swift_tests_safely.sh")
        let buildWrapper = try source("script/run_swift_build_safely.sh")
        XCTAssertTrue(envelope.contains("live_envelope_canonical_uuid"))
        XCTAssertTrue(envelope.contains("live_envelope_canonical_uint"))
        XCTAssertTrue(envelope.contains("mach_continuous_time"))
        XCTAssertTrue(envelope.contains("LIDSWITCH_ACTIVE_STATUS_FRESH_SECONDS"))
        XCTAssertEqual(try statusBranches(in: envelope), Set([
            "true:active:uuid", "false:active:uuid", "true:inactive:none",
            "true:terminal:uuid", "true:recovery-required:none",
            "true:recovery-required:uuid", "false:inactive:none",
            "false:inactive:uuid", "false:recovery-required:none",
            "false:recovery-required:uuid",
        ]))
        let terminalReasons = try shellWords("LIDSWITCH_CANDIDATE_TERMINAL_SESSION_REASONS", in: envelope)
        let inactiveNone = try shellWords("LIDSWITCH_CANDIDATE_INACTIVE_NONE_REASONS", in: envelope)
        let recoveryNone = try shellWords("LIDSWITCH_CANDIDATE_RECOVERY_NONE_REASONS", in: envelope)
        let recoverySession = try shellWords("LIDSWITCH_CANDIDATE_RECOVERY_SESSION_REASONS", in: envelope)
        XCTAssertTrue(terminalReasons.contains("user-end"))
        XCTAssertTrue(recoveryNone.contains("invalid-applied-state"))
        XCTAssertTrue(recoverySession.contains("authority-unavailable-rollback-unverified"))
        XCTAssertTrue(terminalReasons.isDisjoint(with: recoveryNone))
        XCTAssertTrue(recoveryNone.isDisjoint(with: recoverySession))
        XCTAssertTrue(terminalReasons.union(recoveryNone).union(recoverySession).allSatisfy { $0.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil })
        let candidateAccepts: (String, String, String, Int, String) -> Bool = { state, reason, session, age, signature in
            switch (state, session) {
            case ("inactive", "none"):
                return inactiveNone.contains(reason) && age <= 60 && signature == "boot_id,updated_monotonic"
            case ("terminal", "uuid"):
                return terminalReasons.contains(reason) && age <= 60 && signature == "boot_id,updated_monotonic"
            case ("recovery-required", "none"):
                return recoveryNone.contains(reason) && age <= 30 && signature == "boot_id,updated_monotonic"
            case ("recovery-required", "uuid"):
                return recoverySession.contains(reason) && age <= 30 && signature == "boot_id,updated_monotonic"
            default:
                return false
            }
        }
        XCTAssertTrue(candidateAccepts("terminal", "user-end", "uuid", 10, "boot_id,updated_monotonic"))
        XCTAssertTrue(candidateAccepts("recovery-required", "invalid-applied-state", "none", 10, "boot_id,updated_monotonic"))
        XCTAssertFalse(candidateAccepts("terminal", "user-end", "none", 10, "boot_id,updated_monotonic"))
        XCTAssertFalse(candidateAccepts("inactive", "unknown", "none", 10, "boot_id,updated_monotonic"))
        XCTAssertFalse(candidateAccepts("recovery-required", "invalid-applied-state", "none", 31, "boot_id,updated_monotonic"))
        XCTAssertFalse(candidateAccepts("terminal", "user-end", "uuid", 10, "boot_id,event,updated_monotonic"))
        let current = try XCTUnwrap(envelope.range(of: "live_envelope_status_is_current()"))
        let matrix = try XCTUnwrap(envelope.range(of: "live_envelope_status_matrix()"))
        let currentBody = String(envelope[current.lowerBound..<matrix.lowerBound])
        XCTAssertTrue(currentBody.contains("wall_age"))
        XCTAssertTrue(currentBody.contains("LIVE_KERNEL_MONOTONIC"))
        XCTAssertTrue(currentBody.contains("LIVE_STATUS_BOOT_ID"))
        for wrapper in [testWrapper, buildWrapper] {
            XCTAssertTrue(wrapper.hasPrefix("#!/bin/bash -p"))
            XCTAssertTrue(wrapper.contains("\"$0\" == /dev/fd/30"))
            XCTAssertTrue(wrapper.contains("\"${BASH_SOURCE[0]}\" == /dev/fd/30"))
            XCTAssertTrue(wrapper.contains("LIDSWITCH_HELD_ENTRY:-"))
            XCTAssertTrue(wrapper.contains("LIDSWITCH_HELD_FD_MAP:-"))
        }
        let buildPostflight = try XCTUnwrap(buildWrapper.range(of: "live_envelope_postflight \"$command_status\""))
        let buildEmit = try XCTUnwrap(buildWrapper.range(of: "swift_sandbox_emit_captured_output"))
        let binRead = try XCTUnwrap(buildWrapper.range(of: "swift_sandbox_read_bin_path"))
        XCTAssertLessThan(binRead.lowerBound, buildEmit.lowerBound)
        XCTAssertLessThan(buildEmit.lowerBound, buildPostflight.lowerBound)
        let testPostflight = try XCTUnwrap(testWrapper.range(of: "live_envelope_postflight \"$command_status\""))
        let testEmit = try XCTUnwrap(testWrapper.range(of: "swift_sandbox_emit_captured_output"))
        XCTAssertLessThan(testEmit.lowerBound, testPostflight.lowerBound)
        // Documentation claims are checked by the isolated descriptor Python
        // gate; this XCTest lane remains coupled only to executable sources.
    }
}

private final class SecurityBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return storage }
    func withValue<R>(_ body: (inout Value) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&storage) }
}

private final class SecurityFixturePower: HelperPowerSystem {
    var source: HelperPowerSource = .ac
    var disabled: Bool? = false
    var ac: Int? = 10
    var setCalls: [String] = []
    func powerSource() -> HelperPowerSource { source }
    func sleepDisabled() -> Bool? { disabled }
    func acSleepMinutes() -> Int? { ac }
    func setSleepDisabled(_ enabled: Bool) throws {
        setCalls.append("sleep=\(enabled ? 1 : 0)")
        disabled = enabled
    }
    func setACSleepMinutes(_ minutes: Int) throws {
        setCalls.append("ac=\(minutes)")
        ac = minutes
    }
}

private struct AuthorityFixture {
    let directory: URL
    let configuration: HelperServiceConfiguration
    let power = SecurityFixturePower()
    let store: RecoveryAuthorityStore

    var recoveryStoreFactory: (String) -> RecoveryAuthorityStore? { { _ in store } }

    var statusProjectionWriter: StatusProjectionDispatcher.Writer {
        let directory = directory
        return { task, _ in
            guard let descriptor = try? TestSandbox.openManagedDirectory(at: directory) else {
                return .unsafeExisting
            }
            defer { close(descriptor) }
            return HelperStatusStore.writeOutcome(
                task: task,
                heldDirectoryDescriptor: descriptor,
                expectations: .init(ownerUID: getuid(), groupID: getgid(), mode: 0o755)
            )
        }
    }

    init() throws {
        directory = try TestSandbox.makeDirectory(label: "authority").url
        guard chmod(directory.path, 0o755) == 0,
              let store = RecoveryAuthorityStore(
                supportDirectory: directory.path,
                expectations: .init(ownerUID: getuid(), groupID: getgid(), mode: 0o755),
                ancestorPolicy: .testTemporaryDirectory
              ),
              store.provision() == .ready else { throw CocoaError(.fileWriteUnknown) }
        self.store = store
        configuration = HelperServiceConfiguration(expectedOwnerUID: getuid(), qualifiedBuild: "25F84",
                                                   supportDirectory: directory.path,
                                                   appliedStatePath: directory.appendingPathComponent("applied-state").path,
                                                   statusPath: directory.appendingPathComponent("helper-status").path,
                                                   policyPath: directory.appendingPathComponent("enrollment-policy").path)
    }

    func privateApplied() -> AppliedState? {
        guard case let .privateAuthority(state) = store.appliedRecord() else { return nil }
        return state
    }

    func installPrivateApplied(_ state: AppliedState) throws {
        guard store.withTransaction({ store.publishApplied(state, $0).isVerified }) == true else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
