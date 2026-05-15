import Darwin
import Foundation

enum PrivilegedHelperManager {
    static func diagnosticHelperScript() -> String {
        helperScript(stateFile: AppPaths.desiredStateFile.path)
    }

    static func diagnosticLaunchDaemonPlist() -> String {
        launchDaemonPlist()
    }

    static func diagnosticInstallScript(initiallyEnabled: Bool) -> String {
        installScript(initiallyEnabled: initiallyEnabled)
    }

    static func diagnosticUninstallScript() -> String {
        uninstallScript()
    }

    static func install(initiallyEnabled: Bool) throws {
        let script = installScript(initiallyEnabled: initiallyEnabled)
        try runAsAdministrator(
            script,
            prompt: "LidSwitch needs admin permission to install the AC-only lid-awake helper."
        )
    }

    static func uninstall() throws {
        let script = uninstallScript()
        try runAsAdministrator(
            script,
            prompt: "LidSwitch needs admin permission to restore sleep behavior and remove its helper."
        )
    }

    static func restoreSleepNow() throws {
        let script = """
        /usr/bin/pmset -a disablesleep 0
        if [ -f \(shellQuote(AppPaths.rootOriginalACSleepPath)) ]; then
          original="$(/bin/cat \(shellQuote(AppPaths.rootOriginalACSleepPath)) | /usr/bin/tr -cd '0-9')"
          if [ -n "$original" ]; then
            /usr/bin/pmset -c sleep "$original"
          fi
        fi
        """

        try runAsAdministrator(
            script,
            prompt: "LidSwitch needs admin permission to restore normal sleep behavior."
        )
    }

