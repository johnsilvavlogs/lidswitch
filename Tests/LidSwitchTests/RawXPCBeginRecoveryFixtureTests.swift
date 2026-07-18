import Foundation
import LidSwitchXPCBridge
import XCTest
@testable import LidSwitch

final class RawXPCBeginRecoveryFixtureTests: XCTestCase {
    func testDirectBeginReplyIsIssuedWithoutReconnect() throws {
        let sessionID = UUID()
        let issued = reply(
            reason: "verified",
            sessionID: sessionID,
            expiryMonotonic: 1_234,
            state: .active
        )
        var operations: [UInt32] = []

        let resolution = try RawHelperControlClient.resolveBeginForTesting(
            sessionID: sessionID
        ) { operation, requestedSessionID in
            operations.append(operation)
            XCTAssertEqual(requestedSessionID, sessionID)
            return .accepted(issued)
        }

        XCTAssertEqual(resolution, .issued(issued))
        XCTAssertEqual(operations, [UInt32(LS_OPERATION_BEGIN.rawValue)])
    }

    func testAcceptedBeginLostReplyReconnectsExactlyOnceWithoutSecondBeginAndPreservesExpiry() throws {
        let sessionID = UUID()
        let originalExpiry = 4_321.25
        let active = reply(
            reason: "reconnected",
            sessionID: sessionID,
            expiryMonotonic: originalExpiry,
            state: .active
        )
        var operations: [UInt32] = []
        var connectionGeneration = 1

        let resolution = try RawHelperControlClient.resolveBeginForTesting(
            sessionID: sessionID
        ) { operation, requestedSessionID in
            XCTAssertEqual(requestedSessionID, sessionID)
            operations.append(operation)
            if operation == UInt32(LS_OPERATION_BEGIN.rawValue) {
                // The bridge invalidates/releases this connection before the
                // resolver receives the only reconnect-eligible error.
                connectionGeneration = 2
                throw HelperControlError.indeterminateTransport(60)
            }
            XCTAssertEqual(operation, UInt32(LS_OPERATION_RECONNECT.rawValue))
            XCTAssertEqual(connectionGeneration, 2, "RECONNECT must use the fresh authenticated connection")
            return .accepted(active)
        }

        XCTAssertEqual(resolution, .reconnected(active))
        XCTAssertEqual(
            operations,
            [UInt32(LS_OPERATION_BEGIN.rawValue), UInt32(LS_OPERATION_RECONNECT.rawValue)]
        )
        XCTAssertEqual(active.expiryMonotonic, originalExpiry)
        XCTAssertEqual(operations.filter { $0 == UInt32(LS_OPERATION_BEGIN.rawValue) }.count, 1)
    }

    func testBeginNotDeliveredReconnectTerminalProofDoesNotCreateAuthority() throws {
        let sessionID = UUID()
        let terminal = reply(
            reason: "reconnect-peer-mismatch",
            sessionID: sessionID,
            expiryMonotonic: 0,
            state: .terminal
        )
        var operations: [UInt32] = []

        let resolution = try RawHelperControlClient.resolveBeginForTesting(
            sessionID: sessionID
        ) { operation, _ in
            operations.append(operation)
            if operation == UInt32(LS_OPERATION_BEGIN.rawValue) {
                throw HelperControlError.indeterminateTransport(57)
            }
            return .rejected(terminal)
        }

        XCTAssertEqual(resolution, .terminal(terminal))
        XCTAssertEqual(
            operations,
            [UInt32(LS_OPERATION_BEGIN.rawValue), UInt32(LS_OPERATION_RECONNECT.rawValue)]
        )
    }

