import Darwin
import Foundation
import LidSwitchCore

enum PrivilegedHelperManager {
    static func diagnosticAdministratorCommand(_ script: String) -> String {
        administratorCommand(script)
    }

    static func diagnosticLaunchDaemonPlist() -> String {
        launchDaemonPlist()
    }

    static func diagnosticInstallScript() -> String {
        installScript()
    }

    static func diagnosticUninstallScript() -> String {
        uninstallScript()
    }

    static func diagnosticRestoreScript() -> String {
        forceRestoreScript()
    }

    static func diagnosticNormalRestoreScriptForTesting() -> String {
        "set -euo pipefail\n\(restoreScript(force: false))"
    }

    static func install() throws {
        guard CompatibilityPolicy.isQualified(systemBuild: SystemBuild.current() ?? "") else {
            throw NSError(
                domain: "LidSwitch.Compatibility",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "This macOS build has not passed LidSwitch safety checks. Protection remains off."]
            )
        }
        try runAsAdministrator(
            installScript(),
            prompt: "LidSwitch needs administrator permission to install its crash-safe helper. Protection will remain off."
        )
    }

    static func uninstall() throws {
        try runAsAdministrator(
            uninstallScript(),
            prompt: "LidSwitch needs administrator permission to restore its power override and remove helper files."
        )
    }

    static func restoreSleepNow() throws {
        try runAsAdministrator(
            forceRestoreScript(),
            prompt: "LidSwitch needs administrator permission to clear its system sleep override."
        )
    }

    private static func runAsAdministrator(_ script: String, prompt: String) throws {
        let command = administratorCommand(script)
        let appleScript = """
        do shell script \(appleScriptQuote(command)) with administrator privileges with prompt \(appleScriptQuote(prompt))
        """

        let result = Shell.run("/usr/bin/osascript", ["-e", appleScript], timeout: 300)
        guard result.exitCode == 0 else {
            let raw = result.stderr.isEmpty ? result.stdout : result.stderr
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let cancelled = normalized.localizedCaseInsensitiveContains("user canceled")
                || normalized.contains("(-128)")
            throw NSError(
                domain: "LidSwitch.PrivilegedHelper",
                code: Int(result.exitCode),
                userInfo: [
                    NSLocalizedDescriptionKey: cancelled
                        ? "Administrator approval was cancelled. LidSwitch made no change during this request; verify the current status before continuing."
                        : (normalized.isEmpty ? "The administrator operation did not complete. Verify the current LidSwitch status before continuing." : normalized)
                ]
            )
        }
    }

    private static func administratorCommand(_ script: String) -> String {
        let encodedScript = Data(script.utf8).base64EncodedString()
        // -f prevents a privileged operation from sourcing the user's zsh startup
        // files. The installer must run only the generated, audited script.
        return "/bin/echo \(shellQuote(encodedScript)) | /usr/bin/base64 --decode | /bin/zsh -f"
    }

    private static func installScript() -> String {
        let sourceHelper = AppPaths.bundledHelperFile.path
        return """
        set -euo pipefail

        root_dir=\(shellQuote(AppPaths.rootSupportDirectory))
        helper_path=\(shellQuote(AppPaths.rootHelperPath))
        legacy_helper_path=\(shellQuote(AppPaths.legacyRootHelperPath))
        helper_version_path=\(shellQuote(AppPaths.rootHelperVersionPath))
        terminal_generations_path=\(shellQuote(AppPaths.rootTerminalGenerationsPath))
        plist_path=\(shellQuote(AppPaths.launchDaemonPath))
        source_helper=\(shellQuote(sourceHelper))
        temp_helper="$root_dir/.LidSwitchHelper.new.$$"
        temp_plist="$plist_path.new.$$"
        terminal_generations_temp="$root_dir/.terminal-generations.new.$$"

        cleanup_failed_install() {
          /bin/rm -f "$temp_helper" "$temp_plist" "$terminal_generations_temp"
        }
        trap cleanup_failed_install EXIT

        lidswitch_terminal_ledger_valid() {
          [ ! -L "$terminal_generations_path" ] || return 1
          [ -f "$terminal_generations_path" ] || return 1
          metadata="$(/usr/bin/stat -f '%u %g %Lp %l %z' "$terminal_generations_path" 2>/dev/null)" || return 1
          set -- $metadata
          [ "$#" -eq 5 ] || return 1
          [ "$1" = "0" ] && [ "$2" = "0" ] && [ "$4" = "1" ] || return 1
          case "$3" in ''|*[!0-7]*) return 1 ;; esac
          [ $((0$3 & 18)) -eq 0 ] || return 1
          [ "$5" -le 2560 ] || return 1
          line_count="$(/usr/bin/awk 'END { print NR }' "$terminal_generations_path")"
          [ "$line_count" -le 64 ] || return 1
          if [ -s "$terminal_generations_path" ]; then
            /usr/bin/grep -Eqv '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' "$terminal_generations_path" && return 1
            duplicate_count="$(/usr/bin/tr '[:upper:]' '[:lower:]' < "$terminal_generations_path" | /usr/bin/sort | /usr/bin/uniq -d | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
            [ "$duplicate_count" -eq 0 ] || return 1
          fi
          return 0
        }

        /bin/launchctl bootout system/\(AppPaths.helperLabel) >/dev/null 2>&1 || true
        /bin/launchctl bootout system "$plist_path" >/dev/null 2>&1 || true
        \(restoreScript(force: false))

        /usr/bin/codesign --verify --strict --verbose=2 "$source_helper" >/dev/null
        /bin/mkdir -p "$root_dir"
        /usr/sbin/chown root:wheel "$root_dir"
        /bin/chmod 0755 "$root_dir"
        if lidswitch_terminal_ledger_valid; then
          /usr/sbin/chown root:wheel "$terminal_generations_path"
          /bin/chmod 0600 "$terminal_generations_path"
        else
          /bin/rm -rf "$terminal_generations_path"
          : > "$terminal_generations_temp"
          /usr/sbin/chown root:wheel "$terminal_generations_temp"
          /bin/chmod 0600 "$terminal_generations_temp"
          /bin/mv -f "$terminal_generations_temp" "$terminal_generations_path"
        fi

        /usr/bin/install -o root -g wheel -m 0755 "$source_helper" "$temp_helper"
        /usr/bin/codesign --verify --strict --verbose=2 "$temp_helper" >/dev/null
        /bin/mv -f "$temp_helper" "$helper_path"

        /usr/bin/printf '%s\n' \(shellQuote(AppPaths.helperVersion)) > "$helper_version_path"
        /usr/sbin/chown root:wheel "$helper_version_path"
        /bin/chmod 0644 "$helper_version_path"

        /bin/cat > "$temp_plist" <<'LIDSWITCH_PLIST'
        \(launchDaemonPlist())
        LIDSWITCH_PLIST
        /usr/sbin/chown root:wheel "$temp_plist"
        /bin/chmod 0644 "$temp_plist"
        /usr/bin/plutil -lint "$temp_plist" >/dev/null
        /bin/mv -f "$temp_plist" "$plist_path"

        /bin/rm -f "$legacy_helper_path"
        /bin/launchctl enable system/\(AppPaths.helperLabel)
        /bin/launchctl bootstrap system "$plist_path"

        trap - EXIT
        """
    }

    private static func uninstallScript() -> String {
        """
        set -euo pipefail
        plist_path=\(shellQuote(AppPaths.launchDaemonPath))

        /bin/launchctl disable system/\(AppPaths.helperLabel)
        /bin/launchctl bootout system/\(AppPaths.helperLabel) >/dev/null 2>&1 || true
        /bin/launchctl bootout system "$plist_path" >/dev/null 2>&1 || true
        \(restoreScript(force: false))
        /bin/rm -f "$plist_path" \(shellQuote(AppPaths.rootHelperPath)) \(shellQuote(AppPaths.legacyRootHelperPath))
        /bin/rm -rf \(shellQuote(AppPaths.rootSupportDirectory))
        """
    }

    private static func forceRestoreScript() -> String {
        "set -euo pipefail\n\(restoreScript(force: true))"
    }

    private static func restoreScript(force: Bool) -> String {
        let forceValue = force ? "1" : "0"
        return """
        lidswitch_applied_state=\(shellQuote(AppPaths.rootAppliedStatePath))
        lidswitch_status_path=\(shellQuote(AppPaths.rootHelperStatusPath))
        lidswitch_legacy_ac=\(shellQuote(AppPaths.rootOriginalACSleepPath))
        lidswitch_legacy_battery=\(shellQuote(AppPaths.rootOriginalBatterySleepPath))

        lidswitch_pmset_bounded() {
          /usr/bin/perl -e 'alarm(shift @ARGV); exec @ARGV or exit 127' 5 /usr/bin/pmset "$@"
        }

        lidswitch_write_status() {
          state="$1"
          reason="$2"
          session="$3"
          status_parent="$(/usr/bin/dirname "$lidswitch_status_path")"
          [ -d "$status_parent" ] || return 0
          status_temp="$lidswitch_status_path.tmp.$$"
          /usr/bin/printf 'state=%s\\nreason=%s\\nsession=%s\\nupdated=%s\\n' \
            "$state" "$reason" "$session" "$(/bin/date +%s)" > "$status_temp" || return 0
          /bin/chmod 0644 "$status_temp" >/dev/null 2>&1 || true
          /bin/mv -f "$status_temp" "$lidswitch_status_path" >/dev/null 2>&1 || /bin/rm -f "$status_temp"
        }

        lidswitch_read_sleep_disabled() {
          lidswitch_pmset_bounded -g live 2>/dev/null | /usr/bin/awk '
            $1 == "SleepDisabled" && ($2 == "0" || $2 == "1") { print $2; found=1; exit }
            END { if (!found) exit 1 }
          '
        }

        lidswitch_read_ac_sleep() {
          lidswitch_pmset_bounded -g custom 2>/dev/null | /usr/bin/awk '
            /^AC Power:/ { ac=1; next }
            /^Battery Power:/ { ac=0; next }
            ac && $1 == "sleep" && $2 ~ /^[0-9]+$/ { print $2; found=1; exit }
            END { if (!found) exit 1 }
          '
        }

        lidswitch_read_battery_sleep() {
          lidswitch_pmset_bounded -g custom 2>/dev/null | /usr/bin/awk '
            /^Battery Power:/ { battery=1; next }
            /^AC Power:/ { battery=0; next }
            battery && $1 == "sleep" && $2 ~ /^[0-9]+$/ { print $2; found=1; exit }
            END { if (!found) exit 1 }
          '
        }

        lidswitch_restore_sleep_disabled() {
          attempt=1
          while [ "$attempt" -le 3 ]; do
            current="$(lidswitch_read_sleep_disabled 2>/dev/null || true)"
            [ "$current" = "0" ] && return 0
            if [ "$current" = "1" ]; then
              lidswitch_pmset_bounded -a disablesleep 0 >/dev/null 2>&1 || true
            fi
            verified="$(lidswitch_read_sleep_disabled 2>/dev/null || true)"
            [ "$verified" = "0" ] && return 0
            if [ "$attempt" -lt 3 ]; then
              /bin/sleep "$attempt"
            fi
            attempt=$((attempt + 1))
          done
          return 1
        }

        lidswitch_restore_ac_sleep() {
          original="$1"
          attempt=1
          while [ "$attempt" -le 3 ]; do
            current="$(lidswitch_read_ac_sleep 2>/dev/null || true)"
            [ "$current" = "$original" ] && return 0
            if [ -n "$current" ] && [ "$current" != "0" ]; then
              # A newer actor superseded LidSwitch's applied value. Do not overwrite it.
              return 0
            fi
            if [ "$current" = "0" ]; then
              lidswitch_pmset_bounded -c sleep "$original" >/dev/null 2>&1 || true
            fi
            verified="$(lidswitch_read_ac_sleep 2>/dev/null || true)"
            [ "$verified" = "$original" ] && return 0
            if [ -n "$verified" ] && [ "$verified" != "0" ]; then
              return 0
            fi
            if [ "$attempt" -lt 3 ]; then
              /bin/sleep "$attempt"
            fi
            attempt=$((attempt + 1))
          done
          return 1
        }

        lidswitch_restore_battery_sleep() {
          original="$1"
          attempt=1
          while [ "$attempt" -le 3 ]; do
            current="$(lidswitch_read_battery_sleep 2>/dev/null || true)"
            [ "$current" = "$original" ] && return 0
            if [ -n "$current" ] && [ "$current" != "0" ]; then
              return 0
            fi
            if [ "$current" = "0" ]; then
              lidswitch_pmset_bounded -b sleep "$original" >/dev/null 2>&1 || true
            fi
            verified="$(lidswitch_read_battery_sleep 2>/dev/null || true)"
            [ "$verified" = "$original" ] && return 0
            if [ -n "$verified" ] && [ "$verified" != "0" ]; then
              return 0
            fi
            if [ "$attempt" -lt 3 ]; then
              /bin/sleep "$attempt"
            fi
            attempt=$((attempt + 1))
          done
          return 1
        }

        lidswitch_parse_applied_state() {
          [ ! -L "$lidswitch_applied_state" ] && [ -f "$lidswitch_applied_state" ] || return 2
          metadata="$(/usr/bin/stat -f '%u:%g:%Lp:%l:%z' "$lidswitch_applied_state" 2>/dev/null)" || return 2
          IFS=: read -r owner group mode links size <<< "$metadata"
          [ "$owner" = "0" ] && [ "$group" = "0" ] && [ "$links" = "1" ] || return 2
          case "$mode" in 600|640|644) ;; *) return 2 ;; esac
          [ "$size" -gt 0 ] && [ "$size" -le 4096 ] || return 2

          /usr/bin/awk '
            BEGIN { valid=1; count=0 }
            {
              separator=index($0, "=")
              if (separator <= 1) { valid=0; next }
              key=substr($0, 1, separator - 1)
              value=substr($0, separator + 1)
              if (key != "session" && key != "changed_sleep_disabled" && key != "changed_ac_sleep" && key != "original_ac_sleep") {
                valid=0; next
              }
              if (seen[key]++) { valid=0; next }
              values[key]=value
              count++
            }
            END {
              session=values["session"]
              changed_sleep=values["changed_sleep_disabled"]
              changed_ac=values["changed_ac_sleep"]
              original=values["original_ac_sleep"]
              if (count != 4 || length(session) != 36 || session ~ /[^0-9A-Fa-f-]/ ||
                  substr(session,9,1) != "-" || substr(session,14,1) != "-" ||
                  substr(session,19,1) != "-" || substr(session,24,1) != "-") valid=0
              if (changed_sleep != "0" && changed_sleep != "1") valid=0
              if (changed_ac != "0" && changed_ac != "1") valid=0
              if (changed_ac == "1" && (original !~ /^[0-9]+$/ || original + 0 <= 0)) valid=0
              if (changed_ac == "0" && original != "unknown") valid=0
              if (!valid) exit 2
              print changed_sleep, changed_ac, original, session
            }
          ' "$lidswitch_applied_state"
        }

        lidswitch_legacy_file_safe() {
          path="$1"
          [ ! -L "$path" ] && [ -f "$path" ] || return 1
          metadata="$(/usr/bin/stat -f '%u:%g:%Lp:%l:%z' "$path" 2>/dev/null)" || return 1
          IFS=: read -r owner group mode links size <<< "$metadata"
          [ "$owner" = "$(/usr/bin/id -u)" ] && [ "$links" = "1" ] || return 1
          # Historical releases created this root-owned, read-only evidence as
          # root:admin on macOS. Group identity is not a trust boundary because
          # the exact mode allowlist below rejects every group-writable file.
          case "$mode" in 600|640|644) ;; *) return 1 ;; esac
          [ "$size" -gt 0 ] && [ "$size" -le 128 ]
        }

        lidswitch_legacy_original() {
          path="$1"
          lidswitch_legacy_file_safe "$path" || return 1
          value="$(/bin/cat "$path" 2>/dev/null | /usr/bin/tr -d '[:space:]')"
          case "$value" in
            ''|*[!0-9]*|0) return 1 ;;
            *) /usr/bin/printf '%s\\n' "$value" ;;
          esac
        }

        lidswitch_restore_owned_state() {
          force=\(forceValue)
          state_present=0
          changed_sleep=0
          changed_ac=0
          changed_battery=0
          original=unknown
          original_battery=unknown
          session=none
          legacy_evidence=0

          if [ -e "$lidswitch_applied_state" ] || [ -L "$lidswitch_applied_state" ]; then
            state_present=1
            parsed="$(lidswitch_parse_applied_state 2>/dev/null)" || {
              if [ "$force" != "1" ]; then
                lidswitch_write_status recovery-required invalid-applied-state none
                return 75
              fi
              changed_sleep=1
              legacy_original="$(lidswitch_legacy_original "$lidswitch_legacy_ac" 2>/dev/null || true)"
              if [ -n "$legacy_original" ]; then
                changed_ac=1
                original="$legacy_original"
              fi
            }
            if [ -n "${parsed:-}" ]; then
              IFS=' ' read -r changed_sleep changed_ac original session <<< "$parsed"
            fi
          elif [ "$force" = "1" ]; then
            changed_sleep=1
            legacy_original="$(lidswitch_legacy_original "$lidswitch_legacy_ac" 2>/dev/null || true)"
            if [ -n "$legacy_original" ]; then
              changed_ac=1
              original="$legacy_original"
            fi
          fi

          # Migrate a valid legacy baseline even when the new applied-state file
          # does not exist. Restoration remains ownership-aware: the helper only
          # writes when the current AC sleep value is still LidSwitch's applied 0;
          # a newer nonzero value is left untouched by lidswitch_restore_ac_sleep.
          for legacy_path in "$lidswitch_legacy_ac" "$lidswitch_legacy_battery"; do
            if [ -e "$legacy_path" ] || [ -L "$legacy_path" ]; then
              if ! lidswitch_legacy_file_safe "$legacy_path"; then
                lidswitch_write_status recovery-required unsafe-legacy-state "$session"
                return 75
              fi
              legacy_evidence=1
            fi
          done

          if [ "$changed_ac" = "0" ]; then
            legacy_original="$(lidswitch_legacy_original "$lidswitch_legacy_ac" 2>/dev/null || true)"
            if [ -n "$legacy_original" ]; then
              changed_ac=1
              original="$legacy_original"
            fi
          fi
          legacy_battery_original="$(lidswitch_legacy_original "$lidswitch_legacy_battery" 2>/dev/null || true)"
          if [ -n "$legacy_battery_original" ]; then
            changed_battery=1
            original_battery="$legacy_battery_original"
          fi

          [ "$force" = "1" ] && changed_sleep=1
          [ "$legacy_evidence" = "1" ] && changed_sleep=1

          sleep_ok=1
          ac_ok=1
          battery_ok=1
          if [ "$changed_sleep" = "1" ]; then
            lidswitch_restore_sleep_disabled || sleep_ok=0
          fi
          if [ "$changed_ac" = "1" ]; then
            lidswitch_restore_ac_sleep "$original" || ac_ok=0
          fi
          if [ "$changed_battery" = "1" ]; then
            lidswitch_restore_battery_sleep "$original_battery" || battery_ok=0
          fi

          if [ "$sleep_ok" != "1" ] || [ "$ac_ok" != "1" ] || [ "$battery_ok" != "1" ]; then
            lidswitch_write_status recovery-required restore-unverified "$session"
            return 75
          fi

          if ! /bin/rm -f "$lidswitch_applied_state"; then
            lidswitch_write_status recovery-required applied-state-remove-failed "$session"
            return 75
          fi
          /bin/rm -f "$lidswitch_legacy_ac" "$lidswitch_legacy_battery" >/dev/null 2>&1 || true
          if [ "$state_present" = "1" ] || [ "$force" = "1" ] || [ "$legacy_evidence" = "1" ]; then
            lidswitch_write_status inactive restored "$session"
          fi
          return 0
        }

        lidswitch_restore_owned_state
        """
    }

    private static func launchDaemonPlist() -> String {
        let ownerUID = getuid()
        let qualifiedBuild = SystemBuild.current() ?? "unqualified"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(AppPaths.helperLabel)</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(AppPaths.rootHelperPath)</string>
            <string>--lease-path</string>
            <string>\(xmlEscape(AppPaths.activationLeaseFile.path))</string>
            <string>--owner-uid</string>
            <string>\(ownerUID)</string>
            <string>--qualified-build</string>
            <string>\(xmlEscape(qualifiedBuild))</string>
            <string>--support-directory</string>
            <string>\(xmlEscape(AppPaths.rootSupportDirectory))</string>
            <string>--applied-state</string>
            <string>\(xmlEscape(AppPaths.rootAppliedStatePath))</string>
            <string>--status-path</string>
            <string>\(xmlEscape(AppPaths.rootHelperStatusPath))</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <dict>
            <key>SuccessfulExit</key>
            <false/>
          </dict>
          <key>WatchPaths</key>
          <array>
            <string>\(xmlEscape(AppPaths.activationLeaseFile.path))</string>
          </array>
          <key>ProcessType</key>
          <string>Background</string>
          <key>ThrottleInterval</key>
          <integer>10</integer>
          <key>StandardOutPath</key>
          <string>/var/log/lidswitch-helper.log</string>
          <key>StandardErrorPath</key>
          <string>/var/log/lidswitch-helper.log</string>
        </dict>
        </plist>
        """
    }

    private static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
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
