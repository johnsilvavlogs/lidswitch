# Hosted immutable candidate authority

`hosted-immutable-candidate.yml` is intentionally an orchestration artifact,
not candidate source.  It checks out the workflow revision to `orchestration/`
and checks out `6200836869591acb4bf65edb825eb62e84b56f87` separately to
`source/`.  The latter must remain detached, clean, and at tree
`d86650eccfe3326fc968fc855a07a1e3d06aaf57` throughout the held build.

The workflow is manual only, has `contents: read`, uses no repository secrets
or caches, and fails before authority creation unless the runner is arm64,
`kern.osversion` is `25E246`, `ImageVersion` is `20260720.0258.1`, and the
Command Line Tools / macOS SDK locations match the reviewed policy.  The only
release build invocation is the descriptor-held wrapper whose source-manifest
digest is `7b14608282edca96003effaf1c5c70426368aa7e4a32d5a3c9b6550032e3e260`.

The workflow uses only full-SHA official actions:

- `actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0` (v7.0.0)
- `actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02` (v4.6.2)

It uploads exactly one evidence tree.  That tree contains the source identity
and manifest, runner policy/context, system/role descriptors, generated held
entry and contract, live-envelope receipt binding, immutable build envelope,
candidate/package manifests, DMG, helper/app bytes, and SHA-256 ledger.  The
artifact action's digest is retained in the GitHub run summary; the immutable
tree digest is stored in `evidence-tree.json` inside the upload.

## Deterministic local download and verification

After an independently accepted run, download only its named artifact into a
fresh empty directory, then verify every ledger-listed leaf.  This does not
install, mount, launch, or execute candidate bytes:

```bash
run_id=REVIEWED_RUN_ID
out="$(/usr/bin/mktemp -d /private/tmp/lidswitch-hosted-evidence.XXXXXX)"
gh run download "$run_id" --name "lidswitch-v0.2.13-build8-hosted-candidate-${run_id}-1" --dir "$out"
/usr/bin/python3 -I -S -B orchestration/verify_hosted_candidate_evidence.py --evidence "$out"
```

The downloaded `workflow-context.json` must identify the reviewed workflow
SHA/ref/run/attempt and runner image.  Compare GitHub's run-summary
`artifact-digest` to the API/UI before treating the evidence as retained.
Installation remains a later local validation step on 25F84; this workflow
has no install or runtime/root/power operation.
