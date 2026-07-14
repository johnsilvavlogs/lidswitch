import Foundation

/// The only recovery intents accepted by the privileged helper. Keeping the
/// vocabulary in LidSwitchCore makes the app, generated argv contract, and
/// helper parser share one exact wire representation.
public enum RecoveryIntent: String, CaseIterable, Equatable, Sendable {
    case install
    case uninstall
    case userRestore = "user-restore"
    case startup
}

public enum AdministratorOperation: String, CaseIterable, Equatable, Sendable {
    case install
    case uninstall
    case userRestore = "user-restore"
}

/// Bounded, canonical stdout from a helper one-shot. The enclosing root
/// transaction may carry it into a durable receipt, but callers never infer a
/// result from prose, stderr, or a substring.
public enum HelperOneShotResult: Equatable, Sendable {
    case provisionReady
    case pristineIdle
    /// A historical installation was proven safe without a session UUID.
    /// This must never be projected as pristine or as a fabricated terminal
    /// generation.
    case migratedIdle(reason: String)
    case terminalIdle(sessionID: UUID, reason: String)
    case recoveryRequired(reason: String)
    case internalFailure(reason: String)

    public static let maximumBytes = 512

    public var exitCode: Int32 {
        switch self {
        case .provisionReady, .pristineIdle, .migratedIdle, .terminalIdle: 0
        case .recoveryRequired: 75
        case .internalFailure: 78
        }
    }

    public var payload: String {
        let fields: (String, String, String)
        switch self {
        case .provisionReady:
            fields = ("provision-ready", "none", "ready")
        case .pristineIdle:
            fields = ("pristine-idle", "none", "pristine")
        case let .migratedIdle(reason):
            fields = ("migrated-idle", "none", reason)
        case let .terminalIdle(sessionID, reason):
            fields = ("terminal-idle", sessionID.uuidString.lowercased(), reason)
        case let .recoveryRequired(reason):
            fields = ("recovery-required", "none", reason)
        case let .internalFailure(reason):
            fields = ("internal-failure", "none", reason)
        }
        return [
            "schema=1",
            "outcome=\(fields.0)",
            "session=\(fields.1)",
            "reason=\(fields.2)",
            "",
        ].joined(separator: "\n")
    }

    public static func parse(_ raw: String) -> HelperOneShotResult? {
        guard raw.utf8.count <= maximumBytes,
              let values = RecoveryWireCodec.fields(raw, expectedCount: 4),
              values["schema"] == "1",
              let outcome = values["outcome"],
              let session = values["session"],
              let reason = values["reason"],
              RecoveryWireCodec.isReason(reason)
        else { return nil }

        let result: HelperOneShotResult
        switch outcome {
        case "provision-ready" where session == "none" && reason == "ready":
            result = .provisionReady
        case "pristine-idle" where session == "none" && reason == "pristine":
            result = .pristineIdle
        case "migrated-idle" where session == "none" && reason.hasPrefix("legacy-"):
            result = .migratedIdle(reason: reason)
        case "terminal-idle":
            guard let id = RecoveryWireCodec.canonicalUUID(session) else { return nil }
            result = .terminalIdle(sessionID: id, reason: reason)
        case "recovery-required" where session == "none":
            result = .recoveryRequired(reason: reason)
        case "internal-failure" where session == "none":
            result = .internalFailure(reason: reason)
        default:
            return nil
        }
        return result.payload == raw ? result : nil
    }
}

/// Durable app-readable transaction truth. This is a completion receipt, not
/// recovery authority: private applied/proof/ledger files remain root-only.
public struct AdministratorTransactionReceipt: Equatable, Sendable {
    public enum State: String, Equatable, Sendable { case running, terminal }
    public enum Outcome: String, Equatable, Sendable {
        case pending
        case safeIdle = "safe-idle"
        case recoveryRequired = "recovery-required"
        case operationFailed = "operation-failed"
        case installedButStopped = "installed-but-stopped"
    }

    public static let schemaVersion = 1
    public static let maximumBytes = 1_024

    public let transactionID: UUID
    public let operation: AdministratorOperation
    public let state: State
    public let outcome: Outcome
    public let sessionID: UUID?
    public let reason: String

    public init(
        transactionID: UUID,
        operation: AdministratorOperation,
        state: State,
        outcome: Outcome,
        sessionID: UUID?,
        reason: String
    ) {
        self.transactionID = transactionID
        self.operation = operation
        self.state = state
        self.outcome = outcome
        self.sessionID = sessionID
        self.reason = reason
    }

    public static func running(transactionID: UUID, operation: AdministratorOperation) -> Self {
        .init(transactionID: transactionID, operation: operation, state: .running,
              outcome: .pending, sessionID: nil, reason: "started")
    }

