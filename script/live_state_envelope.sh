#!/bin/bash
[[ "${LIDSWITCH_HELD_ENTRY:-}" == v1 && "${BASH_SOURCE[0]}" == /dev/fd/32 && "${LIDSWITCH_HELD_COMMON_LOADED:-}" == 1 ]] || return 64
readonly LIDSWITCH_HELD_ENVELOPE_LOADED=1

# Read-only host-state envelope for Swift build/test wrappers. This file is
# sourced before HOME is isolated and is never sourced by the sandboxed test
# process. Every pathname and executable below is literal; caller environment
# cannot redirect the observation surface.

LIDSWITCH_LIVE_STATUS_PATH="/Library/Application Support/LidSwitch/helper-status"
LIDSWITCH_LIVE_ROOT_SUPPORT="/Library/Application Support/LidSwitch"
LIDSWITCH_LIVE_DAEMON_PLIST="/Library/LaunchDaemons/com.johnsilva.lidswitch.helper.plist"
LIDSWITCH_LIVE_HELPER_LABEL="com.johnsilva.lidswitch.helper"
LIDSWITCH_LIVE_MACH_SERVICE="com.johnsilva.lidswitch.helper.control"
LIDSWITCH_LIVE_APP_BINARY="/Applications/LidSwitch.app/Contents/MacOS/LidSwitch"
LIDSWITCH_LIVE_MAX_STATUS_BYTES=4096
LIDSWITCH_LEGACY_STEADY_REASONS="verified verified-after-override-recovery recovered-after-abnormal-exit override-recovered"
LIDSWITCH_CANDIDATE_STEADY_REASONS="verified renewed reconnected override-recovered"
LIDSWITCH_TRANSITIONAL_REASONS="reconnect-pending override-drift-observed"
LIDSWITCH_ACTIVE_RENEWAL_CADENCE_SECONDS=8
LIDSWITCH_ACTIVE_STATUS_FRESH_SECONDS=15
LIDSWITCH_CANDIDATE_INACTIVE_NONE_REASONS="legacy-migration legacy-migration-superseded"
LIDSWITCH_CANDIDATE_TERMINAL_SESSION_REASONS="ac-disconnect activation-failed activation-publication-failed activation-verification-failed confirmed-power-unknown drift expired helper-restart install-recovery legacy-migration legacy-restore peer-process-invalid reconnect-expired reconnect-power-drift renewal-publication-failed replay-or-durability-denial startup-recovery uninstall-recovery unproven-schema2-restore user-end user-restore-recovery"
LIDSWITCH_CANDIDATE_RECOVERY_SESSION_REASONS="ac-disconnect-rollback-unverified activation-failed-rollback-unverified activation-publication-failed-rollback-unverified activation-verification-failed-rollback-unverified authority-unavailable-rollback-unverified confirmed-power-unknown-rollback-unverified drift-rollback-unverified expired-rollback-unverified peer-process-invalid-rollback-unverified reconnect-expired-rollback-unverified reconnect-power-drift-rollback-unverified renewal-publication-failed-rollback-unverified user-end-rollback-unverified"
LIDSWITCH_CANDIDATE_RECOVERY_NONE_REASONS="active-proof-conflict applied-disappeared-during-recovery applied-removal-unsafe applied-removal-unverified applied-state-ambiguous battery-precondition-conflict idle-power-state-unknown idle-sleep-override-active invalid-applied-state invalid-legacy-recovery-journal invalid-private-ledger invalid-recovery-proof legacy-applied-migration-not-published legacy-applied-migration-unverified legacy-evidence-removal-unverified legacy-journal-disappeared legacy-journal-removal-unsafe legacy-journal-removal-unverified legacy-native-idle-unverified legacy-post-proof-native-drift legacy-proof-conflict legacy-proof-journal-mismatch legacy-proof-journal-unverified legacy-proof-missing legacy-proof-not-published legacy-proof-unverified legacy-safe-journal-unverified legacy-sleep-disabled-unknown legacy-sleep-override-ambiguous legacy-sleep-postcondition-unknown legacy-sleep-restore-failed legacy-timer-final-state-unknown legacy-timer-state-unknown legacy-writers-not-quiesced migrated-history-conflict missing-recovery-proof owned-restore-failed power-precondition-conflict power-precondition-unknown pristine-history-conflict recovery-proof-not-published recovery-proof-unverified restore-postcondition-unknown terminal-proof-ledger-mismatch terminal-publication-not-published terminal-publication-unverified unowned-sleep-override-active unproven-applied-state"
LIDSWITCH_LEGACY_INACTIVE_REASONS="activation-failed lease-expired-or-invalid no-valid-lease override-lost power-notification-unavailable recovery-failed signal startup-interrupted-override-recovery startup-state-mismatch terminal-session-recovery"
LIDSWITCH_LEGACY_RECOVERY_NONE_REASONS="invalid-applied-state"
LIDSWITCH_LEGACY_RECOVERY_SESSION_REASONS="activation-failed-applied-state-remove-failed activation-failed-invalid-applied-state activation-failed-restore-pending activation-failed-restore-unverified lease-expired-or-invalid-applied-state-remove-failed lease-expired-or-invalid-invalid-applied-state lease-expired-or-invalid-restore-pending lease-expired-or-invalid-restore-unverified no-valid-lease-applied-state-remove-failed no-valid-lease-invalid-applied-state no-valid-lease-restore-pending no-valid-lease-restore-unverified override-lost-applied-state-remove-failed override-lost-invalid-applied-state override-lost-restore-pending override-lost-restore-unverified power-notification-unavailable-applied-state-remove-failed power-notification-unavailable-invalid-applied-state power-notification-unavailable-restore-pending power-notification-unavailable-restore-unverified recovery-failed-applied-state-remove-failed recovery-failed-invalid-applied-state recovery-failed-restore-pending recovery-failed-restore-unverified signal-applied-state-remove-failed signal-invalid-applied-state signal-restore-pending signal-restore-unverified startup-interrupted-override-recovery-applied-state-remove-failed startup-interrupted-override-recovery-invalid-applied-state startup-interrupted-override-recovery-restore-pending startup-interrupted-override-recovery-restore-unverified startup-state-mismatch-applied-state-remove-failed startup-state-mismatch-invalid-applied-state startup-state-mismatch-restore-unverified terminal-session-recovery-applied-state-remove-failed terminal-session-recovery-invalid-applied-state terminal-session-recovery-restore-pending terminal-session-recovery-restore-unverified"

live_envelope_fail() {
  LIVE_ENVELOPE_ERROR="$1"
  export LIVE_ENVELOPE_ERROR
  echo "LidSwitch live-state envelope denied: $1" >&2
  return 74
}

live_envelope_safe_scalar() {
  [[ "$1" =~ ^[A-Za-z0-9._:/@+,-]*$ ]]
}

live_envelope_control_target() {
  local name="$1" path
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$ ]] || return 74
  swift_sandbox_assert_control_root || return 74
  path="$LIDSWITCH_SWIFT_CONTROL_ROOT/$name"
  [[ ! -e "$path" && ! -L "$path" ]] || return 74
  printf '%s\n' "$path"
}

