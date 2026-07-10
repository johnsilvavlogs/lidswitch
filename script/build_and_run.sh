#!/bin/bash
set -euo pipefail

MODE="${1:---build}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${LIDSWITCH_APP_BUNDLE:-${LIDSWITCH_APP_STAGE_ROOT:-${TMPDIR:-/tmp}/lidswitch-app}/LidSwitch.app}"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/LidSwitch"
BUNDLE_ID="com.johnsilva.LidSwitch"

build() {
  "$ROOT_DIR/script/build_app_bundle.sh" >/dev/null
}

case "$MODE" in
  --build|build|--verify|verify)
    build
    echo "Verified without launching: $APP_BUNDLE"
    ;;
  --run|run)
    build
    /usr/bin/open -n "$APP_BUNDLE"
    ;;
  --debug|debug)
    build
    /usr/bin/lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    build
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'process == "LidSwitch"'
    ;;
  --telemetry|telemetry)
    build
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  *)
    echo "usage: $0 [--build|--verify|--run|--debug|--logs|--telemetry]" >&2
    echo "Launching is always explicit; the default is a no-launch build." >&2
    exit 2
    ;;
esac
