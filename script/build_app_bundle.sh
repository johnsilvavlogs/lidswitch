#!/bin/bash
set -euo pipefail

APP_NAME="LidSwitch"
APP_VERSION="0.2.1"
APP_BUILD="3"
BUNDLE_ID="com.johnsilva.LidSwitch"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}"
TMP_ROOT="${TMP_ROOT%/}"
SCRATCH_PATH="${LIDSWITCH_SCRATCH_PATH:-$TMP_ROOT/lidswitch-swift-build}"
APP_STAGE_ROOT="${LIDSWITCH_APP_STAGE_ROOT:-$TMP_ROOT/lidswitch-app}"
APP_BUNDLE="${LIDSWITCH_APP_BUNDLE:-$APP_STAGE_ROOT/$APP_NAME.app}"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_HELPERS="$APP_CONTENTS/Library/LaunchServices"
APP_BINARY="$APP_MACOS/$APP_NAME"
HELPER_BINARY="$APP_HELPERS/LidSwitchHelper"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_SOURCE="$ROOT_DIR/Resources/$APP_NAME.icns"

process_ids() {
  /usr/bin/pgrep -x "$APP_NAME" 2>/dev/null | /usr/bin/sort -n | /usr/bin/tr '\n' ' ' || true
}

clean_bundle_metadata() {
  local target="$1"
  /usr/bin/find "$target" \( -name '._*' -o -name '.DS_Store' \) -delete 2>/dev/null || true
  /usr/bin/xattr -cr "$target" 2>/dev/null || true
}

before_pids="$(process_ids)"

if [ ! -f "$ICON_SOURCE" ]; then
  echo "Missing app icon: $ICON_SOURCE" >&2
  exit 1
fi

/bin/mkdir -p "$SCRATCH_PATH" "$APP_STAGE_ROOT"
/usr/bin/arch -arm64 /usr/bin/swift build -c release --scratch-path "$SCRATCH_PATH" --product LidSwitch
/usr/bin/arch -arm64 /usr/bin/swift build -c release --scratch-path "$SCRATCH_PATH" --product LidSwitchHelper
BIN_PATH="$(/usr/bin/arch -arm64 /usr/bin/swift build -c release --scratch-path "$SCRATCH_PATH" --show-bin-path)"

/bin/rm -rf "$APP_BUNDLE"
/bin/mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_HELPERS"
COPYFILE_DISABLE=1 /bin/cp "$BIN_PATH/$APP_NAME" "$APP_BINARY"
COPYFILE_DISABLE=1 /bin/cp "$BIN_PATH/LidSwitchHelper" "$HELPER_BINARY"
COPYFILE_DISABLE=1 /bin/cp "$ICON_SOURCE" "$APP_RESOURCES/$APP_NAME.icns"
/bin/chmod 0755 "$APP_BINARY" "$HELPER_BINARY"

/usr/bin/plutil -create xml1 "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $APP_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string $APP_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $APP_VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $APP_BUILD" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $MIN_SYSTEM_VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$INFO_PLIST"
/usr/libexec/PlistBuddy -c 'Add :NSHighResolutionCapable bool true' "$INFO_PLIST"
/usr/libexec/PlistBuddy -c 'Add :NSPrincipalClass string NSApplication' "$INFO_PLIST"

clean_bundle_metadata "$APP_BUNDLE"
/usr/bin/codesign --force --sign - "$HELPER_BINARY"
/usr/bin/codesign --force --sign - "$APP_BUNDLE"

/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")" = "$APP_VERSION"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")" = "$APP_BUILD"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")" = "$BUNDLE_ID"
/usr/bin/codesign --verify --strict --verbose=2 "$HELPER_BINARY" >/dev/null
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" >/dev/null
case "$(/usr/bin/lipo -archs "$APP_BINARY")" in
  *arm64*) ;;
  *) echo "App binary is not arm64" >&2; exit 1 ;;
esac
case "$(/usr/bin/lipo -archs "$HELPER_BINARY")" in
  *arm64*) ;;
  *) echo "Helper binary is not arm64" >&2; exit 1 ;;
esac

after_pids="$(process_ids)"
if [ "$before_pids" != "$after_pids" ]; then
  echo "Building changed the running LidSwitch process set" >&2
  echo "before: $before_pids" >&2
  echo "after:  $after_pids" >&2
  exit 1
fi

echo "$APP_BUNDLE"