live_envelope_kernel_truth() {
  LIVE_KERNEL_BOOT="$(/usr/sbin/sysctl -n kern.bootsessionuuid 2>/dev/null | /usr/bin/tr '[:upper:]' '[:lower:]' | /usr/bin/tr -d '{}[:space:]')" || return 74
  LIVE_KERNEL_BUILD="$(/usr/sbin/sysctl -n kern.osversion 2>/dev/null | /usr/bin/tr -d '[:space:]')" || return 74
  LIVE_KERNEL_MONOTONIC="$(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C /usr/bin/python3 -I -S -c '
import ctypes
class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
libsystem = ctypes.CDLL(None)
libsystem.mach_continuous_time.restype = ctypes.c_uint64
info = Timebase()
if libsystem.mach_timebase_info(ctypes.byref(info)) != 0 or info.denom == 0:
    raise SystemExit(74)
seconds = libsystem.mach_continuous_time() * info.numer / info.denom / 1_000_000_000
print(f"{seconds:.6f}")
')" || return 74
  [[ "$LIVE_KERNEL_BOOT" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || return 74
  [[ "$LIVE_KERNEL_BUILD" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || return 74
  [[ "$LIVE_KERNEL_MONOTONIC" =~ ^[0-9]{1,12}\.[0-9]{6}$ ]] || return 74
}

live_envelope_kv_get() {
  local key="$1" file="$2"
  /usr/bin/awk -F= -v wanted="$key" '
    $1 == wanted { count += 1; value = substr($0, index($0, "=") + 1) }
    END { if (count != 1) exit 65; print value }
  ' "$file"
}

live_envelope_kv_optional() {
  local key="$1" file="$2"
  /usr/bin/awk -F= -v wanted="$key" '
    $1 == wanted { count++; value=substr($0,index($0,"=")+1) }
    END { if (count > 1) exit 65; print (count == 1 ? value : "none") }
  ' "$file"
}

live_envelope_sha256() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ { print $1; ok=1 } END { if (!ok) exit 65 }'
}

live_envelope_canonical_uint() {
  [[ "$1" == "0" || "$1" =~ ^[1-9][0-9]*$ ]]
}

live_envelope_canonical_uuid() {
  [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]
}

live_envelope_lstat() {
  # BSD stat uses lstat(2) unless -L is supplied. The type is part of the
  # fingerprint, so a symlink is rejected rather than followed.
  /usr/bin/stat -f '%HT|%u|%g|%Lp|%l|%z|%d|%i|%m|%c' "$1" 2>/dev/null
}

live_envelope_admin_gid() {
  /usr/bin/dscl . -read /Groups/admin PrimaryGroupID 2>/dev/null | /usr/bin/awk '
    $1 == "PrimaryGroupID:" && $2 ~ /^[0-9]+$/ { count++; value=$2 }
    END { if (count != 1) exit 65; print value }
  '
}

live_envelope_regular_metadata() {
  local path="$1" maximum_size="$2" admin_gid="$3"
  local metadata type owner group mode links size remainder
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    printf '%s\n' "absent"
    return 0
  fi
  metadata="$(live_envelope_lstat "$path")" || return 74
  IFS='|' read -r type owner group mode links size remainder <<< "$metadata"
  [[ "$type" == "Regular File" && "$owner" == "0" && "$links" == "1" ]] || return 74
  [[ "$size" =~ ^[0-9]+$ && "$size" -le "$maximum_size" ]] || return 74
  if [[ "$group" == "0" && "$mode" == "600" ]]; then
    printf 'candidate-private|%s\n' "$metadata"
  elif [[ ( "$group" == "0" || "$group" == "$admin_gid" ) && ( "$mode" == "600" || "$mode" == "640" || "$mode" == "644" ) ]]; then
    printf 'legacy-root-evidence|%s\n' "$metadata"
  else
    return 74
  fi
}

live_envelope_root_executable_metadata() {
  local path="$1" maximum_size="$2" admin_gid="$3"
  local metadata type owner group mode links size remainder
  metadata="$(live_envelope_lstat "$path")" || return 74
  IFS='|' read -r type owner group mode links size remainder <<< "$metadata"
  [[ "$type" == "Regular File" && "$owner" == "0" && ( "$group" == "0" || "$group" == "$admin_gid" ) && "$links" == "1" ]] || return 74
  [[ ( "$mode" == "755" || "$mode" == "555" ) && "$size" =~ ^[0-9]+$ && "$size" -gt 0 && "$size" -le "$maximum_size" ]] || return 74
  printf '%s\n' "$metadata"
}

live_envelope_user_metadata() {
  local path="$1" uid="$2"
  local metadata type owner group mode links size remainder
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    printf '%s\n' "absent"
    return 0
  fi
  metadata="$(live_envelope_lstat "$path")" || return 74
  IFS='|' read -r type owner group mode links size remainder <<< "$metadata"
  [[ "$type" == "Regular File" && "$owner" == "$uid" && "$links" == "1" && "$size" =~ ^[0-9]+$ && "$size" -le 262144 ]] || return 74
  [[ "$mode" == "600" || "$mode" == "644" ]] || return 74
  printf '%s\n' "$metadata"
}

live_envelope_installed_app_metadata() {
  local path="$1" uid="$2"
  local metadata type owner group mode links size remainder
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    printf '%s\n' "absent"
    return 0
  fi
  metadata="$(live_envelope_lstat "$path")" || return 74
  IFS='|' read -r type owner group mode links size remainder <<< "$metadata"
  [[ "$type" == "Regular File" && ( "$owner" == "0" || "$owner" == "$uid" ) && "$links" == "1" ]] || return 74
  [[ "$mode" == "755" || "$mode" == "555" ]] || return 74
  [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 && "$size" -le 67108864 ]] || return 74
  printf '%s\n' "$metadata"
}

live_envelope_directory_structure() {
  local path="$1" expected_owner="$2" admin_gid="$3"
  local metadata type owner group mode links size device inode modified changed
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    printf '%s\n' "absent"
    return 0
  fi
  metadata="$(live_envelope_lstat "$path")" || return 74
  IFS='|' read -r type owner group mode links size device inode modified changed <<< "$metadata"
  [[ "$type" == "Directory" && "$owner" == "$expected_owner" && ( "$group" == "0" || "$group" == "$admin_gid" ) && "$mode" =~ ^[0-7]{3,4}$ ]] || return 74
  (( (8#$mode & 0022) == 0 )) || return 74
  printf '%s|%s|%s|%s|%s|%s\n' "$type" "$owner" "$group" "$mode" "$device" "$inode"
}

live_envelope_capture_power() {
  local scratch="$1" phase="$2" drawing live custom
  drawing="$(live_envelope_control_target "${phase}.pmset-batt")" || return 74
  /usr/bin/pmset -g batt > "$drawing" 2>/dev/null || return 74
  live="$(live_envelope_control_target "${phase}.pmset-live")" || return 74
  /usr/bin/pmset -g live > "$live" 2>/dev/null || return 74
  custom="$(live_envelope_control_target "${phase}.pmset-custom")" || return 74
  /usr/bin/pmset -g custom > "$custom" 2>/dev/null || return 74
  LIVE_POWER_SOURCE="$(/usr/bin/awk '
    /Now drawing from/ {
      count += 1
      if ($0 ~ /\047AC Power\047/) value="ac"
      else if ($0 ~ /\047Battery Power\047/) value="battery"
      else value="unknown"
    }
    END { if (count != 1 || value == "unknown" || value == "") exit 65; print value }
  ' "$drawing")" || return 74
  LIVE_SLEEP_DISABLED="$(/usr/bin/awk '
    $1 == "SleepDisabled" { count += 1; value=$2 }
    END { if (count != 1 || (value != "0" && value != "1")) exit 65; print value }
  ' "$live")" || return 74
  LIVE_AC_SLEEP="$(/usr/bin/awk '
    /^AC Power:/ { ac=1; next }
    /^[^[:space:]]/ && $0 !~ /^AC Power:/ { ac=0 }
    ac && $1 == "sleep" { count += 1; value=$2 }
    END { if (count != 1 || value !~ /^[0-9]+$/) exit 65; print value }
  ' "$custom")" || return 74
}

live_envelope_reason_in_list() {
  local wanted="$1" list="$2" item
  for item in $list; do [[ "$item" == "$wanted" ]] && return 0; done
  return 1
}

live_envelope_status_is_current() {
  local maximum="$1" wall_now wall_age
  live_envelope_canonical_uint "$maximum" || return 74
  wall_now="$(/bin/date +%s)" || return 74
  wall_age=$((wall_now - LIVE_STATUS_UPDATED))
  [[ "$wall_age" -ge -2 && "$wall_age" -le "$maximum" ]] || return 74
  if [[ "$LIVE_STATUS_SCHEMA" == "canonical-v2" ]]; then
    [[ "$LIVE_STATUS_BOOT_ID" == "$LIVE_KERNEL_BOOT" ]] || return 74
    /usr/bin/awk -v now="$LIVE_KERNEL_MONOTONIC" -v then="$LIVE_STATUS_MONOTONIC" -v bound="$maximum" '
      BEGIN { age=now-then; if (age < -2 || age > bound) exit 74 }
    ' || return 74
  fi
}

live_envelope_legacy_idle_status_is_not_future() {
  local wall_now wall_age
  [[ "$LIVE_STATUS_SCHEMA" == "legacy-v1" ]] || return 74
  wall_now="$(/bin/date +%s)" || return 74
  wall_age=$((wall_now - LIVE_STATUS_UPDATED))
  [[ "$wall_age" -ge -2 ]] || return 74
}

live_envelope_override_evidence_is_exact() {
  local now age
  [[ "$LIVE_STATUS_EVENT" == "override-drift" && "$LIVE_STATUS_OBSERVED_POWER" == "ac" ]] || return 74
  [[ "$LIVE_STATUS_OBSERVED_SESSION" == "$LIVE_STATUS_SESSION" && "$LIVE_STATUS_SESSION" != "none" ]] || return 74
  [[ "$LIVE_STATUS_OBSERVED_SLEEP_DISABLED" == 0 || "$LIVE_STATUS_OBSERVED_SLEEP_DISABLED" == 1 || "$LIVE_STATUS_OBSERVED_SLEEP_DISABLED" == unreadable ]] || return 74
  [[ "$LIVE_STATUS_OBSERVED_AC_SLEEP" == unreadable ]] || live_envelope_canonical_uint "$LIVE_STATUS_OBSERVED_AC_SLEEP" || return 74
  live_envelope_canonical_uint "$LIVE_STATUS_OBSERVED_AT" || return 74
  now="$(/bin/date +%s)" || return 74
  age=$((now - LIVE_STATUS_OBSERVED_AT))
  [[ "$age" -ge -2 && "$age" -le 60 ]] || return 74
}

live_envelope_status_matrix() {
  local candidate=false session_kind=invalid
  LIVE_STATUS_LEGACY_STALE_IDLE=false
  [[ "$LIVE_PLIST_CONTRACT" != "candidate-mach-service" ]] || candidate=true
  if [[ "$LIVE_STATUS_SESSION" == "none" ]]; then session_kind=none; else session_kind=uuid; fi
  case "$candidate:$LIVE_STATUS_STATE:$session_kind" in
    true:active:uuid)
      case "$LIVE_STATUS_REASON" in
        verified|renewed|reconnected)
          [[ "$LIVE_STATUS_SCHEMA" == "canonical-v2" && "$LIVE_STATUS_EVIDENCE_SIGNATURE" == "boot_id,updated_monotonic" ]] || return 74 ;;
        override-recovered)
          [[ "$LIVE_STATUS_SCHEMA" == "canonical-v2" && "$LIVE_STATUS_EVIDENCE_SIGNATURE" == "boot_id,recovery_budget,updated_monotonic" && "$LIVE_STATUS_RECOVERY_BUDGET" == "spent" ]] || return 74 ;;
        *) return 74 ;;
      esac
      live_envelope_status_is_current 15 || return 74
      LIVE_STATUS_REASON_CLASS="active-steady"
      ;;
    false:active:uuid)
      live_envelope_reason_in_list "$LIVE_STATUS_REASON" "$LIDSWITCH_LEGACY_STEADY_REASONS" || return 74
      if [[ "$LIVE_STATUS_SCHEMA" == "canonical-v2" ]]; then
        case "$LIVE_STATUS_REASON:$LIVE_STATUS_EVIDENCE_SIGNATURE:$LIVE_STATUS_RECOVERY_BUDGET" in
          verified:boot_id,updated_monotonic:none|verified-after-override-recovery:boot_id,recovery_budget,updated_monotonic:spent|recovered-after-abnormal-exit:boot_id,updated_monotonic:none|recovered-after-abnormal-exit:boot_id,recovery_budget,updated_monotonic:spent|override-recovered:boot_id,recovery_budget,updated_monotonic:spent) ;;
          *) return 74 ;;
        esac
      else
        [[ "$LIVE_STATUS_SCHEMA" == "legacy-v1" && "$LIVE_STATUS_EVIDENCE_SIGNATURE" == "none" ]] || return 74
      fi
      live_envelope_status_is_current 15 || return 74
      LIVE_STATUS_REASON_CLASS="active-steady"
      ;;
    true:inactive:none)
      live_envelope_reason_in_list "$LIVE_STATUS_REASON" "$LIDSWITCH_CANDIDATE_INACTIVE_NONE_REASONS" || return 74
      [[ "$LIVE_STATUS_SCHEMA" == "canonical-v2" && "$LIVE_STATUS_EVIDENCE_SIGNATURE" == "boot_id,updated_monotonic" ]] || return 74
      live_envelope_status_is_current 60 || return 74
      LIVE_STATUS_REASON_CLASS="safe-idle"
      ;;
    true:terminal:uuid)
      live_envelope_reason_in_list "$LIVE_STATUS_REASON" "$LIDSWITCH_CANDIDATE_TERMINAL_SESSION_REASONS" || return 74
      if [[ "$LIVE_STATUS_REASON" == "legacy-migration" ]]; then
        [[ "$LIVE_STATUS_SCHEMA" == "canonical-v2" && "$LIVE_STATUS_EVIDENCE_SIGNATURE" == "boot_id,projection_authority,projection_generation,projection_token,updated_monotonic" ]] || return 74
      else
        [[ "$LIVE_STATUS_SCHEMA" == "canonical-v2" && "$LIVE_STATUS_EVIDENCE_SIGNATURE" == "boot_id,updated_monotonic" ]] || return 74
      fi
      live_envelope_status_is_current 60 || return 74
      LIVE_STATUS_REASON_CLASS="safe-idle"
      ;;
    true:recovery-required:none)
      live_envelope_reason_in_list "$LIVE_STATUS_REASON" "$LIDSWITCH_CANDIDATE_RECOVERY_NONE_REASONS" || return 74
      [[ "$LIVE_STATUS_SCHEMA" == "canonical-v2" && "$LIVE_STATUS_EVIDENCE_SIGNATURE" == "boot_id,updated_monotonic" ]] || return 74
      live_envelope_status_is_current 30 || return 74
      LIVE_STATUS_REASON_CLASS="recovery-required"
      ;;
    true:recovery-required:uuid)
      live_envelope_reason_in_list "$LIVE_STATUS_REASON" "$LIDSWITCH_CANDIDATE_RECOVERY_SESSION_REASONS" || return 74
      [[ "$LIVE_STATUS_SCHEMA" == "canonical-v2" && "$LIVE_STATUS_EVIDENCE_SIGNATURE" == "boot_id,updated_monotonic" ]] || return 74
      live_envelope_status_is_current 30 || return 74
      LIVE_STATUS_REASON_CLASS="recovery-required"
      ;;
    false:inactive:none|false:inactive:uuid)
      live_envelope_reason_in_list "$LIVE_STATUS_REASON" "$LIDSWITCH_LEGACY_INACTIVE_REASONS" || return 74
      if [[ "$LIVE_STATUS_SCHEMA" == "legacy-v1" ]]; then
        [[ "$LIVE_STATUS_EVIDENCE_SIGNATURE" == "none" ]] || return 74
        if live_envelope_status_is_current 60; then :
        else
          live_envelope_legacy_idle_status_is_not_future || return 74
          LIVE_STATUS_LEGACY_STALE_IDLE=true
        fi
      elif [[ "$LIVE_STATUS_EVIDENCE_SIGNATURE" == "boot_id,updated_monotonic" ]]; then :
      elif [[ "$LIVE_STATUS_REASON" == "override-lost" && "$LIVE_STATUS_EVIDENCE_SIGNATURE" == "boot_id,event,observed_ac_sleep,observed_at,observed_power,observed_session,observed_sleep_disabled,updated_monotonic" ]]; then
        live_envelope_override_evidence_is_exact || return 74
      else return 74
      fi
      [[ "$LIVE_STATUS_SCHEMA" == "legacy-v1" ]] || live_envelope_status_is_current 60 || return 74
      LIVE_STATUS_REASON_CLASS="safe-idle"
      ;;
    false:recovery-required:none)
      live_envelope_reason_in_list "$LIVE_STATUS_REASON" "$LIDSWITCH_LEGACY_RECOVERY_NONE_REASONS" || return 74
      [[ "$LIVE_STATUS_SCHEMA" == "canonical-v2" && "$LIVE_STATUS_EVIDENCE_SIGNATURE" == "boot_id,updated_monotonic" ]] || return 74
      live_envelope_status_is_current 30 || return 74
      LIVE_STATUS_REASON_CLASS="recovery-required"
      ;;
    false:recovery-required:uuid)
      live_envelope_reason_in_list "$LIVE_STATUS_REASON" "$LIDSWITCH_LEGACY_RECOVERY_SESSION_REASONS" || return 74
      [[ "$LIVE_STATUS_SCHEMA" == "canonical-v2" ]] || return 74
      if [[ "$LIVE_STATUS_EVIDENCE_SIGNATURE" == "boot_id,updated_monotonic" ]]; then :
      elif [[ "$LIVE_STATUS_REASON" == override-lost-* && "$LIVE_STATUS_EVIDENCE_SIGNATURE" == "boot_id,event,observed_ac_sleep,observed_at,observed_power,observed_session,observed_sleep_disabled,updated_monotonic" ]]; then
        live_envelope_override_evidence_is_exact || return 74
      else return 74
      fi
      live_envelope_status_is_current 30 || return 74
      LIVE_STATUS_REASON_CLASS="recovery-required"
      ;;
    *) return 74 ;;
  esac
}

