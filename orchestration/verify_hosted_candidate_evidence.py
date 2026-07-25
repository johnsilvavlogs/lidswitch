#!/usr/bin/python3
"""Fail-closed verifier for an extracted hosted-candidate evidence tree."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
from pathlib import Path

SCHEMA = "lidswitch-hosted-evidence-v2"
REQUIRED = {"orchestration/workflow.yml", "orchestration/bootstrap.py", "orchestration/policy.json", "orchestration/collector.py", "orchestration/verifier.py", "receipts/prepare.json", "receipts/build.json", "authority/ledger.json", "authority/entry.py", "authority/contract.json", "authority/live-envelope.json", "authority/live-state-retained.receipt", "authority/preflight-state.snapshot", "authority/postflight-state.snapshot", "workflow-context.json", "source/source_snapshot_manifest.jsonl", "source/release.env", "package/build-envelope.json", "packaging/capture_immutable_build_envelope.py", "packaging/assemble_manual_adhoc_candidate.py", "packaging/immutable_candidate_core.py", "packaging/build_immutable_candidate.py", "packaging/package_immutable_candidate.py", "packaging/validate_immutable_candidate.py", "packaging/validate_immutable_dmg.py", "candidate/candidate-manifest.json", "candidate/package-manifest.json", "candidate/LidSwitch.dmg", "candidate/LidSwitch.dmg.sha256", "candidate/LidSwitchHelper", "release-output/LidSwitch", "release-output/LidSwitchHelper", "release-output/build-receipt.json", "release-output/GeneratedReleaseHelperTrustAnchor.generated.swift"}


def canon(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode() + b"\n"


def sha(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb", buffering=0) as handle:
        for block in iter(lambda: handle.read(131072), b""):
            value.update(block)
    return value.hexdigest()


def load(path: Path) -> object:
    raw = path.read_bytes()
    value = json.loads(raw.decode("utf-8"))
    if canon(value) != raw:
        raise ValueError("noncanonical json: " + str(path))
    return value


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def main() -> int:
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    root = args.evidence.resolve(strict=True)
    if root.is_symlink() or not root.is_dir():
        raise SystemExit("unsafe evidence root")
    ledger_path = root / "evidence-tree.json"
    ledger = load(ledger_path)
    require(isinstance(ledger, dict) and ledger.get("schema") == SCHEMA, "invalid evidence ledger")
    files = ledger.get("files")
    inventory = ledger.get("inventory")
    require(isinstance(files, dict) and files and isinstance(inventory, list) and inventory == sorted(files) and len(inventory) == len(set(inventory)), "empty or invalid ledger inventory")
    require(set(files) == REQUIRED, "missing or extra declared evidence leaf")
    bindings = ledger.get("bindings")
    require(isinstance(bindings, dict) and set(bindings.values()) <= set(files), "invalid evidence bindings")
    actual = set()
    for path in root.rglob("*"):
        if path.is_symlink():
            raise SystemExit("symlink in evidence tree")
        if path.is_file():
            actual.add(str(path.relative_to(root)))
    require(actual == set(files) | {"evidence-tree.json"}, "missing or extra evidence leaf")
    for relative, expected in files.items():
        require(isinstance(relative, str) and relative in inventory and not relative.startswith("/") and ".." not in relative.split("/"), "unsafe ledger path")
        path = root / relative
        info = os.lstat(path)
        require(isinstance(expected, dict) and not path.is_symlink() and stat.S_ISREG(info.st_mode) and info.st_nlink == expected.get("nlink") == 1 and stat.S_IMODE(info.st_mode) == expected.get("mode") and info.st_size == expected.get("size") and sha(path) == expected.get("sha256"), "evidence mismatch: " + relative)
    policy = load(root / "orchestration/policy.json")
    authority = load(root / "authority/ledger.json")
    contract = load(root / "authority/contract.json")
    context = load(root / "workflow-context.json")
    prepare = load(root / "receipts/prepare.json")
    build = load(root / "receipts/build.json")
    live = load(root / "authority/live-envelope.json")
    require(policy["source"]["commit"] == authority["source"]["commit"] == context["source_commit"], "source commit cross-binding mismatch")
    require(policy["source"]["tree"] == authority["source"]["tree"] == context["source_tree"], "source tree cross-binding mismatch")
    require(policy["source_manifest_sha256"] == authority["source"]["manifest_sha256"], "manifest cross-binding mismatch")
    require(authority["generated"]["entry"]["sha256"] == files["authority/entry.py"]["sha256"] and authority["generated"]["contract"]["sha256"] == files["authority/contract.json"]["sha256"], "authority byte cross-binding mismatch")
    require(contract["roles"]["wrapper"]["sha256"] == policy["source"]["wrapper_sha256"], "wrapper cross-binding mismatch")
    packaging_roles = {"capture_package": "capture_immutable_build_envelope.py", "assemble_package": "assemble_manual_adhoc_candidate.py", "candidate_core": "immutable_candidate_core.py", "build_manifest": "build_immutable_candidate.py", "package_manifest": "package_immutable_candidate.py", "validate_candidate": "validate_immutable_candidate.py", "validate_dmg": "validate_immutable_dmg.py"}
    for role, name in packaging_roles.items():
        require(contract["roles"][role]["sha256"] == files["packaging/" + name]["sha256"], "packaging closure cross-binding mismatch")
    expected_context = {"schema", "source_commit", "source_tree", "orchestration_commit_sha", "workflow_file_sha256", "workflow_ref", "reviewed_orchestration_sha", "run_id", "run_attempt", "image_version", "policy_sha256", "release_output", "package_parent", "candidate_root", "sdk_version", "driver_sha256"}
    require(set(context) == expected_context and context["schema"] == "lidswitch-hosted-workflow-context-v2", "workflow context schema mismatch")
    require(context["policy_sha256"] == files["orchestration/policy.json"]["sha256"] and context["workflow_file_sha256"] == files["orchestration/workflow.yml"]["sha256"] and context["orchestration_commit_sha"] == context["reviewed_orchestration_sha"] and context["workflow_ref"] == "refs/heads/main" and context["run_id"] and context["run_attempt"] and context["image_version"] == policy["runner"]["image_version"], "workflow context mismatch")
    require(prepare["ledger"]["sha256"] == files["authority/ledger.json"]["sha256"] and build["ledger"]["sha256"] == files["authority/ledger.json"]["sha256"], "prepare/build authority mismatch")
    for name, relative in (("live-state-retained.receipt", "authority/live-state-retained.receipt"), ("preflight-state.snapshot", "authority/preflight-state.snapshot"), ("postflight-state.snapshot", "authority/postflight-state.snapshot"), ("hosted-live-envelope.json", "authority/live-envelope.json")):
        require(build["retained"][name]["sha256"] == files[relative]["sha256"] and build["retained"][name]["size"] == files[relative]["size"], "held build retained binding mismatch")
    receipt = (root / "authority/live-state-retained.receipt").read_text("utf-8")
    fields = dict(line.split("=", 1) for line in receipt.splitlines() if "=" in line)
    require(fields.get("terminal") == "idle-uninstalled" and fields.get("kernel") == "25E246" and fields.get("child_command_exit") == "0" and fields.get("wrapper_exit") == "0" and fields.get("outcome") == "preserved", "terminal receipt invalid")
    require(fields.get("preflight_sha256") == files["authority/preflight-state.snapshot"]["sha256"] and fields.get("postflight_sha256") == files["authority/postflight-state.snapshot"]["sha256"], "snapshot receipt binding mismatch")
    for snapshot in ("authority/preflight-state.snapshot", "authority/postflight-state.snapshot"):
        state = dict(line.split("=", 1) for line in (root / snapshot).read_text("utf-8").splitlines() if "=" in line)
        require(state.get("host_class") == "idle-uninstalled" and state.get("kernel_build") == "25E246", "snapshot terminal state invalid")
    require(live["receipt_sha256"] == files["authority/live-state-retained.receipt"]["sha256"] and live["preflight_sha256"] == fields["preflight_sha256"] and live["postflight_sha256"] == fields["postflight_sha256"], "live-envelope binding mismatch")
    envelope = load(root / "package/build-envelope.json")
    release_receipt = load(root / "release-output/build-receipt.json")
    candidate_manifest = load(root / "candidate/candidate-manifest.json")
    package_manifest = load(root / "candidate/package-manifest.json")
    require(envelope.get("schema_version") == "lidswitch-verified-envelope-rev19" and envelope.get("source_commit") == context["source_commit"] and envelope.get("wrapper_sha256") == policy["source"]["wrapper_sha256"], "build envelope schema mismatch")
    release = envelope.get("release_output")
    require(isinstance(release, dict) and release.get("build_receipt_sha256") == files["release-output/build-receipt.json"]["sha256"] and release.get("anchor_sha256") == files["release-output/GeneratedReleaseHelperTrustAnchor.generated.swift"]["sha256"], "release envelope mismatch")
    require(release.get("app", {}).get("sha256") == files["release-output/LidSwitch"]["sha256"] and release.get("helper", {}).get("sha256") == files["release-output/LidSwitchHelper"]["sha256"], "release binary digest mismatch")
    require(release.get("app", {}).get("size") == files["release-output/LidSwitch"]["size"] and release.get("helper", {}).get("size") == files["release-output/LidSwitchHelper"]["size"] and isinstance(release.get("helper", {}).get("cdhash"), str) and len(release["helper"]["cdhash"]) == 40, "release identity mismatch")
    require(candidate_manifest.get("schema_version") == "lidswitch-immutable-candidate-v3" and package_manifest.get("schema_version") == "lidswitch-immutable-candidate-v3" and candidate_manifest.get("source", {}).get("commit") == context["source_commit"] and package_manifest.get("source", {}).get("commit") == context["source_commit"], "candidate manifest mismatch")
    require(candidate_manifest.get("envelope", {}).get("sha256") == files["package/build-envelope.json"]["sha256"] and package_manifest.get("envelope", {}).get("sha256") == files["package/build-envelope.json"]["sha256"], "manifest envelope mismatch")
    checksum = (root / "candidate/LidSwitch.dmg.sha256").read_text("utf-8").strip().split()[0]
    require(checksum == files["candidate/LidSwitch.dmg"]["sha256"], "dmg checksum mismatch")
    require(release_receipt.get("artifacts", {}).get("app", {}).get("sha256") == files["release-output/LidSwitch"]["sha256"] and release_receipt.get("artifacts", {}).get("helper", {}).get("sha256") == files["release-output/LidSwitchHelper"]["sha256"], "release receipt artifact mismatch")
    print(json.dumps({"evidence_tree_sha256": sha(ledger_path), "files_verified": len(files)}, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, UnicodeError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        raise SystemExit("hosted-evidence-denied: " + str(error))
