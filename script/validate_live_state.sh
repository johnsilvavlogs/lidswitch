#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

APP_NAME="LidSwitch"
ROOT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT_DIR/script/release.env"
APP_BUNDLE="${LIDSWITCH_INSTALLED_APP:-/Applications/LidSwitch.app}"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
HELPER_LABEL="$LIDSWITCH_HELPER_LABEL"
HELPER="$LIDSWITCH_ROOT_HELPER_PATH"
HELPER_VERSION="$LIDSWITCH_ROOT_SUPPORT_DIRECTORY/Current/helper-version"
POLICY="$LIDSWITCH_ROOT_ENROLLMENT_POLICY_PATH"
PLIST="/Library/LaunchDaemons/$LIDSWITCH_HELPER_LABEL.plist"
MACH_SERVICE="$LIDSWITCH_MACH_SERVICE"
TERMINAL_LEDGER="/Library/Application Support/LidSwitch/terminal-generations"
RECOVERY_LEDGER="/Library/Application Support/LidSwitch/recovery-reservations"
RECOVERY_PROOF="/Library/Application Support/LidSwitch/recovery-proof"
APPLIED_STATE="/Library/Application Support/LidSwitch/applied-state"
STATUS_FILE="/Library/Application Support/LidSwitch/helper-status"
LEGACY_LOGIN="$HOME/Library/LaunchAgents/com.johnsilva.LidSwitch.login.plist"
LEGACY_HELPER="/Library/Application Support/LidSwitch/lidswitch-helper"
LEGACY_V4_HELPER="/Library/Application Support/LidSwitch/LidSwitchHelper"
LEGACY_V4_VERSION="/Library/Application Support/LidSwitch/helper-version"
EXPECTED_HELPER_VERSION="$LIDSWITCH_HELPER_VERSION"
EXPECTED_BUILD="$LIDSWITCH_QUALIFIED_SYSTEM_BUILD"
OBSERVATION_SECONDS="${LIDSWITCH_LIVE_OBSERVATION_SECONDS:-40}"
CANARY_PREFLIGHT_TOOL="$ROOT_DIR/script/candidate_canary_preflight.py"
CANARY_PREFLIGHT_RECEIPT="${LIDSWITCH_CANARY_PREFLIGHT_RECEIPT:-}"
CANARY_ACTIVE_RECEIPT="${LIDSWITCH_CANARY_ACTIVE_RECEIPT:-}"
CANARY_FINAL_RECEIPT="${LIDSWITCH_CANARY_FINAL_RECEIPT:-}"
CANARY_CANDIDATE_MANIFEST="${LIDSWITCH_CANARY_CANDIDATE_MANIFEST:-}"
CANARY_BINDING="${LIDSWITCH_CANARY_BINDING:-}"

fail() {
  echo "controlled-live-canary: $*" >&2
  exit 1
}

if [ "${LIDSWITCH_CONTROLLED_CANARY:-0}" != "1" ]; then
  fail "refusing live power validation without LIDSWITCH_CONTROLLED_CANARY=1"
fi
test -f "$CANARY_PREFLIGHT_TOOL" || fail "candidate canary preflight tool is missing"
test -n "$CANARY_PREFLIGHT_RECEIPT" || fail "LIDSWITCH_CANARY_PREFLIGHT_RECEIPT is required from the safe-idle preflight"
test -n "$CANARY_ACTIVE_RECEIPT" || fail "LIDSWITCH_CANARY_ACTIVE_RECEIPT is required for exact session binding"
test -n "$CANARY_FINAL_RECEIPT" || fail "LIDSWITCH_CANARY_FINAL_RECEIPT is required for canonical finalization"
test -n "$CANARY_CANDIDATE_MANIFEST" || fail "LIDSWITCH_CANARY_CANDIDATE_MANIFEST is required"
test -n "$CANARY_BINDING" || fail "LIDSWITCH_CANARY_BINDING is required"
test -f "$CANARY_PREFLIGHT_RECEIPT" || fail "candidate preflight receipt is missing"
test ! -e "$CANARY_ACTIVE_RECEIPT" || fail "active receipt path must be a new file"
test ! -e "$CANARY_FINAL_RECEIPT" || fail "final receipt path must be a new file"
case "$OBSERVATION_SECONDS" in
  ''|*[!0-9]*) fail "LIDSWITCH_LIVE_OBSERVATION_SECONDS must be an integer of at least 40" ;;
esac
[ "$OBSERVATION_SECONDS" -ge 40 ] || fail "LIDSWITCH_LIVE_OBSERVATION_SECONDS must be at least 40"

