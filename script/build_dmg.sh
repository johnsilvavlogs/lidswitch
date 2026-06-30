#!/usr/bin/env bash
set -euo pipefail

APP_NAME="LidSwitch"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
TMP_ROOT="${TMPDIR:-/tmp}"
TMP_ROOT="${TMP_ROOT%/}"
APP_STAGE_ROOT="${LIDSWITCH_APP_STAGE_ROOT:-$TMP_ROOT/lidswitch-app}"
APP_BUNDLE="${LIDSWITCH_APP_BUNDLE:-$APP_STAGE_ROOT/$APP_NAME.app}"
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

verify_bundle_signature() {
  local target="$1"
  local attempt
  for attempt in 1 2 3 4 5; do
    clean_bundle_metadata "$target"
    if /usr/bin/codesign --verify --deep --strict --verbose=2 "$target" >/dev/null 2>/dev/null; then
      return 0
    fi
    sleep 0.25
  done
  clean_bundle_metadata "$target"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$target" >/dev/null
}

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
clean_bundle_metadata "$APP_BUNDLE"

STAGE_DIR="$(/usr/bin/mktemp -d /tmp/lidswitch-dmg.XXXXXX)"
cleanup() {
  /bin/rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

CLEAN_APP="$STAGE_DIR/$APP_NAME.app"
/usr/bin/ditto --norsrc --noextattr "$APP_BUNDLE" "$CLEAN_APP"
clean_bundle_metadata "$CLEAN_APP"
sign_bundle_ad_hoc "$CLEAN_APP"
verify_bundle_signature "$CLEAN_APP"

rm -f "$DMG_PATH" "$CHECKSUM_PATH"
COPYFILE_DISABLE=1 /usr/bin/hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$CLEAN_APP" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

clean_bundle_metadata "$DMG_PATH"

(
  cd "$DIST_DIR"
  /usr/bin/shasum -a 256 "$APP_NAME.dmg" | tee "$CHECKSUM_PATH"
)

clean_bundle_metadata "$DMG_PATH"

cat <<EOF
Created:
  $DMG_PATH
  $CHECKSUM_PATH

This DMG is not notarized. Recipients may need to use Open Anyway in macOS Security settings.
EOF
