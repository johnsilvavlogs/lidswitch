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
- stale acknowledgement rejection;
- lease expiry, excessive lifetime, and reboot mismatch;
- unplug restoration and no rearm;
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

The script observes 10 seconds of fresh acknowledgements, sends `SIGKILL` to the app, waits up to 45 seconds for verified restoration, and proves there is no automatic rearm. A later human-observed unplug/replug and short lid-close test completes local deployment qualification.

## Public surface

```bash
npm run validate:site
npm run public:hygiene
npm run scan:secrets:test
node scripts/scan-public-secrets.mjs
```