live_envelope_capture_status() {
  local scratch="$1" phase="$2" copy
  local before after type owner group mode links size remainder count signature recovery_budget
  local projection_authority projection_generation projection_token
  LIVE_STATUS_LEGACY_STALE_IDLE=false
  if [[ ! -e "$LIDSWITCH_LIVE_STATUS_PATH" && ! -L "$LIDSWITCH_LIVE_STATUS_PATH" ]]; then
    LIVE_STATUS_PRESENCE="absent"
    LIVE_STATUS_META="absent"
    LIVE_STATUS_STATE="none"
    LIVE_STATUS_REASON="none"
    LIVE_STATUS_REASON_CLASS="none"
    LIVE_STATUS_SESSION="none"
    LIVE_STATUS_UPDATED="none"
    LIVE_STATUS_MONOTONIC="none"
    LIVE_STATUS_BOOT_ID="none"
    LIVE_STATUS_SCHEMA="absent"
    LIVE_STATUS_EVIDENCE_SIGNATURE="none"
    return 0
  fi
  before="$(live_envelope_lstat "$LIDSWITCH_LIVE_STATUS_PATH")" || return 74
  IFS='|' read -r type owner group mode links size remainder <<< "$before"
  [[ "$type" == "Regular File" && "$owner" == "0" && "$group" == "0" && "$mode" == "644" && "$links" == "1" ]] || return 74
  [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 && "$size" -le "$LIDSWITCH_LIVE_MAX_STATUS_BYTES" ]] || return 74
  copy="$(live_envelope_control_target "${phase}.helper-status")" || return 74
  /bin/cat -- "$LIDSWITCH_LIVE_STATUS_PATH" > "$copy" || return 74
  after="$(live_envelope_lstat "$LIDSWITCH_LIVE_STATUS_PATH")" || return 74
  [[ "$after" == "$before" ]] || return 74
  [[ "$(/usr/bin/wc -c < "$copy" | /usr/bin/tr -d '[:space:]')" == "$size" ]] || return 74
  signature="$(/usr/bin/awk -F= '
    BEGIN { canonical[1]="state"; canonical[2]="reason"; canonical[3]="session"; canonical[4]="updated" }
    $0 !~ /^[a-z_][a-z0-9_]{0,47}=[ -~]{0,96}$/ { exit 65 }
    {
      key=$1
      if (seen[key]++) exit 65
      if (NR <= 4 && key != canonical[NR]) exit 65
      if (NR > 4) {
        if (key <= prior) exit 65
        if (key != "boot_id" && key != "event" && key != "observed_ac_sleep" &&
            key != "observed_at" && key != "observed_power" && key != "observed_session" &&
            key != "observed_sleep_disabled" && key != "recovered_at" &&
            key != "projection_authority" && key != "projection_generation" &&
            key != "projection_token" && key != "recovery_budget" &&
            key != "updated_monotonic") exit 65
        signature = signature (signature == "" ? "" : ",") key
        prior=key
      }
    }
    END { if (NR < 4 || NR > 12) exit 65; print (signature == "" ? "none" : signature) }
  ' "$copy")" || return 74
  count="$(/usr/bin/awk 'END { print NR }' "$copy")" || return 74
  LIVE_STATUS_STATE="$(live_envelope_kv_get state "$copy")" || return 74
  LIVE_STATUS_REASON="$(live_envelope_kv_get reason "$copy")" || return 74
  LIVE_STATUS_SESSION="$(live_envelope_kv_get session "$copy")" || return 74
  LIVE_STATUS_UPDATED="$(live_envelope_kv_get updated "$copy")" || return 74
  LIVE_STATUS_MONOTONIC="$(/usr/bin/awk -F= '$1 == "updated_monotonic" { count++; value=substr($0,index($0,"=")+1) } END { if (count > 1) exit 65; print (count == 1 ? value : "none") }' "$copy")" || return 74
  LIVE_STATUS_BOOT_ID="$(/usr/bin/awk -F= '$1 == "boot_id" { count++; value=substr($0,index($0,"=")+1) } END { if (count > 1) exit 65; print (count == 1 ? value : "none") }' "$copy")" || return 74
  recovery_budget="$(/usr/bin/awk -F= '$1 == "recovery_budget" { count++; value=substr($0,index($0,"=")+1) } END { if (count > 1) exit 65; print (count == 1 ? value : "none") }' "$copy")" || return 74
  projection_authority="$(live_envelope_kv_optional projection_authority "$copy")" || return 74
  projection_generation="$(live_envelope_kv_optional projection_generation "$copy")" || return 74
  projection_token="$(live_envelope_kv_optional projection_token "$copy")" || return 74
  LIVE_STATUS_RECOVERY_BUDGET="$recovery_budget"
  LIVE_STATUS_EVENT="$(live_envelope_kv_optional event "$copy")" || return 74
  LIVE_STATUS_OBSERVED_AC_SLEEP="$(live_envelope_kv_optional observed_ac_sleep "$copy")" || return 74
  LIVE_STATUS_OBSERVED_AT="$(live_envelope_kv_optional observed_at "$copy")" || return 74
  LIVE_STATUS_OBSERVED_POWER="$(live_envelope_kv_optional observed_power "$copy")" || return 74
  LIVE_STATUS_OBSERVED_SESSION="$(live_envelope_kv_optional observed_session "$copy")" || return 74
  LIVE_STATUS_OBSERVED_SLEEP_DISABLED="$(live_envelope_kv_optional observed_sleep_disabled "$copy")" || return 74
  [[ "$LIVE_STATUS_STATE" =~ ^[a-z0-9-]{1,32}$ && "$LIVE_STATUS_REASON" =~ ^[a-z0-9-]{1,96}$ ]] || return 74
  [[ "$LIVE_STATUS_SESSION" == "none" ]] || live_envelope_canonical_uuid "$LIVE_STATUS_SESSION" || return 74
  live_envelope_canonical_uint "$LIVE_STATUS_UPDATED" || return 74
  if [[ "$LIVE_STATUS_MONOTONIC" != "none" ]]; then
    [[ "$LIVE_STATUS_MONOTONIC" =~ ^(0|[1-9][0-9]*)\.[0-9]{3}$ ]] || return 74
  fi
  if [[ "$LIVE_STATUS_BOOT_ID" != "none" ]]; then
    live_envelope_canonical_uuid "$LIVE_STATUS_BOOT_ID" || return 74
  fi
  if [[ "$projection_authority" != "none" || "$projection_generation" != "none" || "$projection_token" != "none" ]]; then
    [[ "$projection_authority" =~ ^[0-9a-f]{16}$ ]] || return 74
    live_envelope_canonical_uint "$projection_generation" || return 74
    [[ "$projection_generation" -gt 0 ]] || return 74
    live_envelope_canonical_uuid "$projection_token" || return 74
  fi
  LIVE_STATUS_EVIDENCE_SIGNATURE="$signature"
  if [[ "$count" == "4" ]]; then
    [[ "$LIVE_PLIST_CONTRACT" == "legacy-watchpaths" && "$signature" == "none" ]] || return 74
    LIVE_STATUS_SCHEMA="legacy-v1"
  else
    [[ "$signature" == *boot_id* && "$signature" == *updated_monotonic* ]] || return 74
    [[ "$LIVE_STATUS_BOOT_ID" != "none" && "$LIVE_STATUS_MONOTONIC" != "none" ]] || return 74
    LIVE_STATUS_SCHEMA="canonical-v2"
  fi

  live_envelope_status_matrix || return 74
  LIVE_STATUS_PRESENCE="present"
  LIVE_STATUS_META="$before"
}

