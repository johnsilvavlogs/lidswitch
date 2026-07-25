#!/usr/bin/python3
"""Fail-closed verifier for one extracted hosted immutable-candidate tree."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import types
from pathlib import Path

SCHEMA = "lidswitch-hosted-evidence-v2"
# This is the immutable_candidate_core.py blob in the independently pinned
# source commit 6200836.  Do not execute an evidence supplied Python program
# unless it is this exact reviewed byte sequence.
AUTHORITATIVE_CORE_SHA256 = "045c46f5fe7ab917d4e700fb4fbc10dbc125247b9eb14e8f8e6500037de14f32"
SOURCE_COMMIT = "6200836869591acb4bf65edb825eb62e84b56f87"
SOURCE_TREE = "d86650eccfe3326fc968fc855a07a1e3d06aaf57"
PACKAGING_ROLES = {
    "capture_package": "capture_immutable_build_envelope.py",
    "assemble_package": "assemble_manual_adhoc_candidate.py",
    "candidate_core": "immutable_candidate_core.py",
    "build_manifest": "build_immutable_candidate.py",
    "package_manifest": "package_immutable_candidate.py",
    "validate_candidate": "validate_immutable_candidate.py",
    "validate_dmg": "validate_immutable_dmg.py",
}
FIXED_BINDINGS = {
    "source_manifest": "source/source_snapshot_manifest.jsonl",
    "authority_ledger": "authority/ledger.json",
    "contract": "authority/contract.json",
    "entry": "authority/entry.py",
    "live_receipt": "authority/live-state-retained.receipt",
    "preflight": "authority/preflight-state.snapshot",
    "postflight": "authority/postflight-state.snapshot",
    "workflow": "orchestration/workflow.yml",
    "context": "workflow-context.json",
    "prepare": "receipts/prepare.json",
    "build": "receipts/build.json",
}
REQUIRED = {
    "orchestration/workflow.yml", "orchestration/bootstrap.py", "orchestration/policy.json",
    "orchestration/collector.py", "orchestration/verifier.py", "receipts/prepare.json",
    "receipts/build.json", "authority/ledger.json", "authority/entry.py",
    "authority/contract.json", "authority/live-envelope.json",
    "authority/live-state-retained.receipt", "authority/preflight-state.snapshot",
    "authority/postflight-state.snapshot", "workflow-context.json",
    "source/source_snapshot_manifest.jsonl", "source/release.env", "package/build-envelope.json",
    *("packaging/" + name for name in PACKAGING_ROLES.values()),
    "candidate/candidate-manifest.json", "candidate/package-manifest.json", "candidate/LidSwitch.dmg",
    "candidate/LidSwitch.dmg.sha256", "candidate/LidSwitchHelper", "release-output/LidSwitch",
    "release-output/LidSwitchHelper", "release-output/build-receipt.json",
    "release-output/GeneratedReleaseHelperTrustAnchor.generated.swift",
}


def canon(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode("utf-8") + b"\n"


def sha_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb", buffering=0) as handle:
        for chunk in iter(lambda: handle.read(131072), b""):
            digest.update(chunk)
    return digest.hexdigest()


def deny(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def _pairs(pairs: list[tuple[object, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if not isinstance(key, str) or key in result:
            raise ValueError("invalid json object")
        result[key] = value
    return result


def _constant(_: str) -> object:
    raise ValueError("invalid json constant")


def load(path: Path) -> dict[str, object]:
    raw = path.read_bytes()
    try:
        value = json.loads(raw.decode("utf-8", "strict"), object_pairs_hook=_pairs,
                           parse_constant=_constant)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise ValueError("invalid json: " + str(path)) from error
    deny(isinstance(value, dict) and canon(value) == raw, "noncanonical json: " + str(path))
    return value


def exact(value: object, keys: tuple[str, ...], label: str) -> dict[str, object]:
    deny(isinstance(value, dict) and tuple(value) == keys, label + " schema mismatch")
    return value


def hexdigest(value: object, label: str = "digest") -> str:
    deny(isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value), label + " invalid")
    return value


def positive(value: object, label: str) -> int:
    deny(isinstance(value, int) and not isinstance(value, bool) and value > 0, label + " invalid")
    return value


def descriptor(value: object, *, path: str | None = None, label: str) -> dict[str, object]:
    item = exact(value, ("dev", "gid", "inode", "mode", "nlink", "path", "sha256", "size", "uid"), label)
    deny(isinstance(item["path"], str) and (path is None or item["path"] == path), label + " path mismatch")
    hexdigest(item["sha256"], label)
    for key in ("dev", "gid", "inode", "mode", "nlink", "size", "uid"):
        deny(isinstance(item[key], int) and not isinstance(item[key], bool) and item[key] >= 0, label + " descriptor invalid")
    deny(item["nlink"] == 1 and item["size"] > 0, label + " descriptor invalid")
    return item


def descriptor_matches(item: object, meta: dict[str, object], path: str, label: str) -> None:
    value = descriptor(item, path=path, label=label)
    deny(value["sha256"] == meta["sha256"] and value["size"] == meta["size"] and value["mode"] == meta["mode"], label + " byte binding mismatch")


def leaf_meta(root: Path, relative: str, expected: object) -> dict[str, object]:
    deny(isinstance(expected, dict) and tuple(expected) == ("mode", "nlink", "sha256", "size"), "ledger leaf schema mismatch")
    path = root / relative
    info = os.lstat(path)
    deny(not path.is_symlink() and stat.S_ISREG(info.st_mode), "unsafe evidence leaf: " + relative)
    deny(expected["nlink"] == info.st_nlink == 1 and expected["mode"] == stat.S_IMODE(info.st_mode)
         and expected["size"] == info.st_size and expected["sha256"] == sha(path), "evidence mismatch: " + relative)
    hexdigest(expected["sha256"], "ledger digest")
    positive(expected["size"], "ledger size")
    return expected


def trusted_core(root: Path, files: dict[str, object]):
    path = root / "packaging/immutable_candidate_core.py"
    payload = path.read_bytes()
    deny(sha_bytes(payload) == AUTHORITATIVE_CORE_SHA256 == files["packaging/immutable_candidate_core.py"]["sha256"], "unreviewed candidate core")
    module = types.ModuleType("hosted_immutable_candidate_core")
    module.__file__ = str(path)
    # The fixed blob only defines validation primitives; it has no CLI or
    # subprocess entry point.  Its hash was pinned before executing it.
    exec(compile(payload, str(path), "exec"), module.__dict__)
    return module


def candidate_order(value: dict[str, object]) -> dict[str, object]:
    """Restore the producer's typed order before invoking its exact validator.

    Candidate JSON is canonicalized with sorted keys on disk.  The pinned core
    intentionally uses insertion order as an additional typed-schema check, so
    its pure validator is invoked with the producer order after this verifier
    has already established canonical bytes.
    """
    def ordered(item: object, names: tuple[str, ...]) -> object:
        if not isinstance(item, dict):
            return item
        return {name: item[name] for name in names}
    artifact = ("role", "name", "sha256", "size", "mode", "uid", "gid", "tree_sha256", "signature_receipt")
    signed = artifact + ("identifier", "cdhash", "signing_profile", "team_id", "notarized")
    receipt = ("role", "name", "sha256", "tool_sha256", "subject_role", "subject_name", "subject_sha256", "subject_size", "source_commit", "candidate_binding", "previous_receipt", "strict", "exit")
    release = ordered(value["envelope"]["release_output"], ("seal_sha256", "build_receipt_sha256", "anchor_sha256", "anchor_size", "source_manifest_sha256", "release_identity_sha256", "app", "helper"))
    release["app"] = ordered(release["app"], ("identifier", "sha256", "size"))
    release["helper"] = ordered(release["helper"], ("cdhash", "identifier", "sha256", "signature", "size", "teamIdentifier", "timestamp"))
    envelope = ordered(value["envelope"], ("receipt_sha256", "wrapper_sha256", "source_tree_sha256", "toolchain_sha256", "release_output")); envelope["release_output"] = release
    package = ordered(value["package"], ("dmg", "checksum", "extraction_receipt", "extracted_tree_sha256"))
    for name in ("dmg", "checksum"):
        if package[name] is not None:
            package[name] = ordered(package[name], artifact)
    return {
        "schema_version": value["schema_version"], "candidate_id": value["candidate_id"], "phase": value["phase"],
        "envelope": envelope,
        "release_identity": ordered(value["release_identity"], ("name", "sha256", "signing_profile", "team_id", "notarized")),
        "source": ordered(value["source"], ("commit", "tree_sha256")),
        "helper": ordered(value["helper"], signed), "app": ordered(value["app"], signed), "package": package,
        "receipts": [ordered(item, receipt) for item in value["receipts"]],
    }


def source_manifest(root: Path, files: dict[str, object], policy: dict[str, object]) -> dict[str, dict[str, object]]:
    raw = (root / "source/source_snapshot_manifest.jsonl").read_bytes()
    deny(raw.endswith(b"\n") and raw and b"\r" not in raw, "source manifest invalid")
    rows: dict[str, dict[str, object]] = {}
    for line in raw[:-1].split(b"\n"):
        try:
            value = json.loads(line.decode("utf-8", "strict"), object_pairs_hook=_pairs, parse_constant=_constant)
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
            raise ValueError("source manifest invalid") from error
        deny(isinstance(value, dict) and canon(value).rstrip(b"\n") == line and value.get("schema") == "lidswitch-source-manifest-v1", "source manifest invalid")
        name = value.get("path")
        deny(isinstance(name, str) and name and name not in rows, "source manifest invalid")
        rows[name] = value
    deny(sha_bytes(raw) == policy["source_manifest_sha256"] == files["source/source_snapshot_manifest.jsonl"]["sha256"], "source manifest binding mismatch")
    wrapper = rows.get("script/run_swift_build_safely.sh")
    deny(isinstance(wrapper, dict) and wrapper.get("type") == "file" and wrapper.get("sha256") == policy["source"]["wrapper_sha256"], "source manifest wrapper missing")
    release = rows.get("script/release.env")
    deny(isinstance(release, dict) and release.get("sha256") == files["source/release.env"]["sha256"] and release.get("size") == files["source/release.env"]["size"], "release env source mismatch")
    return rows


def check_release_receipt(receipt: dict[str, object], files: dict[str, object]) -> None:
    receipt = exact(receipt, ("artifacts", "build", "captures", "inputs", "schema", "toolchain"), "release receipt")
    deny(receipt["schema"] == "lidswitch-held-release-build-v1", "release receipt schema mismatch")
    artifacts = exact(receipt["artifacts"], ("app", "helper"), "release receipt artifacts")
    app = exact(artifacts["app"], ("identifier", "sha256", "size"), "release app")
    helper = exact(artifacts["helper"], ("cdhash", "identifier", "sha256", "signature", "size", "teamIdentifier", "timestamp"), "release helper")
    deny(app["identifier"] == "com.johnsilva.LidSwitch" and helper["identifier"] == "com.johnsilva.lidswitch.helper", "release identifier mismatch")
    deny(app["sha256"] == files["release-output/LidSwitch"]["sha256"] and app["size"] == files["release-output/LidSwitch"]["size"], "release app binding mismatch")
    deny(helper["sha256"] == files["release-output/LidSwitchHelper"]["sha256"] and helper["size"] == files["release-output/LidSwitchHelper"]["size"], "release helper binding mismatch")
    deny(isinstance(helper["cdhash"], str) and len(helper["cdhash"]) == 40
         and all(c in "0123456789abcdef" for c in helper["cdhash"]), "release CDHash mismatch")
    deny(helper["signature"] == "adhoc" and helper["teamIdentifier"] is None and helper["timestamp"] is None, "release signing mismatch")
    deny(receipt["build"] == {"configuration": "release", "network": False, "paidLicenses": [], "releaseCandidateDefine": True, "signing": "manual-ad-hoc", "stages": ["helper", "app"]}, "release build mismatch")
    captures = receipt["captures"]
    inputs = receipt["inputs"]
    toolchain = receipt["toolchain"]
    deny(isinstance(captures, dict) and tuple(sorted(captures)) == ("app-bin-path", "app-build", "helper-bin-path", "helper-build", "helper-identity", "helper-sign", "helper-verify"), "release captures mismatch")
    deny(isinstance(inputs, dict) and tuple(inputs) == ("appSourceSeal", "baseManifestSHA256", "generatedAnchorSHA256", "helperSourceSeal", "releaseIdentitySHA256", "trustAnchorTemplateSHA256"), "release inputs mismatch")
    deny(isinstance(toolchain, dict) and tuple(toolchain) == ("componentSealSHA256", "driverIdentity", "profileSHA256", "root", "sdk"), "release toolchain mismatch")
    for value in captures.values():
        deny(isinstance(value, str) and len(value.split(":")) == 2 and all(len(part) == 64 and all(c in "0123456789abcdef" for c in part) for part in value.split(":")), "release capture mismatch")
    for value in list(inputs.values()) + [toolchain["componentSealSHA256"], toolchain["profileSHA256"]]:
        hexdigest(value, "release receipt digest")
    deny(inputs["generatedAnchorSHA256"] == files["release-output/GeneratedReleaseHelperTrustAnchor.generated.swift"]["sha256"], "anchor binding mismatch")
    deny(toolchain["root"] == "/Library/Developer/CommandLineTools" and isinstance(toolchain["sdk"], str) and toolchain["sdk"].startswith(toolchain["root"] + "/SDKs/") and isinstance(toolchain["driverIdentity"], str) and toolchain["driverIdentity"].endswith(":swift-frontend"), "release toolchain mismatch")


def main() -> int:
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("--evidence", type=Path, required=True)
    root = parser.parse_args().evidence.resolve(strict=True)
    deny(not root.is_symlink() and root.is_dir(), "unsafe evidence root")
    ledger = load(root / "evidence-tree.json")
    exact(ledger, ("bindings", "files", "inventory", "schema"), "evidence ledger")
    deny(ledger["schema"] == SCHEMA, "invalid evidence ledger")
    files = ledger["files"]
    deny(isinstance(files, dict) and set(files) == REQUIRED and ledger["inventory"] == sorted(files), "missing or extra declared evidence leaf")
    deny(ledger["bindings"] == FIXED_BINDINGS, "invalid evidence bindings")
    actual = set()
    for path in root.rglob("*"):
        deny(not path.is_symlink(), "symlink in evidence tree")
        if path.is_file():
            actual.add(str(path.relative_to(root)))
    deny(actual == set(files) | {"evidence-tree.json"}, "missing or extra evidence leaf")
    for relative, expected in files.items():
        deny(isinstance(relative, str) and relative in ledger["inventory"] and not relative.startswith("/") and ".." not in relative.split("/"), "unsafe ledger path")
        leaf_meta(root, relative, expected)

    core = trusted_core(root, files)
    policy = load(root / "orchestration/policy.json")
    exact(policy, ("runner", "schema", "source", "source_manifest_sha256", "toolchain"), "policy")
    deny(policy["schema"] == "lidswitch-hosted-runner-policy-v1", "policy schema mismatch")
    source = exact(policy["source"], ("commit", "tree", "wrapper_sha256"), "policy source")
    deny(source["commit"] == SOURCE_COMMIT and source["tree"] == SOURCE_TREE, "policy source mismatch")
    hexdigest(source["wrapper_sha256"], "policy wrapper")
    hexdigest(policy["source_manifest_sha256"], "policy manifest")
    source_manifest(root, files, policy)

    authority = load(root / "authority/ledger.json")
    exact(authority, ("generated", "policy", "schema", "source", "system", "wrapper_sha256"), "authority ledger")
    deny(authority["schema"] == "lidswitch-hosted-authority-ledger-v1", "authority schema mismatch")
    descriptor_matches(authority["policy"], files["orchestration/policy.json"], "hosted-runner-policy.json", "authority policy")
    authority_source = exact(authority["source"], ("commit", "manifest_descriptor", "manifest_sha256", "root", "tree"), "authority source")
    deny(authority_source["commit"] == SOURCE_COMMIT and authority_source["tree"] == SOURCE_TREE and authority_source["manifest_sha256"] == policy["source_manifest_sha256"], "authority source mismatch")
    descriptor_matches(authority_source["manifest_descriptor"], files["source/source_snapshot_manifest.jsonl"], "script/source_snapshot_manifest.jsonl", "source manifest descriptor")
    generated = exact(authority["generated"], ("contract", "entry", "root"), "authority generated")
    descriptor_matches(generated["entry"], files["authority/entry.py"], "hosted-held-entry.py", "authority entry")
    descriptor_matches(generated["contract"], files["authority/contract.json"], "hosted-held-contract.json", "authority contract")
    contract = load(root / "authority/contract.json")
    exact(contract, ("bash", "directories", "fd_map", "roles", "schema", "source_manifest"), "authority contract")
    deny(contract["schema"] == "lidswitch-hosted-held-contract-v1" and contract["source_manifest"] == policy["source_manifest_sha256"], "authority contract mismatch")
    deny(isinstance(contract["roles"], dict) and set(PACKAGING_ROLES) | {"wrapper", "common", "envelope", "profile", "safe_file", "supervisor", "source_manifest", "release_identity", "icon"} == set(contract["roles"]), "authority role set mismatch")
    for role, name in PACKAGING_ROLES.items():
        descriptor_matches(contract["roles"][role], files["packaging/" + name], "script/" + name, "packaging closure")
    deny(contract["roles"]["wrapper"]["sha256"] == source["wrapper_sha256"], "wrapper cross-binding mismatch")
    deny(isinstance(authority["system"], dict) and set(authority["system"]) == {"python", "bash", "swift_frontend", "sdk_root", "developer_dir"}, "authority system mismatch")
    system = authority["system"]
    descriptor(system["python"], path="/usr/bin/python3", label="authority python")
    descriptor(system["bash"], path="/bin/bash", label="authority bash")
    swift = descriptor(system["swift_frontend"], path="/Library/Developer/CommandLineTools/usr/bin/swift-frontend", label="authority swift")
    deny(exact(system["sdk_root"], ("dev", "gid", "inode", "mode", "nlink", "uid"), "authority sdk root")["nlink"] >= 2 and system["developer_dir"] == policy["toolchain"]["developer_dir"], "authority toolchain mismatch")

    prepare = load(root / "receipts/prepare.json")
    build = load(root / "receipts/build.json")
    exact(prepare, ("authority", "contract", "entry", "ledger", "schema", "source_manifest_sha256"), "prepare receipt")
    deny(prepare["schema"] == "lidswitch-hosted-prepare-v2" and prepare["source_manifest_sha256"] == policy["source_manifest_sha256"], "prepare receipt mismatch")
    for name, relative, path in (("ledger", "authority/ledger.json", "hosted-authority-ledger.json"), ("entry", "authority/entry.py", "hosted-held-entry.py"), ("contract", "authority/contract.json", "hosted-held-contract.json")):
        descriptor_matches(prepare[name], files[relative], path, "prepare binding")
    exact(build, ("contract", "entry", "generated", "ledger", "release_output", "retained", "schema", "source"), "build receipt")
    deny(build["schema"] == "lidswitch-hosted-build-v2" and build["source"] == authority["source"] and build["generated"] == authority["generated"], "build authority mismatch")
    for name, relative, path in (("ledger", "authority/ledger.json", "hosted-authority-ledger.json"), ("entry", "authority/entry.py", "hosted-held-entry.py"), ("contract", "authority/contract.json", "hosted-held-contract.json")):
        descriptor_matches(build[name], files[relative], path, "build binding")
    retained_map = {"live-state-retained.receipt": "authority/live-state-retained.receipt", "preflight-state.snapshot": "authority/preflight-state.snapshot", "postflight-state.snapshot": "authority/postflight-state.snapshot", "hosted-live-envelope.json": "authority/live-envelope.json"}
    deny(isinstance(build["retained"], dict) and set(build["retained"]) == set(retained_map), "build retained mismatch")
    for name, relative in retained_map.items():
        descriptor_matches(build["retained"][name], files[relative], name, "retained binding")
    fields = dict(line.split("=", 1) for line in (root / "authority/live-state-retained.receipt").read_text("utf-8").splitlines() if "=" in line)
    deny(fields.get("terminal") == "idle-uninstalled" and fields.get("kernel") == policy["runner"]["kernel"] and fields.get("child_command_exit") == "0" and fields.get("wrapper_exit") == "0" and fields.get("outcome") == "preserved", "terminal receipt invalid")
    for snapshot in ("preflight", "postflight"):
        values = dict(line.split("=", 1) for line in (root / ("authority/" + snapshot + "-state.snapshot")).read_text("utf-8").splitlines() if "=" in line)
        deny(values.get("host_class") == "idle-uninstalled" and values.get("kernel_build") == policy["runner"]["kernel"], "snapshot terminal state invalid")
    live = load(root / "authority/live-envelope.json")
    exact(live, ("postflight_sha256", "preflight_sha256", "receipt_sha256"), "live envelope")
    deny(live["receipt_sha256"] == files["authority/live-state-retained.receipt"]["sha256"] and live["preflight_sha256"] == fields.get("preflight_sha256") == files["authority/preflight-state.snapshot"]["sha256"] and live["postflight_sha256"] == fields.get("postflight_sha256") == files["authority/postflight-state.snapshot"]["sha256"], "live envelope binding mismatch")

    context = load(root / "workflow-context.json")
    exact(context, ("candidate_root", "driver_sha256", "image_version", "orchestration_commit_sha", "package_parent", "policy_sha256", "release_output", "reviewed_orchestration_sha", "run_attempt", "run_id", "schema", "sdk_version", "source_commit", "source_tree", "workflow_file_sha256", "workflow_ref"), "workflow context")
    deny(context["schema"] == "lidswitch-hosted-workflow-context-v2" and context["source_commit"] == SOURCE_COMMIT and context["source_tree"] == SOURCE_TREE and context["workflow_ref"] == "refs/heads/main" and context["orchestration_commit_sha"] == context["reviewed_orchestration_sha"] and context["policy_sha256"] == files["orchestration/policy.json"]["sha256"] and context["workflow_file_sha256"] == files["orchestration/workflow.yml"]["sha256"] and context["image_version"] == policy["runner"]["image_version"], "workflow context mismatch")
    hexdigest(context["driver_sha256"], "workflow driver")
    deny(all(isinstance(context[key], str) and context[key] for key in ("run_id", "run_attempt", "release_output", "package_parent", "candidate_root", "sdk_version")), "workflow context invalid")
    deny(swift["sha256"] == context["driver_sha256"], "authority/context toolchain mismatch")

    envelope = load(root / "package/build-envelope.json")
    exact(envelope, ("environment", "executables", "release_output", "schema_version", "source_commit", "source_tree_sha256", "toolchain_sha256", "wrapper_sha256"), "build envelope")
    deny(envelope["schema_version"] == core.ENVELOPE_SCHEMA and envelope["source_commit"] == SOURCE_COMMIT and envelope["source_tree_sha256"] == policy["source_manifest_sha256"] and envelope["wrapper_sha256"] == source["wrapper_sha256"] and envelope["toolchain_sha256"] == context["driver_sha256"], "build envelope mismatch")
    deny(envelope["environment"] == {"locale": "C", "timezone": "UTC", "path": "/usr/bin:/bin:/usr/sbin:/sbin"}, "build envelope environment mismatch")
    deny(isinstance(envelope["executables"], list) and 1 <= len(envelope["executables"]) <= 16, "build envelope executable mismatch")
    roles = set()
    for executable in envelope["executables"]:
        exact(executable, ("path", "role", "sha256"), "build executable")
        deny(isinstance(executable["role"], str) and executable["role"] not in roles and isinstance(executable["path"], str), "build executable mismatch")
        roles.add(executable["role"]); hexdigest(executable["sha256"], "executable digest")
    release = exact(envelope["release_output"], ("anchor_sha256", "anchor_size", "app", "build_receipt_sha256", "helper", "release_identity_sha256", "seal_sha256", "source_manifest_sha256"), "release output")
    release_receipt = load(root / "release-output/build-receipt.json")
    check_release_receipt(release_receipt, files)
    deny(release["build_receipt_sha256"] == files["release-output/build-receipt.json"]["sha256"] and release["anchor_sha256"] == files["release-output/GeneratedReleaseHelperTrustAnchor.generated.swift"]["sha256"] and release["anchor_size"] == files["release-output/GeneratedReleaseHelperTrustAnchor.generated.swift"]["size"] and release["source_manifest_sha256"] == policy["source_manifest_sha256"] and release["app"] == release_receipt["artifacts"]["app"] and release["helper"] == release_receipt["artifacts"]["helper"] and release["release_identity_sha256"] == release_receipt["inputs"]["releaseIdentitySHA256"], "release output binding mismatch")
    for key in ("anchor_sha256", "build_receipt_sha256", "release_identity_sha256", "seal_sha256", "source_manifest_sha256"):
        hexdigest(release[key], "release digest")

    candidate = load(root / "candidate/candidate-manifest.json")
    packaged = load(root / "candidate/package-manifest.json")
    candidate_keys = {"schema_version", "candidate_id", "phase", "envelope", "release_identity", "source", "helper", "app", "package", "receipts"}
    deny(set(candidate) == candidate_keys and set(packaged) == candidate_keys, "candidate manifest schema mismatch")
    envelope_sha = files["package/build-envelope.json"]["sha256"]
    try:
        core.validate_manifest(candidate_order(candidate), envelope, envelope_sha)
        core.validate_manifest(candidate_order(packaged), envelope, envelope_sha)
    except (core.CandidateError, KeyError, TypeError, ValueError) as error:
        raise ValueError("candidate manifest invalid: " + str(error)) from error
    deny(candidate["phase"] == "app-captured" and packaged["phase"] == "package-captured" and candidate["receipts"] == packaged["receipts"][:6], "candidate phase/receipt mismatch")
    deny(len(packaged["receipts"]) == 9 and tuple(item["role"] for item in packaged["receipts"]) == core.PHASES["package-captured"], "candidate receipt order mismatch")
    binding = core.candidate_binding(candidate_order(packaged))
    previous = "0" * 64
    for item in candidate_order(packaged)["receipts"]:
        deny(item["candidate_binding"] == binding and item["source_commit"] == SOURCE_COMMIT and item["previous_receipt"] == previous and item["sha256"] == sha_bytes(core.canonical_receipt_payload(item)), "candidate receipt chain mismatch")
        previous = item["sha256"]
    for manifest in (candidate, packaged):
        deny(manifest["source"]["commit"] == SOURCE_COMMIT and manifest["source"]["tree_sha256"] == policy["source_manifest_sha256"] and manifest["release_identity"]["signing_profile"] == "manual-adhoc" and manifest["release_identity"]["team_id"] is None and manifest["release_identity"]["notarized"] is False and manifest["release_identity"]["sha256"] == release["release_identity_sha256"], "candidate identity mismatch")
        helper = manifest["helper"]
        deny(helper["sha256"] == files["candidate/LidSwitchHelper"]["sha256"] == files["release-output/LidSwitchHelper"]["sha256"] and helper["size"] == files["candidate/LidSwitchHelper"]["size"] == files["release-output/LidSwitchHelper"]["size"] and helper["identifier"] == release_receipt["artifacts"]["helper"]["identifier"] and helper["cdhash"] == release_receipt["artifacts"]["helper"]["cdhash"], "candidate helper mismatch")
        deny(manifest["app"]["identifier"] == release_receipt["artifacts"]["app"]["identifier"] and manifest["app"]["signing_profile"] == "manual-adhoc" and manifest["app"]["team_id"] is None and manifest["app"]["notarized"] is False, "candidate app signing mismatch")
    deny(packaged["package"]["dmg"]["sha256"] == files["candidate/LidSwitch.dmg"]["sha256"] and packaged["package"]["dmg"]["size"] == files["candidate/LidSwitch.dmg"]["size"] and packaged["package"]["checksum"]["sha256"] == files["candidate/LidSwitch.dmg.sha256"]["sha256"] and packaged["package"]["checksum"]["size"] == files["candidate/LidSwitch.dmg.sha256"]["size"] and packaged["package"]["extracted_tree_sha256"] == packaged["app"]["tree_sha256"], "package artifact mismatch")
    checksum = (root / "candidate/LidSwitch.dmg.sha256").read_bytes()
    core.validate_checksum(checksum, packaged["package"]["dmg"]["name"], packaged["package"]["dmg"]["sha256"])
    print(json.dumps({"evidence_tree_sha256": sha(root / "evidence-tree.json"), "files_verified": len(files)}, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, UnicodeError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        raise SystemExit("hosted-evidence-denied: " + str(error))
