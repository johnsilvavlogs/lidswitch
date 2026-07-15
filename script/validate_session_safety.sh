#!/bin/bash
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

ROOT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
"$ROOT_DIR/script/run_swift_tests_safely.sh" --filter SessionSafetyTests

echo "Session safety simulations passed"
