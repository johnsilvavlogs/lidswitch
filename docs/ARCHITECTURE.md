# Architecture

LidSwitch `0.2.9` is a SwiftPM menu bar app with three targets:

- `LidSwitch`: UI, inspection, lease writer, installation and recovery controls.
- `LidSwitchCore`: lease schema, monotonic clock, boot identity, and compatibility policy.
- `LidSwitchHelper`: compiled root helper using IOKit power notifications and bounded timers.

## Session flow

1. The user prepares helper version `4`; legacy login and shell-helper artifacts are removed while protection remains off.
2. The user confirms **Start Plugged-In Session** on AC power.
3. The app writes a user-owned `0600` activation lease atomically. It contains the session UUID, the immutable `kern.bootsessionuuid` boot identity, monotonic issue/expiry times, UID, and macOS build. Calendar/NTP adjustments to mutable `kern.boottime` cannot invalidate a same-boot lease.
4. launchd reacts to the lease path. There is no `StartInterval`.
5. The helper securely reopens the lease with `O_NOFOLLOW | O_NONBLOCK`, validates its file descriptor metadata, and verifies current AC power and settings.
6. Before changing anything, the helper writes a root-owned applied-state record. It then applies AC sleep `0` when needed and `SleepDisabled=1`, verifying both.
7. A serial `DispatchSourceTimer` coordinator accepts **active** only when the lease, fresh helper acknowledgement, session UUID, and direct AC source agree. It never depends on the main run loop or a full `PowerInspector.snapshot`, and it is the sole termination authority for an owned active generation.
8. The coordinator renews every 8 seconds using monotonic deadlines. Immediately before atomic lease publication, it rechecks the prior expiry and fresh matching helper/AC state.
9. The root-owned `terminal-generations` ledger is the authoritative tombstone, bounded to the newest 64 session UUIDs; helper status remains the current acknowledgement surface. Replaying a fresh lease with a tombstoned UUID cannot reactivate the helper.

Helper preparation preserves a valid bounded ledger, normalizes it to root-owned, non-writable mode `0644` so the unprivileged app can validate readiness, and atomically replaces missing, symlinked, nonregular, writable, oversized, malformed, or duplicate state with an empty safe ledger after restoration. Every helper rewrite also restores `0644`, preventing readiness from drifting after the first terminal session.

## End and recovery

Unplug, quit, reboot, app death, lease expiry, invalid input, lost acknowledgement, signal, or setting drift ends the session. One exception is a single owned `SleepDisabled=0` loss while AC, the matching current lease, applied-state, helper session, and nonterminal generation all still agree: the helper records a root-owned bounded `recovery_budget=reserved` marker before mutation and `spent` after success, then reapplies `SleepDisabled=1` to the same UUID. The marker survives helper restart; a restart while reserved fails closed, while a restart with spent budget retains the spent state. App and helper inspections use IOKit plus `CFPreferences` reads of `com.apple.PowerManagement`; only privileged mutations use bounded `pmset` commands. During reconciliation, only an unreadable native `SleepDisabled` or AC-sleep value is retried after bounded 100 ms and 300 ms delays; known values are never reread by this tolerance path. A transient unreadable result that becomes healthy stays in the same session without spending recovery budget, while repeated unreadability terminalizes and restores. A second owned loss in that generation, explicit AC-sleep drift, terminal markers, or a failed reapply also terminalizes and restores. Restoration:

- clears `SleepDisabled` only when LidSwitch recorded ownership;
- restores AC sleep only if the current value still equals LidSwitch's applied `0`;
- never applies a stale saved value of `0`;
- retries and verifies restoration;
- retains applied-state and emits `recovery-required` on failure.

launchd uses `KeepAlive.SuccessfulExit=false` with throttling only to recover abnormal helper exits. Clean expiry and clean restoration exit successfully and do not persist.

After the app heartbeat observes a terminal helper state, the menu remains in a bounded restoring state for up to 30 seconds. This covers the helper's worst-case verified rollback retry path with margin while remaining below the 45-second live acceptance limit. A typed red rollback-verification alert is shown only if that bounded verification still cannot prove `SleepDisabled=0`, no activation lease, and no helper recovery marker. Every later authoritative snapshot (bootstrap, manual refresh, timer, and power-source observer) rechecks that exact predicate; it clears only that typed alert when no newer local session exists, announces the safe-idle transition once, and retains all generic operation errors and unsafe/unknown snapshots. User-invoked preparation and restore operations retain their separate shorter timeouts.

## Compatibility and packaging

Activation is currently qualified only for macOS build `25F84`. The packaged app includes `CFBundleShortVersionString=0.2.9`, `CFBundleVersion=1`, and helper version `4` under `Contents/Library/LaunchServices`.

Automatic gates build, test, sign, mount, and inspect artifacts without launching the app or changing power state. The live canary is separate.