live_envelope_capture_installation() {
  local scratch="$1" phase="$2" admin_gid="$3" plist_copy launchd_out
  local plist_before plist_after type owner group mode links size remainder label launchctl_status index actual
  if [[ ! -e "$LIDSWITCH_LIVE_DAEMON_PLIST" && ! -L "$LIDSWITCH_LIVE_DAEMON_PLIST" ]]; then
    LIVE_PLIST_META="absent"
    LIVE_PLIST_SHA256="absent"
    LIVE_PLIST_CONTRACT="absent"
    LIVE_PLIST_QUALIFIED_BUILD="absent"
    LIVE_HELPER_PATH="absent"
    LIVE_HELPER_META="absent"
  else
    plist_copy="$(live_envelope_control_target "${phase}.launchd.plist")" || return 74
    plist_before="$(live_envelope_lstat "$LIDSWITCH_LIVE_DAEMON_PLIST")" || return 74
    IFS='|' read -r type owner group mode links size remainder <<< "$plist_before"
    [[ "$type" == "Regular File" && "$owner" == "0" && "$group" == "0" && "$mode" == "644" && "$links" == "1" ]] || return 74
    [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 && "$size" -le 65536 ]] || return 74
    /bin/cat -- "$LIDSWITCH_LIVE_DAEMON_PLIST" > "$plist_copy" || return 74
    plist_after="$(live_envelope_lstat "$LIDSWITCH_LIVE_DAEMON_PLIST")" || return 74
    [[ "$plist_after" == "$plist_before" && "$(/usr/bin/wc -c < "$plist_copy" | /usr/bin/tr -d '[:space:]')" == "$size" ]] || return 74
    /usr/bin/plutil -lint "$plist_copy" >/dev/null 2>&1 || return 74
    label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist_copy" 2>/dev/null)" || return 74
    [[ "$label" == "$LIDSWITCH_LIVE_HELPER_LABEL" ]] || return 74
    LIVE_HELPER_PATH="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$plist_copy" 2>/dev/null)" || return 74
    case "$LIVE_HELPER_PATH" in
      "/Library/Application Support/LidSwitch/Current/LidSwitchHelper"|"/Library/Application Support/LidSwitch/LidSwitchHelper"|"/Library/Application Support/LidSwitch/lidswitch-helper") ;;
      *) return 74 ;;
    esac
    if /usr/libexec/PlistBuddy -c 'Print :WatchPaths' "$plist_copy" >/dev/null 2>&1; then
      LIVE_PLIST_CONTRACT="legacy-watchpaths"
      LIVE_PLIST_QUALIFIED_BUILD="legacy"
    else
      [[ "$(/usr/libexec/PlistBuddy -c "Print :MachServices:$LIDSWITCH_LIVE_MACH_SERVICE" "$plist_copy" 2>/dev/null)" == "true" ]] || return 74
      LIVE_PLIST_CONTRACT="candidate-mach-service"
      local expected_arguments=(
        "$LIVE_HELPER_PATH"
        "--owner-uid" "$(/usr/bin/id -u)"
        "--qualified-build" "$LIVE_KERNEL_BUILD"
        "--support-directory" "$LIDSWITCH_LIVE_ROOT_SUPPORT"
        "--applied-state" "$LIDSWITCH_LIVE_ROOT_SUPPORT/applied-state"
        "--status-path" "$LIDSWITCH_LIVE_STATUS_PATH"
        "--policy-path" "$LIDSWITCH_LIVE_ROOT_SUPPORT/Current/enrollment-policy"
      )
      for index in "${!expected_arguments[@]}"; do
        actual="$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:$index" "$plist_copy" 2>/dev/null)" || return 74
        [[ "$actual" == "${expected_arguments[$index]}" ]] || return 74
      done
      ! /usr/libexec/PlistBuddy -c "Print :ProgramArguments:${#expected_arguments[@]}" "$plist_copy" >/dev/null 2>&1 || return 74
      LIVE_PLIST_QUALIFIED_BUILD="$LIVE_KERNEL_BUILD"
    fi
    LIVE_PLIST_META="$plist_before"
    LIVE_PLIST_SHA256="$(live_envelope_sha256 "$plist_copy")" || return 74
    LIVE_HELPER_META="$(live_envelope_root_executable_metadata "$LIVE_HELPER_PATH" 16777216 "$admin_gid")" || return 74
    [[ "$LIVE_HELPER_META" != "absent" ]] || return 74
  fi

  launchd_out="$(live_envelope_control_target "${phase}.launchctl-print")" || return 74
  if /bin/launchctl print "system/$LIDSWITCH_LIVE_HELPER_LABEL" > "$launchd_out" 2>&1; then
    LIVE_LAUNCHD_PRESENCE="present"
    # launchctl includes nested objects with their own state fields. Select the
    # unique shallowest matching field; equal-depth duplicates are malformed.
    LIVE_LAUNCHD_STATE="$(/usr/bin/awk '
      { match($0, /^[ \t]*/); depth=RLENGTH; body=substr($0,depth+1) }
      body == "state = running" || body == "state = not running" { if (!found || depth < best) { best=depth; count=1; value=substr(body,9); found=1 } else if (depth == best) count++ }
      END { if (!found || count != 1) exit 65; print value }
    ' "$launchd_out")" || return 74
    LIVE_LAUNCHD_PID="$(/usr/bin/awk '
      { match($0, /^[ \t]*/); depth=RLENGTH; body=substr($0,depth+1) }
      body ~ /^pid = [0-9]+$/ { if (!found || depth < best) { best=depth; count=1; value=substr(body,7); found=1 } else if (depth == best) count++ }
      END { if (count > 1) exit 65; print (found ? value : "none") }
    ' "$launchd_out")" || return 74
    LIVE_LAUNCHD_PROGRAM="$(/usr/bin/awk '
      { match($0, /^[ \t]*/); depth=RLENGTH; body=substr($0,depth+1) }
      body ~ /^program = \/.*$/ { if (!found || depth < best) { best=depth; count=1; value=substr(body,11); found=1 } else if (depth == best) count++ }
      END { if (count > 1) exit 65; print (found ? value : "none") }
    ' "$launchd_out")" || return 74
    [[ "$LIVE_PLIST_META" != "absent" && "$LIVE_LAUNCHD_PROGRAM" == "$LIVE_HELPER_PATH" ]] || return 74
  else
    launchctl_status=$?
    [[ "$launchctl_status" == "3" || "$launchctl_status" == "64" || "$launchctl_status" == "113" ]] || return 74
    /usr/bin/awk -v label="$LIDSWITCH_LIVE_HELPER_LABEL" '
      NR == 1 && $0 == "Bad request." { bad=1; next }
      $0 == "Could not find service \"" label "\" in domain for system" { missing++; next }
      { exit 65 }
      END { if (missing != 1 || NR < 1 || NR > 2) exit 65 }
    ' "$launchd_out" || return 74
    LIVE_LAUNCHD_PRESENCE="absent"
    LIVE_LAUNCHD_STATE="none"
    LIVE_LAUNCHD_PID="none"
    LIVE_LAUNCHD_PROGRAM="none"
  fi
  LIVE_APP_META="$(live_envelope_installed_app_metadata "$LIDSWITCH_LIVE_APP_BINARY" "$(/usr/bin/id -u)")" || return 74
}

