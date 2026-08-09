import Darwin
import Foundation
import LidSwitchCore

/// App-side entry point for administrator enrollment boundaries only. Routine
/// Start, Restore, relaunch, and detached recovery use the already-installed
/// authenticated helper XPC service; they must never reach this layer. Power
/// state, applied authority, ledgers, proof, and status are owned exclusively
/// by the verified helper one-shot.
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

    /// A one-time repair boundary for a missing or unloaded helper. This is
    /// deliberately not exposed as the ordinary Restore Sleep action.
    static func repairMissingHelperAndRestore() throws -> AdministratorOperationResult {
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
        // Both the GUI-side osascript spawn and the root shell use a closed
        // environment. `-f` prevents startup files; env -i also forbids a
        // caller-controlled interpreter, dynamic-loader, or shell-init
        // variable from crossing the authorization boundary.
        return "/bin/echo \(shellQuote(encodedScript)) | /usr/bin/base64 --decode | /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=C LC_ALL=C PERL5OPT= PERL5LIB= DYLD_LIBRARY_PATH= DYLD_FRAMEWORK_PATH= DYLD_INSERT_LIBRARIES= ENV= BASH_ENV= ZDOTDIR= /bin/zsh -f"
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