    func testExactIdleReconnectProofRetriesOneFreshBeginAndIssues() throws {
        let sessionID = UUID()
        let idle = reply(
            reason: "reconnect-peer-mismatch",
            sessionID: sessionID,
            expiryMonotonic: 0,
            state: .idle
        )
        let issued = reply(
            reason: "verified",
            sessionID: sessionID,
            expiryMonotonic: 1_234,
            state: .active
        )
        var operations: [UInt32] = []

        let resolution = try RawHelperControlClient.resolveBeginForTesting(
            sessionID: sessionID
        ) { operation, requestedSessionID in
            XCTAssertEqual(requestedSessionID, sessionID)
            operations.append(operation)
            if operation == UInt32(LS_OPERATION_BEGIN.rawValue) {
                if operations.filter({ $0 == UInt32(LS_OPERATION_BEGIN.rawValue) }).count == 1 {
                    throw HelperControlError.indeterminateTransport(60)
                }
                return .accepted(issued)
            }
            XCTAssertEqual(operation, UInt32(LS_OPERATION_RECONNECT.rawValue))
            return .rejected(idle)
        }

        XCTAssertEqual(resolution, .issued(issued))
        XCTAssertEqual(
            operations,
            [
                UInt32(LS_OPERATION_BEGIN.rawValue),
                UInt32(LS_OPERATION_RECONNECT.rawValue),
                UInt32(LS_OPERATION_BEGIN.rawValue),
            ]
        )
        XCTAssertEqual(operations.filter { $0 == UInt32(LS_OPERATION_BEGIN.rawValue) }.count, 2)
        XCTAssertEqual(operations.filter { $0 == UInt32(LS_OPERATION_RECONNECT.rawValue) }.count, 1)
    }

    func testExactIdleReconnectProofRetryUncertaintyDoesNotLoop() throws {
        let sessionID = UUID()
        let idle = reply(
            reason: "reconnect-peer-mismatch",
            sessionID: sessionID,
            expiryMonotonic: 0,
            state: .idle
        )
        var operations: [UInt32] = []

        let resolution = try RawHelperControlClient.resolveBeginForTesting(
            sessionID: sessionID
        ) { operation, requestedSessionID in
            XCTAssertEqual(requestedSessionID, sessionID)
            operations.append(operation)
            if operation == UInt32(LS_OPERATION_RECONNECT.rawValue) {
                return .rejected(idle)
            }
            throw HelperControlError.indeterminateTransport(60)
        }

        guard case let .authorityMayRemain(reason) = resolution else {
            return XCTFail("an uncertain retry BEGIN must remain unresolved")
        }
        XCTAssertTrue(reason.contains("indeterminate-transport"))
        XCTAssertEqual(
            operations,
            [
                UInt32(LS_OPERATION_BEGIN.rawValue),
                UInt32(LS_OPERATION_RECONNECT.rawValue),
                UInt32(LS_OPERATION_BEGIN.rawValue),
            ]
        )
        XCTAssertEqual(operations.filter { $0 == UInt32(LS_OPERATION_BEGIN.rawValue) }.count, 2)
        XCTAssertEqual(operations.filter { $0 == UInt32(LS_OPERATION_RECONNECT.rawValue) }.count, 1)
    }

    func testExactIdleReconnectProofRetryUnsafeResponseDoesNotLoop() throws {
        let sessionID = UUID()
        let idle = reply(
            reason: "reconnect-peer-mismatch",
            sessionID: sessionID,
            expiryMonotonic: 0,
            state: .idle
        )
        let recoveryRequired = reply(
            reason: "recovery-required",
            sessionID: sessionID,
            expiryMonotonic: 0,
            state: .recoveryRequired
        )
        var operations: [UInt32] = []

        let resolution = try RawHelperControlClient.resolveBeginForTesting(
            sessionID: sessionID
        ) { operation, _ in
            operations.append(operation)
            if operation == UInt32(LS_OPERATION_RECONNECT.rawValue) {
                return .rejected(idle)
            }
            if operations.filter({ $0 == UInt32(LS_OPERATION_BEGIN.rawValue) }).count == 1 {
                throw HelperControlError.indeterminateTransport(60)
            }
            return .rejected(recoveryRequired)
        }

        XCTAssertEqual(resolution, .authorityMayRemain("recovery-required"))
        XCTAssertEqual(
            operations,
            [
                UInt32(LS_OPERATION_BEGIN.rawValue),
                UInt32(LS_OPERATION_RECONNECT.rawValue),
                UInt32(LS_OPERATION_BEGIN.rawValue),
            ]
        )
        XCTAssertEqual(operations.filter { $0 == UInt32(LS_OPERATION_BEGIN.rawValue) }.count, 2)
        XCTAssertEqual(operations.filter { $0 == UInt32(LS_OPERATION_RECONNECT.rawValue) }.count, 1)
    }

    func testReconnectPeerMismatchActiveEvidenceDoesNotRetryBegin() throws {
        let sessionID = UUID()
        let active = reply(
            reason: "reconnect-peer-mismatch",
            sessionID: sessionID,
            expiryMonotonic: 1_234,
            state: .active
        )
        var operations: [UInt32] = []

        let resolution = try RawHelperControlClient.resolveBeginForTesting(
            sessionID: sessionID
        ) { operation, _ in
            operations.append(operation)
            if operation == UInt32(LS_OPERATION_BEGIN.rawValue) {
                throw HelperControlError.indeterminateTransport(60)
            }
            return .rejected(active)
        }

        XCTAssertEqual(resolution, .authorityMayRemain("reconnect-peer-mismatch"))
        XCTAssertEqual(
            operations,
            [UInt32(LS_OPERATION_BEGIN.rawValue), UInt32(LS_OPERATION_RECONNECT.rawValue)]
        )
    }

