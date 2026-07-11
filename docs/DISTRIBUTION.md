# Distribution

## Current channel

LidSwitch `0.2.7` build `1` is distributed as a public manual DMG. It is ad-hoc signed, not Developer ID signed, and not notarized. Recipients must expect Gatekeeper's **Open Anyway** flow.

Do not claim App Store distribution, Apple notarization, automatic background protection, battery support, or compatibility beyond qualified build `25F84`.

## Release checklist

1. Confirm the branch diff contains no unrelated user work.
2. Run the JTBD impact plan and `full-release` profile.
3. Confirm session simulations and the no-launch bundle/DMG checks are green.
4. Confirm the bundle reports app version `0.2.7`, build `1`, helper version `2`, arm64, and strict ad-hoc signature validity.
5. Confirm Gatekeeper rejection is expected and documented.
6. Run public hygiene, site Playwright, and secret scans.
7. Run the explicit local canary after automated gates, then the unplug/replug and short lid-close observations.
8. Publish `dist/LidSwitch.dmg` and `dist/LidSwitch.dmg.sha256` on GitHub Releases.
9. State the exact qualified macOS build and manual approval requirement in release notes.

Packaging commands:

```bash
./script/build_dmg.sh
./script/validate_dmg.sh
```

Neither command launches the app or changes live power state.
