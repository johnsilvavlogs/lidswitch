#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH_PATH="${LIDSWITCH_SCRATCH_PATH:-${TMPDIR:-/tmp}/lidswitch-session-safety-build}"

cd "$ROOT_DIR"
/usr/bin/arch -arm64 /usr/bin/swift test \
  --scratch-path "$SCRATCH_PATH" \
  --filter SessionSafetyTests

echo "Session safety simulations passed"
