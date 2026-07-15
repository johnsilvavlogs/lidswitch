#!/bin/bash -p
[[ $- == *p* && "$0" == /dev/fd/30 && "${BASH_SOURCE[0]}" == /dev/fd/30 && "${LIDSWITCH_HELD_ENTRY:-}" == v1 && "${LIDSWITCH_HELD_FD_MAP:-}" == 30,31,32,33,34,35,36,37,38,39,40,41 ]] || { echo "held entry required" >&2; exit 64; }
IFS= read -r -n 1 held_release <&41 || exit 64
[[ "$held_release" == R ]] || exit 64
[[ -z "${LIDSWITCH_HELD_RELEASE_CANDIDATE:-}" ]] || exit 64
readonly LIDSWITCH_HELD_WRAPPER_LOADED=1
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

usage() { echo "usage: $0 [--filter LidSwitchTests.TestCase/testMethod] [--benchmark-output /private/tmp/<root>/<file> --benchmark-app-bundle /private/tmp/<root>/<app>.app --benchmark-samples 5...100]" >&2; exit 64; }
selector=""
benchmark_output=""; benchmark_app=""; benchmark_samples=""
benchmark_output_set=false; benchmark_app_set=false; benchmark_samples_set=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --filter) [[ $# -ge 2 && -z "$selector" ]] || usage; selector="$2"; shift 2 ;;
    --filter=*) [[ -z "$selector" ]] || usage; selector="${1#--filter=}"; shift ;;
    --benchmark-output) [[ $# -ge 2 && "$benchmark_output_set" == false ]] || usage; benchmark_output="$2"; benchmark_output_set=true; shift 2 ;;
    --benchmark-app-bundle) [[ $# -ge 2 && "$benchmark_app_set" == false ]] || usage; benchmark_app="$2"; benchmark_app_set=true; shift 2 ;;
    --benchmark-samples) [[ $# -ge 2 && "$benchmark_samples_set" == false ]] || usage; benchmark_samples="$2"; benchmark_samples_set=true; shift 2 ;;
    --scratch-path|--scratch-path=*) echo "--scratch-path is owned by the safe wrapper" >&2; exit 64 ;;
    *) usage ;;
  esac
done
[[ -z "$selector" || "$selector" =~ ^LidSwitchTests\.[A-Za-z_][A-Za-z0-9_]*/test[A-Za-z_][A-Za-z0-9_]*$ ]] || usage
if [[ "$benchmark_output_set" == true || "$benchmark_app_set" == true || "$benchmark_samples_set" == true ]]; then
  [[ "$benchmark_output_set" == true && "$benchmark_app_set" == true && "$benchmark_samples_set" == true ]] || { echo "partial benchmark request is forbidden" >&2; exit 64; }
  [[ "$selector" == "LidSwitchTests.BenchmarkHarnessTests/testEnvironmentBenchmarkCommandWritesOnlyWhenExplicitlyRequested" ]] || { echo "benchmark request requires the exact benchmark test" >&2; exit 64; }
  [[ "$benchmark_samples" =~ ^[0-9]+$ && "$benchmark_samples" -ge 5 && "$benchmark_samples" -le 100 ]] || usage
  LIDSWITCH_BENCHMARK_OUTPUT="$benchmark_output"
  LIDSWITCH_BENCHMARK_APP_BUNDLE="$benchmark_app"
  LIDSWITCH_BENCHMARK_WARM_SAMPLES="$benchmark_samples"
  export LIDSWITCH_BENCHMARK_OUTPUT LIDSWITCH_BENCHMARK_APP_BUNDLE LIDSWITCH_BENCHMARK_WARM_SAMPLES
fi

ROOT_DIR="${LIDSWITCH_HELD_REPO_ROOT:-}"
[[ "$ROOT_DIR" == /* ]] || exit 64
source /dev/fd/31
source /dev/fd/32
swift_sandbox_reject_inherited_paths || exit $?
swift_sandbox_reject_inherited_fds || exit $?
if ! swift_sandbox_setup "$ROOT_DIR"; then
  [[ -z "${LIDSWITCH_SWIFT_EXEC_ROOT:-}" ]] || echo "Retained denied Swift test execution root: $LIDSWITCH_SWIFT_EXEC_ROOT" >&2
  [[ -z "${LIDSWITCH_SWIFT_CONTROL_ROOT:-}" ]] || echo "Retained denied Swift test control root: $LIDSWITCH_SWIFT_CONTROL_ROOT" >&2
  exit 64
fi
if ! live_envelope_preflight; then
  echo "Retained denied Swift test execution root: $LIDSWITCH_SWIFT_EXEC_ROOT" >&2
  echo "Retained denied Swift test control root: $LIDSWITCH_SWIFT_CONTROL_ROOT" >&2
  status=74
  trap '' HUP INT TERM
  live_envelope_finalize_terminal_receipt 256 "$status" || status=74
  trap - HUP INT TERM
  exit 74
fi

cd "$LIDSWITCH_SWIFT_SOURCE_ROOT"
status=0
postflight_done=false
postflight_on_exit() {
  local shell_status=$?
  if [[ "$postflight_done" != true ]]; then
    set +e
    # A trap has not authenticated/consumed every capture, so it may retain
    # evidence but must never publish a terminal receipt prematurely.
    postflight_done=true
    echo "Retained Swift test execution root: $LIDSWITCH_SWIFT_EXEC_ROOT" >&2
    echo "Retained Swift test control root: $LIDSWITCH_SWIFT_CONTROL_ROOT" >&2
    echo "Retained host receipt: unavailable-before-capture-validation" >&2
    exit "${status:-$shell_status}"
  fi
}
trap postflight_on_exit EXIT
trap 'status=129; exit 129' HUP
trap 'status=130; exit 130' INT
trap 'status=143; exit 143' TERM
capture_names=(test-build)
xctest_started=false
if swift_sandbox_run test-build build test-build \
  --build-tests \
  --enable-xctest \
  --disable-swift-testing \
  -Xswiftc -F \
  -Xswiftc "$LIDSWITCH_SWIFT_XCODE_PLATFORM_FRAMEWORKS" \
  -Xswiftc -I \
  -Xswiftc "$LIDSWITCH_SWIFT_XCODE_PLATFORM_USR_LIB" \
  -Xswiftc -L \
  -Xswiftc "$LIDSWITCH_SWIFT_XCODE_PLATFORM_USR_LIB" \
  -Xcc -F \
  -Xcc "$LIDSWITCH_SWIFT_XCODE_PLATFORM_FRAMEWORKS" \
  --scratch-path "$LIDSWITCH_SWIFT_SCRATCH_PATH" \
  --cache-path "$LIDSWITCH_SWIFTPM_CACHE_PATH" \
  --config-path "$LIDSWITCH_SWIFTPM_CONFIG_PATH" \
  --security-path "$LIDSWITCH_SWIFTPM_SECURITY_PATH"; then
  command_status="$LIDSWITCH_SWIFT_CHILD_EXIT"
  status="$command_status"
else
  command_status="$(swift_sandbox_authenticated_child_exit_or_untrusted)"
  status=74
fi
if [[ "$status" -eq 0 && "$command_status" -eq 0 ]]; then
  xctest_started=true
  capture_names+=(test-main)
  if swift_sandbox_run_xctest test-main "$selector"; then
    command_status="$LIDSWITCH_SWIFT_CHILD_EXIT"
    status="$command_status"
  else
    command_status="$(swift_sandbox_authenticated_child_exit_or_untrusted)"
    status=74
  fi
fi
output_consumed=false
if swift_sandbox_reassert_before_sensitive_host_action "${capture_names[@]}"; then
  output_consumed=true
  for capture_name in "${capture_names[@]}"; do
    if ! swift_sandbox_emit_captured_output "$capture_name"; then
      output_consumed=false
      break
    fi
  done
fi
if [[ "$output_consumed" == true ]]; then
  LIDSWITCH_SWIFT_CAPTURE_IDENTIFIERS=""
  for capture_name in "${capture_names[@]}"; do
    if ! capture_identifier="$(swift_sandbox_capture_identifier "$capture_name")"; then
      output_consumed=false
      break
    fi
    [[ -z "$LIDSWITCH_SWIFT_CAPTURE_IDENTIFIERS" ]] || LIDSWITCH_SWIFT_CAPTURE_IDENTIFIERS+=","
    LIDSWITCH_SWIFT_CAPTURE_IDENTIFIERS+="$capture_name:$capture_identifier"
  done
fi
if [[ "$output_consumed" == true ]] \
    && swift_sandbox_reassert_before_sensitive_host_action "${capture_names[@]}" \
    && live_envelope_postflight "$command_status"; then
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
if ! swift_sandbox_reassert_before_sensitive_host_action "${capture_names[@]}"; then
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