normalize_path() {
  case "$1" in
    /private/var/*) printf '/var/%s\n' "${1#/private/var/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

executable_path_for_pid() {
  /usr/sbin/lsof -a -p "$1" -Fn 2>/dev/null | /usr/bin/awk '
    $0 == "ftxt" { text = 1; next }
    text && substr($0, 1, 1) == "n" { print substr($0, 2); exit }
  '
}

app_pid() {
  local expected pid path
  expected="$(normalize_path "$APP_BINARY")"
  /usr/bin/pgrep -x "$APP_NAME" 2>/dev/null | while read -r pid; do
    path="$(executable_path_for_pid "$pid")"
    if [ "$(normalize_path "$path")" = "$expected" ]; then
      printf '%s\n' "$pid"
    fi
  done | /usr/bin/head -n 1
}

sleep_disabled() {
  /usr/bin/pmset -g live | /usr/bin/awk '
    $1 == "SleepDisabled" && ($2 == "0" || $2 == "1") { print $2; found=1; exit }
    END { if (!found) exit 1 }
  '
}

ac_sleep_minutes() {
  /usr/bin/pmset -g custom | /usr/bin/awk '
    /^AC Power:/ { ac=1; next }
    /^Battery Power:/ { ac=0; next }
    ac && $1 == "sleep" && $2 ~ /^[0-9]+$/ { print $2; found=1; exit }
    END { if (!found) exit 1 }
  '
}

power_is_ac() {
  /usr/bin/pmset -g batt | /usr/bin/grep -Fq "Now drawing from 'AC Power'"
}

status_value() {
  /usr/bin/awk -F= -v key="$1" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$STATUS_FILE"
}

test "$(/usr/sbin/sysctl -n kern.osversion)" = "$EXPECTED_BUILD" || fail "macOS build is not $EXPECTED_BUILD"
power_is_ac || fail "Mac must remain on AC power"
test "$(sleep_disabled)" = "1" || fail "start a verified LidSwitch session before this canary"
test -x "$APP_BINARY" || fail "installed app is missing"
test -x "$HELPER" || fail "native helper is missing"
test ! -e "$LEGACY_HELPER" || fail "legacy shell helper is still present"
test ! -e "$LEGACY_V4_HELPER" || fail "legacy v4 helper is still present"
test ! -e "$LEGACY_V4_VERSION" || fail "legacy v4 helper version marker is still present"
test ! -e "$LEGACY_LOGIN" || fail "legacy login item is still present"
test -f "$HELPER_VERSION" || fail "helper version marker is missing"
test -f "$POLICY" || fail "authenticated enrollment policy is missing"
test -f "$TERMINAL_LEDGER" || fail "terminal ledger is missing"
test -f "$RECOVERY_LEDGER" || fail "recovery reservation ledger is missing"
test -f "$RECOVERY_PROOF" || fail "recovery proof is missing"
for private_authority in "$TERMINAL_LEDGER" "$RECOVERY_LEDGER" "$RECOVERY_PROOF"; do
  test "$(/usr/bin/stat -f '%u:%g:%Lp:%l' "$private_authority")" = "0:0:600:1" \
    || fail "private recovery authority metadata is unsafe"
done
test "$(/usr/bin/tr -d '[:space:]' < "$HELPER_VERSION")" = "$EXPECTED_HELPER_VERSION" || fail "helper version is not $EXPECTED_HELPER_VERSION"
test -f "$PLIST" || fail "LaunchDaemon plist is missing"
if /usr/bin/plutil -extract WatchPaths raw -o - "$PLIST" >/dev/null 2>&1; then
  fail "LaunchDaemon retained the retired WatchPaths lease trigger"
fi
if /usr/bin/plutil -extract StartInterval raw -o - "$PLIST" >/dev/null 2>&1; then
  fail "LaunchDaemon retained a StartInterval poller"
fi
test "$(/usr/libexec/PlistBuddy -c "Print :MachServices:$MACH_SERVICE" "$PLIST" 2>/dev/null)" = "true" || fail "authenticated raw-XPC Mach service is missing"
/bin/launchctl print "system/$HELPER_LABEL" >/dev/null || fail "helper is not registered with launchd"
test -f "$APPLIED_STATE" || fail "applied-state ownership record is missing"
test "$(/usr/bin/stat -f '%u:%g:%Lp:%l' "$APPLIED_STATE")" = "0:0:600:1" \
  || fail "applied-state authority metadata is unsafe"
test -f "$STATUS_FILE" || fail "helper status is missing"
pid="$(app_pid)"
test -n "$pid" || fail "installed LidSwitch app is not running"
# Ordinary-user validation intentionally treats 0600 recovery files as opaque.
# Exact content/schema checks belong to the root no-launch gate and the helper's
# descriptor-held parsers; this canary consumes only public status projection,
# private-file metadata, native power, and final authority disappearance.

# The manager creates the preflight receipt while the candidate is safely idle,
# then manually starts it.  This read-only bind records the exact public active
# session before any deliberate SIGKILL occurs; it cannot manufacture a session.
/usr/bin/python3 -I -S -B "$CANARY_PREFLIGHT_TOOL" bind-active \
  --preflight-receipt "$CANARY_PREFLIGHT_RECEIPT" \
  --active-receipt "$CANARY_ACTIVE_RECEIPT" \
  --status-file "$STATUS_FILE" --candidate-manifest "$CANARY_CANDIDATE_MANIFEST" \
  --canary-binding "$CANARY_BINDING" --app-bundle "$APP_BUNDLE" --helper "$HELPER" \
  || fail "candidate receipt could not bind the active session"

# This is intentionally a second opt-in. It changes only SleepDisabled through
# pmset; it never edits the root-owned lease, status, applied-state, or ledger.
# The preflight proves this helper owns the active generation before injection.
if [ "${LIDSWITCH_INJECT_OVERRIDE_DRIFT:-0}" = "1" ]; then
  session_before="$(status_value session)"
  updated_before="$(status_value updated)"
  monotonic_before="$(status_value updated_monotonic)"
  test -n "$session_before" && test "$session_before" != "none" || fail "active helper session is missing"
  test -n "$updated_before" || fail "active helper timestamp is missing"
  test -n "$monotonic_before" || fail "active helper monotonic timestamp is missing"
  test "$(status_value state)" = "active" || fail "helper is not active before drift injection"
  test "$(sleep_disabled)" = "1" || fail "SleepDisabled is not helper-owned before injection"
  echo "Injecting owned SleepDisabled loss; waiting up to 10 seconds for same-session recovery."
  /usr/bin/sudo /usr/bin/pmset -a disablesleep 0
  recovered=0
  for _ in $(/usr/bin/jot 10); do
    current_updated="$(status_value updated)"
    if power_is_ac \
      && [ "$(sleep_disabled 2>/dev/null || true)" = "1" ] \
      && [ "$(ac_sleep_minutes 2>/dev/null || true)" = "0" ] \
      && [ "$(status_value state)" = "active" ] \
      && [ "$(status_value reason)" = "override-recovered" ] \
      && [ "$(status_value session)" = "$session_before" ] \
      && [ "$current_updated" -ge "$updated_before" ] \
      && [ -n "$(status_value updated_monotonic)" ]; then
      recovered=1
      break
    fi
    /bin/sleep 1
  done
  test "$recovered" = "1" || fail "owned SleepDisabled loss did not recover within 10 seconds"
fi

for _ in $(/usr/bin/jot "$OBSERVATION_SECONDS"); do
  power_is_ac || fail "power changed during active observation"
  test "$(sleep_disabled)" = "1" || fail "sleep override dropped during active observation"
  test "$(status_value state)" = "active" || fail "helper did not acknowledge the active session"
  test -n "$(status_value boot_id)" || fail "helper status boot identity is missing"
  test -n "$(status_value updated_monotonic)" || fail "helper monotonic acknowledgement is missing"
  /bin/sleep 1
done

echo "Active session remained verified for $OBSERVATION_SECONDS seconds; killing app PID $pid to prove peer-process-invalid rollback."
/bin/kill -KILL "$pid"

restored=0
for _ in $(/usr/bin/jot 45); do
  current="$(sleep_disabled 2>/dev/null || true)"
  if [ "$current" = "0" ] && [ ! -e "$APPLIED_STATE" ]; then
    restored=1
    break
  fi
  /bin/sleep 1
done
test "$restored" = "1" || fail "system sleep did not restore within 45 seconds"
test -z "$(app_pid)" || fail "app relaunched automatically after SIGKILL"

/bin/sleep 5
test "$(sleep_disabled)" = "0" || fail "sleep override rearmed after restoration"
test ! -e "$APPLIED_STATE" || fail "applied-state remained after verified restoration"
test "$(status_value state)" = "terminal" || fail "helper did not record a verified terminal state"
test "$(status_value reason)" = "peer-process-invalid" || fail "helper misclassified unsolicited app death"

/usr/bin/python3 -I -S -B "$CANARY_PREFLIGHT_TOOL" finalize \
  --active-receipt "$CANARY_ACTIVE_RECEIPT" \
  --final-receipt "$CANARY_FINAL_RECEIPT" \
  --status-file "$STATUS_FILE" --candidate-manifest "$CANARY_CANDIDATE_MANIFEST" \
  --canary-binding "$CANARY_BINDING" --app-bundle "$APP_BUNDLE" --helper "$HELPER" \
  || fail "candidate receipt could not finalize exact rollback evidence"

echo "Controlled live canary passed: active proof, SIGKILL rollback, and no automatic rearm."