live_envelope_capture_legacy_lease() {
  local scratch="$1" phase="$2" real_home="$3" expected_session="$4"
  local expectation="${5:-active}" path="$real_home/Library/Application Support/LidSwitch/activation-lease" copy
  local before after type owner group mode links size remainder uid now lifetime
  uid="$(/usr/bin/id -u)" || return 74
  [[ -e "$path" && ! -L "$path" ]] || return 74
  before="$(live_envelope_lstat "$path")" || return 74
  IFS='|' read -r type owner group mode links size remainder <<< "$before"
  [[ "$type" == "Regular File" && "$owner" == "$uid" && "$mode" == "600" && "$links" == "1" ]] || return 74
  [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 && "$size" -le 4096 ]] || return 74
  copy="$(live_envelope_control_target "${phase}.activation-lease")" || return 74
  /bin/cat -- "$path" > "$copy" || return 74
  after="$(live_envelope_lstat "$path")" || return 74
  [[ "$after" == "$before" && "$(/usr/bin/wc -c < "$copy" | /usr/bin/tr -d '[:space:]')" == "$size" ]] || return 74
  /usr/bin/awk -F= '
    length($0) == 0 { next }
    $0 !~ /^[a-z_]+=[A-Za-z0-9._:-]+$/ { exit 65 }
    { if (seen[$1]++) exit 65; count++ }
    END {
      split("schema mode session boot expires issued_mono expires_mono uid build", required, " ")
      if (count != 9) exit 65
      for (i=1; i<=9; i++) if (!seen[required[i]]) exit 65
    }
  ' "$copy" || return 74
  LIVE_LEASE_SESSION="$(live_envelope_kv_get session "$copy" | /usr/bin/tr '[:upper:]' '[:lower:]')" || return 74
  LIVE_LEASE_BOOT="$(live_envelope_kv_get boot "$copy" | /usr/bin/tr '[:upper:]' '[:lower:]')" || return 74
  LIVE_LEASE_EXPIRES="$(live_envelope_kv_get expires "$copy")" || return 74
  LIVE_LEASE_ISSUED_MONO="$(live_envelope_kv_get issued_mono "$copy")" || return 74
  LIVE_LEASE_EXPIRES_MONO="$(live_envelope_kv_get expires_mono "$copy")" || return 74
  LIVE_LEASE_UID="$(live_envelope_kv_get uid "$copy")" || return 74
  LIVE_LEASE_BUILD="$(live_envelope_kv_get build "$copy")" || return 74
  [[ "$(live_envelope_kv_get schema "$copy")" == "1" && "$(live_envelope_kv_get mode "$copy")" == "active" ]] || return 74
  [[ "$LIVE_LEASE_SESSION" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || return 74
  [[ "$LIVE_LEASE_BOOT" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ && "$LIVE_LEASE_UID" == "$uid" ]] || return 74
  [[ "$LIVE_LEASE_EXPIRES" =~ ^[0-9]{9,12}$ && "$LIVE_LEASE_ISSUED_MONO" =~ ^[0-9]{1,12}(\.[0-9]+)?$ && "$LIVE_LEASE_EXPIRES_MONO" =~ ^[0-9]{1,12}(\.[0-9]+)?$ ]] || return 74
  [[ -n "$LIVE_LEASE_BUILD" ]] && live_envelope_safe_scalar "$LIVE_LEASE_BUILD" || return 74
  lifetime="$(/usr/bin/awk -v issued="$LIVE_LEASE_ISSUED_MONO" -v expires="$LIVE_LEASE_EXPIRES_MONO" 'BEGIN { delta=expires-issued; if (delta <= 0 || delta > 30.001) exit 65; printf "%.6f", delta }')" || return 74
  now="$(/bin/date +%s)" || return 74
  case "$expectation" in
    active)
      [[ "$LIVE_LEASE_SESSION" == "$expected_session" ]] || return 74
      [[ "$LIVE_LEASE_BOOT" == "$LIVE_KERNEL_BOOT" && "$LIVE_LEASE_BUILD" == "$LIVE_KERNEL_BUILD" ]] || return 74
      [[ "$LIVE_LEASE_EXPIRES" -gt "$now" && "$LIVE_LEASE_EXPIRES" -le $((now + 35)) ]] || return 74
      /usr/bin/awk -v issued="$LIVE_LEASE_ISSUED_MONO" -v expires="$LIVE_LEASE_EXPIRES_MONO" \
        -v current="$LIVE_KERNEL_MONOTONIC" -v epochRemaining="$((LIVE_LEASE_EXPIRES - now))" '
          BEGIN {
            monoRemaining=expires-current; delta=monoRemaining-epochRemaining; if (delta < 0) delta=-delta
            if (!(issued <= current && current < expires && monoRemaining > 0 && monoRemaining <= 35.001 && delta <= 5.001)) exit 65
          }
        ' || return 74
      ;;
    expired)
      [[ "$expected_session" == "none" && "$LIVE_LEASE_EXPIRES" -le "$now" ]] || return 74
      if [[ "$LIVE_LEASE_BOOT" == "$LIVE_KERNEL_BOOT" ]]; then
        /usr/bin/awk -v expires="$LIVE_LEASE_EXPIRES_MONO" -v current="$LIVE_KERNEL_MONOTONIC" \
          'BEGIN { if (!(expires <= current)) exit 65 }' || return 74
      fi
      ;;
    *) return 74 ;;
  esac
  LIVE_LEASE_META="$before"
  LIVE_LEASE_LIFETIME="$lifetime"
}

live_envelope_capture_idle_lease() {
  local path="$1/Library/Application Support/LidSwitch/activation-lease"
  [[ ! -e "$path" && ! -L "$path" ]] || return 74
  LIVE_LEASE_SESSION="none"
  LIVE_LEASE_BOOT="none"
  LIVE_LEASE_EXPIRES="none"
  LIVE_LEASE_ISSUED_MONO="none"
  LIVE_LEASE_EXPIRES_MONO="none"
  LIVE_LEASE_UID="none"
  LIVE_LEASE_BUILD="none"
  LIVE_LEASE_META="absent"
  LIVE_LEASE_LIFETIME="none"
}