    private static func runAsAdministrator(_ script: String, prompt: String) throws {
        let encodedScript = Data(script.utf8).base64EncodedString()
        let command = "/bin/echo \(shellQuote(encodedScript)) | /usr/bin/base64 --decode | /bin/zsh"
        let appleScript = """
        do shell script \(appleScriptQuote(command)) with administrator privileges with prompt \(appleScriptQuote(prompt))
        """

        let result = Shell.run("/usr/bin/osascript", ["-e", appleScript])
        guard result.exitCode == 0 else {
            let message = result.stderr.isEmpty ? result.stdout : result.stderr
            throw NSError(
                domain: "LidSwitch.PrivilegedHelper",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: message.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        }
    }

    private static func installScript(initiallyEnabled: Bool) -> String {
        let userSupportDirectory = AppPaths.userSupportDirectory.path
        let desiredStateFile = AppPaths.desiredStateFile.path
        let desiredState = initiallyEnabled ? "enabled" : "disabled"
        let uid = getuid()
        let gid = getgid()

        return """
        set -euo pipefail

        root_dir=\(shellQuote(AppPaths.rootSupportDirectory))
        helper_path=\(shellQuote(AppPaths.rootHelperPath))
        plist_path=\(shellQuote(AppPaths.launchDaemonPath))
        user_support_dir=\(shellQuote(userSupportDirectory))
        desired_state_file=\(shellQuote(desiredStateFile))

        /bin/mkdir -p "$root_dir" "$user_support_dir"
        /usr/sbin/chown \(uid):\(gid) "$user_support_dir"
        /bin/chmod 0755 "$user_support_dir"
        /usr/bin/printf '%s\\n' \(shellQuote(desiredState)) > "$desired_state_file"
        /usr/sbin/chown \(uid):\(gid) "$desired_state_file"
        /bin/chmod 0644 "$desired_state_file"

        /bin/cat > "$helper_path" <<'LIDSWITCH_HELPER'
        \(helperScript(stateFile: desiredStateFile))
        LIDSWITCH_HELPER
        /usr/sbin/chown root:wheel "$helper_path"
        /bin/chmod 0755 "$helper_path"

        /bin/cat > "$plist_path" <<'LIDSWITCH_PLIST'
        \(launchDaemonPlist())
        LIDSWITCH_PLIST
        /usr/sbin/chown root:wheel "$plist_path"
        /bin/chmod 0644 "$plist_path"
        /usr/bin/plutil -lint "$plist_path" >/dev/null

        /bin/launchctl bootout system "$plist_path" >/dev/null 2>&1 || true
        /bin/launchctl bootstrap system "$plist_path"
        /bin/launchctl kickstart -k system/\(AppPaths.helperLabel)
        """
    }

    private static func uninstallScript() -> String {
        let desiredStateFile = AppPaths.desiredStateFile.path
        let uid = getuid()
        let gid = getgid()

        return """
        set -euo pipefail

        plist_path=\(shellQuote(AppPaths.launchDaemonPath))
        original_ac_sleep=\(shellQuote(AppPaths.rootOriginalACSleepPath))
        desired_state_file=\(shellQuote(desiredStateFile))

        /bin/mkdir -p "$(/usr/bin/dirname "$desired_state_file")"
        /usr/bin/printf 'disabled\\n' > "$desired_state_file"
        /usr/sbin/chown \(uid):\(gid) "$desired_state_file"
        /bin/chmod 0644 "$desired_state_file"

        /usr/bin/pmset -a disablesleep 0
        if [ -f "$original_ac_sleep" ]; then
          original="$(/bin/cat "$original_ac_sleep" | /usr/bin/tr -cd '0-9')"
          if [ -n "$original" ]; then
            /usr/bin/pmset -c sleep "$original"
          fi
        fi

        /bin/launchctl bootout system "$plist_path" >/dev/null 2>&1 || true
        /bin/rm -f "$plist_path" \(shellQuote(AppPaths.rootHelperPath))
        /bin/rm -rf \(shellQuote(AppPaths.rootSupportDirectory))
        """
    }

    private static func helperScript(stateFile: String) -> String {
        """
        #!/bin/zsh
        set -u

        state_file=\(shellQuote(stateFile))
        root_dir=\(shellQuote(AppPaths.rootSupportDirectory))
        original_ac_sleep=\(shellQuote(AppPaths.rootOriginalACSleepPath))

        /bin/mkdir -p "$root_dir"

        desired_state() {
          if [ -f "$state_file" ]; then
            /bin/cat "$state_file" | /usr/bin/tr -d '[:space:]'
          else
            /bin/echo disabled
          fi
        }

        current_ac_sleep() {
          /usr/bin/pmset -g custom | /usr/bin/awk '
            /^AC Power:/ { ac=1; next }
            /^Battery Power:/ { ac=0; next }
            ac && $1 == "sleep" { print $2; exit }
          '
        }

        remember_original_ac_sleep() {
          if [ ! -f "$original_ac_sleep" ]; then
            original="$(current_ac_sleep)"
            if [ -n "$original" ]; then
              /usr/bin/printf '%s\\n' "$original" > "$original_ac_sleep"
            fi
          fi
        }

        restore_original_ac_sleep() {
          if [ -f "$original_ac_sleep" ]; then
            original="$(/bin/cat "$original_ac_sleep" | /usr/bin/tr -cd '0-9')"
            if [ -n "$original" ]; then
              /usr/bin/pmset -c sleep "$original"
            fi
            /bin/rm -f "$original_ac_sleep"
          fi
        }

        sleep_disabled="$(/usr/bin/pmset -g live | /usr/bin/awk '/SleepDisabled/ { print $2; exit }')"
        power_source="$(/usr/bin/pmset -g batt)"
        desired="$(desired_state)"

        if [ "$desired" = "enabled" ] && [[ "$power_source" == *"Now drawing from 'AC Power'"* ]]; then
          remember_original_ac_sleep
          /usr/bin/pmset -c sleep 0
          if [ "$sleep_disabled" != "1" ]; then
            /usr/bin/pmset -a disablesleep 1
          fi
        else
          if [ "$sleep_disabled" != "0" ]; then
            /usr/bin/pmset -a disablesleep 0
          fi

          if [ "$desired" != "enabled" ]; then
            restore_original_ac_sleep
          fi
        fi
        """
    }

    private static func launchDaemonPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(AppPaths.helperLabel)</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(AppPaths.rootHelperPath)</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>StartInterval</key>
          <integer>5</integer>
          <key>StandardOutPath</key>
          <string>/var/log/lidswitch-helper.log</string>
          <key>StandardErrorPath</key>
          <string>/var/log/lidswitch-helper.err</string>
        </dict>
        </plist>
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuote(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        + "\""
    }
}
