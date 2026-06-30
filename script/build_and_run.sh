#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="LidSwitch"
BUNDLE_ID="com.johnsilva.LidSwitch"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}"
TMP_ROOT="${TMP_ROOT%/}"
APP_STAGE_ROOT="${LIDSWITCH_APP_STAGE_ROOT:-$TMP_ROOT/lidswitch-app}"
APP_BUNDLE="${LIDSWITCH_APP_BUNDLE:-$APP_STAGE_ROOT/$APP_NAME.app}"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_SOURCE="$ROOT_DIR/Resources/$APP_NAME.icns"
ICON_FILE="$APP_NAME.icns"

clean_bundle_metadata() {
  local target="$1"
  /usr/bin/find "$target" \( -name '._*' -o -name '.DS_Store' \) -delete 2>/dev/null || true
  /usr/bin/xattr -cr "$target" 2>/dev/null || true
  /usr/bin/xattr -d com.apple.FinderInfo "$target" 2>/dev/null || true
  /usr/bin/xattr -d 'com.apple.fileprovider.fpfs#P' "$target" 2>/dev/null || true
  /usr/bin/xattr -d com.apple.provenance "$target" 2>/dev/null || true
  /usr/bin/find "$target" -exec /usr/bin/xattr -d com.apple.FinderInfo {} + 2>/dev/null || true
  /usr/bin/find "$target" -exec /usr/bin/xattr -d 'com.apple.fileprovider.fpfs#P' {} + 2>/dev/null || true
  /usr/bin/find "$target" -exec /usr/bin/xattr -d com.apple.provenance {} + 2>/dev/null || true
}

sign_bundle_ad_hoc() {
  local target="$1"
  local attempt
  for attempt in 1 2 3 4 5; do
    clean_bundle_metadata "$target"
    if /usr/bin/codesign --force --sign - "$target" >/dev/null 2>/dev/null; then
      return 0
    fi
    sleep 0.25
  done
  clean_bundle_metadata "$target"
  /usr/bin/codesign --force --sign - "$target" >/dev/null
}

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

/usr/bin/arch -arm64 swift build
BUILD_BINARY="$(/usr/bin/arch -arm64 swift build --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
COPYFILE_DISABLE=1 cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

if [ ! -f "$ICON_SOURCE" ]; then
  echo "Missing app icon: $ICON_SOURCE" >&2
  exit 1
fi
COPYFILE_DISABLE=1 cp "$ICON_SOURCE" "$APP_RESOURCES/$ICON_FILE"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIconFile</key>
  <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

sign_bundle_ad_hoc "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

normalize_path() {
  local path="$1"
  while [[ "$path" == *//* ]]; do
    path="${path//\/\//\/}"
  done
  case "$path" in
    /private/var/*)
      printf '/var/%s\n' "${path#/private/var/}"
      ;;
    *)
      printf '%s\n' "$path"
      ;;
  esac
}

executable_path_for_pid() {
  /usr/sbin/lsof -a -p "$1" -Fn 2>/dev/null | awk '
    $0 == "ftxt" { text = 1; next }
    text && substr($0, 1, 1) == "n" { print substr($0, 2); exit }
  '
}

running_app_binary() {
  local expected path
  expected="$(normalize_path "$APP_BINARY")"
  pgrep -x "$APP_NAME" | while read -r pid; do
    path="$(executable_path_for_pid "$pid")"
    if [ "$(normalize_path "$path")" = "$expected" ]; then
      printf '%s\n' "$path"
    fi
  done | head -n 1
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    test -n "$(running_app_binary)"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
