# LidSwitch

LidSwitch is a minimal native macOS menu bar app for one job: keep a MacBook awake when the lid is closed. It defaults to the safer AC-only mode and includes an explicit battery opt-in for users who need processing to continue while unplugged.

![LidSwitch running](screenshots/lidswitch-working.png)

## What It Does

- Adds a compact `MenuBarExtra` with one primary switch: **Keep awake when plugged in**.
- Adds a secondary **Allow on battery** switch that stays off unless explicitly enabled.
- Shows live power source and sleep-override state.
- Enables `SleepDisabled` only when the app is enabled and macOS reports AC Power.
- Automatically clears `SleepDisabled` on battery unless both switches are enabled.
- Warns clearly when the Mac is on battery and lid-close sleep is still allowed.
- Provides **Restore** and **Uninstall** controls from the menu bar panel.
- Uses the standard macOS administrator prompt for privileged helper install, restore, and uninstall.

## Safety Model

macOS exposes `disablesleep` as a system-wide power flag, not as a clean AC-only preference. LidSwitch handles that by installing a small root LaunchDaemon helper that polls the current power source and a user-owned desired-state file.

The helper behavior is intentionally conservative:

- If keep-awake is enabled and power source is AC: set AC idle sleep to `0` and set `SleepDisabled` to `1`.
- If keep-awake is enabled, battery opt-in is enabled, and power source is battery: set battery idle sleep to `0` and set `SleepDisabled` to `1`.
- If power source is battery and battery opt-in is disabled: set `SleepDisabled` to `0`.
- If keep-awake is disabled: set `SleepDisabled` to `0` and restore saved AC and battery idle-sleep values if LidSwitch saved them.

The app never stores credentials. It delegates privileged work to macOS via the normal authorization dialog.

## Requirements

- macOS 14 or newer
- Apple Swift toolchain / Xcode command line tools
- Accessibility permission for validation scripts that inspect the menu bar UI
- Administrator access for first install, restore, and uninstall actions

## Build And Run

Use the project runner:

```bash
./script/build_and_run.sh
```

Verify launch:

```bash
./script/build_and_run.sh --verify
```

The runner builds the SwiftPM executable, stages a local app bundle at:

```text
dist/LidSwitch.app
```

and launches it as a real macOS app bundle rather than a raw executable.

## Test

Run unit tests:

```bash
swift test
```

Run the full JTBD gate:

```bash
python /Users/johnsilva/.agents/skills/jtbd-done-gate/scripts/done_gate.py
```

The gate checks Swift build/test, helper/plist syntax, app bundle launch, and the live menu bar/power-state smoke.

## Installed Files

When enabled for the first time, LidSwitch installs:

```text
/Library/LaunchDaemons/com.johnsilva.lidswitch.helper.plist
/Library/Application Support/LidSwitch/lidswitch-helper
/Library/Application Support/LidSwitch/helper-version
/Library/Application Support/LidSwitch/original-ac-sleep
/Library/Application Support/LidSwitch/original-battery-sleep
~/Library/Application Support/LidSwitch/desired-state
```

The root-owned files are removed by **Uninstall**. The desired-state file is user-owned and stores only the keep-awake mode and battery opt-in:

```text
mode=enabled
battery=disabled
```

Legacy `enabled` and `disabled` files still read safely; legacy `enabled` means AC-only.

## Current Verified State

The implementation was verified on macOS 26.3 with the app enabled while connected to AC power:

- `SleepDisabled 1`
- desired state `mode=enabled`, `battery=disabled`
- LaunchDaemon loaded as `com.johnsilva.lidswitch.helper`
- battery power profile preserved with `sleep 1`
- menu bar UI showed `Keeping awake when plugged in` and the battery opt-in control

Proof is stored locally under:

```text
.jtbd-done-gate/reports/<timestamp>/report.md
```

Reports are ignored by git; rerun the gate to regenerate local proof.

## More Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Operations](docs/OPERATIONS.md)
- [Validation](docs/VALIDATION.md)
