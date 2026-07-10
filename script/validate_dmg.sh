#!/usr/bin/env bash
set -euo pipefail

APP_NAME="LidSwitch"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
CHECKSUM_PATH="$DMG_PATH.sha256"
EXPECTED_VERSION="0.2.0"
EXPECTED_BUILD="2"

process_ids() {
  /usr/bin/pgrep -x "$APP_NAME" 2>/dev/null | /usr/bin/sort -n | /usr/bin/tr '\n' ' ' || true
}

clean_file_metadata() {
  local target="$1"
  /usr/bin/xattr -cr "$target" 2>/dev/null || true
  /usr/bin/xattr -d com.apple.FinderInfo "$target" 2>/dev/null || true
  /usr/bin/xattr -d 'com.apple.fileprovider.fpfs#P' "$target" 2>/dev/null || true
  /usr/bin/xattr -d com.apple.provenance "$target" 2>/dev/null || true
  /usr/bin/find "$target" -exec /usr/bin/xattr -d com.apple.FinderInfo {} + 2>/dev/null || true
  /usr/bin/find "$target" -exec /usr/bin/xattr -d 'com.apple.fileprovider.fpfs#P' {} + 2>/dev/null || true
  /usr/bin/find "$target" -exec /usr/bin/xattr -d com.apple.provenance {} + 2>/dev/null || true
}

assert_no_release_blocking_file_metadata() {
  local target="$1"
  local attrs
  local attempt

  for attempt in 1 2 3 4 5; do
    clean_file_metadata "$target"
    attrs="$(/usr/bin/xattr "$target" 2>/dev/null || true)"
    if [ -z "$attrs" ]; then
      return 0
    fi
    sleep 0.25
  done

  attrs="$(/usr/bin/xattr "$target" 2>/dev/null || true)"
  if [ "$attrs" = "com.apple.provenance" ]; then
    echo "Ignoring host-managed com.apple.provenance on $target; checksum and mounted app validation cover the release artifact bytes."
    return 0
  fi

  echo "Unexpected extended attributes remain on $target" >&2
  /usr/bin/xattr -lr "$target" >&2
  exit 1
}

assert_no_release_blocking_tree_metadata() {
  local target="$1"
  local blocking_attrs
  local all_attrs

  all_attrs="$(/usr/bin/xattr -lr "$target" 2>/dev/null || true)"
  blocking_attrs="$(
    awk -F': ' '
      NF >= 2 {
        name = $2
        sub(/:.*/, "", name)
        if (name != "com.apple.provenance") {
          print
        }
      }
    ' <<<"$all_attrs"
  )"

  if [ -n "$blocking_attrs" ]; then
    echo "Unexpected extended attributes remain on mounted app" >&2
    printf '%s\n' "$blocking_attrs" >&2
    exit 1
  fi

  if [ -n "$all_attrs" ]; then
    echo "Ignoring host-managed com.apple.provenance on mounted app tree; strict codesign verification still follows."
  fi
}

before_pids="$(process_ids)"
"$ROOT_DIR/script/build_dmg.sh"
after_build_pids="$(process_ids)"
if [ "$before_pids" != "$after_build_pids" ]; then
  echo "DMG build changed the running LidSwitch process set" >&2
  exit 1
fi

(
  cd "$DIST_DIR"
  /usr/bin/shasum -a 256 -c "$(basename "$CHECKSUM_PATH")"
)

MOUNT_DIR="$(/usr/bin/mktemp -d /tmp/lidswitch-dmg-verify.XXXXXX)"
VERIFY_DMG="$(/usr/bin/mktemp /tmp/lidswitch-dmg-copy.XXXXXX.dmg)"
SPCTL_OUT="$(/usr/bin/mktemp /tmp/lidswitch-spctl.XXXXXX)"
DETACHED=0

cleanup() {
  if [ "$DETACHED" = "0" ] && /sbin/mount | /usr/bin/grep -Fq "on $MOUNT_DIR "; then
    /usr/bin/hdiutil detach "$MOUNT_DIR" >/dev/null || true
  fi
  /bin/rmdir "$MOUNT_DIR" 2>/dev/null || true
  /bin/rm -f "$VERIFY_DMG"
  /bin/rm -f "$SPCTL_OUT"
}
trap cleanup EXIT

assert_no_release_blocking_file_metadata "$DMG_PATH"
COPYFILE_DISABLE=1 /bin/cp -X "$DMG_PATH" "$VERIFY_DMG"
clean_file_metadata "$VERIFY_DMG"

expected_hash="$(awk '{ print $1; exit }' "$CHECKSUM_PATH")"
actual_hash="$(/usr/bin/shasum -a 256 "$VERIFY_DMG" | awk '{ print $1; exit }')"
if [ "$actual_hash" != "$expected_hash" ]; then
  echo "Temporary DMG verification copy checksum mismatch" >&2
  echo "expected: $expected_hash" >&2
  echo "actual:   $actual_hash" >&2
  exit 1
fi

/usr/bin/hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_DIR" "$VERIFY_DMG" >/dev/null
APP_ON_DMG="$MOUNT_DIR/$APP_NAME.app"

if [ ! -d "$APP_ON_DMG" ]; then
  echo "Mounted DMG does not contain $APP_NAME.app" >&2
  /bin/ls -la "$MOUNT_DIR" >&2
  exit 1
fi

assert_no_release_blocking_tree_metadata "$APP_ON_DMG"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_ON_DMG" >/dev/null
/usr/bin/codesign --verify --strict --verbose=2 "$APP_ON_DMG/Contents/Library/LaunchServices/LidSwitchHelper" >/dev/null
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_ON_DMG/Contents/Info.plist")" = "$EXPECTED_VERSION"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_ON_DMG/Contents/Info.plist")" = "$EXPECTED_BUILD"
test -x "$APP_ON_DMG/Contents/Library/LaunchServices/LidSwitchHelper"
node "$ROOT_DIR/scripts/scan-public-secrets.mjs" --release-artifacts --path "$DIST_DIR" --path "$APP_ON_DMG"

if /usr/sbin/spctl --assess --type execute --verbose=2 "$APP_ON_DMG" >"$SPCTL_OUT" 2>&1; then
  cat "$SPCTL_OUT" >&2
  echo "Expected Gatekeeper rejection for unsigned/not-notarized app" >&2
  exit 1
fi

if ! /usr/bin/grep -Fq "rejected" "$SPCTL_OUT"; then
  cat "$SPCTL_OUT" >&2
  echo "Expected spctl output to include rejection" >&2
  exit 1
fi

/usr/bin/hdiutil detach "$MOUNT_DIR" >/dev/null
DETACHED=1

after_validation_pids="$(process_ids)"
if [ "$before_pids" != "$after_validation_pids" ]; then
  echo "DMG validation changed the running LidSwitch process set" >&2
  exit 1
fi

cat <<EOF
DMG validation passed:
  $DMG_PATH
  $CHECKSUM_PATH
  mounted app codesign strict verification passed
  Gatekeeper rejection confirmed for manual approval flow
EOF
