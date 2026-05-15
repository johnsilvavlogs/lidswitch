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
- desired state is `enabled`
- `SleepDisabled` matches the current power source
- battery sleep profile remains `1`
- menu bar item is exposed through Accessibility
- panel text includes the primary toggle, battery-safety copy, and enabled status

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