live_envelope_capture() {
  local phase="$1" output="$2" scratch="$3" nonce="$4" real_home="$5"
  local uid admin_gid root_struct applied terminal reservations proof lock original_ac original_battery history epoch host_class
  uid="$(/usr/bin/id -u)" || return 74
  admin_gid="$(live_envelope_admin_gid)" || return 74
  live_envelope_kernel_truth || return 74
  live_envelope_capture_power "$scratch" "$phase" || return 74
  live_envelope_capture_installation "$scratch" "$phase" "$admin_gid" || return 74
  local status_captured=false attempt
  for attempt in 1 2 3; do
    if live_envelope_capture_status "$scratch" "${phase}.status${attempt}"; then status_captured=true; break; fi
  done
  [[ "$status_captured" == true ]] || return 74
  root_struct="$(live_envelope_directory_structure "$LIDSWITCH_LIVE_ROOT_SUPPORT" 0 "$admin_gid")" || return 74
  applied="$(live_envelope_regular_metadata "$LIDSWITCH_LIVE_ROOT_SUPPORT/applied-state" 4096 "$admin_gid")" || return 74
  terminal="$(live_envelope_regular_metadata "$LIDSWITCH_LIVE_ROOT_SUPPORT/terminal-generations" 131072 "$admin_gid")" || return 74
  reservations="$(live_envelope_regular_metadata "$LIDSWITCH_LIVE_ROOT_SUPPORT/recovery-reservations" 131072 "$admin_gid")" || return 74
  proof="$(live_envelope_regular_metadata "$LIDSWITCH_LIVE_ROOT_SUPPORT/recovery-proof" 4096 "$admin_gid")" || return 74
  lock="$(live_envelope_regular_metadata "$LIDSWITCH_LIVE_ROOT_SUPPORT/root-state.lock" 4096 "$admin_gid")" || return 74
  original_ac="$(live_envelope_regular_metadata "$LIDSWITCH_LIVE_ROOT_SUPPORT/original-ac-sleep" 128 "$admin_gid")" || return 74
  original_battery="$(live_envelope_regular_metadata "$LIDSWITCH_LIVE_ROOT_SUPPORT/original-battery-sleep" 128 "$admin_gid")" || return 74
  history="$(live_envelope_user_metadata "$real_home/Library/Application Support/LidSwitch/session-history.json" "$uid")" || return 74
  epoch="$(/bin/date +%s)" || return 74
  live_envelope_kernel_truth || return 74

  if [[ "$LIVE_STATUS_BOOT_ID" != "none" ]]; then
    [[ "$LIVE_STATUS_BOOT_ID" == "$LIVE_KERNEL_BOOT" ]] || return 74
    /usr/bin/awk -v status="$LIVE_STATUS_MONOTONIC" -v current="$LIVE_KERNEL_MONOTONIC" \
      'BEGIN { if (!(status ~ /^[0-9]+([.][0-9]+)?$/ && status <= current + 1.0)) exit 65 }' || return 74
  fi

  if [[ "$LIVE_STATUS_PRESENCE" == "present" && "$LIVE_STATUS_STATE" == "active" ]]; then
    [[ "$LIVE_POWER_SOURCE" == "ac" && "$LIVE_SLEEP_DISABLED" == "1" && "$LIVE_AC_SLEEP" == "0" ]] || return 74
    [[ "$LIVE_STATUS_SESSION" != "none" && "$LIVE_STATUS_REASON_CLASS" == "active-steady" ]] || return 74
    [[ "$LIVE_LAUNCHD_PRESENCE" == "present" && "$LIVE_LAUNCHD_STATE" == "running" && "$LIVE_LAUNCHD_PID" =~ ^[0-9]+$ ]] || return 74
    if [[ "$LIVE_PLIST_CONTRACT" == "candidate-mach-service" ]]; then
      # Candidate authority is the helper's connection-bound private lease. A
      # user activation-lease is legacy residue and must be absent; bounded
      # status advancement across the preflight cadence proves liveness.
      live_envelope_capture_idle_lease "$real_home" || return 74
      LIVE_AUTHORITY_KIND="candidate-status-renewal"
      [[ "$LIVE_STATUS_BOOT_ID" == "$LIVE_KERNEL_BOOT" && "$LIVE_STATUS_MONOTONIC" != "none" ]] || return 74
    else
      local lease_captured=false
      for attempt in 1 2 3; do
        if live_envelope_capture_legacy_lease "$scratch" "${phase}.lease${attempt}" "$real_home" "$LIVE_STATUS_SESSION" active; then lease_captured=true; break; fi
      done
      [[ "$lease_captured" == true ]] || return 74
      LIVE_AUTHORITY_KIND="legacy-user-lease"
      live_envelope_kernel_truth || return 74
      [[ "$LIVE_LEASE_BOOT" == "$LIVE_KERNEL_BOOT" && "$LIVE_LEASE_BUILD" == "$LIVE_KERNEL_BUILD" ]] || return 74
      [[ "$LIVE_STATUS_BOOT_ID" == "none" || "$LIVE_STATUS_BOOT_ID" == "$LIVE_KERNEL_BOOT" ]] || return 74
      if [[ "$LIVE_STATUS_MONOTONIC" != "none" ]]; then
        /usr/bin/awk \
          -v status="$LIVE_STATUS_MONOTONIC" \
          -v issued="$LIVE_LEASE_ISSUED_MONO" \
          -v expires="$LIVE_LEASE_EXPIRES_MONO" -v current="$LIVE_KERNEL_MONOTONIC" \
          'BEGIN { if (!(issued <= status && status <= expires && status <= current + 1.0)) exit 65 }' || return 74
      fi
    fi
    host_class="active"
  elif [[ "$LIVE_SLEEP_DISABLED" == "0" ]]; then
    if [[ "$LIVE_STATUS_PRESENCE" == "present" ]]; then
      [[ "$LIVE_STATUS_REASON_CLASS" == "safe-idle" ]] || return 74
      host_class="idle-installed"
    else
      [[ "$LIVE_LAUNCHD_PRESENCE" == "absent" ]] || return 74
      host_class="idle-uninstalled"
    fi
    if [[ "$LIVE_STATUS_LEGACY_STALE_IDLE" == true ]]; then
      [[ "$LIVE_PLIST_CONTRACT" == "legacy-watchpaths" ]] || return 74
      case "$LIVE_LAUNCHD_PRESENCE" in
        present)
          [[ "$LIVE_LAUNCHD_STATE" == "not running" && "$LIVE_LAUNCHD_PID" == "none" ]] || return 74
          ;;
        absent)
          [[ "$LIVE_LAUNCHD_STATE" == "none" && "$LIVE_LAUNCHD_PID" == "none" && "$LIVE_LAUNCHD_PROGRAM" == "none" ]] || return 74
          ;;
        *) return 74 ;;
      esac
      [[ "$LIVE_POWER_SOURCE" == "ac" && "$LIVE_AC_SLEEP" == "0" ]] || return 74
    fi
    if [[ "$LIVE_PLIST_CONTRACT" == "legacy-watchpaths" && ( -e "$real_home/Library/Application Support/LidSwitch/activation-lease" || -L "$real_home/Library/Application Support/LidSwitch/activation-lease" ) ]]; then
      live_envelope_capture_legacy_lease "$scratch" "${phase}.expired" "$real_home" none expired || return 74
    else
      live_envelope_capture_idle_lease "$real_home" || return 74
    fi
    LIVE_AUTHORITY_KIND="none"
  else
    return 74
  fi

  swift_sandbox_assert_control_root || return 74
  [[ "$(/usr/bin/dirname "$output")" == "$LIDSWITCH_SWIFT_CONTROL_ROOT" && ! -e "$output" && ! -L "$output" ]] || return 74
  {
    printf 'schema=1\nnonce=%s\nphase=%s\ncaptured_epoch=%s\n' "$nonce" "$phase" "$epoch"
    printf 'kernel_boot=%s\nkernel_build=%s\nkernel_monotonic=%s\n' "$LIVE_KERNEL_BOOT" "$LIVE_KERNEL_BUILD" "$LIVE_KERNEL_MONOTONIC"
    printf 'host_class=%s\npower_source=%s\nsleep_disabled=%s\nac_sleep_minutes=%s\n' "$host_class" "$LIVE_POWER_SOURCE" "$LIVE_SLEEP_DISABLED" "$LIVE_AC_SLEEP"
    printf 'status_presence=%s\nstatus_state=%s\nstatus_reason=%s\nstatus_reason_class=%s\n' "$LIVE_STATUS_PRESENCE" "$LIVE_STATUS_STATE" "$LIVE_STATUS_REASON" "$LIVE_STATUS_REASON_CLASS"
    printf 'status_session=%s\nstatus_updated=%s\nstatus_monotonic=%s\nstatus_boot_id=%s\nstatus_schema=%s\nstatus_evidence=%s\nstatus_meta=%s\n' "$LIVE_STATUS_SESSION" "$LIVE_STATUS_UPDATED" "$LIVE_STATUS_MONOTONIC" "$LIVE_STATUS_BOOT_ID" "$LIVE_STATUS_SCHEMA" "$LIVE_STATUS_EVIDENCE_SIGNATURE" "$LIVE_STATUS_META"
    printf 'launchd_presence=%s\nlaunchd_state=%s\nlaunchd_pid=%s\nlaunchd_program=%s\n' "$LIVE_LAUNCHD_PRESENCE" "$LIVE_LAUNCHD_STATE" "$LIVE_LAUNCHD_PID" "$LIVE_LAUNCHD_PROGRAM"
    printf 'plist_contract=%s\nplist_qualified_build=%s\nplist_meta=%s\nplist_sha256=%s\nhelper_path=%s\nhelper_meta=%s\napp_meta=%s\n' "$LIVE_PLIST_CONTRACT" "$LIVE_PLIST_QUALIFIED_BUILD" "$LIVE_PLIST_META" "$LIVE_PLIST_SHA256" "$LIVE_HELPER_PATH" "$LIVE_HELPER_META" "$LIVE_APP_META"
    printf 'root_support_structure=%s\nprivate_applied_meta=%s\nprivate_terminal_meta=%s\nprivate_reservations_meta=%s\nprivate_proof_meta=%s\nprivate_lock_meta=%s\n' "$root_struct" "$applied" "$terminal" "$reservations" "$proof" "$lock"
    printf 'original_ac_meta=%s\noriginal_battery_meta=%s\n' "$original_ac" "$original_battery"
    printf 'authority_kind=%s\nlease_session=%s\nlease_boot=%s\nlease_expires=%s\nlease_issued_mono=%s\nlease_expires_mono=%s\nlease_uid=%s\nlease_build=%s\nlease_meta=%s\nlease_lifetime=%s\n' "$LIVE_AUTHORITY_KIND" "$LIVE_LEASE_SESSION" "$LIVE_LEASE_BOOT" "$LIVE_LEASE_EXPIRES" "$LIVE_LEASE_ISSUED_MONO" "$LIVE_LEASE_EXPIRES_MONO" "$LIVE_LEASE_UID" "$LIVE_LEASE_BUILD" "$LIVE_LEASE_META" "$LIVE_LEASE_LIFETIME"
    printf 'user_history_diagnostic_meta=%s\n' "$history"
  } > "$output" || return 74
  /usr/bin/awk -F= 'NF < 2 || seen[$1]++ { exit 65 } END { if (NR < 30) exit 65 }' "$output" || return 74
}

