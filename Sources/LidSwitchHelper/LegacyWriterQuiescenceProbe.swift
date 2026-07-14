import Foundation
import LidSwitchCore

/// Administrator recovery has a narrower precondition than normal daemon
/// recovery: both historical launchd writers must be demonstrably absent while
/// `RootStateLock` is held.  The result intentionally has no Boolean success
/// initializer, so argv, environment, or an app-side caller cannot assert
/// quiescence on behalf of the helper.
struct LegacyWriterQuiescenceProbe: Sendable {
    enum Outcome: Equatable, Sendable {
        case quiesced
        case indeterminate(String)
    }

    private let inspect: @Sendable () -> Outcome

    init(inspect: @escaping @Sendable () -> Outcome) {
        self.inspect = inspect
    }

    func verify() -> Outcome { inspect() }

    /// Production uses the bounded contained-process primitive for each fixed
    /// launchctl observation. Any non-exact result stays indeterminate, so the
    /// former caller-provided Boolean cannot become a privilege escalation.
    static func system(ownerUID: uid_t, qualifiedBuild: String) -> LegacyWriterQuiescenceProbe {
        guard ownerUID > 0, qualifiedBuild == ReleaseIdentity.qualifiedSystemBuild else {
            return LegacyWriterQuiescenceProbe { .indeterminate("legacy-writer-probe-configuration-invalid") }
        }
        let currentTarget = "system/com.johnsilva.lidswitch.helper"
        let legacyLabel = "com.johnsilva.LidSwitch.login"
        let legacyDomain = "gui/\(ownerUID)"
        let legacyTarget = "\(legacyDomain)/\(legacyLabel)"
        return LegacyWriterQuiescenceProbe {
            // The one-shot helper itself is not the system launchd service.
            // The wrapper booted that service out before execing this process;
            // this query proves only that durable writer is still absent.
            let current = ContainedProcessRunner.run(.currentHelperPrint)
            guard Self.exactMissingService(current, target: currentTarget) else {
                return .indeterminate("current-writer-present-or-indeterminate")
            }
            let legacy = ContainedProcessRunner.run(.legacyHelperPrint(ownerUID))
            guard Self.exactMissingService(legacy, target: legacyTarget) else {
                return .indeterminate("legacy-writer-present-or-indeterminate")
            }
            let disabled = ContainedProcessRunner.run(.legacyHelperPrintDisabled(ownerUID))
            guard Self.exactLegacyDisabled(disabled, label: legacyLabel) else {
                return .indeterminate("legacy-writer-disable-state-indeterminate")
            }
            return .quiesced
        }
    }

    static let fixtureQuiesced = LegacyWriterQuiescenceProbe { .quiesced }

    private static func exactMissingService(
        _ result: ContainedProcessResult,
        target: String
    ) -> Bool {
        guard result.outcome == .completed,
              result.exitCode != 0,
              result.stdout.utf8.count + result.stderr.utf8.count < 16 * 1_024
        else { return false }
        let text = result.stdout + "\n" + result.stderr
        return text.contains(target)
            && (text.contains("Could not find service") || text.contains("could not find service"))
    }

    private static func exactLegacyDisabled(
        _ result: ContainedProcessResult,
        label: String
    ) -> Bool {
        guard result.outcome == .completed, result.exitCode == 0 else { return false }
        return result.stdout.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            let text = String(line)
            return text.contains("\"\(label)\"") && text.contains("=> true")
        }
    }
}
