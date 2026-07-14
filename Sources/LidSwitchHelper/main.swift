import Darwin
import Foundation
import LidSwitchCore

guard getuid() == 0 else {
    fputs("LidSwitchHelper must run as root.\n", stderr)
    exit(78)
}
guard let configuration = HelperServiceConfiguration.parse(arguments: CommandLine.arguments) else {
    fputs("Invalid LidSwitchHelper configuration.\n", stderr)
    // A malformed invocation is a transient/bootstrap contract failure, not a
    // safely persisted recovery-required stop.
    exit(78)
}
let execution = HelperControlService.execute(configuration: configuration)
switch execution {
case let .daemon(exitCode):
    exit(exitCode)
case let .oneShot(result):
    var emitted = result
    var payload = result.payload
    let environment = ProcessInfo.processInfo.environment
    if environment["LIDSWITCH_RESULT_FORMAT"] == "administrator-receipt-v1" {
        guard case let .recoverOnce(intent) = configuration.mode,
              let transactionRaw = environment["LIDSWITCH_ADMIN_TRANSACTION"],
              let transaction = UUID(uuidString: transactionRaw),
              transaction.uuidString.lowercased() == transactionRaw,
              let operationRaw = environment["LIDSWITCH_ADMIN_OPERATION"],
              let operation = AdministratorOperation(rawValue: operationRaw),
              (operation == .install && intent == .install)
                || (operation == .uninstall && intent == .uninstall)
                || (operation == .userRestore && intent == .userRestore)
        else {
            emitted = .internalFailure(reason: "invalid-administrator-receipt-context")
            emitted.payload.withCString { fputs($0, stdout) }
            exit(emitted.exitCode)
        }
        payload = AdministratorTransactionReceipt.terminal(
            transactionID: transaction,
            operation: operation,
            helperResult: result
        ).payload
    }
    payload.withCString { fputs($0, stdout) }
    exit(emitted.exitCode)
}
