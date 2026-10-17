import Foundation
import XCTest
@testable import LidSwitch
@testable import LidSwitchCore
@testable import LidSwitchHelper

final class RecoveryInstallHandoffTests: XCTestCase {
    private let transaction = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

    func testOnlyExactTerminalInstallRecoveryReceiptsRequestInstalledRestore() throws {
        let reasons = AdministratorTransactionReceipt.installedHelperRestoreReasons
        XCTAssertEqual(Set(reasons).count, 5)
        XCTAssertEqual(
            Set(reasons),
            Set(["containment-extinguished-explicit-recovery-required"]
                + RecoveryProof.DetachedTransitionDisposition.allCases.map(\.reason))
        )

        for reason in reasons {
            let receipt = makeReceipt(reason: reason)
            XCTAssertTrue(receipt.requiresInstalledHelperRestore)
            XCTAssertEqual(AdministratorTransactionReceipt.parse(receipt.payload), receipt)
            XCTAssertFalse(AdministratorOperationResult.recoveryRequired(receipt).provesSafeIdle)
            XCTAssertFalse(AdministratorOperationResult.safeIdle(receipt).provesSafeIdle)

            for operation in [AdministratorOperation.uninstall, .userRestore] {
                XCTAssertFalse(makeReceipt(operation: operation, reason: reason).requiresInstalledHelperRestore)
            }
            XCTAssertFalse(makeReceipt(state: .running, reason: reason).requiresInstalledHelperRestore)
            XCTAssertFalse(makeReceipt(session: UUID(), reason: reason).requiresInstalledHelperRestore)
            for outcome in [AdministratorTransactionReceipt.Outcome.pending, .safeIdle, .operationFailed, .installedButStopped] {
                XCTAssertFalse(makeReceipt(outcome: outcome, reason: reason).requiresInstalledHelperRestore)
            }
            for altered in [reason + "-extra", "prefix-" + reason, reason.uppercased()] {
                XCTAssertFalse(makeReceipt(reason: altered).requiresInstalledHelperRestore)
            }
        }

        for reason in ["containment-pending", "containment-extinction-unproven", "idle-sleep-override-active",
                       "recovery-required", "detached-transition-pending", "pristine"] {
            XCTAssertFalse(makeReceipt(reason: reason).requiresInstalledHelperRestore)
        }
    }

    func testInstallShellMatchesWholeCanonicalReceiptForThisTransactionOnly() {
        let selector = SecureHelperInstaller.installedHelperRestoreHandoffScript(
            transactionID: transaction, operation: .install
        )
        XCTAssertTrue(selector.hasPrefix("case \"$recovery_payload\" in\n"))
        XCTAssertTrue(selector.hasSuffix(") recovery_handoff=1 ;;\nesac"))
        XCTAssertFalse(selector.contains("*"), "a reason prefix cannot authorize bootstrap")
        XCTAssertFalse(selector.contains("recovery_safe=1"))
        XCTAssertEqual(selector.components(separatedBy: "recovery_handoff=1").count - 1, 1)

        for reason in AdministratorTransactionReceipt.installedHelperRestoreReasons {
            let payload = makeReceipt(reason: reason).payload.trimmingCharacters(in: .newlines)
            XCTAssertTrue(selector.contains("'" + payload + "'"))
        }
        XCTAssertEqual(selector.components(separatedBy: "schema=1\ntransaction=").count - 1, 5)
        let otherTransaction = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        XCTAssertFalse(selector.contains(otherTransaction.uuidString.lowercased()))
        for operation in [AdministratorOperation.uninstall, .userRestore] {
            XCTAssertEqual(SecureHelperInstaller.installedHelperRestoreHandoffScript(
                transactionID: transaction, operation: operation
            ), ":")
        }
    }

    func testGeneratedInstallerBootstrapsHandoffButRetainsRecoveryRequiredResult() throws {
        let script = PrivilegedHelperManager.diagnosticInstallScript()
        let selector = SecureHelperInstaller.installedHelperRestoreHandoffScript(
            transactionID: transaction, operation: .install
        )
        XCTAssertTrue(script.contains(selector))
        XCTAssertTrue(script.contains("recovery_safe=0\nrecovery_handoff=0"))
        XCTAssertTrue(script.contains("if [ \"$recovery_handoff\" != 1 ]; then\n      publish_receipt update \"$recovery_payload\"\n      completed=1\n      exit 75\n    fi"))

        let selection = try XCTUnwrap(script.range(of: selector))
        let bootstrap = try XCTUnwrap(script.range(of: "/bin/launchctl bootstrap system \"$plist\"", range: selection.upperBound..<script.endIndex))
        let completion = try XCTUnwrap(script.range(of: "if [ \"$recovery_handoff\" = 1 ]; then exit 75; fi", range: bootstrap.upperBound..<script.endIndex))
        let finalPublication = try XCTUnwrap(script.range(of: "publish_receipt update \"$recovery_payload\"\ncompleted=1", range: bootstrap.upperBound..<completion.lowerBound))
        XCTAssertLessThan(bootstrap.lowerBound, finalPublication.lowerBound)
        XCTAssertFalse(script[selection.upperBound..<completion.lowerBound].contains("recovery_safe=1"))
        for other in [PrivilegedHelperManager.diagnosticUninstallScript(), PrivilegedHelperManager.diagnosticRestoreScript()] {
            XCTAssertFalse(other.contains(selector))
            XCTAssertFalse(other.contains(") recovery_handoff=1 ;;"))
        }
    }

    private func makeReceipt(
        operation: AdministratorOperation = .install,
        state: AdministratorTransactionReceipt.State = .terminal,
        outcome: AdministratorTransactionReceipt.Outcome = .recoveryRequired,
        session: UUID? = nil,
        reason: String
    ) -> AdministratorTransactionReceipt {
        .init(transactionID: transaction, operation: operation, state: state,
              outcome: outcome, sessionID: session, reason: reason)
    }
}
