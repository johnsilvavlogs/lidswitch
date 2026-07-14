import Darwin
import Foundation
import LidSwitchCore

/// App-side entry point for every administrator recovery operation. Power
/// state, applied authority, ledgers, proof, and status are owned exclusively
/// by the verified helper one-shot; this layer never carries a shell recovery
/// implementation.
enum PrivilegedHelperManager {
    /// Leaves ample room below Darwin's one-megabyte argv/environment ceiling.
    /// The transaction wrapper is expected to be tens of kilobytes; a future
    /// binary-in-argv regression is rejected before `osascript` is spawned.
    static let maximumAdministratorAppleScriptBytes = 256 * 1_024

    static func install() throws -> AdministratorOperationResult {
        guard CompatibilityPolicy.isQualified(systemBuild: SystemBuild.current() ?? "") else {
            throw NSError(
                domain: "LidSwitch.Compatibility",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "This macOS build has not passed LidSwitch safety checks. Protection remains off."
                ]
            )
        }
        return try SecureHelperInstaller.perform(.install)
    }

    static func uninstall() throws -> AdministratorOperationResult {
        try SecureHelperInstaller.perform(.uninstall)
    }

    static func restoreSleepNow() throws -> AdministratorOperationResult {
        try SecureHelperInstaller.perform(.userRestore)
    }

    static func diagnosticAdministratorCommand(_ script: String) -> String {
        administratorCommand(script)
    }

    static func diagnosticLaunchDaemonPlist() -> String {
        LaunchDaemonContract.render(ownerUID: UInt32(getuid()))
    }

    static func diagnosticInstallScript() -> String {
        SecureHelperInstaller.diagnosticScript(for: .install)
    }

    static func diagnosticUninstallScript() -> String {
        SecureHelperInstaller.diagnosticScript(for: .uninstall)
    }

    static func diagnosticRestoreScript() -> String {
        SecureHelperInstaller.diagnosticScript(for: .userRestore)
    }

    static func administratorAppleScript(command: String, prompt: String) -> String {
        "do shell script \(appleScriptQuote(command)) with administrator privileges with prompt \(appleScriptQuote(prompt))"
    }

    static func administratorAppleScriptFitsSafeArgumentBudget(_ source: String) -> Bool {
        source.lengthOfBytes(using: .utf8) <= maximumAdministratorAppleScriptBytes
    }

    static func administratorCommand(_ script: String) -> String {
        let encodedScript = Data(script.utf8).base64EncodedString()
        // -f prevents the privileged operation from sourcing user startup
        // files. Only the generated, audited transaction wrapper executes;
        // that wrapper acquires the shared administrator-operation lock before
        // any launchd, authority, power, or installation mutation.
        return "/bin/echo \(shellQuote(encodedScript)) | /usr/bin/base64 --decode | /bin/zsh -f"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func appleScriptQuote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
