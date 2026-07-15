import Foundation
import XCTest
@testable import LidSwitch
@testable import LidSwitchCore
@testable import LidSwitchHelper

/// Executable-but-unrun while the live-session safety gate is closed. These are
/// pure argv/codec/dispatch fixtures and never launch a helper or subprocess.
final class AdministratorRecoveryIntegrationTests: XCTestCase {
    func testCurrentAuthorityBeginAndRenewalAreSchemaThreeAndShapePreserving() throws {
        let session = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let owner = AppliedState.Owner(
            pid: 42,
            startSeconds: 100,
            startMicroseconds: 1,
            asid: 9,
            euid: 501,
            bootID: "00000000-0000-4000-8000-000000000001"
        )
        let current = AppliedState.currentAuthority(
            sessionID: session,
            changedSleepDisabled: true,
            changedACSleep: true,
            originalACSleep: 10,
            owner: owner,
            leaseExpiryMonotonic: 30
        )
        XCTAssertEqual(current.provenance, .current)
        XCTAssertEqual(current.payloadShape, .schemaTwelve)
        XCTAssertTrue(current.storagePayload.hasPrefix("schema=3\n"))
        XCTAssertEqual(current.storagePayload.split(separator: "\n").count, 12)
        let renewed = try XCTUnwrap(current.replacingLeaseExpiry(60))
        XCTAssertEqual(renewed.payloadShape, .schemaTwelve)
        XCTAssertEqual(renewed.provenance, .current)
        XCTAssertEqual(renewed.storagePayload.replacingOccurrences(of: "lease_expiry_mono=60.0", with: "lease_expiry_mono=30.0"), current.storagePayload)

        let fourteen = AppliedState(
            sessionID: session,
            changedSleepDisabled: true,
            changedACSleep: true,
            originalACSleep: 10,
            changedBatterySleep: false,
            originalBatterySleep: nil,
            owner: owner,
            leaseExpiryMonotonic: 30,
            provenance: .current,
            payloadShape: .schemaFourteen
        )
        let renewedFourteen = try XCTUnwrap(fourteen.replacingLeaseExpiry(60))
        XCTAssertEqual(renewedFourteen.payloadShape, .schemaFourteen)
        XCTAssertEqual(renewedFourteen.storagePayload.replacingOccurrences(of: "lease_expiry_mono=60.0", with: "lease_expiry_mono=30.0"), fourteen.storagePayload)
    }

    func testCanonicalArgumentContractsAreExactly13_15_17AndParseStrictly() throws {
        let owner: UInt32 = 501
        let executable = "/private/var/root/LidSwitchHelper"
        let daemon = LaunchDaemonContract.programArguments(ownerUID: owner)
        let provision = LaunchDaemonContract.provisionArguments(
            ownerUID: owner,
            executable: executable
        )
        let recovery = LaunchDaemonContract.recoveryArguments(
            ownerUID: owner,
            executable: executable,
            intent: .uninstall
        )

        XCTAssertEqual(daemon.count, 13)
        XCTAssertEqual(provision.count, 15)
        XCTAssertEqual(recovery.count, 17)
        XCTAssertEqual(Array(provision.dropFirst()), Array(daemon.dropFirst()) + ["--mode", "provision-root-state-lock"])
        XCTAssertEqual(Array(recovery.dropFirst()), Array(daemon.dropFirst()) + ["--mode", "recover-once", "--intent", "uninstall"])
        XCTAssertEqual(HelperServiceConfiguration.parse(arguments: daemon)?.mode, .daemon)
        XCTAssertEqual(
            HelperServiceConfiguration.parse(arguments: provision)?.mode,
            .provisionRootStateLock
        )
        XCTAssertEqual(
            HelperServiceConfiguration.parse(arguments: recovery)?.mode,
            .recoverOnce(.uninstall)
        )

        XCTAssertNil(HelperServiceConfiguration.parse(arguments: recovery + ["--intent", "install"]))
        XCTAssertNil(HelperServiceConfiguration.parse(arguments: recovery + ["--unknown", "value"]))
        XCTAssertNil(HelperServiceConfiguration.parse(arguments: Array(recovery.dropLast())))
        XCTAssertNil(HelperServiceConfiguration.parse(arguments: daemon.map {
            $0 == "501" ? "0501" : $0
        }))
        XCTAssertNil(HelperServiceConfiguration.parse(arguments: daemon.map {
            $0 == ReleaseIdentity.rootStatusPath ? "/private/tmp/attacker-status" : $0
        }))
    }

