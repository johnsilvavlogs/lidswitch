#!/usr/bin/env bash
set -euo pipefail

APP_NAME="LidSwitch"
HELPER_LABEL="com.johnsilva.lidswitch.helper"
DESIRED_STATE="$HOME/Library/Application Support/LidSwitch/desired-state"
HELPER="/Library/Application Support/LidSwitch/lidswitch-helper"
HELPER_VERSION="/Library/Application Support/LidSwitch/helper-version"
PLIST="/Library/LaunchDaemons/com.johnsilva.lidswitch.helper.plist"
EXPECTED_HELPER_VERSION="2"

fail() {
  echo "validate_live_state: $*" >&2
  exit 1
}

pgrep -x "$APP_NAME" >/dev/null || fail "$APP_NAME process is not running"

launchctl print "system/$HELPER_LABEL" >/dev/null || fail "$HELPER_LABEL is not loaded"
test -x "$HELPER" || fail "helper executable is missing"
test -f "$HELPER_VERSION" || fail "helper version file is missing"
test -f "$PLIST" || fail "LaunchDaemon plist is missing"
test -f "$DESIRED_STATE" || fail "desired-state file is missing"

installed_helper_version="$(tr -d '[:space:]' < "$HELPER_VERSION")"
test "$installed_helper_version" = "$EXPECTED_HELPER_VERSION" || fail "helper version is '$installed_helper_version', expected $EXPECTED_HELPER_VERSION"

normalize_pref() {
  case "$1" in
    enabled|enable|true|1|yes|on)
      echo enabled
      ;;
    *)
      echo disabled
      ;;
  esac
}

read_pref() {
  local key="$1"
  local default_value="$2"
  local compact value

  compact="$(tr -d '[:space:]' < "$DESIRED_STATE")"
  if [ "$compact" = "enabled" ]; then
    if [ "$key" = "mode" ]; then
      echo enabled
    else
      echo disabled
    fi
    return
  fi

  if [ "$compact" = "disabled" ]; then
    echo disabled
    return
  fi

  value="$(
    awk -F= -v desired_key="$key" '
      function trim(value) {
        gsub(/^[ \t]+|[ \t]+$/, "", value)
        return value
      }

      NF >= 2 {
        field=tolower(trim($1))
        value=tolower(trim($2))

        if (desired_key == "mode" && (field == "mode" || field == "enabled" || field == "keepawake" || field == "keep-awake")) {
          print value
        }

        if (desired_key == "battery" && (field == "battery" || field == "allowbattery" || field == "allow-battery" || field == "batterykeepawake" || field == "battery-keep-awake")) {
          print value
        }
      }
    ' "$DESIRED_STATE" | tail -n 1
  )"

  normalize_pref "${value:-$default_value}"
}

desired="$(read_pref mode disabled)"
battery_pref="$(read_pref battery disabled)"
test "$desired" = "enabled" || fail "desired mode is '$desired', expected enabled"
test "$battery_pref" = "disabled" || fail "battery preference is '$battery_pref', expected disabled for safe default smoke"

pm_batt="$(pmset -g batt)"
pm_live="$(pmset -g live)"
pm_custom="$(pmset -g custom)"

sleep_disabled="$(awk '/SleepDisabled/ { print $2; exit }' <<<"$pm_live")"
test -n "$sleep_disabled" || fail "could not read SleepDisabled"

if grep -q "Now drawing from 'AC Power'" <<<"$pm_batt"; then
  test "$sleep_disabled" = "1" || fail "AC power should have SleepDisabled 1"
elif grep -q "Now drawing from 'Battery Power'" <<<"$pm_batt"; then
  if [ "$battery_pref" = "enabled" ]; then
    test "$sleep_disabled" = "1" || fail "battery opt-in should have SleepDisabled 1"
  else
    test "$sleep_disabled" = "0" || fail "battery power without opt-in should have SleepDisabled 0"
  fi
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
if [ "$battery_pref" = "enabled" ]; then
  test "$battery_sleep" = "0" || fail "battery opt-in should set battery sleep 0, got $battery_sleep"
else
  test "$battery_sleep" != "0" || fail "battery sleep profile is still overridden while opt-in is disabled"
fi

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
grep -q "Allow on battery" <<<"$panel" || fail "menu panel missing battery opt-in toggle"
grep -q "Battery sleep stays normal" <<<"$panel" || fail "menu panel missing battery safety copy"
grep -Eq "Keeping awake on power|Armed for power" <<<"$panel" || fail "menu panel missing enabled status"

echo "live state ok: desired=$desired battery=$battery_pref sleepDisabled=$sleep_disabled helperVersion=$installed_helper_version menuItem=$menu_item"
