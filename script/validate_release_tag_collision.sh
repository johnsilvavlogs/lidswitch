#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT_DIR/script/release.env"
RECEIPT_PATH="$ROOT_DIR/release/tag-collision-receipt.json"
REMOTE_URL="https://github.com/johnsilvavlogs/lidswitch.git"
GIT_BIN=/usr/bin/git
RECEIPT_DIRECTORY="$ROOT_DIR/release"
REMOTE_OUTPUT="$RECEIPT_DIRECTORY/.tag-list.$$"
EXPECTED_RECEIPT="$RECEIPT_DIRECTORY/.tag-receipt-expected.$$"
TEMP_RECEIPT=

cleanup() {
  /bin/rm -f "$REMOTE_OUTPUT" "$EXPECTED_RECEIPT"
  [ -z "$TEMP_RECEIPT" ] || /bin/rm -f "$TEMP_RECEIPT"
}
trap cleanup EXIT

fail() {
  local message="$1"
  local status="$2"
  echo "release-tag-collision: $message" >&2
  exit "$status"
}

validate_remote_tags() {
  /usr/bin/awk '
    function valid_ref(value) {
      return value ~ /^refs\/tags\/[^[:space:]]+(\^\{\})?$/
    }
    {
      if (NF != 2 || (length($1) != 40 && length($1) != 64) || $1 !~ /^[0-9A-Fa-f]+$/ || !valid_ref($2)) exit 1
    }
  ' "$REMOTE_OUTPUT"
}

receipt_is_exact() {
  local path="$1"
  local timestamp="$2"
  [ ! -L "$path" ] && [ -f "$path" ] || return 1
  [ "$(/usr/bin/stat -f '%u:%Lp:%l' "$path")" = "$(/usr/bin/id -u):600:1" ] || return 1
  /usr/bin/printf '{\n  "releaseTag": "%s",\n  "repository": "johnsilvavlogs/lidswitch",\n  "collisionFree": true,\n  "checkedAt": "%s"\n}\n' \
    "$LIDSWITCH_RELEASE_TAG" "$timestamp" > "$EXPECTED_RECEIPT"
  /usr/bin/cmp -s "$EXPECTED_RECEIPT" "$path"
}

[ -d "$RECEIPT_DIRECTORY" ] && [ ! -L "$RECEIPT_DIRECTORY" ] || fail "release directory is unsafe" 64
case "$LIDSWITCH_RELEASE_TAG" in
  v[0-9]*.[0-9]*.[0-9]*) ;;
  *) fail "release tag is not normalized" 64 ;;
esac
if [ -e "$RECEIPT_PATH" ] || [ -L "$RECEIPT_PATH" ]; then
  fail "existing receipt is stale or invalid; refusing to overwrite it" 74
fi

if ! "$GIT_BIN" ls-remote --tags "$REMOTE_URL" > "$REMOTE_OUTPUT"; then
  fail "remote tag listing failed; no collision receipt was written" 69
fi
if ! validate_remote_tags; then
  fail "remote tag listing was malformed; no collision receipt was written" 70
fi
if /usr/bin/awk -v tag="$LIDSWITCH_RELEASE_TAG" '
  $2 == "refs/tags/" tag || $2 == "refs/tags/" tag "^{}" { found = 1 }
  END { exit found ? 0 : 1 }
' "$REMOTE_OUTPUT"; then
  echo "Release tag already exists: $LIDSWITCH_RELEASE_TAG" >&2
  exit 1
fi

umask 077
TEMP_RECEIPT="$(/usr/bin/mktemp "$RECEIPT_DIRECTORY/.tag-collision-receipt.XXXXXX")"
timestamp="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
case "$timestamp" in
  ????-??-??T??:??:??Z) ;;
  *) fail "UTC receipt timestamp is not RFC3339" 71 ;;
esac
/usr/bin/printf '{\n  "releaseTag": "%s",\n  "repository": "johnsilvavlogs/lidswitch",\n  "collisionFree": true,\n  "checkedAt": "%s"\n}\n' \
  "$LIDSWITCH_RELEASE_TAG" "$timestamp" > "$TEMP_RECEIPT"
/bin/chmod 0600 "$TEMP_RECEIPT"
receipt_is_exact "$TEMP_RECEIPT" "$timestamp" || fail "temporary receipt failed canonical schema validation" 72
/bin/mv -f "$TEMP_RECEIPT" "$RECEIPT_PATH"
TEMP_RECEIPT=
/bin/sync
receipt_is_exact "$RECEIPT_PATH" "$timestamp" || fail "published receipt failed canonical schema validation" 73
