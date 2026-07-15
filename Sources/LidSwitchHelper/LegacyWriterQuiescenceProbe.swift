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

    static func exactMissingService(
        _ result: ContainedProcessResult,
        target: String
    ) -> Bool {
        guard result.outcome == .completed,
              result.exitCode != 0,
              result.stdout.isEmpty,
              result.stdout.utf8.count + result.stderr.utf8.count < 16 * 1_024
        else { return false }

        let components = target.split(separator: "/", omittingEmptySubsequences: false)
        let label: String
        let domainDescription: String
        switch components.count {
        case 2 where components[0] == "system":
            label = String(components[1])
            domainDescription = "system"
        case 3 where components[0] == "gui":
            let rawUID = String(components[1])
            guard let uid = UInt32(rawUID), uid > 0, String(uid) == rawUID else { return false }
            label = String(components[2])
            domainDescription = "user gui: \(uid)"
        default:
            return false
        }
        guard label.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil else {
            return false
        }

        let missing = "Could not find service \"\(label)\" in domain for \(domainDescription)"
        let accepted = [
            missing,
            missing + "\n",
            "Bad request.\n" + missing,
            "Bad request.\n" + missing + "\n",
        ]
        return accepted.contains(result.stderr)
    }

    static func exactLegacyDisabled(
        _ result: ContainedProcessResult,
        label: String
    ) -> Bool {
        guard result.outcome == .completed,
              result.exitCode == 0,
              result.stderr.isEmpty,
              result.stdout.utf8.count < 16 * 1_024
        else { return false }
        guard label.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil else {
            return false
        }
        let accepted = Set([
            "\"\(label)\" => true",
            "\"\(label)\" => disabled",
        ])
        let matches = result.stdout.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            accepted.contains(String(line).trimmingCharacters(in: .whitespaces))
        }
        return matches.count == 1
    }
}
