# Validation

LidSwitch has three validation layers: unit tests, generated-helper linting, and live product smoke.

## Unit Tests

```bash
swift test
```

Current tests cover:

- AC power parsing
- battery power and percentage parsing
- `SleepDisabled` parsing
- AC idle-sleep parsing
- battery idle-sleep parsing
- legacy and key/value preference parsing
- AC-only and battery opt-in policy decisions

## Helper And Plist Linting

```bash
.build/debug/LidSwitch --print-helper | zsh -n /dev/stdin
.build/debug/LidSwitch --print-install-script | zsh -n /dev/stdin
.build/debug/LidSwitch --print-uninstall-script | zsh -n /dev/stdin
.build/debug/LidSwitch --print-plist | plutil -lint -
```

These checks validate generated artifacts without installing or modifying privileged system files.

## App Bundle Launch

```bash
./script/build_and_run.sh --verify
```

This builds the SwiftPM target, stages `dist/LidSwitch.app`, launches the app bundle, and confirms the process exists.

## Live Product Smoke

```bash
./script/validate_live_state.sh
```

This checks:

- `LidSwitch` process is running
- LaunchDaemon is loaded
- helper executable exists
- helper version is current
- desired mode is `enabled`
- battery opt-in is disabled for the safe default smoke
- `SleepDisabled` matches the current power source and battery opt-in
- battery sleep profile is not overridden when battery opt-in is disabled
- menu bar item is exposed through Accessibility
- panel text includes the primary toggle, battery opt-in toggle, battery-safety copy, and enabled status

This smoke expects the app to be installed and enabled. It is part of the JTBD done gate.

## JTBD Done Gate

```bash
python /Users/johnsilva/.agents/skills/jtbd-done-gate/scripts/done_gate.py --plan
python /Users/johnsilva/.agents/skills/jtbd-done-gate/scripts/done_gate.py
```

The final successful run used `full-release` and passed:

1. Swift build
2. Swift tests
3. Helper script syntax
4. Helper plist syntax
5. App bundle launch
6. Live menu bar power smoke

## Local Proof

```text
.jtbd-done-gate/reports/<timestamp>/report.md
```

Gate reports are ignored by git. Re-run the gate to regenerate current proof after cloning or changing the app.
