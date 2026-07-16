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

    func testBeginNotDeliveredReconnectIdleProofDoesNotCreateAuthority() throws {
        let sessionID = UUID()
        let idle = reply(
            reason: "idle",
            sessionID: sessionID,
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
            return .rejected(idle)
        }

        XCTAssertEqual(resolution, .idle(idle))
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

    func testFreshConnectionRebindsBeforeItsSingleTerminalRestoreEffect() {
        let sessionID = UUID()
        let active = reply(
            reason: "reconnected",
            sessionID: sessionID,
            expiryMonotonic: 900,
            state: .active
        )
        let terminal = reply(
            reason: "peer-restore",
            sessionID: sessionID,
            expiryMonotonic: 0,
            state: .terminal
        )
        var operations: [UInt32] = []
        var rebound = false

        let resolution = RawHelperControlClient.terminateGenerationForTesting(
            sessionID: sessionID,
            intent: .restore
        ) { operation, requestedSessionID in
            operations.append(operation)
            if operation == UInt32(LS_OPERATION_RECONNECT.rawValue) {
                XCTAssertEqual(requestedSessionID, sessionID)
                rebound = true
                return .accepted(active)
            }
            XCTAssertTrue(rebound, "a fresh RESTORE cannot cross before exact-session rebind")
            XCTAssertEqual(operation, UInt32(LS_OPERATION_RESTORE.rawValue))
            XCTAssertEqual(requestedSessionID, Self.zeroUUID)
            return .accepted(terminal)
        }

        XCTAssertEqual(resolution, .terminated(terminal))
        XCTAssertEqual(
            operations,
            [UInt32(LS_OPERATION_RECONNECT.rawValue), UInt32(LS_OPERATION_RESTORE.rawValue)]
        )
        XCTAssertEqual(operations.filter { $0 == UInt32(LS_OPERATION_RESTORE.rawValue) }.count, 1)
    }

    func testOnlyTerminalOperationsUseTheExtendedWireTimeout() {
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

    func testTerminalReconnectProofConsumesNoAdditionalTerminalEffect() {
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
        XCTAssertEqual(operations, [UInt32(LS_OPERATION_RECONNECT.rawValue)])
    }

    func testAcceptedWrongSessionRestoreRemainsAuthorityMayRemainAfterOneReconnect() {
        let sessionID = UUID()
        let active = reply(reason: "reconnected", sessionID: sessionID, expiryMonotonic: 900, state: .active)
        let unrelatedTerminal = reply(reason: "other", sessionID: UUID(), expiryMonotonic: 0, state: .terminal)
        var operations: [UInt32] = []

        let resolution = RawHelperControlClient.terminateGenerationForTesting(
            sessionID: sessionID,
            intent: .restore
        ) { operation, _ in
            operations.append(operation)
            return operation == UInt32(LS_OPERATION_RECONNECT.rawValue)
                ? .accepted(active)
                : .accepted(unrelatedTerminal)
        }

        XCTAssertEqual(resolution, .authorityMayRemain("terminal-reply-session-mismatch"))
        XCTAssertEqual(operations, [UInt32(LS_OPERATION_RECONNECT.rawValue), UInt32(LS_OPERATION_RESTORE.rawValue)])
        XCTAssertEqual(operations.filter { $0 == UInt32(LS_OPERATION_RESTORE.rawValue) }.count, 1)
    }

    func testRejectedWrongSessionRestoreRemainsAuthorityMayRemainAfterOneReconnect() {
        let sessionID = UUID()
        let active = reply(reason: "reconnected", sessionID: sessionID, expiryMonotonic: 900, state: .active)
        let unrelatedIdle = reply(reason: "other", sessionID: UUID(), expiryMonotonic: 0, state: .idle)
        var operations: [UInt32] = []

        let resolution = RawHelperControlClient.terminateGenerationForTesting(
            sessionID: sessionID,
            intent: .restore
        ) { operation, _ in
            operations.append(operation)
            return operation == UInt32(LS_OPERATION_RECONNECT.rawValue)
                ? .accepted(active)
                : .rejected(unrelatedIdle)
        }

        XCTAssertEqual(resolution, .authorityMayRemain("terminal-reply-session-mismatch"))
        XCTAssertEqual(operations, [UInt32(LS_OPERATION_RECONNECT.rawValue), UInt32(LS_OPERATION_RESTORE.rawValue)])
        XCTAssertEqual(operations.filter { $0 == UInt32(LS_OPERATION_RESTORE.rawValue) }.count, 1)
    }

    func testZeroSessionRestoreReplyRemainsAuthorityMayRemainAfterOneReconnect() {
        let sessionID = UUID()
        let active = reply(reason: "reconnected", sessionID: sessionID, expiryMonotonic: 900, state: .active)
        let zeroTerminal = reply(reason: "zero", sessionID: Self.zeroUUID, expiryMonotonic: 0, state: .terminal)
        var operations: [UInt32] = []

        let resolution = RawHelperControlClient.terminateGenerationForTesting(
            sessionID: sessionID,
            intent: .restore
        ) { operation, _ in
            operations.append(operation)
            return operation == UInt32(LS_OPERATION_RECONNECT.rawValue)
                ? .accepted(active)
                : .accepted(zeroTerminal)
        }

        XCTAssertEqual(resolution, .authorityMayRemain("terminal-reply-session-mismatch"))
        XCTAssertEqual(operations, [UInt32(LS_OPERATION_RECONNECT.rawValue), UInt32(LS_OPERATION_RESTORE.rawValue)])
        XCTAssertEqual(operations.filter { $0 == UInt32(LS_OPERATION_RESTORE.rawValue) }.count, 1)
    }

    func testRejectedWrongSessionReconnectRemainsAuthorityMayRemainWithoutTerminalEffect() {
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

        XCTAssertEqual(resolution, .authorityMayRemain("terminal-reconnect-session-mismatch"))
        XCTAssertEqual(operations, [UInt32(LS_OPERATION_RECONNECT.rawValue)])
        XCTAssertFalse(operations.contains(UInt32(LS_OPERATION_RESTORE.rawValue)))
    }

    func testRejectedExactSessionRestoreRetainsTypedTerminalResult() {
        let sessionID = UUID()
        let active = reply(reason: "reconnected", sessionID: sessionID, expiryMonotonic: 900, state: .active)
        let terminal = reply(reason: "expired", sessionID: sessionID, expiryMonotonic: 0, state: .terminal)
        var operations: [UInt32] = []

        let resolution = RawHelperControlClient.terminateGenerationForTesting(
            sessionID: sessionID,
            intent: .restore
        ) { operation, _ in
            operations.append(operation)
            return operation == UInt32(LS_OPERATION_RECONNECT.rawValue)
                ? .accepted(active)
                : .rejected(terminal)
        }

        XCTAssertEqual(resolution, .alreadyTerminal(terminal))
        XCTAssertEqual(operations, [UInt32(LS_OPERATION_RECONNECT.rawValue), UInt32(LS_OPERATION_RESTORE.rawValue)])
        XCTAssertEqual(operations.filter { $0 == UInt32(LS_OPERATION_RESTORE.rawValue) }.count, 1)
    }

    func testIndeterminateTerminalReplyNeverRetriesOrRenews() {
        let sessionID = UUID()
        let active = reply(
            reason: "reconnected",
            sessionID: sessionID,
            expiryMonotonic: 900,
            state: .active
        )
        var operations: [UInt32] = []

        let resolution = RawHelperControlClient.terminateGenerationForTesting(
            sessionID: sessionID,
            intent: .restore
        ) { operation, _ in
            operations.append(operation)
            if operation == UInt32(LS_OPERATION_RECONNECT.rawValue) {
                return .accepted(active)
            }
            throw HelperControlError.indeterminateTransport(60)
        }

        guard case .authorityMayRemain = resolution else {
            return XCTFail("a lost terminal reply must remain unresolved")
        }
        XCTAssertEqual(
            operations,
            [UInt32(LS_OPERATION_RECONNECT.rawValue), UInt32(LS_OPERATION_RESTORE.rawValue)]
        )
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