    func testEveryOneShotTokenHasExactExitAndCanonicalRoundTrip() {
        let session = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let cases: [(HelperOneShotResult, Int32)] = [
            (.provisionReady, 0),
            (.pristineIdle, 0),
            (.migratedIdle(reason: "legacy-migration"), 0),
            (.terminalIdle(sessionID: session, reason: "user-restore-recovery"), 0),
            (.recoveryRequired(reason: "invalid-private-ledger"), 75),
            (.internalFailure(reason: "invalid-one-shot-outcome"), 78),
        ]
        for (result, exitCode) in cases {
            XCTAssertEqual(result.exitCode, exitCode)
            XCTAssertEqual(HelperOneShotResult.parse(result.payload), result)
            XCTAssertNil(HelperOneShotResult.parse(result.payload + "\n"))
        }
        XCTAssertNil(HelperOneShotResult.parse(
            HelperOneShotResult.migratedIdle(reason: "restored").payload
        ))
    }

    func testOneShotDispatchMapsSafeRequiredAndInternalWithoutDaemonListener() {
        let configuration = makeConfiguration(mode: .recoverOnce(.userRestore))
        var daemonCalls = 0
        for (assessment, expected) in [
            (RecoveryAssessment.pristineIdle, HelperOneShotResult.pristineIdle),
            (
                .migratedIdle("legacy-migration-superseded"),
                .migratedIdle(reason: "legacy-migration-superseded")
            ),
            (
                .terminalIdle(UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!, "restored"),
                .terminalIdle(
                    sessionID: UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!,
                    reason: "restored"
                )
            ),
            (.recoveryRequired("restore-unverified"), .recoveryRequired(reason: "restore-unverified")),
        ] {
            let execution = HelperControlService.execute(
                configuration: configuration,
                operations: .init(
                    provision: { _ in .ready },
                    recover: { _, _ in assessment },
                    daemon: { _ in daemonCalls += 1; return 0 }
                )
            )
            XCTAssertEqual(execution, .oneShot(expected))
        }
        XCTAssertEqual(daemonCalls, 0)

        let provisionFailure = HelperControlService.execute(
            configuration: makeConfiguration(mode: .provisionRootStateLock),
            operations: .init(
                provision: { _ in .recoveryRequired("unsafe-root-state-directory") },
                recover: { _, _ in .pristineIdle },
                daemon: { _ in daemonCalls += 1; return 0 }
            )
        )
        XCTAssertEqual(
            provisionFailure,
            .oneShot(.internalFailure(reason: "unsafe-root-state-directory"))
        )
        XCTAssertEqual(daemonCalls, 0)

        let legacyState = AppliedState(
            sessionID: UUID(),
            changedSleepDisabled: true,
            changedACSleep: false,
            originalACSleep: nil
        )
        let impossibleOneShot = HelperControlService.execute(
            configuration: configuration,
            operations: .init(
                provision: { _ in .ready },
                recover: { _, _ in .legacyRestoreOnly(legacyState) },
                daemon: { _ in daemonCalls += 1; return 0 }
            )
        )
        XCTAssertEqual(
            impossibleOneShot,
            .oneShot(.internalFailure(reason: "invalid-one-shot-outcome"))
        )
        XCTAssertEqual(impossibleOneShot.exitCode, 78)
        XCTAssertEqual(daemonCalls, 0)

        let daemonExecution = HelperControlService.execute(
            configuration: makeConfiguration(mode: .daemon),
            operations: .init(
                provision: { _ in .ready },
                recover: { _, _ in .pristineIdle },
                daemon: { _ in daemonCalls += 1; return 71 }
            )
        )
        XCTAssertEqual(daemonExecution, .daemon(exitCode: 71))
        XCTAssertEqual(daemonCalls, 1)
    }

