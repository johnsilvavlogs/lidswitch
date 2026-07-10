#!/bin/bash
set -euo pipefail

APP_NAME="LidSwitch"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT_DIR/script/release.env"
APP_BUNDLE="${LIDSWITCH_INSTALLED_APP:-/Applications/LidSwitch.app}"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
HELPER_LABEL="com.johnsilva.lidswitch.helper"
HELPER="/Library/Application Support/LidSwitch/LidSwitchHelper"
HELPER_VERSION="/Library/Application Support/LidSwitch/helper-version"
APPLIED_STATE="/Library/Application Support/LidSwitch/applied-state"
STATUS_FILE="/Library/Application Support/LidSwitch/helper-status"
LEASE="$HOME/Library/Application Support/LidSwitch/activation-lease"
LEGACY_LOGIN="$HOME/Library/LaunchAgents/com.johnsilva.LidSwitch.login.plist"
LEGACY_HELPER="/Library/Application Support/LidSwitch/lidswitch-helper"
EXPECTED_HELPER_VERSION="$LIDSWITCH_HELPER_VERSION"
EXPECTED_BUILD="25F84"
OBSERVATION_SECONDS="${LIDSWITCH_LIVE_OBSERVATION_SECONDS:-40}"

fail() {
  echo "controlled-live-canary: $*" >&2
  exit 1
}

if [ "${LIDSWITCH_CONTROLLED_CANARY:-0}" != "1" ]; then
  fail "refusing live power validation without LIDSWITCH_CONTROLLED_CANARY=1"
fi
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

lease_is_absent_or_expired() {
  [ ! -e "$LEASE" ] && return 0
  expires="$(/usr/bin/awk -F= '$1 == "expires" { print $2; exit }' "$LEASE" 2>/dev/null || true)"
  case "$expires" in ''|*[!0-9]*) return 1 ;; esac
  [ "$expires" -le "$(/bin/date +%s)" ]
}

test "$(/usr/sbin/sysctl -n kern.osversion)" = "$EXPECTED_BUILD" || fail "macOS build is not $EXPECTED_BUILD"
power_is_ac || fail "Mac must remain on AC power"
test "$(sleep_disabled)" = "1" || fail "start a verified LidSwitch session before this canary"
test -x "$APP_BINARY" || fail "installed app is missing"
test -x "$HELPER" || fail "native helper is missing"
test ! -e "$LEGACY_HELPER" || fail "legacy shell helper is still present"
test ! -e "$LEGACY_LOGIN" || fail "legacy login item is still present"
test -f "$HELPER_VERSION" || fail "helper version marker is missing"
test "$(/usr/bin/tr -d '[:space:]' < "$HELPER_VERSION")" = "$EXPECTED_HELPER_VERSION" || fail "helper version is not $EXPECTED_HELPER_VERSION"
/bin/launchctl print "system/$HELPER_LABEL" >/dev/null || fail "helper is not registered with launchd"
test -f "$LEASE" || fail "activation lease is missing"
test -f "$APPLIED_STATE" || fail "applied-state ownership record is missing"
test -f "$STATUS_FILE" || fail "helper status is missing"
pid="$(app_pid)"
test -n "$pid" || fail "installed LidSwitch app is not running"
changed_ac="$(/usr/bin/awk -F= '$1 == "changed_ac_sleep" { print $2; exit }' "$APPLIED_STATE")"
original_ac="$(/usr/bin/awk -F= '$1 == "original_ac_sleep" { print $2; exit }' "$APPLIED_STATE")"
case "$changed_ac:$original_ac" in
  1:[1-9]*|0:unknown) ;;
  *) fail "applied-state has an invalid AC restoration baseline" ;;
esac

for _ in $(/usr/bin/jot "$OBSERVATION_SECONDS"); do
  power_is_ac || fail "power changed during active observation"
  test "$(sleep_disabled)" = "1" || fail "sleep override dropped during active observation"
  test "$(status_value state)" = "active" || fail "helper did not acknowledge the active session"
  updated="$(status_value updated)"
  now="$(/bin/date +%s)"
  test -n "$updated" || fail "helper status timestamp is missing"
  age=$((now - updated))
  test "$age" -ge -2 && test "$age" -le 6 || fail "helper acknowledgement is stale"
  /bin/sleep 1
done

echo "Active session remained verified for $OBSERVATION_SECONDS seconds; killing app PID $pid to prove lease-expiry rollback."
/bin/kill -KILL "$pid"

restored=0
for _ in $(/usr/bin/jot 45); do
  current="$(sleep_disabled 2>/dev/null || true)"
  ac_restored=1
  if [ "$changed_ac" = "1" ]; then
    test "$(ac_sleep_minutes 2>/dev/null || true)" = "$original_ac" || ac_restored=0
  fi
  if [ "$current" = "0" ] && [ "$ac_restored" = "1" ] && lease_is_absent_or_expired && [ ! -e "$APPLIED_STATE" ]; then
    restored=1
    break
  fi
  /bin/sleep 1
done
test "$restored" = "1" || fail "system sleep did not restore within 45 seconds"
test -z "$(app_pid)" || fail "app relaunched automatically after SIGKILL"

/bin/sleep 5
test "$(sleep_disabled)" = "0" || fail "sleep override rearmed after restoration"
lease_is_absent_or_expired || fail "a current lease reappeared without a new user action"
test ! -e "$APPLIED_STATE" || fail "applied-state remained after verified restoration"
test "$(status_value state)" = "inactive" || fail "helper did not record a verified inactive state"

echo "Controlled live canary passed: active proof, SIGKILL rollback, and no automatic rearm."
