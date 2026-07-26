#!/usr/bin/python3
"""Freeze one hosted candidate proof tree under a closed inventory ledger."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
from pathlib import Path

MAX = 1024 * 1024 * 1024
SCHEMA = "lidswitch-hosted-evidence-v2"

# The ledger must name every retained leaf, not just a convenient subset of
# cross-links.  Keeping this as a closed identity map makes omissions and
# additions independently visible in the immutable evidence receipt.
EXPECTED_BINDINGS = {
    "orchestration/workflow.yml", "orchestration/bootstrap.py", "orchestration/policy.json",
    "orchestration/collector.py", "orchestration/verifier.py", "receipts/prepare.json",
    "receipts/build.json", "authority/ledger.json", "authority/entry.py",
    "authority/contract.json", "authority/live-envelope.json",
    "authority/live-state-retained.receipt", "authority/preflight-state.snapshot",
    "authority/postflight-state.snapshot", "workflow-context.json",
    "source/source_snapshot_manifest.jsonl", "source/release.env", "package/build-envelope.json",
    "packaging/capture_immutable_build_envelope.py",
    "packaging/assemble_manual_adhoc_candidate.py",
    "packaging/immutable_candidate_core.py", "packaging/build_immutable_candidate.py",
    "packaging/package_immutable_candidate.py", "packaging/validate_immutable_candidate.py",
    "packaging/validate_immutable_dmg.py", "packaging/LidSwitchReleaseIdentity.json",
    "candidate/candidate-manifest.json", "candidate/package-manifest.json",
    "candidate/LidSwitch.dmg", "candidate/LidSwitch.dmg.sha256", "candidate/LidSwitchHelper",
    "release-output/LidSwitch", "release-output/LidSwitchHelper",
    "release-output/build-receipt.json",
    "release-output/GeneratedReleaseHelperTrustAnchor.generated.swift",
}


def canon(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode() + b"\n"


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb", buffering=0) as handle:
        for block in iter(lambda: handle.read(131072), b""):
            value.update(block)
    return value.hexdigest()


def regular(path: Path) -> dict[str, object]:
    info = os.lstat(path)
    if path.is_symlink() or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or not 0 < info.st_size <= MAX:
        raise ValueError("unsafe evidence leaf: " + str(path))
    result = {"sha256": digest(path), "size": info.st_size, "mode": stat.S_IMODE(info.st_mode), "nlink": info.st_nlink}
    after = os.lstat(path)
    if (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
        raise ValueError("drift evidence leaf: " + str(path))
    return result


def copy_leaf(source: Path, target: Path, files: dict[str, object], rel: str) -> None:
    observed = regular(source)
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    os.chmod(target, 0o400)
    copied = regular(target)
    if copied["sha256"] != observed["sha256"] or copied["size"] != observed["size"]:
        raise ValueError("evidence copy mismatch: " + rel)
    files[rel] = copied


def main() -> int:
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--orchestration", type=Path, required=True)
    parser.add_argument("--authority", type=Path, required=True)
    parser.add_argument("--package-parent", type=Path, required=True)
    parser.add_argument("--candidate-root", type=Path, required=True)
    parser.add_argument("--release-output", type=Path, required=True)
    parser.add_argument("--workflow-context", type=Path, required=True)
    parser.add_argument("--prepare-receipt", type=Path, required=True)
    parser.add_argument("--build-receipt", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists() or args.output.is_symlink():
        raise SystemExit("evidence output already exists")
    args.output.mkdir(mode=0o700)
    files: dict[str, object] = {}
    wanted = [
        (args.orchestration / ".github/workflows/hosted-immutable-candidate.yml", "orchestration/workflow.yml"),
        (args.orchestration / "orchestration/hosted_held_bootstrap.py", "orchestration/bootstrap.py"),
        (args.orchestration / "orchestration/hosted-runner-policy.json", "orchestration/policy.json"),
        (args.orchestration / "orchestration/collect_hosted_candidate_evidence.py", "orchestration/collector.py"),
        (args.orchestration / "orchestration/verify_hosted_candidate_evidence.py", "orchestration/verifier.py"),
        (args.prepare_receipt, "receipts/prepare.json"),
        (args.build_receipt, "receipts/build.json"),
        (args.authority / "hosted-authority-ledger.json", "authority/ledger.json"),
        (args.authority / "hosted-held-entry.py", "authority/entry.py"),
        (args.authority / "hosted-held-contract.json", "authority/contract.json"),
        (args.authority / "hosted-live-envelope.json", "authority/live-envelope.json"),
        (args.authority / "live-state-retained.receipt", "authority/live-state-retained.receipt"),
        (args.authority / "preflight-state.snapshot", "authority/preflight-state.snapshot"),
        (args.authority / "postflight-state.snapshot", "authority/postflight-state.snapshot"),
        (args.package_parent / "build-envelope.json", "package/build-envelope.json"),
        (args.workflow_context, "workflow-context.json"),
        (args.source / "script/source_snapshot_manifest.jsonl", "source/source_snapshot_manifest.jsonl"),
        (args.source / "script/release.env", "source/release.env"),
    ]
    for relative in ("capture_immutable_build_envelope.py", "assemble_manual_adhoc_candidate.py", "immutable_candidate_core.py", "build_immutable_candidate.py", "package_immutable_candidate.py", "validate_immutable_candidate.py", "validate_immutable_dmg.py"):
        wanted.append((args.package_parent / "held-packaging/script" / relative, "packaging/" + relative))
    # The release identity is consumed by the held assembler.  Retain its
    # exact copied leaf so the verifier can bind the release-output identity
    # claim to the descriptor that authorized it.
    wanted.append((args.package_parent / "held-packaging/Resources/LidSwitchReleaseIdentity.json", "packaging/LidSwitchReleaseIdentity.json"))
    for name in ("candidate-manifest.json", "package-manifest.json", "LidSwitch.dmg", "LidSwitch.dmg.sha256", "LidSwitchHelper"):
        wanted.append((args.candidate_root / name, "candidate/" + name))
    for name in ("LidSwitch", "LidSwitchHelper", "build-receipt.json", "GeneratedReleaseHelperTrustAnchor.generated.swift"):
        wanted.append((args.release_output / name, "release-output/" + name))
    for source, relative in wanted:
        copy_leaf(source, args.output / relative, files, relative)
    if set(files) != EXPECTED_BINDINGS:
        raise ValueError("unexpected hosted evidence inventory")
    ledger = {"schema": SCHEMA, "files": files,
              "inventory": sorted(files),
              "bindings": {relative: relative for relative in sorted(EXPECTED_BINDINGS)}}
    payload = canon(ledger)
    ledger_path = args.output / "evidence-tree.json"
    ledger_path.write_bytes(payload)
    os.chmod(ledger_path, 0o400)
    print(json.dumps({"evidence_tree_sha256": hashlib.sha256(payload).hexdigest(), "output": str(args.output)}, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
