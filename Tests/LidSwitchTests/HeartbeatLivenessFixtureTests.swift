import Foundation
import LidSwitchXPCBridge
import XCTest
@testable import LidSwitch

private final class HeartbeatLivenessBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    func read<T>(_ body: (Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(storage)
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&storage)
        lock.unlock()
    }
}

private func heartbeatRawClient() -> RawHelperControlClient {
    RawHelperControlClient(
        helperIdentity: CodeIdentity(
            identifier: "com.johnsilva.lidswitch.fixture",
            cdhash: Data(repeating: 0, count: 20),
            teamIdentifier: nil
        )
    )
}

private func heartbeatRawReply(
    reason: String,
    sessionID: UUID,
    expiry: TimeInterval = 30,
    state: HelperControlReply.State = .active
) -> HelperControlReply {
    HelperControlReply(
        reason: reason,
        sessionID: sessionID,
        expiryMonotonic: expiry,
        state: state,
        power: .ac,
        sleepDisabled: state == .active,
        acSleepMinutes: state == .active ? 0 : 5
    )
}

final class HeartbeatLivenessFixtureTests: XCTestCase {
    func testClosedNoAdvanceReasonMapperNeverClassifiesNativeIndeterminacyAsRenewed() {
        let sessionID = UUID()
        func reply(reason: String) -> HelperControlReply {
            HelperControlReply(
                reason: reason,
                sessionID: sessionID,
                expiryMonotonic: 30,
                state: .active,
                power: .unknown,
                sleepDisabled: true,
                acSleepMinutes: 0
            )
        }

        XCTAssertEqual(
            RawHelperControlClient.classifyRenewalReplyForTesting(reply(reason: "native-state-indeterminate")),
            .indeterminateNoAdvance(reason: "native-state-indeterminate")
        )
        XCTAssertEqual(
            RawHelperControlClient.classifyRenewalReplyForTesting(reply(reason: "power-source-unconfirmed")),
            .indeterminateNoAdvance(reason: "power-source-unconfirmed")
        )
        XCTAssertEqual(
            RawHelperControlClient.classifyRenewalReplyForTesting(reply(reason: "verified")),
            .renewed(expiryMonotonic: 30)
        )
    }

    func testRawRecoveryDefersReconnectUntilLaterCycleWithoutBegin() throws {
        let client = heartbeatRawClient()
        let sessionID = UUID()
        var firstCycle: [UInt32] = []
        XCTAssertThrowsError(try client.renewForTesting(sessionID: sessionID) { operation, requested in
            XCTAssertEqual(requested, sessionID)
            firstCycle.append(operation)
            XCTAssertEqual(operation, UInt32(LS_OPERATION_RENEW.rawValue))
            throw HelperControlError.indeterminateTransport(11)
        }) { error in
            XCTAssertEqual(error as? HelperControlError, .indeterminateTransport(11))
        }
        XCTAssertEqual(firstCycle, [UInt32(LS_OPERATION_RENEW.rawValue)])

        var reconnectCycle: [UInt32] = []
        XCTAssertEqual(
            try client.renewForTesting(sessionID: sessionID) { operation, requested in
                XCTAssertEqual(requested, sessionID)
                reconnectCycle.append(operation)
                XCTAssertEqual(operation, UInt32(LS_OPERATION_RECONNECT.rawValue))
                return .accepted(heartbeatRawReply(reason: "reconnected", sessionID: sessionID))
            },
            .reconnected(originalExpiryMonotonic: 30)
        )
        XCTAssertEqual(reconnectCycle, [UInt32(LS_OPERATION_RECONNECT.rawValue)])

        var directAfterReconnect: [UInt32] = []
        XCTAssertThrowsError(try client.renewDirectForTesting(sessionID: sessionID) { operation, requested in
            XCTAssertEqual(requested, sessionID)
            directAfterReconnect.append(operation)
            XCTAssertEqual(operation, UInt32(LS_OPERATION_RENEW.rawValue))
            throw HelperControlError.indeterminateTransport(12)
        })
        XCTAssertEqual(directAfterReconnect, [UInt32(LS_OPERATION_RENEW.rawValue)])

        var nextCycle: [UInt32] = []
        let rebound = try client.renewForTesting(sessionID: sessionID) { operation, requested in
            XCTAssertEqual(requested, sessionID)
            nextCycle.append(operation)
            XCTAssertEqual(operation, UInt32(LS_OPERATION_RECONNECT.rawValue), "recovery marker must reconnect before another RENEW")
            return .accepted(heartbeatRawReply(reason: "reconnected", sessionID: sessionID))
        }
        XCTAssertEqual(rebound, .reconnected(originalExpiryMonotonic: 30))
        var finalDirect: [UInt32] = []
        XCTAssertEqual(
            try client.renewDirectForTesting(sessionID: sessionID) { operation, requested in
                XCTAssertEqual(requested, sessionID)
                finalDirect.append(operation)
                XCTAssertEqual(operation, UInt32(LS_OPERATION_RENEW.rawValue))
                return .accepted(heartbeatRawReply(reason: "verified", sessionID: sessionID, expiry: 38))
            },
            .renewed(expiryMonotonic: 38)
        )
        XCTAssertEqual(nextCycle, [UInt32(LS_OPERATION_RECONNECT.rawValue)])
        XCTAssertEqual(finalDirect, [UInt32(LS_OPERATION_RENEW.rawValue)])
        XCTAssertFalse((firstCycle + reconnectCycle + directAfterReconnect + nextCycle + finalDirect).contains(UInt32(LS_OPERATION_BEGIN.rawValue)))
    }

    func testRawReconnectNoAdvanceRetainsExactUnboundMarkerForNextTick() throws {
        let client = heartbeatRawClient()
        let sessionID = UUID()
        var firstCycle: [UInt32] = []
        XCTAssertThrowsError(try client.renewForTesting(sessionID: sessionID) { operation, requested in
            XCTAssertEqual(requested, sessionID)
            firstCycle.append(operation)
            XCTAssertEqual(operation, UInt32(LS_OPERATION_RENEW.rawValue))
            throw HelperControlError.indeterminateTransport(21)
        })
        XCTAssertEqual(firstCycle, [UInt32(LS_OPERATION_RENEW.rawValue)])

        var unboundReconnectCycle: [UInt32] = []
        XCTAssertEqual(
            try client.renewForTesting(sessionID: sessionID) { operation, requested in
                XCTAssertEqual(requested, sessionID)
                unboundReconnectCycle.append(operation)
                XCTAssertEqual(operation, UInt32(LS_OPERATION_RECONNECT.rawValue), "unbound reconnect must not dead-end at connection-mismatch")
                return .accepted(heartbeatRawReply(reason: "native-state-indeterminate", sessionID: sessionID))
            },
            .reconnectedButUnbound(reason: "native-state-indeterminate")
        )
        XCTAssertEqual(unboundReconnectCycle, [UInt32(LS_OPERATION_RECONNECT.rawValue)])

        var nextCycle: [UInt32] = []
        XCTAssertEqual(
            try client.renewForTesting(sessionID: sessionID) { operation, requested in
                XCTAssertEqual(requested, sessionID)
                nextCycle.append(operation)
                XCTAssertEqual(operation, UInt32(LS_OPERATION_RECONNECT.rawValue), "unbound reconnect must retry RECONNECT before RENEW")
                return .accepted(heartbeatRawReply(reason: "reconnected", sessionID: sessionID))
            },
            .reconnected(originalExpiryMonotonic: 30)
        )
        XCTAssertEqual(nextCycle, [UInt32(LS_OPERATION_RECONNECT.rawValue)])
        XCTAssertFalse((firstCycle + unboundReconnectCycle + nextCycle).contains(UInt32(LS_OPERATION_BEGIN.rawValue)))
    }

