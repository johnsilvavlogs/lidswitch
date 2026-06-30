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

This builds the SwiftPM target, stages `LidSwitch.app` under `${TMPDIR}/lidswitch-app`
by default, launches the app bundle, and confirms the process exists.
The verification checks that the running `LidSwitch` process is the staged bundle
from this repo, not another process with the same name.
Use `LIDSWITCH_APP_STAGE_ROOT` or `LIDSWITCH_APP_BUNDLE` to override the staging
path when needed.

## Landing Page Validation

```bash
npm install
npm run site:check
npm run site:test
```

`site:check` verifies the static page contains the required manual-install,
privacy, safety, and launch-status claims while rejecting common fake launch
claims such as fake stars, testimonials, Apple affiliation, analytics, or
notarization promises. It also checks that the primary CTA, numbered step
badges, and green eyebrow/accent text meet the WCAG AA 4.5:1 contrast threshold
for normal text.

`site:test` runs Playwright against the static site across desktop, tablet, and
mobile projects. The tests cover:

- hero comprehension and primary CTAs
- manual Gatekeeper/Open Anyway disclosure
- safety and launch-status trust claims
- product screenshot accessibility text, including the current primary toggle and battery opt-in labels
- keyboard focus order
- responsive overflow
- install and privacy documentation links

To validate a Vercel deployment instead of localhost:

```bash
SITE_BASE_URL=https://<deployment>.vercel.app npm run site:test
```

After the repository is public and the release is published, verify the anonymous
GitHub surface:

```bash
npm run launch:check-public
```

This confirms unauthenticated requests can see the repository, MIT license
metadata, the latest non-draft release, and the `LidSwitch.dmg` plus checksum
assets.

## DMG Packaging Dry Run

```bash
./script/build_dmg.sh --dry-run
```

The dry run confirms the unsigned manual DMG packaging path without launching the
app or writing release artifacts.

## DMG Artifact Validation

```bash
./script/validate_dmg.sh
```

This builds `dist/LidSwitch.dmg`, verifies `dist/LidSwitch.dmg.sha256`, mounts the
DMG, checks that the packaged `LidSwitch.app` has no extended attributes, runs
strict codesign verification on the mounted app, and confirms Gatekeeper rejects
the unsigned/not-notarized app so the manual approval flow remains explicit.

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

This smoke expects the app to be installed and enabled.

## Release Validation Checklist

```bash
swift build
swift test
npm install
npm run validate:site
npm run scan:secrets
./script/build_dmg.sh --dry-run
./script/validate_dmg.sh
npm run launch:check-public
```

For native-app changes, verify generated helper artifacts:

```bash
.build/debug/LidSwitch --print-helper | zsh -n /dev/stdin
.build/debug/LidSwitch --print-install-script | zsh -n /dev/stdin
.build/debug/LidSwitch --print-uninstall-script | zsh -n /dev/stdin
.build/debug/LidSwitch --print-plist | plutil -lint -
```

For installed-helper or power-policy changes, also run:

```bash
./script/build_and_run.sh --verify
./script/validate_live_state.sh
```

The release checklist should cover:

1. Swift build
2. Swift tests
3. Helper script syntax
4. Helper plist syntax
5. App bundle launch
6. Live menu bar power smoke
7. DMG artifact validation
8. Site static claim, contrast, icon, and link checks
9. Site Playwright UI tests
10. Open-source secret scan
11. Public GitHub release reachability after publishing
