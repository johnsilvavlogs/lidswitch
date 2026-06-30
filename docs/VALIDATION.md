# Validation

LidSwitch has three validation layers: unit tests, generated-helper linting, and live product smoke.
The public launch also adds site validation for the Vercel-hosted landing page.
Current release packaging is validated for Apple Silicon Macs.

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
- status copy for plugged-in protection, battery sleep allowed, and policy/system drift

## Helper And Plist Linting

```bash
.build/debug/LidSwitch --print-helper | zsh -n /dev/stdin
.build/debug/LidSwitch --print-install-script | zsh -n /dev/stdin
.build/debug/LidSwitch --print-uninstall-script | zsh -n /dev/stdin
.build/debug/LidSwitch --print-plist | plutil -lint -
.build/debug/LidSwitch --print-helper-status
```

These checks validate generated artifacts without installing or modifying privileged system files.
The helper-status diagnostic reports whether launchd sees the helper and whether the installed helper/plist content matches the generated current artifacts.

## App Bundle Launch

```bash
./script/build_and_run.sh --verify
```

This builds the SwiftPM target, stages `dist/LidSwitch.app`, launches the app bundle, and confirms the process exists.
The verification checks that the running `LidSwitch` process is the staged bundle from this repo, not another process with the same name.

## Landing Page Validation

```bash
npm install
npm run site:check
npm run site:test
```

`site:check` verifies the static page contains the required manual-install,
open-source, privacy, and safety claims while rejecting common fake launch claims
such as fake stars, testimonials, Apple affiliation, analytics, or notarization
promises.

`site:test` runs Playwright against the static site across desktop, tablet, and
mobile projects. The tests cover:

- hero comprehension and primary CTAs
- manual Gatekeeper/Open Anyway disclosure
- safety and open-source trust claims
- product screenshot accessibility text, including the current primary toggle and battery opt-in labels
- keyboard focus order
- responsive overflow
- install and privacy documentation links

To validate a Vercel deployment instead of localhost:

```bash
SITE_BASE_URL=https://<deployment>.vercel.app npm run site:test
```

## DMG Packaging Dry Run

```bash
./script/build_dmg.sh --dry-run
```

The dry run confirms the unsigned manual DMG packaging path without launching the
app or writing release artifacts.

## Live Product Smoke

```bash
./script/validate_live_state.sh
```

This checks:

- `LidSwitch` process is running
- running `LidSwitch` binary path is this repo's staged app bundle
- LaunchDaemon is loaded
- helper executable exists
- helper version is current
- desired mode is `enabled`
- battery opt-in is disabled for the safe default smoke
- `SleepDisabled` matches the current power source and battery opt-in
- battery sleep profile is not overridden when battery opt-in is disabled
- menu bar item is exposed through Accessibility
- panel text includes the primary toggle, battery opt-in toggle, battery-safety copy, and enabled status
- battery-on-AC-only state is represented as sleep allowed instead of protected

This smoke expects the app to be installed and enabled. It is part of the JTBD done gate.

## JTBD Done Gate

```bash
./scripts/run-jtbd-gate.sh --plan
./scripts/run-jtbd-gate.sh
```

The native-app successful run used `full-release` and passed:

1. Swift build
2. Swift tests
3. Helper script syntax
4. Helper plist syntax
5. App bundle launch
6. Live menu bar power smoke

Public-launch profile adds:

1. Site static claim check
2. Site Playwright UI
3. DMG packaging dry run
4. Open-source secret scan

## Local Proof

```text
.jtbd-done-gate/reports/<timestamp>/report.md
```

Gate reports are ignored by git. Re-run the gate to regenerate current proof after cloning or changing the app.