    func testCoordinatorAndRawClientDeferReconnectAcrossLogicalCycles() throws {
        let root = try TestSandbox.makeDirectory(label: "heartbeat-raw-cycle-boundary").url
        let client = heartbeatRawClient()
        let sessionID = UUID()
        let clock = HeartbeatLivenessBox<TimeInterval>(0)
        let logicalCycle = HeartbeatLivenessBox(0)
        let wireOperations = HeartbeatLivenessBox([UInt32]())
        let requestedSessions = HeartbeatLivenessBox([UUID]())
        let commitPermissions = HeartbeatLivenessBox([Bool]())
        let renewalModes = HeartbeatLivenessBox([SessionHeartbeatRenewalMode]())
        let restores = HeartbeatLivenessBox(0)
        let ended = HeartbeatLivenessBox([String]())
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 1,
            renewalInterval: 8,
            monotonicNow: { clock.read { $0 } },
            observe: { _ in
                SessionHeartbeatObservation(power: .ac, authority: .verified, helperStatus: nil)
            },
            renew: { requestedSessionID, mode, commitGuard -> SessionHeartbeatAdvance in
                requestedSessions.mutate { $0.append(requestedSessionID) }
                commitPermissions.mutate { $0.append(commitGuard()) }
                renewalModes.mutate { $0.append(mode) }
                let cycle = logicalCycle.read { $0 }
                let exchange: (UInt32, UUID) throws -> HelperControlExchangeOutcome = { operation, requested in
                    requestedSessions.mutate { $0.append(requested) }
                    wireOperations.mutate { $0.append(operation) }
                    if cycle == 1, mode == .recoverTransportOnce {
                        throw HelperControlError.indeterminateTransport(51)
                    }
                    if (cycle == 2 || cycle == 3), mode == .recoverTransportOnce {
                        return .accepted(heartbeatRawReply(reason: "reconnected", sessionID: sessionID))
                    }
                    if cycle == 2, mode == .directOnly {
                        throw HelperControlError.indeterminateTransport(52)
                    }
                    if cycle == 3, mode == .directOnly {
                        return .accepted(heartbeatRawReply(reason: "verified", sessionID: sessionID, expiry: 38))
                    }
                    throw HelperControlError.rejected("unexpected-heartbeat-wire-operation")
                }
                let advance: HelperLeaseAdvance
                switch mode {
                case .recoverTransportOnce:
                    advance = try client.renewForTesting(sessionID: requestedSessionID, exchange: exchange)
                case .directOnly:
                    advance = try client.renewDirectForTesting(sessionID: requestedSessionID, exchange: exchange)
                }
                switch advance {
                case let .renewed(expiryMonotonic):
                    return .renewed(expiryMonotonic: expiryMonotonic)
                case let .reconnected(originalExpiryMonotonic):
                    return .reconnected(originalExpiryMonotonic: originalExpiryMonotonic)
                case let .reconnectedButUnbound(reason):
                    return .reconnectedButUnbound(reason: reason)
                case let .indeterminateNoAdvance(reason):
                    return .indeterminateNoAdvance(reason: reason)
                }
            },
            revoke: { restores.mutate { $0 += 1 } },
            diagnostics: SessionDiagnosticStore(file: root.appendingPathComponent("history.json")),
            onAcknowledged: { _ in },
            onEnded: { _, reason in ended.mutate { $0.append(reason) } }
        )
        coordinator.start(sessionID: sessionID, initialLeaseExpiresMonotonic: 30, initiallyAcknowledged: true)

        logicalCycle.mutate { $0 = 1 }
        clock.mutate { $0 = 8 }
        coordinator.evaluateForTesting()
        XCTAssertEqual(wireOperations.read { $0 }, [UInt32(LS_OPERATION_RENEW.rawValue)])

        logicalCycle.mutate { $0 = 2 }
        clock.mutate { $0 = 9 }
        coordinator.evaluateForTesting()
        XCTAssertEqual(
            wireOperations.read { $0 },
            [UInt32(LS_OPERATION_RENEW.rawValue), UInt32(LS_OPERATION_RECONNECT.rawValue), UInt32(LS_OPERATION_RENEW.rawValue)]
        )