    func testAdministratorReceiptIsTransactionMatchedBoundedAndCanonical() {
        let transaction = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        for operation in AdministratorOperation.allCases {
            let running = AdministratorTransactionReceipt.running(
                transactionID: transaction,
                operation: operation
            )
            XCTAssertEqual(AdministratorTransactionReceipt.parse(running.payload), running)
            let terminal = AdministratorTransactionReceipt.terminal(
                transactionID: transaction,
                operation: operation,
                helperResult: .terminalIdle(
                    sessionID: UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!,
                    reason: "restored"
                )
            )
            XCTAssertEqual(AdministratorTransactionReceipt.parse(terminal.payload), terminal)
            XCTAssertLessThan(terminal.payload.utf8.count, AdministratorTransactionReceipt.maximumBytes)
            XCTAssertNil(AdministratorTransactionReceipt.parse(terminal.payload + "reason=duplicate\n"))
            XCTAssertNil(AdministratorTransactionReceipt.parse(terminal.payload.replacingOccurrences(
                of: transaction.uuidString.lowercased(),
                with: UUID().uuidString.lowercased()
            ) + "\n"))

            let migrated = AdministratorTransactionReceipt.terminal(
                transactionID: transaction,
                operation: operation,
                helperResult: .migratedIdle(reason: "legacy-migration")
            )
            XCTAssertEqual(migrated.outcome, .safeIdle)
            XCTAssertNil(migrated.sessionID)
            XCTAssertEqual(AdministratorTransactionReceipt.parse(migrated.payload), migrated)

            let forgedNilSessionSafe = AdministratorTransactionReceipt(
                transactionID: transaction,
                operation: operation,
                state: .terminal,
                outcome: .safeIdle,
                sessionID: nil,
                reason: "restore-failed"
            )
            XCTAssertNil(AdministratorTransactionReceipt.parse(forgedNilSessionSafe.payload))
        }
    }

    func testTimeoutAndLateReceiptReconciliationNeverClaimsCancellation() {
        let transaction = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let operation = AdministratorOperation.userRestore
        let running = AdministratorTransactionReceipt.running(
            transactionID: transaction,
            operation: operation
        )
        let terminal = AdministratorTransactionReceipt.terminal(
            transactionID: transaction,
            operation: operation,
            helperResult: .pristineIdle
        )

        XCTAssertEqual(
            AdministratorTransactionRunner.classify(
                observation: AdministratorTransactionRunner.observation(
                    raw: terminal.payload,
                    transactionID: transaction,
                    operation: operation
                ),
                processOutcome: .timedOut,
                processExitCode: 124,
                transactionID: transaction,
                operation: operation
            ),
            .safeIdle(terminal),
            "an exact late terminal receipt is authoritative after the wait times out"
        )
        guard case .completionIndeterminate = AdministratorTransactionRunner.classify(
            observation: AdministratorTransactionRunner.observation(
                raw: running.payload,
                transactionID: transaction,
                operation: operation
            ),
            processOutcome: .timedOut,
            processExitCode: 124,
            transactionID: transaction,
            operation: operation
        ) else {
            return XCTFail("a running transaction must remain completion-indeterminate")
        }
        guard case .completionIndeterminate = AdministratorTransactionRunner.classify(
            observation: .invalid,
            processOutcome: .completed,
            processExitCode: 1,
            transactionID: transaction,
            operation: operation
        ) else {
            return XCTFail("a malformed receipt must never be reported as cancellation")
        }
        guard case .notStarted = AdministratorTransactionRunner.classify(
            observation: .absent,
            processOutcome: .completed,
            processExitCode: 1,
            transactionID: transaction,
            operation: operation
        ) else {
            return XCTFail("only completed failure plus exact absence proves not-started")
        }
        XCTAssertEqual(
            AdministratorTransactionRunner.classify(
                observation: .absent,
                processOutcome: .spawnFailed,
                processExitCode: 127,
                transactionID: transaction,
                operation: operation
            ),
            .notStarted(operation: operation, reason: "administrator-launch-failed")
        )
        XCTAssertEqual(
            AdministratorTransactionRunner.classify(
                observation: .absent,
                processOutcome: .rejected,
                processExitCode: 127,
                transactionID: transaction,
                operation: operation
            ),
            .notStarted(operation: operation, reason: "administrator-launch-rejected")
        )
        guard case .completionIndeterminate = AdministratorTransactionRunner.classify(
            observation: .absent,
            processOutcome: .postSpawnSetupFailed,
            processExitCode: 127,
            transactionID: transaction,
            operation: operation
        ) else {
            return XCTFail("a post-spawn setup failure can race privileged dispatch")
        }
        let busyReceipt = AdministratorTransactionReceipt(
            transactionID: transaction,
            operation: operation,
            state: .terminal,
            outcome: .operationFailed,
            sessionID: nil,
            reason: "administrator-operation-already-running"
        )
        XCTAssertEqual(
            AdministratorTransactionRunner.classify(
                observation: .terminal(busyReceipt),
                processOutcome: .completed,
                processExitCode: 1,
                transactionID: transaction,
                operation: operation
            ),
            .notStarted(
                operation: operation,
                reason: "administrator-operation-already-running"
            )
        )
    }

