#!/bin/bash -p
[[ $- == *p* && "$0" == /dev/fd/30 && "${BASH_SOURCE[0]}" == /dev/fd/30 && "${LIDSWITCH_HELD_ENTRY:-}" == v1 && "${LIDSWITCH_HELD_FD_MAP:-}" == 30,31,32,33,34,35,36,37,38,39,40,41 ]] || { echo "held entry required" >&2; exit 64; }
IFS= read -r -n 1 held_release <&41 || exit 64
[[ "$held_release" == R ]] || exit 64
[[ "${LIDSWITCH_HELD_RELEASE_CANDIDATE:-}" == v1 ]] || exit 64
readonly LIDSWITCH_HELD_WRAPPER_LOADED=1
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

usage() { echo "usage: $0 [--print-bin-path]" >&2; exit 64; }
PRINT_BIN_PATH=false
case "${1:-}" in
  "") ;;
  --print-bin-path) PRINT_BIN_PATH=true ;;
  *) usage ;;
esac
[[ $# -le 1 ]] || usage

ROOT_DIR="${LIDSWITCH_HELD_REPO_ROOT:-}"
[[ "$ROOT_DIR" == /* ]] || exit 64
source /dev/fd/31
source /dev/fd/32
swift_sandbox_reject_inherited_paths || exit $?
swift_sandbox_reject_inherited_fds || exit $?
if ! swift_sandbox_setup "$ROOT_DIR" release; then
  [[ -z "${LIDSWITCH_SWIFT_EXEC_ROOT:-}" ]] || echo "Retained denied Swift build execution root: $LIDSWITCH_SWIFT_EXEC_ROOT" >&2
  [[ -z "${LIDSWITCH_SWIFT_CONTROL_ROOT:-}" ]] || echo "Retained denied Swift build control root: $LIDSWITCH_SWIFT_CONTROL_ROOT" >&2
  exit 64
fi
if ! live_envelope_preflight; then
  echo "Retained denied Swift build execution root: $LIDSWITCH_SWIFT_EXEC_ROOT" >&2
  echo "Retained denied Swift build control root: $LIDSWITCH_SWIFT_CONTROL_ROOT" >&2
  status=74
  trap '' HUP INT TERM
  live_envelope_finalize_terminal_receipt 256 "$status" || status=74
  trap - HUP INT TERM
  exit 74
fi
cd "$LIDSWITCH_SWIFT_HELPER_SOURCE_ROOT"

status=0
command_status=256
output_consumed=false
release_published=false
helper_path=""
app_path=""
helper_cdhash=""
capture_names=()
postflight_done=false
postflight_on_exit() {
  local shell_status=$?
  if [[ "$postflight_done" != true ]]; then
    set +e
    postflight_done=true
    echo "Retained Swift build execution root: $LIDSWITCH_SWIFT_EXEC_ROOT" >&2
    echo "Retained Swift build control root: $LIDSWITCH_SWIFT_CONTROL_ROOT" >&2
    echo "Retained host receipt: unavailable-before-capture-validation" >&2
    exit "${status:-$shell_status}"
  fi
}
trap postflight_on_exit EXIT
trap 'status=129; exit 129' HUP
trap 'status=130; exit 130' INT
trap 'status=143; exit 143' TERM
if swift_sandbox_run helper-build build release-helper \
  -c release \
  --scratch-path "$LIDSWITCH_SWIFT_HELPER_SCRATCH_PATH" \
  --cache-path "$LIDSWITCH_SWIFTPM_CACHE_PATH" \
  --config-path "$LIDSWITCH_SWIFTPM_CONFIG_PATH" \
  --security-path "$LIDSWITCH_SWIFTPM_SECURITY_PATH" \
  --product LidSwitchHelper; then
  command_status="$LIDSWITCH_SWIFT_CHILD_EXIT"
  status="$command_status"
  capture_names+=(helper-build)
else
  command_status="$(swift_sandbox_authenticated_child_exit_or_untrusted)"
  status=74
fi
if [[ "$status" -eq 0 && "$command_status" -eq 0 ]]; then
  if swift_sandbox_run helper-bin-path build release-helper \
    -c release \
    --scratch-path "$LIDSWITCH_SWIFT_HELPER_SCRATCH_PATH" \
    --cache-path "$LIDSWITCH_SWIFTPM_CACHE_PATH" \
    --config-path "$LIDSWITCH_SWIFTPM_CONFIG_PATH" \
    --security-path "$LIDSWITCH_SWIFTPM_SECURITY_PATH" \
    --show-bin-path; then
    command_status="$LIDSWITCH_SWIFT_CHILD_EXIT"
    status="$command_status"
    capture_names+=(helper-bin-path)
  else
    command_status="$(swift_sandbox_authenticated_child_exit_or_untrusted)"
    status=74
  fi
fi
if [[ "$status" -eq 0 && "$command_status" -eq 0 ]]; then
  HELPER_BIN_PATH="$(swift_sandbox_read_bin_path helper-bin-path "$LIDSWITCH_SWIFT_HELPER_SCRATCH_PATH")" || status=74
  helper_path="$HELPER_BIN_PATH/LidSwitchHelper"
  swift_sandbox_assert_release_binary_path helper "$helper_path" || status=74
fi
if [[ "$status" -eq 0 ]]; then
  if swift_sandbox_sign_release_helper helper-sign "$helper_path"; then
    command_status="$LIDSWITCH_SWIFT_CHILD_EXIT"; status="$command_status"; capture_names+=(helper-sign)
  else
    command_status="$(swift_sandbox_authenticated_child_exit_or_untrusted)"; status=74
  fi
fi
if [[ "$status" -eq 0 ]]; then
  if swift_sandbox_verify_release_helper helper-verify "$helper_path"; then
    command_status="$LIDSWITCH_SWIFT_CHILD_EXIT"; status="$command_status"; capture_names+=(helper-verify)
  else
    command_status="$(swift_sandbox_authenticated_child_exit_or_untrusted)"; status=74
  fi
fi
if [[ "$status" -eq 0 ]]; then
  if swift_sandbox_inspect_release_helper helper-identity "$helper_path"; then
    command_status="$LIDSWITCH_SWIFT_CHILD_EXIT"; status="$command_status"; capture_names+=(helper-identity)
  else
    command_status="$(swift_sandbox_authenticated_child_exit_or_untrusted)"; status=74
  fi
fi
if [[ "$status" -eq 0 ]]; then
  helper_cdhash="$(swift_sandbox_read_release_helper_cdhash helper-identity)" || status=74
  helper_relative="${helper_path#"$LIDSWITCH_SWIFT_EXEC_ROOT/"}"
  [[ "$helper_relative" != "$helper_path" ]] || status=74
fi
if [[ "$status" -eq 0 ]]; then
  swift_sandbox_reassert_before_sensitive_host_action "${capture_names[@]}" || status=74
  swift_sandbox_derive_release_app_source "$helper_relative" "$helper_cdhash" || status=74
fi
if [[ "$status" -eq 0 ]]; then
  cd "$LIDSWITCH_SWIFT_APP_SOURCE_ROOT"
  if swift_sandbox_run app-build build release-app \
    -c release \
    --scratch-path "$LIDSWITCH_SWIFT_APP_SCRATCH_PATH" \
    --cache-path "$LIDSWITCH_SWIFTPM_CACHE_PATH" \
    --config-path "$LIDSWITCH_SWIFTPM_CONFIG_PATH" \
    --security-path "$LIDSWITCH_SWIFTPM_SECURITY_PATH" \
    --product LidSwitch; then
    command_status="$LIDSWITCH_SWIFT_CHILD_EXIT"; status="$command_status"; capture_names+=(app-build)
  else
    command_status="$(swift_sandbox_authenticated_child_exit_or_untrusted)"; status=74
  fi
fi
if [[ "$status" -eq 0 ]]; then
  if swift_sandbox_run app-bin-path build release-app \
    -c release \
    --scratch-path "$LIDSWITCH_SWIFT_APP_SCRATCH_PATH" \
    --cache-path "$LIDSWITCH_SWIFTPM_CACHE_PATH" \
    --config-path "$LIDSWITCH_SWIFTPM_CONFIG_PATH" \
    --security-path "$LIDSWITCH_SWIFTPM_SECURITY_PATH" \
    --show-bin-path; then
    command_status="$LIDSWITCH_SWIFT_CHILD_EXIT"; status="$command_status"; capture_names+=(app-bin-path)
  else
    command_status="$(swift_sandbox_authenticated_child_exit_or_untrusted)"; status=74
  fi
fi
if [[ "$status" -eq 0 ]]; then
  APP_BIN_PATH="$(swift_sandbox_read_bin_path app-bin-path "$LIDSWITCH_SWIFT_APP_SCRATCH_PATH")" || status=74
  app_path="$APP_BIN_PATH/LidSwitch"
  swift_sandbox_assert_release_binary_path app "$app_path" || status=74
  app_relative="${app_path#"$LIDSWITCH_SWIFT_EXEC_ROOT/"}"
  [[ "$app_relative" != "$app_path" ]] || status=74
fi
if [[ "$status" -eq 0 ]]; then
  swift_sandbox_reassert_before_sensitive_host_action "${capture_names[@]}" || status=74
fi
if [[ "$status" -eq 0 ]]; then
  LIDSWITCH_RELEASE_CAPTURE_IDENTIFIERS="app-bin-path=$(swift_sandbox_capture_identifier app-bin-path),app-build=$(swift_sandbox_capture_identifier app-build),helper-bin-path=$(swift_sandbox_capture_identifier helper-bin-path),helper-build=$(swift_sandbox_capture_identifier helper-build),helper-identity=$(swift_sandbox_capture_identifier helper-identity),helper-sign=$(swift_sandbox_capture_identifier helper-sign),helper-verify=$(swift_sandbox_capture_identifier helper-verify)" || status=74
  LIDSWITCH_SWIFT_CAPTURE_IDENTIFIERS="${LIDSWITCH_RELEASE_CAPTURE_IDENTIFIERS//=/:}"
fi
if [[ "$status" -eq 0 ]]; then
  swift_sandbox_publish_release_output "$helper_relative" "$app_relative" "$helper_cdhash" "$LIDSWITCH_RELEASE_CAPTURE_IDENTIFIERS" || status=74
  [[ "$status" -eq 0 ]] && release_published=true
fi
if [[ "$status" -eq 0 ]]; then
  output_consumed=true
  for capture_name in "${capture_names[@]}"; do
    swift_sandbox_emit_captured_output "$capture_name" || output_consumed=false
  done
  if [[ "$PRINT_BIN_PATH" == true ]]; then
    printf '%s\n' "$LIDSWITCH_SWIFT_RELEASE_OUTPUT_ROOT"
  fi
fi
postflight_reassert=false
if [[ "$output_consumed" == true && "$release_published" == true ]]; then
  swift_sandbox_reassert_before_sensitive_host_action "${capture_names[@]}" && postflight_reassert=true
fi
if [[ "$postflight_reassert" == true ]] && live_envelope_postflight "$command_status"; then
  LIVE_ENVELOPE_TERMINAL_OUTCOME=preserved
  LIVE_ENVELOPE_TERMINAL_ERROR=none
  if [[ "$command_status" -ne 0 ]]; then
    LIVE_ENVELOPE_TERMINAL_OUTCOME=command-failed-host-preserved
  elif ! swift_sandbox_publish_benchmark; then
    LIVE_ENVELOPE_TERMINAL_OUTCOME=benchmark-publication-failed-host-unverified
    LIVE_ENVELOPE_TERMINAL_ERROR=benchmark-publication-failed
    status=74
  fi
else
  status=74
  if [[ "${LIVE_ENVELOPE_TERMINAL_OUTCOME:-}" != host-drift ]]; then
    LIVE_ENVELOPE_TERMINAL_OUTCOME=envelope-failed-host-unverified
    LIVE_ENVELOPE_TERMINAL_ERROR=envelope-output-or-postflight-failed
  fi
fi
final_reassert=false
if [[ "$output_consumed" == true && "$release_published" == true ]]; then
  swift_sandbox_reassert_before_sensitive_host_action "${capture_names[@]}" && final_reassert=true
fi
if [[ "$final_reassert" != true ]]; then
  status=74
  LIVE_ENVELOPE_TERMINAL_OUTCOME=envelope-final-reassert-failed-host-unverified
  LIVE_ENVELOPE_TERMINAL_ERROR=final-runtime-or-capture-reassert-failed
fi
# All diagnostic/output/status-affecting work is complete before the only
# terminal receipt attempt.  A failed receipt leaves no receipt-success claim.
trap '' HUP INT TERM
live_envelope_finalize_terminal_receipt "$command_status" "$status" || status=74
postflight_done=true
trap - EXIT HUP INT TERM
exit "$status"