        logicalCycle.mutate { $0 = 3 }
        clock.mutate { $0 = 10 }
        coordinator.evaluateForTesting()
        XCTAssertEqual(
            wireOperations.read { $0 },
            [
                UInt32(LS_OPERATION_RENEW.rawValue),
                UInt32(LS_OPERATION_RECONNECT.rawValue), UInt32(LS_OPERATION_RENEW.rawValue),
                UInt32(LS_OPERATION_RECONNECT.rawValue), UInt32(LS_OPERATION_RENEW.rawValue),
            ]
        )
        XCTAssertEqual(
            renewalModes.read { $0 },
            [.recoverTransportOnce, .recoverTransportOnce, .directOnly, .recoverTransportOnce, .directOnly]
        )
        XCTAssertEqual(restores.read { $0 }, 0)
        XCTAssertTrue(ended.read { $0 }.isEmpty)
        XCTAssertTrue(requestedSessions.read { $0.allSatisfy { $0 == sessionID } })
        XCTAssertTrue(commitPermissions.read { $0.allSatisfy { $0 } })
        XCTAssertFalse(wireOperations.read { $0 }.contains(UInt32(LS_OPERATION_BEGIN.rawValue)))
    }

    func testRawTransportMarkersAreSessionBoundAndTerminalClearingIsExact() throws {
        let client = heartbeatRawClient()
        let sessionA = UUID()
        let sessionB = UUID()

        XCTAssertThrowsError(try client.renewDirectForTesting(sessionID: sessionA) { operation, _ in
            XCTAssertEqual(operation, UInt32(LS_OPERATION_RENEW.rawValue))
            throw HelperControlError.indeterminateTransport(31)
        })

        var beginB: [UInt32] = []
        XCTAssertEqual(
            try client.resolveBeginWithTransportStateForTesting(sessionID: sessionB) { operation, requested in
                XCTAssertEqual(requested, sessionB)
                beginB.append(operation)
                XCTAssertEqual(operation, UInt32(LS_OPERATION_BEGIN.rawValue))
                return .accepted(heartbeatRawReply(reason: "verified", sessionID: sessionB))
            },
            .issued(heartbeatRawReply(reason: "verified", sessionID: sessionB))
        )
        var renewB: [UInt32] = []
        _ = try client.renewDirectForTesting(sessionID: sessionB) { operation, requested in
            XCTAssertEqual(requested, sessionB)
            renewB.append(operation)
            return .accepted(heartbeatRawReply(reason: "verified", sessionID: sessionB, expiry: 38))
        }
        XCTAssertEqual(beginB + renewB, [UInt32(LS_OPERATION_BEGIN.rawValue), UInt32(LS_OPERATION_RENEW.rawValue)])

        var terminalA: [UInt32] = []
        let terminalResolution = client.terminateGenerationWithTransportStateForTesting(sessionID: sessionA, intent: .end) { operation, requested in
            terminalA.append(operation)
            XCTAssertEqual(operation, UInt32(LS_OPERATION_END.rawValue))
            XCTAssertEqual(requested, sessionA)
            return .accepted(heartbeatRawReply(reason: "user-end", sessionID: sessionA, expiry: 0, state: .terminal))
        }
        XCTAssertEqual(
            terminalResolution,
            .terminated(heartbeatRawReply(reason: "user-end", sessionID: sessionA, expiry: 0, state: .terminal))
        )
        XCTAssertEqual(terminalA, [UInt32(LS_OPERATION_END.rawValue)])

        var afterTerminalB: [UInt32] = []
        _ = try client.renewDirectForTesting(sessionID: sessionB) { operation, requested in
            XCTAssertEqual(requested, sessionB)
            afterTerminalB.append(operation)
            return .accepted(heartbeatRawReply(reason: "native-state-indeterminate", sessionID: sessionB, expiry: 46))
        }
        XCTAssertEqual(afterTerminalB, [UInt32(LS_OPERATION_RENEW.rawValue)], "terminal A cannot clear B's bound transport")

        var afterNoAdvanceB: [UInt32] = []
        _ = try client.renewForTesting(sessionID: sessionB) { operation, requested in
            XCTAssertEqual(requested, sessionB)
            afterNoAdvanceB.append(operation)
            return .accepted(heartbeatRawReply(reason: "verified", sessionID: sessionB, expiry: 54))
        }
        XCTAssertEqual(afterNoAdvanceB, [UInt32(LS_OPERATION_RENEW.rawValue)], "bound direct no-advance must not re-arm reconnect")

        var afterTerminal: [UInt32] = []
        _ = try client.renewForTesting(sessionID: sessionA) { operation, requested in
            XCTAssertEqual(requested, sessionA)
            afterTerminal.append(operation)
            return .accepted(heartbeatRawReply(reason: "verified", sessionID: sessionA, expiry: 38))
        }
        XCTAssertEqual(afterTerminal, [UInt32(LS_OPERATION_RENEW.rawValue)], "terminal clears only A's recovery marker")
        XCTAssertFalse((beginB + renewB + terminalA + afterTerminalB + afterNoAdvanceB + afterTerminal).contains(UInt32(LS_OPERATION_RESTORE.rawValue)))
    }

    func testDiagnosticProjectionFaultsDoNotBlockRenewOrBoundedReconnect() throws {
        let fixtureNow = Date(timeIntervalSince1970: 10_000)
        let variants: [(String, @Sendable (UUID) -> HelperStatusRecord?)] = [
            ("missing-or-corrupt", { _ in nil }),
            ("stale-active", { sessionID in
                HelperStatusRecord(
                    state: "active", reason: "verified", sessionID: sessionID,
                    updatedAt: fixtureNow.addingTimeInterval(-13)
                )
            }),
            ("wrong-session-active", { _ in
                HelperStatusRecord(state: "active", reason: "verified", sessionID: UUID(), updatedAt: fixtureNow)
            }),
        ]

        for (label, makeStatus) in variants {
            let root = try TestSandbox.makeDirectory(label: "heartbeat-projection-\(label)").url
            let clock = HeartbeatLivenessBox<TimeInterval>(0)
            let renewals = HeartbeatLivenessBox([SessionHeartbeatAdvance]())
            let restores = HeartbeatLivenessBox(0)
            let ended = HeartbeatLivenessBox([String]())
            let sessionID = UUID()
            let status = makeStatus(sessionID)
            let coordinator = SessionHeartbeatCoordinator(
                observationInterval: 1,
                renewalInterval: 8,
                now: { fixtureNow },
                monotonicNow: { clock.read { $0 } },
                observe: { _ in
                    SessionHeartbeatObservation(power: .ac, authority: .verified, helperStatus: status)
                },
                renew: { _, _ in
                    let ordinal = renewals.read { $0.count }
                    let advance: SessionHeartbeatAdvance
                    switch ordinal {
                    case 0: advance = .renewed(expiryMonotonic: 38)
                    case 1: advance = .reconnected(originalExpiryMonotonic: 38)
                    case 2: advance = .renewed(expiryMonotonic: 46)
                    default: advance = .renewed(expiryMonotonic: 54)
                    }
                    renewals.mutate { $0.append(advance) }
                    return advance
                },
                revoke: { restores.mutate { $0 += 1 } },
                diagnostics: SessionDiagnosticStore(file: root.appendingPathComponent("history.json")),
                onAcknowledged: { _ in },
                onEnded: { _, reason in ended.mutate { $0.append(reason) } }
            )

            coordinator.start(sessionID: sessionID, initialLeaseExpiresMonotonic: 30, initiallyAcknowledged: true)
            for instant in [8.0, 16.0, 24.0] {
                clock.mutate { $0 = instant }
                coordinator.evaluateForTesting()
            }

            XCTAssertEqual(restores.read { $0 }, 0, "\(label) must stay diagnostic")
            XCTAssertTrue(ended.read { $0 }.isEmpty, "\(label) must not terminalize")
            XCTAssertEqual(renewals.read { $0 }.count, 4, "\(label) must keep RENEW and one bounded RECONNECT live")
            coordinator.stop(reason: "test-complete")
        }
    }

    func testAcceptedNoAdvanceRetainsOldDeadlineAndNeverRecordsRenewal() throws {
        let root = try TestSandbox.makeDirectory(label: "heartbeat-no-advance").url
        let clock = HeartbeatLivenessBox<TimeInterval>(0)
        let power = HeartbeatLivenessBox(SessionHeartbeatObservation.Power.ac)
        let renewCalls = HeartbeatLivenessBox(0)
        let restores = HeartbeatLivenessBox(0)
        let ended = HeartbeatLivenessBox([String]())
        let diagnostics = SessionDiagnosticStore(file: root.appendingPathComponent("history.json"))
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 1,
            renewalInterval: 8,
            monotonicNow: { clock.read { $0 } },
            observe: { _ in
                let current = power.read { $0 }
                return SessionHeartbeatObservation(
                    power: current,
                    authority: current == .ac ? .verified : .indeterminate,
                    helperStatus: nil
                )
            },
            renew: { _, _ in
                let ordinal = renewCalls.read { $0 }
                renewCalls.mutate { $0 += 1 }
                return ordinal == 0
                    ? .indeterminateNoAdvance(reason: "power-source-unconfirmed")
                    : .renewed(expiryMonotonic: 38)
            },
            revoke: { restores.mutate { $0 += 1 } },
            diagnostics: diagnostics,
            onAcknowledged: { _ in },
            onEnded: { _, reason in ended.mutate { $0.append(reason) } }
        )
        let sessionID = UUID()
        coordinator.start(sessionID: sessionID, initialLeaseExpiresMonotonic: 30, initiallyAcknowledged: true)
        clock.mutate { $0 = 8 }
        coordinator.evaluateForTesting()
        XCTAssertTrue(diagnostics.flushForTesting())
        XCTAssertFalse(diagnostics.entries().contains { $0.event == "renew-summary" })

        // Withhold a later renewal under persistent unknown power, then cross
        // the original hard expiry. No-advance must not overwrite that deadline
        // or turn the helper-owned expiry rollback into a late RESTORE.
        power.mutate { $0 = .unknown }
        clock.mutate { $0 = 31 }
        coordinator.evaluateForTesting()
        XCTAssertEqual(renewCalls.read { $0 }, 1)
        XCTAssertEqual(restores.read { $0 }, 0, "hard expiry is local-only after no-advance")
        XCTAssertEqual(ended.read { $0 }, ["lease-expired-before-renewal"])
    }

    func testUnknownPowerWithholdsRenewalWithoutRestoreThenRecoversOnAC() throws {
        let root = try TestSandbox.makeDirectory(label: "heartbeat-unknown").url
        let clock = HeartbeatLivenessBox<TimeInterval>(0)
        let power = HeartbeatLivenessBox(SessionHeartbeatObservation.Power.unknown)
        let renewals = HeartbeatLivenessBox(0)
        let restores = HeartbeatLivenessBox(0)
        let ended = HeartbeatLivenessBox([String]())
        let diagnostics = SessionDiagnosticStore(file: root.appendingPathComponent("history.json"))
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 1,
            renewalInterval: 8,
            monotonicNow: { clock.read { $0 } },
            observe: { _ in
                let current = power.read { $0 }
                return SessionHeartbeatObservation(
                    power: current,
                    authority: current == .ac ? .verified : .indeterminate,
                    helperStatus: nil
                )
            },
            renew: { _, _ in
                renewals.mutate { $0 += 1 }
                return .renewed(expiryMonotonic: 39)
            },
            revoke: { restores.mutate { $0 += 1 } },
            diagnostics: diagnostics,
            onAcknowledged: { _ in },
            onEnded: { _, reason in ended.mutate { $0.append(reason) } }
        )
        let sessionID = UUID()
        coordinator.start(sessionID: sessionID, initialLeaseExpiresMonotonic: 30, initiallyAcknowledged: true)
        for instant in [8.0, 9.0, 10.0] {
            clock.mutate { $0 = instant }
            coordinator.evaluateForTesting()
        }
        XCTAssertEqual(renewals.read { $0 }, 0)
        XCTAssertEqual(restores.read { $0 }, 0)
        XCTAssertTrue(ended.read { $0 }.isEmpty)
        XCTAssertTrue(diagnostics.flushForTesting())
        XCTAssertFalse(diagnostics.entries().contains { $0.event == "end" })

        power.mutate { $0 = .ac }
        clock.mutate { $0 = 11 }
        coordinator.evaluateForTesting()
        XCTAssertEqual(renewals.read { $0 }, 1)
        XCTAssertEqual(restores.read { $0 }, 0)
        XCTAssertTrue(ended.read { $0 }.isEmpty)
    }

    func testVirtualTwentyFourMinuteRunRecoversOneBoundedUncertaintyWindowWithoutTermination() throws {
        let root = try TestSandbox.makeDirectory(label: "heartbeat-24m-window").url
        let clock = HeartbeatLivenessBox<TimeInterval>(0)
        let renewals = HeartbeatLivenessBox(0)
        let restores = HeartbeatLivenessBox(0)
        let ended = HeartbeatLivenessBox([String]())
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 1,
            renewalInterval: 8,
            monotonicNow: { clock.read { $0 } },
            observe: { _ in
                let power: SessionHeartbeatObservation.Power = clock.read { $0 } == 600 ? .unknown : .ac
                return SessionHeartbeatObservation(
                    power: power,
                    authority: power == .ac ? .verified : .indeterminate,
                    helperStatus: nil
                )
            },
            renew: { _, _ in
                renewals.mutate { $0 += 1 }
                return .renewed(expiryMonotonic: clock.read { $0 } + 30)
            },
            revoke: { restores.mutate { $0 += 1 } },
            diagnostics: SessionDiagnosticStore(file: root.appendingPathComponent("history.json")),
            onAcknowledged: { _ in },
            onEnded: { _, reason in ended.mutate { $0.append(reason) } }
        )
        coordinator.start(sessionID: UUID(), initialLeaseExpiresMonotonic: 30, initiallyAcknowledged: true)

        for instant in stride(from: 8.0, through: 1_440.0, by: 8.0) {
            clock.mutate { $0 = instant }
            coordinator.evaluateForTesting()
        }

        XCTAssertEqual(renewals.read { $0 }, 179, "one bounded unknown-power tick must withhold one renewal, then recover on AC")
        XCTAssertEqual(restores.read { $0 }, 0)
        XCTAssertTrue(ended.read { $0 }.isEmpty)
    }

    func testIndeterminateRenewalDoesNotRestoreOrRearm() throws {
        let root = try TestSandbox.makeDirectory(label: "heartbeat-indeterminate").url
        let clock = HeartbeatLivenessBox<TimeInterval>(0)
        let renewals = HeartbeatLivenessBox(0)
        let restores = HeartbeatLivenessBox(0)
        let ended = HeartbeatLivenessBox([String]())
        let diagnostics = SessionDiagnosticStore(file: root.appendingPathComponent("history.json"))
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 1,
            renewalInterval: 8,
            monotonicNow: { clock.read { $0 } },
            observe: { _ in SessionHeartbeatObservation(power: .ac, authority: .verified, helperStatus: nil) },
            renew: { _, _, _ -> SessionHeartbeatAdvance in
                renewals.mutate { $0 += 1 }
                throw HelperControlError.indeterminateTransport(9)
            },
            revoke: { restores.mutate { $0 += 1 } },
            diagnostics: diagnostics,
            onAcknowledged: { _ in },
            onEnded: { _, reason in ended.mutate { $0.append(reason) } }
        )
        coordinator.start(sessionID: UUID(), initialLeaseExpiresMonotonic: 30, initiallyAcknowledged: true)
        clock.mutate { $0 = 8 }
        coordinator.evaluateForTesting()
        XCTAssertEqual(renewals.read { $0 }, 1)
        XCTAssertEqual(restores.read { $0 }, 0)
        XCTAssertTrue(ended.read { $0 }.isEmpty)
        XCTAssertTrue(diagnostics.flushForTesting())
        XCTAssertFalse(diagnostics.entries().contains { $0.event == "end" })
    }

    func testPersistentUnknownAtHardExpiryEndsLocallyWithoutRestoreOrRearm() throws {
        let root = try TestSandbox.makeDirectory(label: "heartbeat-unknown-expiry").url
        let clock = HeartbeatLivenessBox<TimeInterval>(0)
        let renewals = HeartbeatLivenessBox(0)
        let restores = HeartbeatLivenessBox(0)
        let ended = HeartbeatLivenessBox([String]())
        let diagnostics = SessionDiagnosticStore(file: root.appendingPathComponent("history.json"))
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 1,
            renewalInterval: 8,
            monotonicNow: { clock.read { $0 } },
            observe: { _ in SessionHeartbeatObservation(power: .unknown, authority: .indeterminate, helperStatus: nil) },
            renew: { _, _ in renewals.mutate { $0 += 1 }; return .renewed(expiryMonotonic: 60) },
            revoke: { restores.mutate { $0 += 1 } },
            diagnostics: diagnostics,
            onAcknowledged: { _ in },
            onEnded: { _, reason in ended.mutate { $0.append(reason) } }
        )
        coordinator.start(sessionID: UUID(), initialLeaseExpiresMonotonic: 30, initiallyAcknowledged: true)
        for instant in [8.0, 16.0, 30.0, 31.0] {
            clock.mutate { $0 = instant }
            coordinator.evaluateForTesting()
        }

        XCTAssertEqual(renewals.read { $0 }, 0)
        XCTAssertEqual(restores.read { $0 }, 0, "hard expiry is a local terminal publication, not a late RESTORE")
        XCTAssertEqual(ended.read { $0 }, ["lease-expired-before-renewal"])
        XCTAssertTrue(diagnostics.flushForTesting())
        XCTAssertEqual(diagnostics.entries().filter { $0.event == "end" }.map(\.reason), ["lease-expired-before-renewal"])
    }

    func testPostReconnectDirectRenewalCannotRequestAnotherReconnect() throws {
        let root = try TestSandbox.makeDirectory(label: "heartbeat-direct-renew").url
        let clock = HeartbeatLivenessBox<TimeInterval>(0)
        let modes = HeartbeatLivenessBox([SessionHeartbeatRenewalMode]())
        let restores = HeartbeatLivenessBox(0)
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 1,
            renewalInterval: 8,
            monotonicNow: { clock.read { $0 } },
            observe: { _ in SessionHeartbeatObservation(power: .ac, authority: .verified, helperStatus: nil) },
            renew: { _, mode, _ in
                modes.mutate { $0.append(mode) }
                if mode == .recoverTransportOnce { return .reconnected(originalExpiryMonotonic: 30) }
                throw HelperControlError.indeterminateTransport(9)
            },
            revoke: { restores.mutate { $0 += 1 } },
            diagnostics: SessionDiagnosticStore(file: root.appendingPathComponent("history.json")),
            onAcknowledged: { _ in },
            onEnded: { _, _ in }
        )
        coordinator.start(sessionID: UUID(), initialLeaseExpiresMonotonic: 30, initiallyAcknowledged: true)
        clock.mutate { $0 = 8 }
        coordinator.evaluateForTesting()
        XCTAssertEqual(modes.read { $0 }, [.recoverTransportOnce, .directOnly])
        XCTAssertEqual(restores.read { $0 }, 0)
    }

    func testUnboundReconnectAdvanceDefersDirectRenewalUntilNextLogicalCycle() throws {
        let root = try TestSandbox.makeDirectory(label: "heartbeat-unbound-reconnect").url
        let clock = HeartbeatLivenessBox<TimeInterval>(0)
        let modes = HeartbeatLivenessBox([SessionHeartbeatRenewalMode]())
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 1,
            renewalInterval: 8,
            monotonicNow: { clock.read { $0 } },
            observe: { _ in SessionHeartbeatObservation(power: .ac, authority: .verified, helperStatus: nil) },
            renew: { _, mode, _ in
                let ordinal = modes.read { $0.count }
                modes.mutate { $0.append(mode) }
                switch ordinal {
                case 0:
                    XCTAssertEqual(mode, .recoverTransportOnce)
                    return .reconnectedButUnbound(reason: "native-state-indeterminate")
                case 1:
                    XCTAssertEqual(mode, .recoverTransportOnce)
                    return .reconnected(originalExpiryMonotonic: 30)
                default:
                    XCTAssertEqual(mode, .directOnly)
                    return .renewed(expiryMonotonic: 38)
                }
            },
            revoke: {},
            diagnostics: SessionDiagnosticStore(file: root.appendingPathComponent("history.json")),
            onAcknowledged: { _ in },
            onEnded: { _, _ in }
        )
        coordinator.start(sessionID: UUID(), initialLeaseExpiresMonotonic: 30, initiallyAcknowledged: true)
        clock.mutate { $0 = 8 }
        coordinator.evaluateForTesting()
        XCTAssertEqual(modes.read { $0 }, [.recoverTransportOnce])

        clock.mutate { $0 = 9 }
        coordinator.evaluateForTesting()
        XCTAssertEqual(modes.read { $0 }, [.recoverTransportOnce, .recoverTransportOnce, .directOnly])
    }

    func testReconnectBaselinesNeverRegressAndCommitOnlyDirectStrictAdvance() throws {
        let cases: [(String, TimeInterval, TimeInterval?, [SessionHeartbeatRenewalMode])] = [
            ("lower", 29, nil, [.recoverTransportOnce]),
            ("equal", 30, 38, [.recoverTransportOnce, .directOnly]),
            ("greater", 35, 40, [.recoverTransportOnce, .directOnly]),
        ]
        for (label, baseline, directExpiry, expectedModes) in cases {
            let root = try TestSandbox.makeDirectory(label: "heartbeat-baseline-\(label)").url
            let clock = HeartbeatLivenessBox<TimeInterval>(0)
            let power = HeartbeatLivenessBox(SessionHeartbeatObservation.Power.ac)
            let modes = HeartbeatLivenessBox([SessionHeartbeatRenewalMode]())
            let ended = HeartbeatLivenessBox([String]())
            let coordinator = SessionHeartbeatCoordinator(
                observationInterval: 1,
                renewalInterval: 8,
                monotonicNow: { clock.read { $0 } },
                observe: { _ in
                    let current = power.read { $0 }
                    return SessionHeartbeatObservation(power: current, authority: current == .ac ? .verified : .indeterminate, helperStatus: nil)
                },
                renew: { _, mode, _ in
                    modes.mutate { $0.append(mode) }
                    if mode == .recoverTransportOnce { return .reconnected(originalExpiryMonotonic: baseline) }
                    return .renewed(expiryMonotonic: directExpiry!)
                },
                revoke: {},
                diagnostics: SessionDiagnosticStore(file: root.appendingPathComponent("history.json")),
                onAcknowledged: { _ in },
                onEnded: { _, reason in ended.mutate { $0.append(reason) } }
            )
            coordinator.start(sessionID: UUID(), initialLeaseExpiresMonotonic: 30, initiallyAcknowledged: true)
            clock.mutate { $0 = 8 }
            coordinator.evaluateForTesting()
            XCTAssertEqual(modes.read { $0 }, expectedModes, label)
            power.mutate { $0 = .unknown }
            clock.mutate { $0 = 29 }
            coordinator.evaluateForTesting()
            XCTAssertTrue(ended.read { $0 }.isEmpty, "\(label) must retain at least the pre-reconnect hard expiry")
            if directExpiry != nil {
                clock.mutate { $0 = 31 }
                coordinator.evaluateForTesting()
                XCTAssertTrue(ended.read { $0 }.isEmpty, "\(label) direct strict advance must commit above pre-reconnect expiry")
            }
        }
    }

    func testGreaterReconnectBaselineRetainsLostRenewalExpiryAfterDirectNoAdvance() throws {
        let root = try TestSandbox.makeDirectory(label: "heartbeat-lost-renewal").url
        let clock = HeartbeatLivenessBox<TimeInterval>(0)
        let power = HeartbeatLivenessBox(SessionHeartbeatObservation.Power.ac)
        let modes = HeartbeatLivenessBox([SessionHeartbeatRenewalMode]())
        let restores = HeartbeatLivenessBox(0)
        let ended = HeartbeatLivenessBox([String]())
        let diagnostics = SessionDiagnosticStore(file: root.appendingPathComponent("history.json"))
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 1,
            renewalInterval: 8,
            monotonicNow: { clock.read { $0 } },
            observe: { _ in
                let current = power.read { $0 }
                return SessionHeartbeatObservation(
                    power: current,
                    authority: current == .ac ? .verified : .indeterminate,
                    helperStatus: nil
                )
            },
            renew: { _, mode, _ in
                modes.mutate { $0.append(mode) }
                if mode == .recoverTransportOnce {
                    return .reconnected(originalExpiryMonotonic: 35)
                }
                return .indeterminateNoAdvance(reason: "native-state-indeterminate")
            },
            revoke: { restores.mutate { $0 += 1 } },
            diagnostics: diagnostics,
            onAcknowledged: { _ in },
            onEnded: { _, reason in ended.mutate { $0.append(reason) } }
        )
        coordinator.start(sessionID: UUID(), initialLeaseExpiresMonotonic: 30, initiallyAcknowledged: true)
        clock.mutate { $0 = 8 }
        coordinator.evaluateForTesting()

        power.mutate { $0 = .unknown }
        clock.mutate { $0 = 31 }
        coordinator.evaluateForTesting()
        XCTAssertEqual(modes.read { $0 }, [.recoverTransportOnce, .directOnly])
        XCTAssertTrue(ended.read { $0 }.isEmpty, "the authenticated lost-renewal expiry must outlive the old deadline")
        XCTAssertEqual(restores.read { $0 }, 0)
        XCTAssertTrue(diagnostics.flushForTesting())
        XCTAssertFalse(diagnostics.entries().contains { $0.event == "renew-summary" })

        clock.mutate { $0 = 36 }
        coordinator.evaluateForTesting()
        XCTAssertEqual(ended.read { $0 }, ["lease-expired-before-renewal"])
        XCTAssertEqual(restores.read { $0 }, 0, "hard expiry remains helper-owned even after recovered baseline")
    }

    func testProjectionDegradationIsOncePerGenerationAndResetsOnStart() throws {
        let root = try TestSandbox.makeDirectory(label: "heartbeat-projection-reset").url
        let clock = HeartbeatLivenessBox<TimeInterval>(0)
        let status = HeartbeatLivenessBox<HelperStatusRecord?>(nil)
        let diagnostics = SessionDiagnosticStore(file: root.appendingPathComponent("history.json"))
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 1,
            monotonicNow: { clock.read { $0 } },
            observe: { _ in
                SessionHeartbeatObservation(
                    power: .unknown,
                    authority: .indeterminate,
                    helperStatus: status.read { $0 }
                )
            },
            renew: { _, _ in .renewed(expiryMonotonic: 30) },
            revoke: {}, diagnostics: diagnostics,
            onAcknowledged: { _ in }, onEnded: { _, _ in }
        )
        let firstSession = UUID()
        coordinator.start(sessionID: firstSession, initialLeaseExpiresMonotonic: 30, initiallyAcknowledged: true)
        coordinator.evaluateForTesting()
        status.mutate {
            $0 = HelperStatusRecord(state: "active", reason: "verified", sessionID: firstSession, updatedAt: Date())
        }
        coordinator.evaluateForTesting()
        status.mutate { $0 = nil }
        coordinator.evaluateForTesting()
        _ = coordinator.stop(reason: "test-complete")
        coordinator.start(sessionID: UUID(), initialLeaseExpiresMonotonic: 30, initiallyAcknowledged: true)
        coordinator.evaluateForTesting()
        XCTAssertTrue(diagnostics.flushForTesting())
        XCTAssertEqual(diagnostics.entries().filter { $0.event == "degraded" }.count, 2)
    }

    func testDisconnectedPowerWinsAtHardExpiryAndPerformsExactlyOneRestore() throws {
        let root = try TestSandbox.makeDirectory(label: "heartbeat-disconnect-priority").url
        let clock = HeartbeatLivenessBox<TimeInterval>(30)
        let restores = HeartbeatLivenessBox(0)
        let ended = HeartbeatLivenessBox([String]())
        let diagnostics = SessionDiagnosticStore(file: root.appendingPathComponent("history.json"))
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 1,
            monotonicNow: { clock.read { $0 } },
            observe: { _ in SessionHeartbeatObservation(power: .disconnected, authority: .indeterminate, helperStatus: nil) },
            renew: { _, _ in .renewed(expiryMonotonic: 60) },
            revoke: { restores.mutate { $0 += 1 } },
            diagnostics: diagnostics,
            onAcknowledged: { _ in },
            onEnded: { _, reason in ended.mutate { $0.append(reason) } }
        )
        coordinator.start(sessionID: UUID(), initialLeaseExpiresMonotonic: 30, initiallyAcknowledged: true)
        coordinator.evaluateForTesting()
        coordinator.evaluateForTesting()

        XCTAssertEqual(restores.read { $0 }, 1)
        XCTAssertEqual(ended.read { $0 }, ["power-disconnected"])
        XCTAssertTrue(diagnostics.flushForTesting())
        XCTAssertEqual(diagnostics.entries().filter { $0.event == "end" }.map(\.reason), ["power-disconnected"])
    }

    func testHeartbeatTerminalProofHandoffRetainsExactAuthenticatedResolution() {
        let sessionID = UUID()
        let reply = HelperControlReply(
            reason: "restored", sessionID: sessionID, expiryMonotonic: 0,
            state: .idle, power: .ac, sleepDisabled: false, acSleepMinutes: 5
        )
        XCTAssertTrue(PowerController.heartbeatAuthenticatedCleanupReplyProofForTesting(
            sessionID: sessionID,
            originalACIdleSleepMinutes: 5,
            resolution: .terminated(reply)
        ))
    }

    func testFreshTerminalProjectionAndDisconnectedPowerRemainImmediateTerminalProof() throws {
        let fixtureNow = Date(timeIntervalSince1970: 10_000)
        for (label, observation) in [
            ("terminal-projection", SessionHeartbeatObservation(
                power: .ac, authority: .verified,
                helperStatus: HelperStatusRecord(state: "terminal", reason: "ac-disconnect", sessionID: nil, updatedAt: fixtureNow)
            )),
            ("native-disconnected", SessionHeartbeatObservation(power: .disconnected, authority: .indeterminate, helperStatus: nil)),
            ("authority-terminal", SessionHeartbeatObservation(power: .ac, authority: .terminal("helper-expired"), helperStatus: nil)),
        ] {
            let root = try TestSandbox.makeDirectory(label: "heartbeat-terminal-\(label)").url
            let restores = HeartbeatLivenessBox(0)
            let renewals = HeartbeatLivenessBox(0)
            let ended = HeartbeatLivenessBox([String]())
            let sessionID = UUID()
            let coordinator = SessionHeartbeatCoordinator(
                observationInterval: 1,
                now: { fixtureNow },
                observe: { _ in
                    if label == "terminal-projection" {
                        return SessionHeartbeatObservation(
                            power: observation.power, authority: observation.authority,
                            helperStatus: HelperStatusRecord(state: "terminal", reason: "ac-disconnect", sessionID: sessionID, updatedAt: fixtureNow)
                        )
                    }
                    return observation
                },
                renew: { _, _ in renewals.mutate { $0 += 1 }; return .renewed(expiryMonotonic: 30) },
                revoke: { restores.mutate { $0 += 1 } },
                diagnostics: SessionDiagnosticStore(file: root.appendingPathComponent("history.json")),
                onAcknowledged: { _ in },
                onEnded: { _, reason in ended.mutate { $0.append(reason) } }
            )
            coordinator.start(sessionID: sessionID, initialLeaseExpiresMonotonic: 30, initiallyAcknowledged: true)
            coordinator.evaluateForTesting()
            XCTAssertEqual(restores.read { $0 }, 1, "\(label)")
            XCTAssertEqual(renewals.read { $0 }, 0, "\(label)")
            XCTAssertEqual(ended.read { $0 }.count, 1, "\(label)")
        }
    }

    func testRenewalUsesOneFreshWriteBoundaryObservationAndReconnectUsesOneMore() throws {
        let root = try TestSandbox.makeDirectory(label: "heartbeat-observation-budget").url
        let clock = HeartbeatLivenessBox<TimeInterval>(0)
        let observations = HeartbeatLivenessBox(0)
        let renewals = HeartbeatLivenessBox(0)
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 1,
            renewalInterval: 8,
            monotonicNow: { clock.read { $0 } },
            observe: { _ in
                observations.mutate { $0 += 1 }
                return SessionHeartbeatObservation(power: .ac, authority: .verified, helperStatus: nil)
            },
            renew: { _, commit in
                XCTAssertTrue(commit(), "RENEW must only cross a fresh AC/authority write boundary")
                let ordinal = renewals.read { $0 }
                renewals.mutate { $0 += 1 }
                return ordinal == 0
                    ? .reconnected(originalExpiryMonotonic: 8.1)
                    : .renewed(expiryMonotonic: 38)
            },
            revoke: {},
            diagnostics: SessionDiagnosticStore(file: root.appendingPathComponent("history.json")),
            onAcknowledged: { _ in },
            onEnded: { _, _ in }
        )
        coordinator.start(sessionID: UUID(), initialLeaseExpiresMonotonic: 8.1, initiallyAcknowledged: true)
        clock.mutate { $0 = 8 }
        coordinator.evaluateForTesting()
        XCTAssertEqual(renewals.read { $0 }, 2)
        XCTAssertEqual(observations.read { $0 }, 4, "tick + write boundary + reconnect observation + immediate write boundary")
    }

    func testFreshTerminalTruthAtRenewalWriteBoundaryPreventsWireRenewalExactlyOnce() throws {
        let fixtureNow = Date(timeIntervalSince1970: 10_000)
        for (label, expectedReason) in [
            ("terminal-projection", "helper-terminal-ac-disconnect"),
            ("terminal-authority", "helper-terminal-authenticated-expired"),
        ] {
            let root = try TestSandbox.makeDirectory(label: "heartbeat-write-terminal-\(label)").url
            let clock = HeartbeatLivenessBox<TimeInterval>(0)
            let observations = HeartbeatLivenessBox(0)
            let committedWireRenewals = HeartbeatLivenessBox(0)
            let restores = HeartbeatLivenessBox(0)
            let ended = HeartbeatLivenessBox([String]())
            let diagnostics = SessionDiagnosticStore(file: root.appendingPathComponent("history.json"))
            let sessionID = UUID()
            let coordinator = SessionHeartbeatCoordinator(
                observationInterval: 1,
                renewalInterval: 8,
                now: { fixtureNow },
                monotonicNow: { clock.read { $0 } },
                observe: { requestedSessionID in
                    let ordinal = observations.read { $0 }
                    observations.mutate { $0 += 1 }
                    guard ordinal > 0 else {
                        return SessionHeartbeatObservation(
                            power: .ac,
                            authority: .verified,
                            helperStatus: HelperStatusRecord(
                                state: "active",
                                reason: "verified",
                                sessionID: requestedSessionID,
                                updatedAt: fixtureNow
                            )
                        )
                    }
                    if label == "terminal-projection" {
                        return SessionHeartbeatObservation(
                            power: .ac,
                            authority: .verified,
                            helperStatus: HelperStatusRecord(
                                state: "terminal",
                                reason: "ac-disconnect",
                                sessionID: requestedSessionID,
                                updatedAt: fixtureNow
                            )
                        )
                    }
                    return SessionHeartbeatObservation(
                        power: .ac,
                        authority: .terminal("authenticated-expired"),
                        helperStatus: nil
                    )
                },
                // Mirrors PowerController's production order: a false commit
                // guard throws before the RawHelperControlClient wire RENEW.
                renew: { _, _, commitGuard -> SessionHeartbeatAdvance in
                    guard commitGuard() else {
                        throw HelperControlError.rejected("fresh-terminal-write-boundary")
                    }
                    committedWireRenewals.mutate { $0 += 1 }
                    return .renewed(expiryMonotonic: 38)
                },
                revoke: { restores.mutate { $0 += 1 } },
                diagnostics: diagnostics,
                onAcknowledged: { _ in },
                onEnded: { _, reason in ended.mutate { $0.append(reason) } }
            )
            coordinator.start(sessionID: sessionID, initialLeaseExpiresMonotonic: 30, initiallyAcknowledged: true)
            clock.mutate { $0 = 8 }
            coordinator.evaluateForTesting()
            clock.mutate { $0 = 9 }
            coordinator.evaluateForTesting()

            XCTAssertEqual(observations.read { $0 }, 2, "\(label) must terminalize at the write boundary without rearm")
            XCTAssertEqual(committedWireRenewals.read { $0 }, 0, "\(label) must block the wire RENEW")
            XCTAssertEqual(restores.read { $0 }, 1, "\(label) must retain one safety cleanup")
            XCTAssertEqual(ended.read { $0 }, [expectedReason])
            XCTAssertTrue(diagnostics.flushForTesting())
            XCTAssertEqual(diagnostics.entries().filter { $0.event == "end" }.map(\.reason), [expectedReason])
        }
    }

    func testFreshInactiveProjectionAtRenewalWriteBoundaryRemainsDiagnosticAndRenews() throws {
        let fixtureNow = Date(timeIntervalSince1970: 10_000)
        let root = try TestSandbox.makeDirectory(label: "heartbeat-write-inactive").url
        let clock = HeartbeatLivenessBox<TimeInterval>(0)
        let observations = HeartbeatLivenessBox(0)
        let committedWireRenewals = HeartbeatLivenessBox(0)
        let restores = HeartbeatLivenessBox(0)
        let ended = HeartbeatLivenessBox([String]())
        let diagnostics = SessionDiagnosticStore(file: root.appendingPathComponent("history.json"))
        let sessionID = UUID()
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 1,
            renewalInterval: 8,
            now: { fixtureNow },
            monotonicNow: { clock.read { $0 } },
            observe: { requestedSessionID in
                let ordinal = observations.read { $0 }
                observations.mutate { $0 += 1 }
                guard ordinal > 0 else {
                    return SessionHeartbeatObservation(
                        power: .ac,
                        authority: .verified,
                        helperStatus: HelperStatusRecord(
                            state: "active",
                            reason: "verified",
                            sessionID: requestedSessionID,
                            updatedAt: fixtureNow
                        )
                    )
                }
                return SessionHeartbeatObservation(
                    power: .ac,
                    authority: .verified,
                    helperStatus: HelperStatusRecord(
                        state: "inactive",
                        reason: "override-lost",
                        sessionID: requestedSessionID,
                        updatedAt: fixtureNow
                    )
                )
            },
            renew: { _, _, commitGuard -> SessionHeartbeatAdvance in
                guard commitGuard() else {
                    throw HelperControlError.rejected("inactive-projection-must-remain-diagnostic")
                }
                committedWireRenewals.mutate { $0 += 1 }
                return .renewed(expiryMonotonic: 38)
            },
            revoke: { restores.mutate { $0 += 1 } },
            diagnostics: diagnostics,
            onAcknowledged: { _ in },
            onEnded: { _, reason in ended.mutate { $0.append(reason) } }
        )
        coordinator.start(sessionID: sessionID, initialLeaseExpiresMonotonic: 30, initiallyAcknowledged: true)
        clock.mutate { $0 = 8 }
        coordinator.evaluateForTesting()

        XCTAssertEqual(observations.read { $0 }, 2)
        XCTAssertEqual(committedWireRenewals.read { $0 }, 1)
        XCTAssertEqual(restores.read { $0 }, 0)
        XCTAssertTrue(ended.read { $0 }.isEmpty)
        XCTAssertTrue(diagnostics.flushForTesting())
        XCTAssertTrue(diagnostics.entries().filter { $0.event == "end" }.isEmpty)
    }

    func testFinalWriteBoundaryExpiryUsesOneSampleAndFinishesWithoutLaterTick() throws {
        let root = try TestSandbox.makeDirectory(label: "heartbeat-final-boundary-expiry").url
        let samples: [TimeInterval] = [0, 29.999, 30.000]
        let sampleIndex = HeartbeatLivenessBox(0)
        let observations = HeartbeatLivenessBox(0)
        let renewalAttempts = HeartbeatLivenessBox(0)
        let committedWireRenewals = HeartbeatLivenessBox(0)
        let restores = HeartbeatLivenessBox(0)
        let ended = HeartbeatLivenessBox([String]())
        let diagnostics = SessionDiagnosticStore(file: root.appendingPathComponent("history.json"))
        let coordinator = SessionHeartbeatCoordinator(
            observationInterval: 1,
            renewalInterval: 8,
            monotonicNow: {
                let ordinal = sampleIndex.read { $0 }
                sampleIndex.mutate { $0 += 1 }
                return samples[min(ordinal, samples.count - 1)]
            },
            observe: { _ in
                observations.mutate { $0 += 1 }
                return SessionHeartbeatObservation(power: .ac, authority: .verified, helperStatus: nil)
            },
            renew: { _, _, commitGuard -> SessionHeartbeatAdvance in
                renewalAttempts.mutate { $0 += 1 }
                guard commitGuard() else {
                    throw HelperControlError.rejected("final-boundary-expiry")
                }
                committedWireRenewals.mutate { $0 += 1 }
                return .renewed(expiryMonotonic: 38)
            },
            revoke: { restores.mutate { $0 += 1 } },
            diagnostics: diagnostics,
            onAcknowledged: { _ in },
            onEnded: { _, reason in ended.mutate { $0.append(reason) } }
        )
        coordinator.start(sessionID: UUID(), initialLeaseExpiresMonotonic: 30, initiallyAcknowledged: true)
        coordinator.evaluateForTesting()

        XCTAssertEqual(sampleIndex.read { $0 }, 3, "start, tick, and one final write-boundary sample")
        XCTAssertEqual(observations.read { $0 }, 2, "the expiry must resolve after the force-fresh write observation")
        XCTAssertEqual(renewalAttempts.read { $0 }, 1, "the final boundary owns the expiry decision")
        XCTAssertEqual(committedWireRenewals.read { $0 }, 0)
        XCTAssertEqual(restores.read { $0 }, 0, "hard expiry is local-only")
        XCTAssertEqual(ended.read { $0 }, ["lease-expired-before-renewal"])
        XCTAssertTrue(diagnostics.flushForTesting())
        XCTAssertEqual(
            diagnostics.entries().filter { $0.event == "end" }.map(\.reason),
            ["lease-expired-before-renewal"]
        )
    }
}