    func testReconnectRecoveryRequiredEvidenceDoesNotRetryBegin() throws {
        let sessionID = UUID()
        let recoveryRequired = reply(
            reason: "recovery-required",
            sessionID: sessionID,
            expiryMonotonic: 0,
            state: .recoveryRequired
        )
        var operations: [UInt32] = []

        let resolution = try RawHelperControlClient.resolveBeginForTesting(
            sessionID: sessionID
        ) { operation, _ in
            operations.append(operation)
            if operation == UInt32(LS_OPERATION_BEGIN.rawValue) {
                throw HelperControlError.indeterminateTransport(60)
            }
            return .rejected(recoveryRequired)
        }

        XCTAssertEqual(resolution, .authorityMayRemain("recovery-required"))
        XCTAssertEqual(
            operations,
            [UInt32(LS_OPERATION_BEGIN.rawValue), UInt32(LS_OPERATION_RECONNECT.rawValue)]
        )
    }

    func testReconnectPeerMismatchForeignEvidenceDoesNotRetryBegin() throws {
        let sessionID = UUID()
        let foreignIdle = reply(
            reason: "reconnect-peer-mismatch",
            sessionID: UUID(),
            expiryMonotonic: 0,
            state: .idle
        )
        var operations: [UInt32] = []

        let resolution = try RawHelperControlClient.resolveBeginForTesting(
            sessionID: sessionID
        ) { operation, _ in
            operations.append(operation)
            if operation == UInt32(LS_OPERATION_BEGIN.rawValue) {
                throw HelperControlError.indeterminateTransport(60)
            }
            return .rejected(foreignIdle)
        }

        XCTAssertEqual(resolution, .authorityMayRemain("begin-reply-session-mismatch"))
        XCTAssertEqual(
            operations,
            [UInt32(LS_OPERATION_BEGIN.rawValue), UInt32(LS_OPERATION_RECONNECT.rawValue)]
        )
    }

    func testBeginTerminalLookingReplyForAnotherSessionRemainsAuthorityMayRemain() throws {
        let sessionID = UUID()
        let unrelatedTerminal = reply(
            reason: "other-session-terminal",
            sessionID: UUID(),
            expiryMonotonic: 0,
            state: .terminal
        )
        var operations: [UInt32] = []

        let resolution = try RawHelperControlClient.resolveBeginForTesting(
            sessionID: sessionID
        ) { operation, _ in
            operations.append(operation)
            return .rejected(unrelatedTerminal)
        }

        XCTAssertEqual(resolution, .authorityMayRemain("begin-reply-session-mismatch"))
        XCTAssertEqual(operations, [UInt32(LS_OPERATION_BEGIN.rawValue)])
    }

    func testBeginAndSingleReconnectBothIndeterminateRemainExplicitlyUnresolved() throws {
        let sessionID = UUID()
        var operations: [UInt32] = []

        let resolution = try RawHelperControlClient.resolveBeginForTesting(
            sessionID: sessionID
        ) { operation, _ in
            operations.append(operation)
            throw HelperControlError.indeterminateTransport(
                operation == UInt32(LS_OPERATION_BEGIN.rawValue) ? 60 : 57
            )
        }

        guard case let .authorityMayRemain(reason) = resolution else {
            return XCTFail("double transport uncertainty must remain safety-critical")
        }
        XCTAssertTrue(reason.contains("indeterminate-transport"))
        XCTAssertEqual(
            operations,
            [UInt32(LS_OPERATION_BEGIN.rawValue), UInt32(LS_OPERATION_RECONNECT.rawValue)]
        )
        XCTAssertEqual(operations.filter { $0 == UInt32(LS_OPERATION_RECONNECT.rawValue) }.count, 1)
    }

