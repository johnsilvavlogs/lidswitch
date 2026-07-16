# LidSwitch

LidSwitch is a native macOS menu bar app for one deliberate job: keep a plugged-in Mac running while its lid is closed for the duration of a session you explicitly start.

Version `0.2.12` build `5` reads power source and power-policy truth through IOKit and macOS's native power-preference domain. Active reconciliation no longer launches competing `pmset` readers, so a stalled command cannot starve helper acknowledgements and falsely end a healthy session. Explicit END/RESTORE exchanges alone receive the bridge's bounded ten-second terminal budget so their synchronous rollback and durable publication can finish under load; liveness-sensitive operations retain the five-second bound and terminal effects are never retried after an indeterminate reply. The serial heartbeat remains the sole authority for an owned active generation; actual disconnect, authenticated-session/status loss, corruption, or explicit setting drift still fails closed.

## Safety model

- Protection is off after install, app launch, login, reboot, or reconnecting power.
- **Prepare Safe Helper** installs helper version `5` into the root-owned `Current` release directory and removes old startup artifacts. It does not enable a session.
- **Start Plugged-In Session** is available only on AC power after live state and bundle checks pass.
- The app begins one authenticated process-bound raw-XPC session. The helper chooses its same-boot monotonic deadline, capped at 30 seconds, and the app renews every 8 seconds.
- The compiled helper validates the enrolled caller identity, exact live process tuple, session UUID, private recovery authority, power source, build, and native power-preference state.
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
- Shared wire/recovery model: `Sources/LidSwitchCore`
- Native helper target: `Sources/LidSwitchHelper`

## Build and test without launching

Portable source, release-identity, and website checks are ordinary repository
commands:

```bash
npm run release:identity:check
npm run release:identity:test
npm run scan:secrets:test
npm run validate:site
```

Swift compilation and XCTest use the descriptor-held launcher described in
`docs/VALIDATION.md`. The two Swift wrapper pathnames reject direct execution;
the retired legacy bundle builders also fail closed. A release build uses only
the installed Apple Command Line Tools. Local XCTest uses the installed free
Xcode runtime because Command Line Tools do not ship XCTest. Neither lane uses
`xcodebuild`, an Apple account, a paid license, or a paid service, and neither
launches the app or changes live power state.

The session suite covers stable boot-session identity, current acknowledgement, monotonic heartbeat starvation, commit-boundary races, expiry, reboot mismatch, unplug/no-rearm, terminal-generation replay, app-death rollback, override drift, abnormal helper recovery, malformed and symlinked state, unknown power, restore failure, bounded diagnostics, stale zero baselines, and event-driven launchd configuration.

## Package without launching

```bash
# First: after the manager-owned held `release-candidate` build has sealed its
# source manifest and toolchain, create its immutable envelope receipt. Then
# package from that one retained release-output directory without rebuilding:
RELEASE_OUTPUT=/private/tmp/lidswitch-swift.RETAINED/release-output
PACKAGE_PARENT="$(/usr/bin/mktemp -d /private/tmp/lidswitch-package.XXXXXX)"
/usr/bin/python3 -I -S -B script/capture_immutable_build_envelope.py \
  --source-commit "$(/usr/bin/git rev-parse HEAD)" \
  --source-manifest script/source_snapshot_manifest.jsonl \
  --held-build-wrapper script/run_swift_build_safely.sh \
  --swift /Library/Developer/CommandLineTools/usr/bin/swift \
  --release-output "$RELEASE_OUTPUT" \
  --output "$PACKAGE_PARENT/build-envelope.json"
/usr/bin/python3 -I -S -B script/assemble_manual_adhoc_candidate.py \
  --envelope-receipt "$PACKAGE_PARENT/build-envelope.json" \
  --release-output "$RELEASE_OUTPUT" \
  --output-root "$PACKAGE_PARENT/candidate"
```

This is a zero-cost local path: it uses only macOS `codesign` with identity
`-`, `hdiutil`, `ditto`, and `shasum`. It does not use Xcode, an Apple account,
Developer ID, Team ID, notarization, a paid CI provider, or any network service.
The assembler copies the two already-built bytes once into a fresh private
candidate root, signs them ad hoc, creates one compressed DMG, extracts it,
and publishes/validates the immutable app and package manifests. It prints the
candidate manifest and DMG paths on success. The retired `build_dmg.sh` and
`validate_dmg.sh` scripts continue to fail closed and are not release commands.

This project does not currently have a Developer ID identity. The DMG is not notarized; first launch requires the documented manual **Open Anyway** approval. Do not describe it as App Store distributed or notarized.

## Controlled live canary

Automatic CI and the `full-release` gate never launch LidSwitch or enable `SleepDisabled`. A live canary is a separate, explicit profile after all simulations pass.

The canary requires the app to be installed and a session to be started through the UI. It observes the active state, kills the app to simulate a crash, waits for peer-invalidation restoration, and proves there is no automatic rearm:

```bash
LIDSWITCH_CONTROLLED_CANARY=1 ./script/validate_live_state.sh
```

See `docs/VALIDATION.md` and `docs/OPERATIONS.md` before running it.

## Installed files

```text
/Applications/LidSwitch.app
/Library/LaunchDaemons/com.johnsilva.lidswitch.helper.plist
/Library/Application Support/LidSwitch/Current/LidSwitchHelper
/Library/Application Support/LidSwitch/Current/helper-version
/Library/Application Support/LidSwitch/Current/enrollment-policy
/Library/Application Support/LidSwitch/applied-state
/Library/Application Support/LidSwitch/helper-status
/Library/Application Support/LidSwitch/terminal-generations
/Library/Application Support/LidSwitch/recovery-reservations
/Library/Application Support/LidSwitch/recovery-proof
/Library/Application Support/LidSwitch/root-state.lock
/Library/Application Support/LidSwitch/administrator-transaction-{uuid}.receipt
~/Library/Application Support/LidSwitch/activation-lease
~/Library/Application Support/LidSwitch/session-history.json
```

The root authority files are private `0600`; the ordinary-user app reads only their metadata and the public bounded helper-status projection. The user activation-lease file is migration/diagnostic residue and cannot authorize the helper. The old `~/Library/LaunchAgents/com.johnsilva.LidSwitch.login.plist` and root `lidswitch-helper` shell script are legacy residue and must be disabled, unloaded, and removed before activation.

## Privacy

The Mac app has no telemetry and sends no passwords, tokens, account identifiers, or power data. The public website uses Vercel Web Analytics for aggregate traffic; GitHub records release downloads. See `docs/PRIVACY.md`.

## License

MIT. See `LICENSE`.
