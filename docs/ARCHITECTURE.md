# Architecture

LidSwitch `0.2.0` is a SwiftPM menu bar app with three targets:

- `LidSwitch`: UI, inspection, lease writer, installation and recovery controls.
- `LidSwitchCore`: lease schema, monotonic clock, boot identity, and compatibility policy.
- `LidSwitchHelper`: compiled root helper using IOKit power notifications and bounded timers.

## Session flow

1. The user prepares helper version `3`; legacy login and shell-helper artifacts are removed while protection remains off.
2. The user confirms **Start Plugged-In Session** on AC power.
3. The app writes a user-owned `0600` activation lease atomically. It contains the session UUID, boot identity, monotonic issue/expiry times, UID, and macOS build.
4. launchd reacts to the lease path. There is no `StartInterval`.
5. The helper securely reopens the lease with `O_NOFOLLOW | O_NONBLOCK`, validates its file descriptor metadata, and verifies current AC power and settings.
6. Before changing anything, the helper writes a root-owned applied-state record. It then applies AC sleep `0` when needed and `SleepDisabled=1`, verifying both.
7. The app accepts **active** only when the lease, fresh helper acknowledgement, session UUID, AC source, and live override all agree.
8. The app renews the same session every 8 seconds; each lease is valid for no more than 30 seconds.

## End and recovery

Unplug, quit, reboot, app death, lease expiry, invalid input, lost acknowledgement, signal, or setting drift ends the session. Restoration:

- clears `SleepDisabled` only when LidSwitch recorded ownership;
- restores AC sleep only if the current value still equals LidSwitch's applied `0`;
- never applies a stale saved value of `0`;
- retries and verifies restoration;
- retains applied-state and emits `recovery-required` on failure.

launchd uses `KeepAlive.SuccessfulExit=false` with throttling only to recover abnormal helper exits. Clean expiry and clean restoration exit successfully and do not persist.

## Compatibility and packaging

Activation is currently qualified only for macOS build `25F84`. The packaged app includes `CFBundleShortVersionString=0.2.0`, `CFBundleVersion=2`, and the signed native helper under `Contents/Library/LaunchServices`.

Automatic gates build, test, sign, mount, and inspect artifacts without launching the app or changing power state. The live canary is separate.
