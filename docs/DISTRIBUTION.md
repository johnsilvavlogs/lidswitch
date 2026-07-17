# Distribution

## Release status

LidSwitch `0.2.12` build `7` is the current public manual release. It passed the
held build, immutable package, transactional install, real menu-bar start/stop,
and controlled app-death rollback gates before publication. Tag `v0.2.12`
points to source commit `57d44b5bd566fd768a12705f2778fbb2d2f45375`;
its only published asset is `LidSwitch.dmg`, whose SHA-256 is
`0c2d03cafc88ee8d947b4f3551e72e046ce50955fb2946eb56bc8b344669dc00`.

The release tier is a public manual DMG with ad-hoc signing, no Developer ID
signature, and no notarization; recipients use Gatekeeper’s **Open Anyway**
flow. Do not claim App Store distribution, Apple notarization, automatic
background protection, battery support, or compatibility beyond qualified
build `25F84`.

## Local zero-cost immutable candidate path

The release owner first performs the held `release-candidate` build. It then
captures the sealed source manifest, held wrapper, selected local Swift binary,
and the frozen held `release-output` directory into a create-once envelope
receipt. The release output must contain exactly the generated trust anchor,
`LidSwitch`, pre-signed `LidSwitchHelper`, and canonical build receipt:

```bash
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

The assembler has no compiler or network authority. It uses only the local
system `codesign` ad-hoc identity (`-`), `hdiutil`, `ditto`, and `shasum`; it
does not call `xcodebuild`, require an Apple account, Developer ID/Team ID,
notarization, paid CI, or any paid service. It rejects substituted or stale
release-output bytes/receipt data by exact inventory, mode, hash, size,
identifier, and helper CDHash checks. It creates a fresh private root, copies
only the bound prebuilt binaries, signs the outer app once (the helper remains
pre-signed), makes one DMG, extracts it, and invokes the immutable build/package manifest
publishers plus their descriptor validation. Legacy `build_dmg.sh` and
`validate_dmg.sh` are intentionally still fail-closed.

## Validation boundary

The published release was produced through the held build and immutable
packaging path above, installed transactionally, and accepted only after the
controlled native canary proved active ownership, peer-process-invalid
rollback, `SleepDisabled=0`, and no automatic rearm. The release asset and the
`releases/latest/download/LidSwitch.dmg` response were downloaded independently
and matched the published digest above.

Public hygiene is available only as an **observational source scan**:

```bash
/usr/bin/python3 -I -S scripts/scan-public-secrets.py --path <tree>
```

It uses descriptor-relative, no-follow traversal, nonblocking regular-file opens, bounded reads, capped findings, and a bounded identity-and-digest second pass. Its typed receipts are exact per-file observations, but a moving-tree result is not an immutable snapshot and is never release-candidate proof. `--release-artifacts` deliberately returns `immutable-candidate-manifest-required` before opening any input. `validate_dmg.sh` remains an inert typed nonzero refusal; use the immutable assembler above only after the held build has completed.

Receipt roots contain an ordinal plus a hash of the encoded input root; paths requiring escaping are hashed. Do not invoke the scanner without the exact `-I -S` startup flags.
