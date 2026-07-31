# Hosted immutable candidate authority

`hosted-immutable-candidate.yml` is intentionally an orchestration artifact,
not candidate source.  It checks out the workflow revision to `orchestration/`
and checks out `cc63481b6823e864fbe217a6182972474a6a8c8d` separately to
`source/`.  The latter must remain detached, clean, and at tree
`b31374650c7cd789c91ea53567a0e47112badb06` throughout the held build.

The workflow is manual only, has `contents: read`, uses no repository secrets
or caches, and fails before authority creation unless the runner is arm64,
`kern.osversion` is `25E246`, `ImageVersion` is `20260720.0258.1`, and the
Command Line Tools / macOS SDK locations match the reviewed policy.  The only
release build invocation is the descriptor-held wrapper whose byte digest is
`7b14608282edca96003effaf1c5c70426368aa7e4a32d5a3c9b6550032e3e260`.
The independently checked source-manifest byte digest is
`79b847db977783d725af0fa2226618d98161751759b0aa990eaa5b29b77502ee`.

The workflow uses only full-SHA official actions:

- `actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0` (v7.0.0)
- `actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02` (v4.6.2)

Two-phase governance is mandatory. First merge this manual-only workflow to
`main`; then independently review the exact resulting 40-hex main commit SHA.
Dispatch with `--ref main` and that SHA as `reviewed_orchestration_sha`. The
run rejects a non-main ref, another repository, a mismatched head/input, or a
non-clean orchestration checkout. This feature branch is not dispatchable.
The wrapper SHA-256 is `7b14608282edca96003effaf1c5c70426368aa7e4a32d5a3c9b6550032e3e260`;
the source-manifest SHA-256 is `79b847db977783d725af0fa2226618d98161751759b0aa990eaa5b29b77502ee`.

It uploads exactly one evidence tree.  That tree contains the source identity
and manifest, runner policy/context, system/role descriptors, generated held
entry and contract, live-envelope receipt binding, immutable build envelope,
candidate/package manifests, DMG, helper/app bytes, and SHA-256 ledger.  The
artifact action's digest is retained in the GitHub run summary; the immutable
tree digest is stored in `evidence-tree.json` inside the upload.

If a reviewed hosted runner omits the `SleepDisabled` row, the held entry—not
the workflow or packaging environment—sets the dedicated hosted authority
marker. The wrapper may then proceed only as an exact AC, idle-uninstalled host
with no status, launchd service, installed helper/app, root support/private
state, activation lease, or user history. Both retained snapshots must say
`sleep_disabled=absent` and carry the assertions proof
`pmset-assertions-system-prevent-system-sleep-0`; the evidence tree retains
and independently parses the matching preflight and postflight raw
`pmset -g assertions` leaves. Any row that is missing in a non-exceptional
state, duplicate, malformed, nonzero, or not system-wide fails closed.

## Deterministic local download and verification

After an independently accepted run, download only its named artifact into a
fresh empty directory, then verify every ledger-listed leaf.  This does not
install, mount, launch, or execute candidate bytes:

```bash
run_id=REVIEWED_RUN_ID
out="$(/usr/bin/mktemp -d /private/tmp/lidswitch-hosted-evidence.XXXXXX)"
gh run download "$run_id" --name "lidswitch-v0.2.14-build9-hosted-candidate-${run_id}-1" --dir "$out"
/usr/bin/python3 -I -S -B orchestration/verify_hosted_candidate_evidence.py --evidence "$out"
```

The downloaded `workflow-context.json` must identify the reviewed workflow
SHA/ref/run/attempt and runner image.  Compare GitHub's run-summary
`artifact-digest` to the API/UI before treating the evidence as retained.
Installation remains a later local validation step on 25F84; this workflow
has no install or runtime/root/power operation.
