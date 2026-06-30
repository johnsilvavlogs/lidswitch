#!/usr/bin/env bash
set -euo pipefail

APP_NAME="LidSwitch"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
CHECKSUM_PATH="$DMG_PATH.sha256"

usage() {
  echo "usage: $0 [--dry-run]" >&2
}

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
elif [ "${1:-}" != "" ]; then
  usage
  exit 2
fi

if [ "$DRY_RUN" = "1" ]; then
  cat <<EOF
Would build $APP_BUNDLE using ./script/build_and_run.sh --verify
Would stage a metadata-free app bundle before packaging
Would create unsigned DMG at $DMG_PATH
Would write SHA-256 checksum at $CHECKSUM_PATH
EOF
  exit 0
fi

"$ROOT_DIR/script/build_and_run.sh" --verify
/usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true

STAGE_DIR="$(/usr/bin/mktemp -d /tmp/lidswitch-dmg.XXXXXX)"
cleanup() {
  /bin/rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

CLEAN_APP="$STAGE_DIR/$APP_NAME.app"
/usr/bin/ditto --norsrc --noextattr "$APP_BUNDLE" "$CLEAN_APP"
/usr/bin/xattr -cr "$CLEAN_APP" 2>/dev/null || true
/usr/bin/codesign --force --sign - "$CLEAN_APP" >/dev/null
/usr/bin/codesign --verify --deep --strict --verbose=2 "$CLEAN_APP" >/dev/null

rm -f "$DMG_PATH" "$CHECKSUM_PATH"
COPYFILE_DISABLE=1 /usr/bin/hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$CLEAN_APP" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

(
  cd "$DIST_DIR"
  /usr/bin/shasum -a 256 "$APP_NAME.dmg" | tee "$CHECKSUM_PATH"
)

cat <<EOF
Created:
  $DMG_PATH
  $CHECKSUM_PATH

This DMG is not notarized. Recipients may need to use Open Anyway in macOS Security settings.
EOF