live_envelope_numeric_not_decreased() {
  /usr/bin/awk -v before="$1" -v after="$2" 'BEGIN { exit !(before ~ /^[0-9]+([.][0-9]+)?$/ && after ~ /^[0-9]+([.][0-9]+)?$/ && after + 0 >= before + 0) }'
}

live_envelope_numeric_strictly_increased() {
  /usr/bin/awk -v before="$1" -v after="$2" 'BEGIN { exit !(before ~ /^[0-9]+([.][0-9]+)?$/ && after ~ /^[0-9]+([.][0-9]+)?$/ && after + 0 > before + 0) }'
}

live_envelope_compare() {
  local before="$1" after="$2" key left right host_class before_epoch after_epoch before_mono after_mono strict=false
  for key in schema nonce host_class kernel_boot kernel_build power_source sleep_disabled ac_sleep_minutes launchd_presence launchd_state launchd_pid launchd_program plist_contract plist_qualified_build plist_meta plist_sha256 helper_path helper_meta app_meta root_support_structure private_terminal_meta private_reservations_meta private_proof_meta private_lock_meta original_ac_meta original_battery_meta; do
    left="$(live_envelope_kv_get "$key" "$before")" || return 74
    right="$(live_envelope_kv_get "$key" "$after")" || return 74
    [[ "$left" == "$right" ]] || return 74
  done
  before_mono="$(live_envelope_kv_get kernel_monotonic "$before")" || return 74
  after_mono="$(live_envelope_kv_get kernel_monotonic "$after")" || return 74
  live_envelope_numeric_not_decreased "$before_mono" "$after_mono" || return 74
  before_epoch="$(live_envelope_kv_get captured_epoch "$before")" || return 74
  after_epoch="$(live_envelope_kv_get captured_epoch "$after")" || return 74
  [[ "$before_epoch" =~ ^[0-9]{9,12}$ && "$after_epoch" =~ ^[0-9]{9,12}$ && "$after_epoch" -ge "$before_epoch" ]] || return 74
  if /usr/bin/awk -v before="$before_mono" -v after="$after_mono" -v cadence="$LIDSWITCH_ACTIVE_RENEWAL_CADENCE_SECONDS" \
    'BEGIN { exit !((after - before) >= cadence) }'; then
    strict=true
  fi
  host_class="$(live_envelope_kv_get host_class "$before")" || return 74
  if [[ "$host_class" == "active" ]]; then
    for key in status_presence status_state status_reason_class status_session status_boot_id status_schema authority_kind; do
      left="$(live_envelope_kv_get "$key" "$before")" || return 74
      right="$(live_envelope_kv_get "$key" "$after")" || return 74
      [[ "$left" == "$right" ]] || return 74
    done
    left="$(live_envelope_kv_get private_applied_meta "$before")" || return 74
    right="$(live_envelope_kv_get private_applied_meta "$after")" || return 74
    if [[ "$(live_envelope_kv_get authority_kind "$before")" == "candidate-status-renewal" ]]; then
      [[ "$left" == candidate-private\|Regular\ File\|0\|0\|600\|1\|* ]] || return 74
      [[ "$right" == candidate-private\|Regular\ File\|0\|0\|600\|1\|* ]] || return 74
    else
      [[ "$left" == "$right" ]] || return 74
    fi
    if [[ "$strict" == true ]]; then
      live_envelope_numeric_strictly_increased "$(live_envelope_kv_get status_updated "$before")" "$(live_envelope_kv_get status_updated "$after")" || return 74
      if [[ "$(live_envelope_kv_get authority_kind "$before")" == "candidate-status-renewal" ]]; then
        right="$(live_envelope_kv_get status_reason "$after")" || return 74
        [[ "$right" == "renewed" || "$right" == "override-recovered" ]] || return 74
      fi
    else
      live_envelope_numeric_not_decreased "$(live_envelope_kv_get status_updated "$before")" "$(live_envelope_kv_get status_updated "$after")" || return 74
    fi
    left="$(live_envelope_kv_get status_monotonic "$before")" || return 74
    right="$(live_envelope_kv_get status_monotonic "$after")" || return 74
    if [[ "$left" == "none" ]]; then
      [[ "$right" == "none" ]] || return 74
    else
      if [[ "$strict" == true ]]; then
        live_envelope_numeric_strictly_increased "$left" "$right" || return 74
      else
        live_envelope_numeric_not_decreased "$left" "$right" || return 74
      fi
    fi
    for key in lease_session lease_boot lease_uid lease_build; do
      left="$(live_envelope_kv_get "$key" "$before")" || return 74
      right="$(live_envelope_kv_get "$key" "$after")" || return 74
      [[ "$left" == "$right" ]] || return 74
    done
    if [[ "$(live_envelope_kv_get authority_kind "$before")" == "legacy-user-lease" ]]; then
      for key in lease_expires lease_issued_mono lease_expires_mono; do
        left="$(live_envelope_kv_get "$key" "$before")" || return 74
        right="$(live_envelope_kv_get "$key" "$after")" || return 74
        if [[ "$strict" == true ]]; then
          live_envelope_numeric_strictly_increased "$left" "$right" || return 74
        else
          live_envelope_numeric_not_decreased "$left" "$right" || return 74
        fi
      done
    else
      for key in lease_expires lease_issued_mono lease_expires_mono lease_meta lease_lifetime; do
        [[ "$(live_envelope_kv_get "$key" "$before")" == "none" || "$(live_envelope_kv_get "$key" "$before")" == "absent" ]] || return 74
        [[ "$(live_envelope_kv_get "$key" "$before")" == "$(live_envelope_kv_get "$key" "$after")" ]] || return 74
      done
    fi
  else
    [[ "$(live_envelope_kv_get private_applied_meta "$before")" == "$(live_envelope_kv_get private_applied_meta "$after")" ]] || return 74
    for key in status_presence status_state status_reason status_reason_class status_session status_updated status_monotonic status_boot_id status_schema status_evidence status_meta; do
      left="$(live_envelope_kv_get "$key" "$before")" || return 74
      right="$(live_envelope_kv_get "$key" "$after")" || return 74
      [[ "$left" == "$right" ]] || return 74
    done
    for key in authority_kind lease_session lease_boot lease_expires lease_issued_mono lease_expires_mono lease_uid lease_build lease_meta lease_lifetime; do
      left="$(live_envelope_kv_get "$key" "$before")" || return 74
      right="$(live_envelope_kv_get "$key" "$after")" || return 74
      [[ "$left" == "$right" ]] || return 74
    done
  fi
}

