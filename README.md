# LidSwitch

LidSwitch is a native macOS menu bar app for one deliberate job: keep a plugged-in Mac running while its lid is closed for the duration of a session you explicitly start.

Version `0.2.7` build `1` tolerates a bounded transient unreadable `pmset` override probe without ending a healthy session, while repeated unreadability and explicit drift still fail closed. After any safety termination, the menu waits for bounded rollback verification before presenting a recovery-required alert. If a later authoritative refresh proves `SleepDisabled=0`, no lease, no recovery marker, and no newer local session, it clears only that provenanced rollback alert and returns to safe-idle UI. It retains the application-owned native confirmations, serial monotonic lease coordinator, and root-owned terminal generation tombstones introduced in `0.2.5`.

## Safety model

- Protection is off after install, app launch, login, reboot, or reconnecting power.
- **Prepare Safe Helper** installs helper version `2` and removes old startup artifacts. It does not enable a session.
- **Start Plugged-In Session** is available only on AC power after live state and bundle checks pass.
- The app writes a same-boot, same-user, same-build lease with a maximum lifetime of 30 seconds and renews it every 8 seconds.
- The compiled helper reopens and validates the newest lease, power source, boot, build, owner, file metadata, and live `pmset` state.
- The helper applies power changes only on state transitions. It has no `StartInterval` loop.
- Unplugging, quitting, restarting, app death, lease expiry, invalid state, lost acknowledgement, or power-setting drift ends the session and restores LidSwitch-owned changes.
- Reconnecting power never starts a new session.
- A bounded owner-only local history records normalized start, acknowledgement, renewal, and end reasons without telemetry or secrets.
- There is no battery keep-awake mode in this release.
- A root-owned applied-state record is removed only after restoration is verified. Failed restoration keeps that evidence and reports **Restore required**.

The app currently qualifies macOS `26.5.2` build `25F84`. Other OS builds remain off until separately validated. The Swift package minimum remains macOS 14 for compilation.

## Repository

- GitHub: <https://github.com/johnsilvavlogs/lidswitch>
- Releases: <https://github.com/johnsilvavlogs/lidswitch/releases/latest>
- App target: `Sources/LidSwitch`
- Shared lease model: `Sources/LidSwitchCore`
- Native helper target: `Sources/LidSwitchHelper`

## Build without launching

```bash
./script/build_app_bundle.sh
./script/validate_bundle.sh
```

The app bundle is staged under the temporary directory unless `LIDSWITCH_APP_BUNDLE` is provided. Both commands preserve the running LidSwitch process set and never alter live power state.

Launching is explicit:

```bash
./script/build_and_run.sh --run
```

## Tests

```bash
swift test --scratch-path /tmp/lidswitch-tests
./script/validate_session_safety.sh
```

The session suite covers current acknowledgement, monotonic heartbeat starvation, commit-boundary races, expiry, reboot mismatch, unplug/no-rearm, terminal-generation replay, app-death rollback, override drift, abnormal helper recovery, malformed and symlinked state, unknown power, restore failure, bounded diagnostics, stale zero baselines, and event-driven launchd configuration.

## Package without launching

```bash
./script/build_dmg.sh
./script/validate_dmg.sh
```

The DMG and checksum are written to `dist/`. Packaging validates version `0.2.7` build `1`, helper version `2`, arm64 binaries, strict ad-hoc signatures, expected Gatekeeper rejection, checksum integrity, and that no app process was started or stopped.

This project does not currently have a Developer ID identity. The DMG is not notarized; first launch requires the documented manual **Open Anyway** approval. Do not describe it as App Store distributed or notarized.

## Controlled live canary

Automatic CI and the `full-release` gate never launch LidSwitch or enable `SleepDisabled`. A live canary is a separate, explicit profile after all simulations pass.

The canary requires the app to be installed and a session to be started through the UI. It observes the active state, kills the app to simulate a crash, waits for lease-expiry restoration, and proves there is no automatic rearm:

```bash
LIDSWITCH_CONTROLLED_CANARY=1 ./script/validate_live_state.sh
```

See `docs/VALIDATION.md` and `docs/OPERATIONS.md` before running it.

## Installed files

```text
/Applications/LidSwitch.app
/Library/LaunchDaemons/com.johnsilva.lidswitch.helper.plist
/Library/Application Support/LidSwitch/LidSwitchHelper
/Library/Application Support/LidSwitch/helper-version
/Library/Application Support/LidSwitch/applied-state
/Library/Application Support/LidSwitch/helper-status
/Library/Application Support/LidSwitch/terminal-generations
~/Library/Application Support/LidSwitch/activation-lease
~/Library/Application Support/LidSwitch/session-history.json
```

The old `~/Library/LaunchAgents/com.johnsilva.LidSwitch.login.plist` and root `lidswitch-helper` shell script are legacy residue and must be disabled, unloaded, and removed before activation.

## Privacy

The Mac app has no telemetry and sends no passwords, tokens, account identifiers, or power data. The public website uses Vercel Web Analytics for aggregate traffic; GitHub records release downloads. See `docs/PRIVACY.md`.

## License

MIT. See `LICENSE`.