    func testFreshConnectionIssuesOneAtomicTerminalRestoreEffect() {
        let sessionID = UUID()
        let terminal = reply(
            reason: "peer-restore",
            sessionID: sessionID,
            expiryMonotonic: 0,
            state: .terminal
        )
        var operations: [UInt32] = []

        let resolution = RawHelperControlClient.terminateGenerationForTesting(
            sessionID: sessionID,
            intent: .restore
        ) { operation, requestedSessionID in
            operations.append(operation)
            XCTAssertEqual(operation, UInt32(LS_OPERATION_RESTORE.rawValue))
            XCTAssertEqual(requestedSessionID, Self.zeroUUID)
            return .accepted(terminal)
        }

        XCTAssertEqual(resolution, .terminated(terminal))
        XCTAssertEqual(operations, [UInt32(LS_OPERATION_RESTORE.rawValue)])
        XCTAssertEqual(operations.filter { $0 == UInt32(LS_OPERATION_RESTORE.rawValue) }.count, 1)
    }

    func testOnlyTerminalSequenceUsesTheExtendedWireTimeout() {
        let ordinary: [UInt32] = [
            UInt32(LS_OPERATION_BEGIN.rawValue),
            UInt32(LS_OPERATION_RENEW.rawValue),
            UInt32(LS_OPERATION_RECONNECT.rawValue),
            UInt32(LS_OPERATION_SNAPSHOT.rawValue),
        ]
        for operation in ordinary {
            XCTAssertEqual(
                RawHelperControlClient.timeoutSecondsForTesting(operation: operation),
                5
            )
        }
        XCTAssertEqual(
            RawHelperControlClient.timeoutSecondsForTesting(
                operation: UInt32(LS_OPERATION_END.rawValue)
            ),
            10
        )
        XCTAssertEqual(
            RawHelperControlClient.timeoutSecondsForTesting(
                operation: UInt32(LS_OPERATION_RESTORE.rawValue)
            ),
            10
        )
    }

    func testTerminalCallsiteBudgetsOneAtomicEffectWithoutRetry() {
        let sessionID = UUID()
        for (intent, terminalOperation, reason) in [
            (HelperGenerationTerminationIntent.end, UInt32(LS_OPERATION_END.rawValue), "user-end"),
            (HelperGenerationTerminationIntent.restore, UInt32(LS_OPERATION_RESTORE.rawValue), "peer-restore"),
        ] {
            let terminal = reply(reason: reason, sessionID: sessionID, expiryMonotonic: 0, state: .terminal)
            var exchanges: [(UInt32, Double)] = []

            let resolution = RawHelperControlClient.terminateGenerationWithTimeoutsForTesting(
                sessionID: sessionID,
                intent: intent
            ) { operation, _, timeout in
                exchanges.append((operation, timeout))
                return .accepted(terminal)
            }

            XCTAssertEqual(resolution, .terminated(terminal))
            XCTAssertEqual(exchanges.map(\.0), [terminalOperation])
            XCTAssertEqual(exchanges.map(\.1), [10])
        }
    }

    func testTerminalProofConsumesOneTerminalEffect() {
        let sessionID = UUID()
        let terminal = reply(
            reason: "expired",
            sessionID: sessionID,
            expiryMonotonic: 0,
            state: .terminal
        )
        var operations: [UInt32] = []

        let resolution = RawHelperControlClient.terminateGenerationForTesting(
            sessionID: sessionID,
            intent: .restore
        ) { operation, _ in
            operations.append(operation)
            return .rejected(terminal)
        }

        XCTAssertEqual(resolution, .alreadyTerminal(terminal))
        XCTAssertEqual(operations, [UInt32(LS_OPERATION_RESTORE.rawValue)])
    }

    func testAcceptedWrongSessionRestoreRemainsAuthorityMayRemainAfterOneEffect() {
        let sessionID = UUID()
        let unrelatedTerminal = reply(reason: "other", sessionID: UUID(), expiryMonotonic: 0, state: .terminal)
        var operations: [UInt32] = []

        let resolution = RawHelperControlClient.terminateGenerationForTesting(
            sessionID: sessionID,
            intent: .restore
        ) { operation, _ in
            operations.append(operation)
            return .accepted(unrelatedTerminal)
        }

        XCTAssertEqual(resolution, .authorityMayRemain("terminal-reply-session-mismatch"))
        XCTAssertEqual(operations, [UInt32(LS_OPERATION_RESTORE.rawValue)])
        XCTAssertEqual(operations.filter { $0 == UInt32(LS_OPERATION_RESTORE.rawValue) }.count, 1)
    }