    func testAdministratorScriptsRetainEvidenceAndUseNoSecondRecoveryAuthority() {
        let source = PrivilegedHelperManager.diagnosticRestoreScript()
        let uninstall = PrivilegedHelperManager.diagnosticUninstallScript()
        for script in [source, uninstall] {
            XCTAssertFalse(script.contains("lidswitch_parse_applied_state"))
            XCTAssertFalse(script.contains("lidswitch_read_sleep_disabled"))
            XCTAssertFalse(script.contains("/usr/bin/pmset"))
            XCTAssertFalse(script.contains("/bin/rm -f \"$lidswitch_applied_state\""))
            XCTAssertTrue(script.contains("LIDSWITCH_RESULT_FORMAT=administrator-receipt-v1"))
            XCTAssertTrue(script.contains("publish_receipt update \"$recovery_payload\""))
            XCTAssertTrue(script.contains("recovery_safe=0"))
            XCTAssertTrue(script.contains("[ \"$recovery_safe\" != 1 ]"))
            XCTAssertTrue(script.contains("failure_reason=recovery-completion-unproven"))
            XCTAssertTrue(script.contains("administrator_lock=/private/var/run/com.johnsilva.lidswitch.administrator.lock"))
            XCTAssertTrue(script.contains("/usr/bin/lockf -s -t 0 9"))
        }
        XCTAssertFalse(uninstall.contains("terminal-generations"))
        XCTAssertFalse(uninstall.contains("recovery-reservations"))
        XCTAssertFalse(uninstall.contains("recovery-proof"))
        XCTAssertFalse(uninstall.contains("root-state.lock"))
        XCTAssertTrue(uninstall.contains("status='\(AppPaths.rootHelperStatusPath)'"))
        XCTAssertTrue(uninstall.contains("/bin/rm -f \"$status\" \"$plist\""))
        XCTAssertTrue(uninstall.contains("administrator-transaction-"))
        XCTAssertTrue(source.contains(".LidSwitch-administrator-"))
        XCTAssertFalse(source.contains("root + \"/.administrator-\""))
        XCTAssertTrue(source.contains("stage_parent="))
        XCTAssertTrue(source.contains("stage_is_verified()"))
        XCTAssertTrue(source.contains("/bin/mkdir -m 0700 \"$stage\" || exit 65"))
        XCTAssertTrue(source.contains("cleanup_verified_stage"))
        XCTAssertTrue(source.contains("legacy_target="))
        XCTAssertTrue(source.contains("/bin/launchctl disable \"$legacy_target\""))
        XCTAssertTrue(source.contains("/bin/launchctl bootout \"$legacy_target\""))
    }

    private func makeConfiguration(mode: HelperServiceConfiguration.Mode) -> HelperServiceConfiguration {
        .init(
            expectedOwnerUID: 501,
            qualifiedBuild: ReleaseIdentity.qualifiedSystemBuild,
            supportDirectory: ReleaseIdentity.rootSupportDirectory,
            appliedStatePath: ReleaseIdentity.rootAppliedStatePath,
            statusPath: ReleaseIdentity.rootStatusPath,
            policyPath: ReleaseIdentity.rootEnrollmentPolicyPath,
            mode: mode
        )
    }
}
