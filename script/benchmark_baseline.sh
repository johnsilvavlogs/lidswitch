#!/bin/bash
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

usage() { echo "usage: $0 --output /private/tmp/<safe-root>/<safe-name> --app-bundle /private/tmp/<safe-root>/<safe-name>.app [--samples 5...100]" >&2; exit 64; }
[[ $# -ge 4 ]] || usage
OUTPUT=""; APP_BUNDLE=""; SAMPLES=5
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) [[ $# -ge 2 ]] || usage; OUTPUT="$2"; shift 2 ;;
    --app-bundle) [[ $# -ge 2 ]] || usage; APP_BUNDLE="$2"; shift 2 ;;
    --samples) [[ $# -ge 2 ]] || usage; SAMPLES="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$OUTPUT" == /private/tmp/* && "$OUTPUT" != /tmp/* && "$APP_BUNDLE" == /private/tmp/* && "$APP_BUNDLE" != /tmp/* && "$SAMPLES" =~ ^[0-9]+$ && "$SAMPLES" -ge 5 && "$SAMPLES" -le 100 ]] || usage
ROOT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
USER_SUPPORT="$HOME/Library/Application Support/LidSwitch"
ROOT_SUPPORT="/Library/Application Support/LidSwitch"
case "$OUTPUT" in /tmp/*) echo "output must use literal /private/tmp" >&2; exit 64 ;; esac
PARENT="$(/usr/bin/dirname "$OUTPUT")"; NAME="$(/usr/bin/basename "$OUTPUT")"; PARENT_NAME="$(/usr/bin/basename "$PARENT")"
APP_PARENT="$(/usr/bin/dirname "$APP_BUNDLE")"
APP_NAME="$(/usr/bin/basename "$APP_BUNDLE")"
APP_ROOT_NAME="$(/usr/bin/basename "$APP_PARENT")"
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$ && "$PARENT_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$ && "$PARENT" != "/private/tmp" && "$PARENT" == "/private/tmp/$PARENT_NAME" && "$(/usr/bin/dirname "$PARENT")" == "/private/tmp" && "$OUTPUT" == "$PARENT/$NAME" ]] || { echo "output must be one safe filename in a direct /private/tmp child" >&2; exit 64; }
for protected in "$ROOT_DIR" "$USER_SUPPORT" "$ROOT_SUPPORT" "/Applications/LidSwitch.app"; do
  [[ "$OUTPUT" != "$protected" && "$OUTPUT" != "$protected"/* ]] || { echo "output must be outside protected roots" >&2; exit 64; }
  [[ "$APP_BUNDLE" != "$protected" && "$APP_BUNDLE" != "$protected"/* && "$APP_PARENT" != "$protected" && "$APP_PARENT" != "$protected"/* ]] || { echo "app bundle must be outside protected roots" >&2; exit 64; }
done
[[ ! -L /private/tmp && -d /private/tmp && "$(/usr/bin/stat -f '%u:%g:%p' /private/tmp)" == "0:0:41777" ]] || { echo "literal /private/tmp is unsafe" >&2; exit 64; }
CANONICAL_PARENT="$(cd "$PARENT" && /bin/pwd -P)" || { echo "output parent is unavailable" >&2; exit 64; }
[[ "$CANONICAL_PARENT" == "$PARENT" && -d "$PARENT" && ! -L "$PARENT" && "$(/usr/bin/stat -f '%u:%g:%p' "$PARENT")" == "$(/usr/bin/id -u):$(/usr/bin/id -g):40700" ]] || { echo "output parent must be an existing current-user/current-group exact-mode 0700 direct child" >&2; exit 64; }
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || { echo "output target must not already exist" >&2; exit 64; }
[[ "$APP_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,91}\.app$ && "$APP_ROOT_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$ ]] || { echo "app bundle components are unsafe" >&2; exit 64; }
[[ "$APP_PARENT" != "/private/tmp" && "$(/usr/bin/dirname "$APP_PARENT")" == "/private/tmp" && "$APP_BUNDLE" == "$APP_PARENT/$APP_NAME" ]] || { echo "app bundle must be one .app leaf in a direct /private/tmp child" >&2; exit 64; }
CANONICAL_APP_PARENT="$(cd "$APP_PARENT" && /bin/pwd -P)" || { echo "app bundle parent is unavailable" >&2; exit 64; }
[[ "$CANONICAL_APP_PARENT" == "$APP_PARENT" && "$APP_PARENT" == "/private/tmp/$APP_ROOT_NAME" && -d "$APP_PARENT" && ! -L "$APP_PARENT" && "$(/usr/bin/stat -f '%u:%g:%p' "$APP_PARENT")" == "$(/usr/bin/id -u):$(/usr/bin/id -g):40700" ]] || { echo "app bundle parent must be an existing current-user/current-group exact-mode 0700 direct child" >&2; exit 64; }
[[ -d "$APP_BUNDLE" && ! -L "$APP_BUNDLE" ]] || { echo "app bundle must be a non-symlink .app directory" >&2; exit 64; }
echo "manager-held benchmark required; use the descriptor-held test command in docs/VALIDATION.md" >&2
exit 64