    func testRejectedWrongSessionRestoreRemainsAuthorityMayRemainAfterOneEffect() {
        let sessionID = UUID()
        let unrelatedIdle = reply(reason: "other", sessionID: UUID(), expiryMonotonic: 0, state: .idle)
        var operations: [UInt32] = []

        let resolution = RawHelperControlClient.terminateGenerationForTesting(
            sessionID: sessionID,
            intent: .restore
        ) { operation, _ in
            operations.append(operation)
            return .rejected(unrelatedIdle)
        }

        XCTAssertEqual(resolution, .authorityMayRemain("terminal-reply-session-mismatch"))
        XCTAssertEqual(operations, [UInt32(LS_OPERATION_RESTORE.rawValue)])
        XCTAssertEqual(operations.filter { $0 == UInt32(LS_OPERATION_RESTORE.rawValue) }.count, 1)
    }

    func testZeroSessionRestoreReplyRemainsAuthorityMayRemainAfterOneEffect() {
        let sessionID = UUID()
        let zeroTerminal = reply(reason: "zero", sessionID: Self.zeroUUID, expiryMonotonic: 0, state: .terminal)
        var operations: [UInt32] = []

        let resolution = RawHelperControlClient.terminateGenerationForTesting(
            sessionID: sessionID,
            intent: .restore
        ) { operation, _ in
            operations.append(operation)
            return .accepted(zeroTerminal)
        }

        XCTAssertEqual(resolution, .authorityMayRemain("terminal-reply-session-mismatch"))
        XCTAssertEqual(operations, [UInt32(LS_OPERATION_RESTORE.rawValue)])
        XCTAssertEqual(operations.filter { $0 == UInt32(LS_OPERATION_RESTORE.rawValue) }.count, 1)
    }

    func testRejectedWrongSessionTerminalReplyRemainsAuthorityMayRemainAfterOneEffect() {
        let sessionID = UUID()
        let unrelatedTerminal = reply(reason: "other", sessionID: UUID(), expiryMonotonic: 0, state: .terminal)
        var operations: [UInt32] = []

        let resolution = RawHelperControlClient.terminateGenerationForTesting(
            sessionID: sessionID,
            intent: .restore
        ) { operation, _ in
            operations.append(operation)
            return .rejected(unrelatedTerminal)
        }

        XCTAssertEqual(resolution, .authorityMayRemain("terminal-reply-session-mismatch"))
        XCTAssertEqual(operations, [UInt32(LS_OPERATION_RESTORE.rawValue)])
    }

    func testRejectedExactSessionRestoreRetainsTypedTerminalResult() {
        let sessionID = UUID()
        let terminal = reply(reason: "expired", sessionID: sessionID, expiryMonotonic: 0, state: .terminal)
        var operations: [UInt32] = []

        let resolution = RawHelperControlClient.terminateGenerationForTesting(
            sessionID: sessionID,
            intent: .restore
        ) { operation, _ in
            operations.append(operation)
            return .rejected(terminal)
        }

        XCTAssertEqual(resolution, .alreadyTerminal(terminal))
        XCTAssertEqual(operations, [UInt32(LS_OPERATION_RESTORE.rawValue)])
        XCTAssertEqual(operations.filter { $0 == UInt32(LS_OPERATION_RESTORE.rawValue) }.count, 1)
    }

    func testIndeterminateTerminalReplyNeverRetriesOrRenews() {
        let sessionID = UUID()
        var operations: [UInt32] = []

        let resolution = RawHelperControlClient.terminateGenerationForTesting(
            sessionID: sessionID,
            intent: .restore
        ) { operation, _ in
            operations.append(operation)
            throw HelperControlError.indeterminateTransport(60)
        }

        guard case .authorityMayRemain = resolution else {
            return XCTFail("a lost terminal reply must remain unresolved")
        }
        XCTAssertEqual(operations, [UInt32(LS_OPERATION_RESTORE.rawValue)])
        XCTAssertFalse(operations.contains(UInt32(LS_OPERATION_RENEW.rawValue)))
        XCTAssertEqual(operations.filter { $0 == UInt32(LS_OPERATION_RESTORE.rawValue) }.count, 1)
    }

    private func reply(
        reason: String,
        sessionID: UUID,
        expiryMonotonic: TimeInterval,
        state: HelperControlReply.State
    ) -> HelperControlReply {
        HelperControlReply(
            reason: reason,
            sessionID: sessionID,
            expiryMonotonic: expiryMonotonic,
            state: state,
            power: state == .active ? .ac : .unknown,
            sleepDisabled: state == .active,
            acSleepMinutes: state == .active ? 0 : 5
        )
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}
