#!/usr/bin/env bash
set -euo pipefail

APP_NAME="LidSwitch"
HELPER_LABEL="com.johnsilva.lidswitch.helper"
DESIRED_STATE="$HOME/Library/Application Support/LidSwitch/desired-state"
HELPER="/Library/Application Support/LidSwitch/lidswitch-helper"
PLIST="/Library/LaunchDaemons/com.johnsilva.lidswitch.helper.plist"

fail() {
  echo "validate_live_state: $*" >&2
  exit 1
}

pgrep -x "$APP_NAME" >/dev/null || fail "$APP_NAME process is not running"

launchctl print "system/$HELPER_LABEL" >/dev/null || fail "$HELPER_LABEL is not loaded"
test -x "$HELPER" || fail "helper executable is missing"
test -f "$PLIST" || fail "LaunchDaemon plist is missing"
test -f "$DESIRED_STATE" || fail "desired-state file is missing"

desired="$(tr -d '[:space:]' < "$DESIRED_STATE")"
test "$desired" = "enabled" || fail "desired-state is '$desired', expected enabled"

pm_batt="$(pmset -g batt)"
pm_live="$(pmset -g live)"
pm_custom="$(pmset -g custom)"

sleep_disabled="$(awk '/SleepDisabled/ { print $2; exit }' <<<"$pm_live")"
test -n "$sleep_disabled" || fail "could not read SleepDisabled"

if grep -q "Now drawing from 'AC Power'" <<<"$pm_batt"; then
  test "$sleep_disabled" = "1" || fail "AC power should have SleepDisabled 1"
elif grep -q "Now drawing from 'Battery Power'" <<<"$pm_batt"; then
  test "$sleep_disabled" = "0" || fail "battery power should have SleepDisabled 0"
else
  fail "unknown power source: $pm_batt"
fi

battery_sleep="$(
  awk '
    /^Battery Power:/ { battery=1; next }
    /^AC Power:/ { battery=0; next }
    battery && $1 == "sleep" { print $2; exit }
  ' <<<"$pm_custom"
)"
test "$battery_sleep" = "1" || fail "battery sleep profile changed; expected 1, got $battery_sleep"

menu_item="$(
  osascript -e 'tell application "System Events" to tell process "LidSwitch" to get name of menu bar items of menu bar 2'
)"
test -n "$menu_item" || fail "menu bar item not exposed through accessibility"

panel="$(
  osascript \
    -e 'tell application "System Events" to tell process "LidSwitch" to click menu bar item 1 of menu bar 2' \
    -e 'delay 0.3' \
    -e 'tell application "System Events"' \
    -e 'tell process "LidSwitch"' \
    -e 'if exists window 1 then' \
    -e 'get entire contents of window 1' \
    -e 'else' \
    -e 'return ""' \
    -e 'end if' \
    -e 'end tell' \
    -e 'end tell'
)"

if [ -z "$panel" ]; then
  panel="$(
    osascript \
      -e 'tell application "System Events" to tell process "LidSwitch" to click menu bar item 1 of menu bar 2' \
      -e 'delay 0.3' \
      -e 'tell application "System Events" to tell process "LidSwitch" to get entire contents of window 1'
  )"
fi

grep -q "Keep awake on power" <<<"$panel" || fail "menu panel missing primary toggle"
grep -q "Battery sleep stays normal" <<<"$panel" || fail "menu panel missing battery safety copy"
grep -Eq "Keeping awake on power|Armed for power" <<<"$panel" || fail "menu panel missing enabled status"

echo "live state ok: desired=$desired sleepDisabled=$sleep_disabled menuItem=$menu_item"
