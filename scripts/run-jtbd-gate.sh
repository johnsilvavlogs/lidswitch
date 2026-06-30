#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

candidate_paths=()
if [[ -n "${JTBD_DONE_GATE_RUNNER:-}" ]]; then
  candidate_paths+=("$JTBD_DONE_GATE_RUNNER")
fi
candidate_paths+=(
  "$HOME/.agents/skills/jtbd-done-gate/scripts/done_gate.py"
  "${CODEX_HOME:-$HOME/.codex}/skills/jtbd-done-gate/scripts/done_gate.py"
)

runner=""
for candidate in "${candidate_paths[@]}"; do
  if [[ -f "$candidate" ]]; then
    runner="$candidate"
    break
  fi
done

if [[ -z "$runner" ]]; then
  cat >&2 <<'EOF'
JTBD done-gate runner not found.

Install the local jtbd-done-gate skill or set:

  JTBD_DONE_GATE_RUNNER=/path/to/done_gate.py

EOF
  exit 127
fi

cd "$ROOT_DIR"
exec python3 "$runner" "$@"
