# Validation

## Automated, no-launch proof

```bash
swift build --scratch-path /tmp/lidswitch-build
swift test --scratch-path /tmp/lidswitch-build
./script/validate_session_safety.sh
./script/validate_bundle.sh
./script/validate_dmg.sh
```

These checks never start the GUI, install the helper, invoke administrator authorization, or change power settings.

The `SessionSafetyTests` suite covers:

- explicit current-session acknowledgement;
- acknowledgement just inside and outside the bounded start timeout;
- more than 30 simulated seconds of full-inspection delay with at least four independent renewals;
- monotonic lease-expiry and atomic commit-boundary rejection;
- stale acknowledgement rejection;
- lease expiry, excessive lifetime, and reboot mismatch;
- unplug restoration and no rearm;
- helper terminal-generation replay rejection after unplug and blocked preflight;
- helper and controller override/status drift termination;
- one owned SleepDisabled-only drift recovery with the same session UUID, fresh
  recovery acknowledgement, bounded diagnostics, and no AC-sleep overwrite;
- a second owned SleepDisabled drift terminalizing without rearm;
- transient unreadable override probes retrying into healthy state without
  spending recovery budget, unreadable-to-explicit-drift following the normal
  recovery path, and repeated unreadability still failing closed;
- helper-ended UI remaining in a restoring state during delayed rollback,
  clearing stale errors after bounded safe-idle proof, and retaining an
  actionable error when the 30-second verification result is still unsafe;
- helper restart after a reserved recovery failing closed, restart after a spent
  recovery retaining the budget, and a new UUID receiving a fresh budget;
- application-owned native Start, Remove Helper, and Quit confirmations: exact
  one affirmative action, cancel/Escape no action, duplicate presentation guard,
  immediate starting state, and fresh-precondition rejection with protection off;
- AC eligibility is independent of display topology, including a single external
  HDMI display in clamshell mode; only the qualified AC/helper/lease contract
  controls session start.
- bounded, structured, owner-only diagnostic history;
- abnormal helper recovery;
- restoration failure retaining applied-state;
- malformed, writable, duplicate, unknown, and symlinked input;
- unknown power and `SleepDisabled` failing closed;
- stale zero baseline rejection;
- crash-only launchd recovery with no polling interval.

Generated admin scripts are linted by both `zsh -n` and `sh -n`; the daemon plist is checked with `plutil`.

## Gate profiles

`native-macos` and `full-release` use simulations plus no-launch artifact validation. They do not include a live power smoke.

The controlled live canary is an explicit manual deployment command, intentionally excluded from every automatic done-gate profile. It requires `LIDSWITCH_CONTROLLED_CANARY=1`. Run it only after the automatic full-release profile passes, on qualified build `25F84`, AC power, lid open, and a manually confirmed active session:

```bash
LIDSWITCH_CONTROLLED_CANARY=1 ./script/validate_live_state.sh
```

The script observes at least 40 seconds of fresh acknowledgements (`LIDSWITCH_LIVE_OBSERVATION_SECONDS`, minimum `40`), sends `SIGKILL` to the app, waits up to 45 seconds for verified restoration, and proves there is no automatic rearm. A later human-observed unplug/replug and short lid-close test completes local deployment qualification.

To exercise the candidate's same-session recovery path, add the separate
`LIDSWITCH_INJECT_OVERRIDE_DRIFT=1` opt-in. It first verifies the helper owns a
current AC session, invokes only `sudo pmset -a disablesleep 0`, and waits at
most 10 seconds for `SleepDisabled=1`, AC sleep `0`, a fresh `active`
`override-recovered` status, and the unchanged session UUID. It never edits
root state files. Do not run this on a production session unless the explicit
canary is intended.

## Public surface

```bash
npm run validate:site
npm run public:hygiene
npm run scan:secrets:test
node scripts/scan-public-secrets.mjs
```