live_envelope_write_receipt() {
  local outcome="$1" child_command_exit="$2" wrapper_exit="$3" pre_hash="$4" post_hash="$5" error="${6:-none}"
  local receipt="$LIDSWITCH_SWIFT_CONTROL_ROOT/live-state-retained.receipt" host_preserved=false benchmark_published=false capture_identifiers="${LIDSWITCH_SWIFT_CAPTURE_IDENTIFIERS:-none}"
  [[ "$child_command_exit" =~ ^([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-6])$ && "$wrapper_exit" =~ ^([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$ ]] || return 74
  live_envelope_safe_scalar "$error" || error="unsafe-error-text"
  case "$outcome" in
    preserved)
      [[ "$child_command_exit" == 0 && "$wrapper_exit" == 0 ]] || return 74
      host_preserved=true
      ;;
    command-failed-host-preserved)
      [[ "$child_command_exit" =~ ^[1-9][0-9]*$ && "$child_command_exit" -le 255 && "$wrapper_exit" == "$child_command_exit" ]] || return 74
      host_preserved=true
      ;;
    preflight-denied)
      [[ "$child_command_exit" == 256 && "$wrapper_exit" == 74 ]] || return 74
      ;;
    benchmark-publication-failed-host-unverified)
      [[ "$child_command_exit" == 0 && "$wrapper_exit" == 74 ]] || return 74
      ;;
    host-drift|envelope-failed-host-unverified|envelope-final-reassert-failed-host-unverified)
      [[ "$child_command_exit" -le 256 && "$wrapper_exit" == 74 ]] || return 74
      ;;
    *) return 74 ;;
  esac
  [[ "$outcome" == "preserved" && "${LIDSWITCH_SWIFT_BENCHMARK_ENABLED:-0}" == "1" ]] && benchmark_published=true
  # Every host-visible receipt is preceded by a full capability reassertion;
  # control/execution roots, immutable source and rendered profile must still
  # be the launch identities even when the sandbox command already ended.
  swift_sandbox_assert_runtime_integrity || return 74
  [[ ! -e "$receipt" && ! -L "$receipt" ]] || return 74
  if ! {
    printf 'schema=3\nnonce=%s\noutcome=%s\nchild_command_exit=%s\nwrapper_exit=%s\n' "$LIDSWITCH_SWIFT_ENVELOPE_NONCE" "$outcome" "$child_command_exit" "$wrapper_exit"
    printf 'preflight_sha256=%s\npostflight_sha256=%s\nhost_preserved=%s\nbenchmark_published=%s\n' "$pre_hash" "$post_hash" "$host_preserved" "$benchmark_published"
    printf 'error=%s\ncapture_identifiers=%s\ncontrol_root=%s\nexecution_root=%s\n' "$error" "$capture_identifiers" "$LIDSWITCH_SWIFT_CONTROL_ROOT" "$LIDSWITCH_SWIFT_EXEC_ROOT"
  } | swift_sandbox_verified_python safe-file PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C -- write-new \
      --root "$LIDSWITCH_SWIFT_CONTROL_ROOT" --identity "$LIDSWITCH_SWIFT_CONTROL_ID" \
        --name live-state-retained.receipt --max-bytes 65536 --allow-root-nlink-growth; then
    echo "could not durably write the retained host receipt" >&2
    return 74
  fi
  # write-new performs the descriptor-safe create/metadata/durability proof.
  # Do not add a post-receipt syscall that could turn a preserved receipt into
  # a later status-74 wrapper result.
  export LIDSWITCH_SWIFT_RETAINED_RECEIPT="$receipt"
}

live_envelope_preflight() {
  local initial="$LIDSWITCH_SWIFT_CONTROL_ROOT/live-preflight-initial.kv" host_class
  LIVE_ENVELOPE_ERROR="none"
  LIVE_ENVELOPE_TERMINAL_OUTCOME="preflight-denied"
  LIVE_ENVELOPE_TERMINAL_ERROR="preflight-unclassified"
  LIVE_ENVELOPE_TERMINAL_PRE_HASH="absent"
  LIVE_ENVELOPE_TERMINAL_POST_HASH="absent"
  export LIVE_ENVELOPE_TERMINAL_OUTCOME LIVE_ENVELOPE_TERMINAL_ERROR LIVE_ENVELOPE_TERMINAL_PRE_HASH LIVE_ENVELOPE_TERMINAL_POST_HASH
  export LIVE_ENVELOPE_ERROR
  live_envelope_capture pre-initial "$initial" "$LIDSWITCH_SWIFT_EXEC_ROOT" "$LIDSWITCH_SWIFT_ENVELOPE_NONCE" "$LIDSWITCH_REAL_HOME" || {
    LIVE_ENVELOPE_TERMINAL_ERROR="preflight-capture-failed"
    export LIVE_ENVELOPE_TERMINAL_ERROR
    return 74
  }
  host_class="$(live_envelope_kv_get host_class "$initial")" || {
    LIVE_ENVELOPE_TERMINAL_ERROR="preflight-class-failed"
    export LIVE_ENVELOPE_TERMINAL_ERROR
    return 74
  }
  if [[ "$host_class" == "active" ]]; then
    /bin/sleep 10 || {
      LIVE_ENVELOPE_TERMINAL_ERROR="preflight-renewal-wait-failed"
      export LIVE_ENVELOPE_TERMINAL_ERROR
      return 74
    }
    live_envelope_capture pre "$LIDSWITCH_SWIFT_PREFLIGHT" "$LIDSWITCH_SWIFT_EXEC_ROOT" "$LIDSWITCH_SWIFT_ENVELOPE_NONCE" "$LIDSWITCH_REAL_HOME" || {
      LIVE_ENVELOPE_TERMINAL_ERROR="preflight-renewal-capture-failed"
      export LIVE_ENVELOPE_TERMINAL_ERROR
      return 74
    }
    live_envelope_compare "$initial" "$LIDSWITCH_SWIFT_PREFLIGHT" || {
      LIVE_ENVELOPE_TERMINAL_ERROR="preflight-renewal-did-not-advance"
      export LIVE_ENVELOPE_TERMINAL_ERROR
      return 74
    }
  else
    LIDSWITCH_SWIFT_PREFLIGHT="$initial"
    export LIDSWITCH_SWIFT_PREFLIGHT
  fi
  LIDSWITCH_SWIFT_PREFLIGHT_SHA256="$(live_envelope_sha256 "$LIDSWITCH_SWIFT_PREFLIGHT")" || {
    LIVE_ENVELOPE_TERMINAL_ERROR="preflight-hash-failed"
    export LIVE_ENVELOPE_TERMINAL_ERROR
    return 74
  }
  swift_sandbox_seal_control_file "$LIDSWITCH_SWIFT_PREFLIGHT" LIDSWITCH_SWIFT_PREFLIGHT_SEAL || {
    LIVE_ENVELOPE_TERMINAL_ERROR="preflight-seal-failed"
    export LIVE_ENVELOPE_TERMINAL_ERROR
    return 74
  }
  LIVE_ENVELOPE_TERMINAL_PRE_HASH="$LIDSWITCH_SWIFT_PREFLIGHT_SHA256"
  export LIDSWITCH_SWIFT_PREFLIGHT_SHA256
  export LIVE_ENVELOPE_TERMINAL_PRE_HASH
}

live_envelope_postflight() {
  local command_exit="$1" post_hash
  LIVE_ENVELOPE_TERMINAL_OUTCOME="host-drift"
  LIVE_ENVELOPE_TERMINAL_ERROR="postflight-unclassified"
  LIVE_ENVELOPE_TERMINAL_PRE_HASH="${LIDSWITCH_SWIFT_PREFLIGHT_SHA256:-absent}"
  LIVE_ENVELOPE_TERMINAL_POST_HASH="absent"
  export LIVE_ENVELOPE_TERMINAL_OUTCOME LIVE_ENVELOPE_TERMINAL_ERROR LIVE_ENVELOPE_TERMINAL_PRE_HASH LIVE_ENVELOPE_TERMINAL_POST_HASH
  swift_sandbox_assert_runtime_integrity || { LIVE_ENVELOPE_TERMINAL_ERROR="postflight-runtime-integrity-failed"; export LIVE_ENVELOPE_TERMINAL_ERROR; return 74; }
  swift_sandbox_assert_sealed_control_file "$LIDSWITCH_SWIFT_PREFLIGHT" "$LIDSWITCH_SWIFT_PREFLIGHT_SEAL" || { LIVE_ENVELOPE_TERMINAL_ERROR="postflight-preflight-seal-failed"; export LIVE_ENVELOPE_TERMINAL_ERROR; return 74; }
  [[ "$(live_envelope_sha256 "$LIDSWITCH_SWIFT_PREFLIGHT")" == "$LIDSWITCH_SWIFT_PREFLIGHT_SHA256" ]] || { LIVE_ENVELOPE_TERMINAL_ERROR="postflight-preflight-hash-failed"; export LIVE_ENVELOPE_TERMINAL_ERROR; return 74; }
  live_envelope_capture post "$LIDSWITCH_SWIFT_POSTFLIGHT" "$LIDSWITCH_SWIFT_EXEC_ROOT" "$LIDSWITCH_SWIFT_ENVELOPE_NONCE" "$LIDSWITCH_REAL_HOME" || {
    LIVE_ENVELOPE_TERMINAL_ERROR="postflight-capture-failed"
    export LIVE_ENVELOPE_TERMINAL_ERROR
    return 74
  }
  post_hash="$(live_envelope_sha256 "$LIDSWITCH_SWIFT_POSTFLIGHT")" || {
    LIVE_ENVELOPE_TERMINAL_ERROR="postflight-hash-failed"
    export LIVE_ENVELOPE_TERMINAL_ERROR
    return 74
  }
  LIVE_ENVELOPE_TERMINAL_POST_HASH="$post_hash"
  export LIVE_ENVELOPE_TERMINAL_POST_HASH
  if ! live_envelope_compare "$LIDSWITCH_SWIFT_PREFLIGHT" "$LIDSWITCH_SWIFT_POSTFLIGHT"; then
    LIVE_ENVELOPE_TERMINAL_ERROR="postflight-fingerprint-mismatch"
    export LIVE_ENVELOPE_TERMINAL_ERROR
    return 74
  fi
  LIVE_ENVELOPE_POST_HASH="$post_hash"
  LIVE_ENVELOPE_POSTFLIGHT_OK=1
  export LIVE_ENVELOPE_POST_HASH LIVE_ENVELOPE_POSTFLIGHT_OK
}

live_envelope_finalize_terminal_receipt() {
  local child_command_exit="$1" wrapper_exit="$2"
  live_envelope_write_receipt "${LIVE_ENVELOPE_TERMINAL_OUTCOME:-envelope-failed-host-unverified}" "$child_command_exit" "$wrapper_exit" "${LIVE_ENVELOPE_TERMINAL_PRE_HASH:-absent}" "${LIVE_ENVELOPE_TERMINAL_POST_HASH:-absent}" "${LIVE_ENVELOPE_TERMINAL_ERROR:-terminal-state-missing}"
}