    public static func terminal(
        transactionID: UUID,
        operation: AdministratorOperation,
        helperResult: HelperOneShotResult
    ) -> Self {
        switch helperResult {
        case .pristineIdle:
            return .init(transactionID: transactionID, operation: operation, state: .terminal,
                         outcome: .safeIdle, sessionID: nil, reason: "pristine")
        case let .migratedIdle(reason):
            return .init(transactionID: transactionID, operation: operation, state: .terminal,
                         outcome: .safeIdle, sessionID: nil, reason: reason)
        case let .terminalIdle(sessionID, reason):
            return .init(transactionID: transactionID, operation: operation, state: .terminal,
                         outcome: .safeIdle, sessionID: sessionID, reason: reason)
        case let .recoveryRequired(reason):
            return .init(transactionID: transactionID, operation: operation, state: .terminal,
                         outcome: .recoveryRequired, sessionID: nil, reason: reason)
        case let .internalFailure(reason):
            return .init(transactionID: transactionID, operation: operation, state: .terminal,
                         outcome: .operationFailed, sessionID: nil, reason: reason)
        case .provisionReady:
            return .init(transactionID: transactionID, operation: operation, state: .terminal,
                         outcome: .operationFailed, sessionID: nil, reason: "invalid-final-provision-result")
        }
    }

    public var payload: String {
        [
            "schema=\(Self.schemaVersion)",
            "transaction=\(transactionID.uuidString.lowercased())",
            "operation=\(operation.rawValue)",
            "state=\(state.rawValue)",
            "outcome=\(outcome.rawValue)",
            "session=\(sessionID?.uuidString.lowercased() ?? "none")",
            "reason=\(reason)",
            "",
        ].joined(separator: "\n")
    }

    public static func parse(_ raw: String) -> Self? {
        guard raw.utf8.count <= maximumBytes,
              let values = RecoveryWireCodec.fields(raw, expectedCount: 7),
              values["schema"] == String(schemaVersion),
              let transaction = values["transaction"].flatMap(RecoveryWireCodec.canonicalUUID),
              let operation = values["operation"].flatMap(AdministratorOperation.init(rawValue:)),
              let state = values["state"].flatMap(State.init(rawValue:)),
              let outcome = values["outcome"].flatMap(Outcome.init(rawValue:)),
              let sessionRaw = values["session"],
              let reason = values["reason"],
              RecoveryWireCodec.isReason(reason)
        else { return nil }
        let session = sessionRaw == "none" ? nil : RecoveryWireCodec.canonicalUUID(sessionRaw)
        guard sessionRaw == "none" || session != nil else { return nil }

        switch (state, outcome, session, reason) {
        case (.running, .pending, nil, "started"):
            break
        case (.terminal, .safeIdle, nil, "pristine"):
            break
        case (.terminal, .safeIdle, nil, let safeReason) where safeReason.hasPrefix("legacy-"):
            break
        case (.terminal, .safeIdle, .some(_), _),
             (.terminal, .recoveryRequired, nil, _),
             (.terminal, .operationFailed, nil, _),
             (.terminal, .installedButStopped, nil, _):
            break
        default:
            return nil
        }
        let receipt = Self(transactionID: transaction, operation: operation, state: state,
                           outcome: outcome, sessionID: session, reason: reason)
        return receipt.payload == raw ? receipt : nil
    }
}

public enum AdministratorOperationResult: Equatable, Sendable {
    case safeIdle(AdministratorTransactionReceipt)
    case recoveryRequired(AdministratorTransactionReceipt)
    case failed(AdministratorTransactionReceipt)
    case installedButStopped(AdministratorTransactionReceipt)
    case notStarted(operation: AdministratorOperation, reason: String)
    case completionIndeterminate(transactionID: UUID, operation: AdministratorOperation, reason: String)

    public var provesSafeIdle: Bool {
        guard case let .safeIdle(receipt) = self else { return false }
        return receipt.state == .terminal && receipt.outcome == .safeIdle
    }
}

private enum RecoveryWireCodec {
    static func fields(_ raw: String, expectedCount: Int) -> [String: String]? {
        var values: [String: String] = [:]
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, !pair[0].isEmpty,
                  values.updateValue(String(pair[1]), forKey: String(pair[0])) == nil
            else { return nil }
        }
        return values.count == expectedCount ? values : nil
    }

    static func canonicalUUID(_ raw: String) -> UUID? {
        guard let value = UUID(uuidString: raw), value.uuidString.lowercased() == raw else { return nil }
        return value
    }

    static func isReason(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.utf8.count <= 96 else { return false }
        return raw.unicodeScalars.allSatisfy {
            ($0.value >= 97 && $0.value <= 122)
                || ($0.value >= 48 && $0.value <= 57)
                || $0.value == 45
        }
    }
}
