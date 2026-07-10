#!/bin/bash
set -euo pipefail

APP_NAME="LidSwitch"
EXPECTED_VERSION="0.2.1"
EXPECTED_BUILD="3"
EXPECTED_ID="com.johnsilva.LidSwitch"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}"
TMP_ROOT="${TMP_ROOT%/}"
APP_BUNDLE="${LIDSWITCH_APP_BUNDLE:-${LIDSWITCH_APP_STAGE_ROOT:-$TMP_ROOT/lidswitch-app}/$APP_NAME.app}"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
HELPER_BINARY="$APP_BUNDLE/Contents/Library/LaunchServices/LidSwitchHelper"
LEASE_PATH="$HOME/Library/Application Support/LidSwitch/activation-lease"
PLIST_TMP="$(/usr/bin/mktemp /tmp/lidswitch-plist.XXXXXX)"
SPCTL_TMP="$(/usr/bin/mktemp /tmp/lidswitch-spctl.XXXXXX)"

cleanup() {
  /bin/rm -f "$PLIST_TMP" "$SPCTL_TMP"
}
trap cleanup EXIT

process_ids() {
  /usr/bin/pgrep -x "$APP_NAME" 2>/dev/null | /usr/bin/sort -n | /usr/bin/tr '\n' ' ' || true
}

lease_fingerprint() {
  if [ -e "$LEASE_PATH" ] || [ -L "$LEASE_PATH" ]; then
    /usr/bin/stat -f '%HT:%u:%g:%Lp:%l:%z:%m' "$LEASE_PATH"
    /usr/bin/shasum -a 256 "$LEASE_PATH" 2>/dev/null || true
  else
    echo "missing"
  fi
}

power_fingerprint() {
  /usr/bin/pmset -g live 2>/dev/null | /usr/bin/awk '$1 == "SleepDisabled" { print "SleepDisabled=" $2; found=1 } END { if (!found) print "SleepDisabled=unavailable" }'
  /usr/bin/pmset -g custom 2>/dev/null | /usr/bin/awk '/^AC Power:/ { ac=1; next } /^Battery Power:/ { ac=0; next } ac && $1 == "sleep" { print "ACSleep=" $2; found=1 } END { if (!found) print "ACSleep=unavailable" }'
}

before_pids="$(process_ids)"
"$ROOT_DIR/script/build_app_bundle.sh" >/dev/null

test -x "$APP_BINARY"
test -x "$HELPER_BINARY"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")" = "$EXPECTED_VERSION"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_BUNDLE/Contents/Info.plist")" = "$EXPECTED_BUILD"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")" = "$EXPECTED_ID"
/usr/bin/codesign --verify --strict --verbose=2 "$HELPER_BINARY" >/dev/null
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" >/dev/null

before_diagnostic_pids="$(process_ids)"
before_diagnostic_lease="$(lease_fingerprint)"
before_diagnostic_power="$(power_fingerprint)"
"$APP_BINARY" --print-plist >"$PLIST_TMP"
"$APP_BINARY" --print-install-script >/dev/null
"$APP_BINARY" --print-uninstall-script >/dev/null
"$APP_BINARY" --print-restore-script >/dev/null
after_diagnostic_pids="$(process_ids)"
after_diagnostic_lease="$(lease_fingerprint)"
after_diagnostic_power="$(power_fingerprint)"
if [ "$before_diagnostic_pids" != "$after_diagnostic_pids" ] \
  || [ "$before_diagnostic_lease" != "$after_diagnostic_lease" ] \
  || [ "$before_diagnostic_power" != "$after_diagnostic_power" ]; then
  echo "Diagnostic commands changed live LidSwitch or power state" >&2
  exit 1
fi
/usr/bin/plutil -lint "$PLIST_TMP" >/dev/null
if /usr/bin/plutil -p "$PLIST_TMP" | /usr/bin/grep -q '"StartInterval"'; then
  echo "LaunchDaemon must not use StartInterval polling" >&2
  exit 1
fi
if ! /usr/bin/plutil -p "$PLIST_TMP" | /usr/bin/grep -q '"SuccessfulExit" => false'; then
  echo "LaunchDaemon must recover abnormal exits only" >&2
  exit 1
fi
if ! /usr/bin/plutil -p "$PLIST_TMP" | /usr/bin/grep -q '"WatchPaths"'; then
  echo "LaunchDaemon must be event-driven by the lease path" >&2
  exit 1
fi

if /usr/sbin/spctl --assess --type execute --verbose=2 "$APP_BUNDLE" >"$SPCTL_TMP" 2>&1; then
  cat "$SPCTL_TMP" >&2
  echo "Expected Gatekeeper rejection for the documented ad-hoc/manual approval build" >&2
  exit 1
fi
/usr/bin/grep -q 'rejected' "$SPCTL_TMP"

after_pids="$(process_ids)"
if [ "$before_pids" != "$after_pids" ]; then
  echo "Bundle validation launched or stopped LidSwitch" >&2
  echo "before: $before_pids" >&2
  echo "after:  $after_pids" >&2
  exit 1
fi

echo "No-launch bundle validation passed: $APP_BUNDLE"
