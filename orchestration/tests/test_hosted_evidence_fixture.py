import hashlib
import json
import os
import subprocess
import tempfile
import types
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VERIFY = ROOT / "orchestration/verify_hosted_candidate_evidence.py"
COMMIT = "6200836869591acb4bf65edb825eb62e84b56f87"


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode() + b"\n"


def digest(value):
    return hashlib.sha256(value).hexdigest()


def write(path, value, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        os.chmod(path, 0o600)
    path.write_bytes(canonical(value) if isinstance(value, dict) else value)
    os.chmod(path, mode)


def meta(path):
    info = path.stat()
    return {"sha256": digest(path.read_bytes()), "size": info.st_size, "mode": info.st_mode & 0o777, "nlink": 1}


def descriptor(path, source_path):
    info = path.stat()
    return {"path": source_path, "dev": 1, "inode": 1, "uid": info.st_uid, "gid": info.st_gid,
            "mode": info.st_mode & 0o777, "nlink": 1, "size": info.st_size,
            "sha256": digest(path.read_bytes())}


def directory_descriptor():
    return {"dev": 1, "inode": 1, "uid": 1, "gid": 1, "mode": 0o755, "nlink": 2}


def system_descriptor(path, sha256):
    return {"path": path, "dev": 1, "inode": 1, "uid": 0, "gid": 0, "mode": 0o555,
            "nlink": 1, "size": 1, "sha256": sha256}


def source_bytes(relative):
    return subprocess.check_output(["git", "show", COMMIT + ":" + relative], cwd=ROOT)


def core_module(payload):
    module = types.ModuleType("fixture_core")
    exec(compile(payload, "fixture_core.py", "exec"), module.__dict__)
    return module


class HostedEvidenceFixtureTests(unittest.TestCase):
    def make_fixture(self):
        required = sorted(__import__("runpy").run_path(str(VERIFY))["REQUIRED"])
        temp = tempfile.TemporaryDirectory()
        root = Path(temp.name)
        package_names = {
            "capture_package": "capture_immutable_build_envelope.py", "assemble_package": "assemble_manual_adhoc_candidate.py",
            "candidate_core": "immutable_candidate_core.py", "build_manifest": "build_immutable_candidate.py",
            "package_manifest": "package_immutable_candidate.py", "validate_candidate": "validate_immutable_candidate.py",
            "validate_dmg": "validate_immutable_dmg.py",
        }
        for role, name in package_names.items():
            write(root / "packaging" / name, source_bytes("script/" + name), 0o444)
        write(root / "packaging/LidSwitchReleaseIdentity.json", source_bytes("Resources/LidSwitchReleaseIdentity.json"), 0o444)
        core = core_module((root / "packaging/immutable_candidate_core.py").read_bytes())
        write(root / "source/source_snapshot_manifest.jsonl", source_bytes("script/source_snapshot_manifest.jsonl"), 0o444)
        write(root / "source/release.env", source_bytes("script/release.env"), 0o444)
        write(root / "orchestration/policy.json", (ROOT / "orchestration/hosted-runner-policy.json").read_bytes(), 0o444)
        write(root / "orchestration/workflow.yml", b"workflow", 0o444)
        write(root / "orchestration/bootstrap.py", b"bootstrap", 0o444)
        write(root / "orchestration/collector.py", b"collector", 0o444)
        write(root / "orchestration/verifier.py", b"verifier", 0o444)
        write(root / "authority/entry.py", b"entry", 0o500)
        roles = {"wrapper": {"path": "script/run_swift_build_safely.sh", "dev": 1, "inode": 1, "uid": 1, "gid": 1, "mode": 0o555, "nlink": 1, "size": 1, "sha256": json.loads((root / "orchestration/policy.json").read_text())["source"]["wrapper_sha256"]}}
        for role, name in package_names.items():
            roles[role] = descriptor(root / "packaging" / name, "script/" + name)
        for role in ("common", "envelope", "profile", "safe_file", "supervisor", "source_manifest", "release_identity", "icon"):
            roles[role] = {"path": "script/" + role, "dev": 1, "inode": 1, "uid": 1, "gid": 1, "mode": 0o444, "nlink": 1, "size": 1, "sha256": "1" * 64}
        roles["source_manifest"] = descriptor(root / "source/source_snapshot_manifest.jsonl", "script/source_snapshot_manifest.jsonl")
        roles["release_identity"] = descriptor(root / "packaging/LidSwitchReleaseIdentity.json", "Resources/LidSwitchReleaseIdentity.json")
        contract = {"schema": "lidswitch-hosted-held-contract-v1", "fd_map": {"x": 1}, "roles": roles,
                    "directories": {"script": directory_descriptor()}, "bash": {"x": 1},
                    "source_manifest": meta(root / "source/source_snapshot_manifest.jsonl")["sha256"]}
        write(root / "authority/contract.json", contract, 0o400)
        policy_desc = descriptor(root / "orchestration/policy.json", str(root / "orchestration/hosted-runner-policy.json"))
        authority = {"schema": "lidswitch-hosted-authority-ledger-v1", "policy": policy_desc,
                     "source": {"commit": COMMIT, "tree": "d86650eccfe3326fc968fc855a07a1e3d06aaf57", "root": directory_descriptor(),
                                "manifest_sha256": meta(root / "source/source_snapshot_manifest.jsonl")["sha256"],
                                "manifest_descriptor": descriptor(root / "source/source_snapshot_manifest.jsonl", str(root / "source/script/source_snapshot_manifest.jsonl"))},
                     "system": {"python": system_descriptor("/usr/bin/python3", "1" * 64), "bash": system_descriptor("/bin/bash", "2" * 64), "swift_frontend": system_descriptor("/Library/Developer/CommandLineTools/usr/bin/swift-frontend", "c" * 64), "sdk_root": directory_descriptor(), "developer_dir": "/Library/Developer/CommandLineTools"},
                     "wrapper_sha256": roles["wrapper"]["sha256"],
                     "generated": {"entry": descriptor(root / "authority/entry.py", str(root / "authority/hosted-held-entry.py")), "contract": descriptor(root / "authority/contract.json", str(root / "authority/hosted-held-contract.json")), "root": directory_descriptor()}}
        write(root / "authority/ledger.json", authority, 0o400)
        authority_meta = meta(root / "authority/ledger.json")
        pre = b"host_class=idle-uninstalled\nkernel_build=25E246\n"
        write(root / "authority/preflight-state.snapshot", pre, 0o400); write(root / "authority/postflight-state.snapshot", pre, 0o400)
        capture_names = ("app-bin-path", "app-build", "helper-bin-path", "helper-build", "helper-identity", "helper-sign", "helper-verify")
        fixture_captures = {name: f"{index:064x}:{index + 16:064x}" for index, name in enumerate(capture_names, 1)}
        release_output_path = "/private/tmp/lidswitch-swift.fixture/release-output"
        receipt_captures = ",".join(name + ":" + fixture_captures[name] for name in capture_names)
        receipt = ("schema=3\nnonce=fixture-nonce\noutcome=preserved\nchild_command_exit=0\nwrapper_exit=0\npreflight_sha256=" + meta(root / "authority/preflight-state.snapshot")["sha256"] + "\npostflight_sha256=" + meta(root / "authority/postflight-state.snapshot")["sha256"] + "\nhost_preserved=true\nbenchmark_published=false\nerror=none\ncapture_identifiers=" + receipt_captures + "\ncontrol_root=/private/tmp/lidswitch-envelope.fixture\nexecution_root=" + str(Path(release_output_path).parent) + "\n").encode()
        write(root / "authority/live-state-retained.receipt", receipt, 0o400)
        write(root / "authority/live-envelope.json", {"schema": "lidswitch-hosted-live-envelope-v2", "receipt_sha256": meta(root / "authority/live-state-retained.receipt")["sha256"], "preflight_sha256": meta(root / "authority/preflight-state.snapshot")["sha256"], "postflight_sha256": meta(root / "authority/postflight-state.snapshot")["sha256"], "wrapper_exit": 0}, 0o400)
        prepare = {"schema": "lidswitch-hosted-prepare-v2", "authority": str(root / "authority"), "ledger": descriptor(root / "authority/ledger.json", str(root / "authority/hosted-authority-ledger.json")), "entry": descriptor(root / "authority/entry.py", str(root / "authority/hosted-held-entry.py")), "contract": descriptor(root / "authority/contract.json", str(root / "authority/hosted-held-contract.json")), "source_manifest_sha256": meta(root / "source/source_snapshot_manifest.jsonl")["sha256"]}
        write(root / "receipts/prepare.json", prepare, 0o400)
        retained = {name: descriptor(root / relative, str(root / "authority" / name)) for name, relative in {"live-state-retained.receipt": "authority/live-state-retained.receipt", "preflight-state.snapshot": "authority/preflight-state.snapshot", "postflight-state.snapshot": "authority/postflight-state.snapshot", "hosted-live-envelope.json": "authority/live-envelope.json"}.items()}
        build = {"schema": "lidswitch-hosted-build-v2", "source": authority["source"], "generated": authority["generated"], "ledger": prepare["ledger"], "entry": prepare["entry"], "contract": prepare["contract"], "retained": retained, "release_output": release_output_path}
        write(root / "receipts/build.json", build, 0o400)
        write(root / "release-output/LidSwitch", b"app-binary", 0o555)
        write(root / "release-output/LidSwitchHelper", b"helper-binary", 0o555)
        write(root / "release-output/GeneratedReleaseHelperTrustAnchor.generated.swift", b"anchor", 0o444)
        app, helper, anchor = (meta(root / "release-output/LidSwitch"), meta(root / "release-output/LidSwitchHelper"), meta(root / "release-output/GeneratedReleaseHelperTrustAnchor.generated.swift"))
        inputs = {"appSourceSeal": "3" * 64, "baseManifestSHA256": meta(root / "source/source_snapshot_manifest.jsonl")["sha256"], "generatedAnchorSHA256": anchor["sha256"], "helperSourceSeal": "4" * 64, "releaseIdentitySHA256": meta(root / "packaging/LidSwitchReleaseIdentity.json")["sha256"], "trustAnchorTemplateSHA256": "6" * 64}
        release_receipt = {"schema": "lidswitch-held-release-build-v1", "artifacts": {"app": {"identifier": "com.johnsilva.LidSwitch", "sha256": app["sha256"], "size": app["size"]}, "helper": {"cdhash": "a" * 40, "identifier": "com.johnsilva.lidswitch.helper", "sha256": helper["sha256"], "signature": "adhoc", "size": helper["size"], "teamIdentifier": None, "timestamp": None}}, "build": {"configuration": "release", "network": False, "paidLicenses": [], "releaseCandidateDefine": True, "signing": "manual-ad-hoc", "stages": ["helper", "app"]}, "captures": fixture_captures, "inputs": inputs, "toolchain": {"componentSealSHA256": "9" * 64, "driverIdentity": "1:swift-frontend", "profileSHA256": "a" * 64, "root": "/Library/Developer/CommandLineTools", "sdk": "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"}}
        write(root / "release-output/build-receipt.json", release_receipt, 0o444)
        release_leaves = {"GeneratedReleaseHelperTrustAnchor.generated.swift": anchor, "LidSwitch": app, "LidSwitchHelper": helper, "build-receipt.json": meta(root / "release-output/build-receipt.json")}
        seal = digest(b"".join((f"{name}|{release_leaves[name]['size']}|{release_leaves[name]['sha256']}\n").encode("ascii") for name in sorted(release_leaves)))
        release = {"seal_sha256": seal, "build_receipt_sha256": meta(root / "release-output/build-receipt.json")["sha256"], "anchor_sha256": anchor["sha256"], "anchor_size": anchor["size"], "source_manifest_sha256": inputs["baseManifestSHA256"], "release_identity_sha256": inputs["releaseIdentitySHA256"], "app": release_receipt["artifacts"]["app"], "helper": release_receipt["artifacts"]["helper"]}
        envelope = {"schema_version": core.ENVELOPE_SCHEMA, "wrapper_sha256": roles["wrapper"]["sha256"], "source_commit": COMMIT, "source_tree_sha256": inputs["baseManifestSHA256"], "toolchain_sha256": "c" * 64, "executables": [{"role": "python3", "path": "/usr/bin/python3", "sha256": "d" * 64}], "environment": {"locale": "C", "timezone": "UTC", "path": "/usr/bin:/bin:/usr/sbin:/sbin"}, "release_output": release}
        write(root / "package/build-envelope.json", envelope, 0o400)
        envelope_sha = meta(root / "package/build-envelope.json")["sha256"]
        write(root / "candidate/LidSwitchHelper", b"helper-binary", 0o755)
        write(root / "candidate/LidSwitch.dmg", b"dmg-bytes", 0o600)
        write(root / "candidate/LidSwitch.dmg.sha256", (meta(root / "candidate/LidSwitch.dmg")["sha256"] + "  LidSwitch.dmg\n").encode(), 0o600)
        signed = lambda role, name, raw, receipt: {"role": role, "name": name, "sha256": raw["sha256"], "size": raw["size"], "mode": raw["mode"], "uid": 1, "gid": 1, "tree_sha256": raw["sha256"], "signature_receipt": receipt, "identifier": "com.johnsilva.lidswitch.helper" if role == "helper" else "com.johnsilva.LidSwitch", "cdhash": "a" * 40, "signing_profile": "manual-adhoc", "team_id": None, "notarized": False}
        helper_artifact = signed("helper", "LidSwitchHelper", meta(root / "candidate/LidSwitchHelper"), "0" * 64)
        app_artifact = signed("app", "LidSwitch.app", {"sha256": "e" * 64, "size": 1, "mode": 0o755}, "0" * 64)
        release_identity = {"name": "release-identity.json", "sha256": inputs["releaseIdentitySHA256"], "signing_profile": "manual-adhoc", "team_id": None, "notarized": False}
        envelope_ref = {"receipt_sha256": envelope_sha, "wrapper_sha256": envelope["wrapper_sha256"], "source_tree_sha256": envelope["source_tree_sha256"], "toolchain_sha256": envelope["toolchain_sha256"], "release_output": release}
        def receipts(manifest, count):
            binding = core.candidate_binding(manifest); previous = "0" * 64; values = []
            for index, role in enumerate(core.PHASES["package-captured"][:count], 1):
                value = {"role": role, "name": "receipt-%02d.json" % index, "sha256": "0" * 64, "tool_sha256": "f" * 64, "subject_role": "release-identity", "subject_name": "release-identity.json", "subject_sha256": inputs["releaseIdentitySHA256"], "subject_size": 1, "source_commit": COMMIT, "candidate_binding": binding, "previous_receipt": previous, "strict": True, "exit": 0}
                value["sha256"] = digest(core.canonical_receipt_payload(value)); previous = value["sha256"]; values.append(value)
            return values
        package_empty = {"dmg": None, "checksum": None, "extraction_receipt": None, "extracted_tree_sha256": None}
        candidate = {"schema_version": core.SCHEMA, "candidate_id": "0" * 64, "phase": "app-captured", "envelope": envelope_ref, "release_identity": release_identity, "source": {"commit": COMMIT, "tree_sha256": envelope["source_tree_sha256"]}, "helper": helper_artifact, "app": app_artifact, "package": package_empty, "receipts": []}
        candidate["receipts"] = receipts(candidate, 6); candidate["helper"]["signature_receipt"] = candidate["receipts"][0]["sha256"]; candidate["app"]["signature_receipt"] = candidate["receipts"][3]["sha256"]; candidate["candidate_id"] = digest(core.canonical({key: value for key, value in candidate.items() if key != "candidate_id"}))
        package_leaf = lambda role, name: {"role": role, "name": name, "sha256": meta(root / "candidate" / name)["sha256"], "size": meta(root / "candidate" / name)["size"], "mode": meta(root / "candidate" / name)["mode"], "uid": 1, "gid": 1, "tree_sha256": meta(root / "candidate" / name)["sha256"], "signature_receipt": "0" * 64}
        package = dict(candidate); package["candidate_id"] = "0" * 64; package["phase"] = "package-captured"; package["package"] = {"dmg": package_leaf("package", "LidSwitch.dmg"), "checksum": package_leaf("checksum", "LidSwitch.dmg.sha256"), "extraction_receipt": "0" * 64, "extracted_tree_sha256": app_artifact["tree_sha256"]}; package["receipts"] = receipts(package, 9); package["helper"]["signature_receipt"] = package["receipts"][0]["sha256"]; package["app"]["signature_receipt"] = package["receipts"][3]["sha256"]; package["package"]["extraction_receipt"] = package["receipts"][8]["sha256"]; package["candidate_id"] = digest(core.canonical({key: value for key, value in package.items() if key != "candidate_id"}))
        write(root / "candidate/candidate-manifest.json", candidate, 0o600); write(root / "candidate/package-manifest.json", package, 0o600)
        context = {"schema": "lidswitch-hosted-workflow-context-v2", "source_commit": COMMIT, "source_tree": "d86650eccfe3326fc968fc855a07a1e3d06aaf57", "orchestration_commit_sha": "1" * 40, "workflow_file_sha256": meta(root / "orchestration/workflow.yml")["sha256"], "workflow_ref": "refs/heads/main", "reviewed_orchestration_sha": "1" * 40, "run_id": "1", "run_attempt": "1", "image_version": json.loads((root / "orchestration/policy.json").read_text())["runner"]["image_version"], "policy_sha256": meta(root / "orchestration/policy.json")["sha256"], "release_output": release_output_path, "package_parent": "/private/tmp/lidswitch-package.fixture", "candidate_root": "/private/tmp/lidswitch-package.fixture/candidate", "sdk_version": "26", "driver_sha256": envelope["toolchain_sha256"]}
        write(root / "workflow-context.json", context, 0o400)
        files = {relative: meta(root / relative) for relative in required}
        write(root / "evidence-tree.json", {"schema": "lidswitch-hosted-evidence-v2", "files": files, "inventory": sorted(files), "bindings": {"source_manifest": "source/source_snapshot_manifest.jsonl", "authority_ledger": "authority/ledger.json", "contract": "authority/contract.json", "entry": "authority/entry.py", "live_receipt": "authority/live-state-retained.receipt", "preflight": "authority/preflight-state.snapshot", "postflight": "authority/postflight-state.snapshot", "workflow": "orchestration/workflow.yml", "context": "workflow-context.json", "prepare": "receipts/prepare.json", "build": "receipts/build.json"}}, 0o400)
        return temp, root

    def verify(self, root):
        return subprocess.run(["/usr/bin/python3", str(VERIFY), "--evidence", str(root)], capture_output=True, text=True)

    def mutate(self, root, relative, change):
        path = root / relative
        value = json.loads(path.read_text())
        change(value)
        write(path, value)
        ledger_path = root / "evidence-tree.json"
        ledger = json.loads(ledger_path.read_text())
        ledger["files"][relative] = meta(path)
        write(ledger_path, ledger, 0o400)

    def assert_denied_mutation(self, relative, change):
        temp, root = self.make_fixture()
        self.mutate(root, relative, change)
        result = self.verify(root)
        temp.cleanup()
        self.assertNotEqual(result.returncode, 0)

    def rewrite_terminal_receipt(self, root, transform):
        receipt_path = root / "authority/live-state-retained.receipt"
        write(receipt_path, transform(receipt_path.read_bytes()), 0o400)
        live_path = root / "authority/live-envelope.json"
        live = json.loads(live_path.read_text())
        live["receipt_sha256"] = meta(receipt_path)["sha256"]
        write(live_path, live, 0o400)
        build_path = root / "receipts/build.json"
        build = json.loads(build_path.read_text())
        for name, relative in {"live-state-retained.receipt": "authority/live-state-retained.receipt", "hosted-live-envelope.json": "authority/live-envelope.json"}.items():
            build["retained"][name] = descriptor(root / relative, build["retained"][name]["path"])
        write(build_path, build, 0o400)
        ledger_path = root / "evidence-tree.json"
        ledger = json.loads(ledger_path.read_text())
        for relative in ("authority/live-state-retained.receipt", "authority/live-envelope.json", "receipts/build.json"):
            ledger["files"][relative] = meta(root / relative)
        write(ledger_path, ledger, 0o400)

    def test_terminal_capture_and_execution_bindings_are_rejected_after_reledgering(self):
        def capture_parts(payload):
            line = next(line for line in payload.splitlines() if line.startswith(b"capture_identifiers="))
            return line, line.split(b"=", 1)[1].split(b",")
        def reorder(payload):
            line, values = capture_parts(payload); values[0], values[1] = values[1], values[0]
            return payload.replace(line, b"capture_identifiers=" + b",".join(values))
        def mismatch(payload):
            line, values = capture_parts(payload); values[0] = values[0].split(b":", 1)[0] + b":" + values[1].split(b":", 1)[1]
            return payload.replace(line, b"capture_identifiers=" + b",".join(values))
        cases = {
            "error": lambda payload: payload.replace(b"error=none", b"error=not-none"),
            "none": lambda payload: payload.replace(capture_parts(payload)[0], b"capture_identifiers=none"),
            "arbitrary": lambda payload: payload.replace(capture_parts(payload)[1][0], b"app-bin-path:" + b"0" * 64 + b":" + b"1" * 64),
            "order": reorder,
            "capture-mismatch": mismatch,
            "execution-root": lambda payload: payload.replace(b"execution_root=/private/tmp/lidswitch-swift.fixture", b"execution_root=/private/tmp/lidswitch-swift.other"),
        }
        for label, transform in cases.items():
            with self.subTest(label=label):
                temp, root = self.make_fixture()
                self.rewrite_terminal_receipt(root, transform)
                result = self.verify(root)
                temp.cleanup()
                self.assertNotEqual(result.returncode, 0)

    def test_complete_v3_fixture_is_accepted(self):
        temp, root = self.make_fixture(); result = self.verify(root); temp.cleanup(); self.assertEqual(result.returncode, 0, result.stderr)

    def test_dmg_checksum_drift_is_rejected(self):
        temp, root = self.make_fixture(); write(root / "candidate/LidSwitch.dmg.sha256", b"0" * 64); result = self.verify(root); temp.cleanup(); self.assertNotEqual(result.returncode, 0)

    def test_receipt_chain_drift_is_rejected(self):
        temp, root = self.make_fixture(); value = json.loads((root / "candidate/package-manifest.json").read_text()); value["receipts"][1]["previous_receipt"] = "0" * 64; write(root / "candidate/package-manifest.json", value); result = self.verify(root); temp.cleanup(); self.assertNotEqual(result.returncode, 0)

    def test_empty_or_extra_bindings_are_rejected(self):
        for bindings in ({}, {"extra": "candidate/LidSwitch.dmg"}):
            temp, root = self.make_fixture(); ledger = json.loads((root / "evidence-tree.json").read_text()); ledger["bindings"] = bindings; write(root / "evidence-tree.json", ledger); result = self.verify(root); temp.cleanup(); self.assertNotEqual(result.returncode, 0)

    def test_v3_semantic_tampering_is_rejected_after_reledgering(self):
        cases = {
            "unknown-candidate-key": ("candidate/candidate-manifest.json", lambda v: v.update(unexpected=True)),
            "missing-candidate-key": ("candidate/candidate-manifest.json", lambda v: v.pop("phase")),
            "envelope-receipt-sha": ("candidate/package-manifest.json", lambda v: v["envelope"].update(receipt_sha256="0" * 64)),
            "candidate-id": ("candidate/package-manifest.json", lambda v: v.update(candidate_id="0" * 64)),
            "candidate-binding": ("candidate/package-manifest.json", lambda v: v["receipts"][0].update(candidate_binding="0" * 64)),
            "receipt-role-order": ("candidate/package-manifest.json", lambda v: v["receipts"][0].update(role="anchor")),
            "receipt-previous-chain": ("candidate/package-manifest.json", lambda v: v["receipts"][1].update(previous_receipt="0" * 64)),
            "candidate-phase": ("candidate/candidate-manifest.json", lambda v: v.update(phase="package-captured")),
            "source-manifest": ("source/source_snapshot_manifest.jsonl", None),
            "toolchain": ("package/build-envelope.json", lambda v: v.update(toolchain_sha256="0" * 64)),
            "prepare-binding": ("receipts/prepare.json", lambda v: v["ledger"].update(sha256="0" * 64)),
            "build-binding": ("receipts/build.json", lambda v: v["retained"]["preflight-state.snapshot"].update(sha256="0" * 64)),
            "absolute-descriptor-path": ("receipts/prepare.json", lambda v: v["ledger"].update(path="hosted-authority-ledger.json")),
            "absolute-descriptor-parent": ("receipts/build.json", lambda v: v["entry"].update(path="/private/tmp/other/hosted-held-entry.py")),
            "live-envelope-schema": ("authority/live-envelope.json", lambda v: v.update(schema="lidswitch-hosted-live-envelope-v1")),
            "live-envelope-wrapper": ("authority/live-envelope.json", lambda v: v.update(wrapper_exit=74)),
            "release-seal": ("package/build-envelope.json", lambda v: v["release_output"].update(seal_sha256="0" * 64)),
            "release-identity": ("package/build-envelope.json", lambda v: v["release_output"].update(release_identity_sha256="0" * 64)),
            "context-release-output": ("workflow-context.json", lambda v: v.update(release_output="/private/tmp/lidswitch-swift.fixture/other")),
            "build-release-output": ("receipts/build.json", lambda v: v.update(release_output="/private/tmp/lidswitch-swift.fixture/other")),
            "helper-identifier": ("candidate/package-manifest.json", lambda v: v["helper"].update(identifier="bad.helper")),
            "helper-cdhash": ("candidate/package-manifest.json", lambda v: v["helper"].update(cdhash="0" * 40)),
            "helper-team": ("candidate/package-manifest.json", lambda v: v["helper"].update(team_id="TEAM")),
            "helper-notarization": ("candidate/package-manifest.json", lambda v: v["helper"].update(notarized=True)),
            "dmg-hash": ("candidate/package-manifest.json", lambda v: v["package"]["dmg"].update(sha256="0" * 64)),
            "dmg-size": ("candidate/package-manifest.json", lambda v: v["package"]["dmg"].update(size=1)),
            "checksum-hash": ("candidate/package-manifest.json", lambda v: v["package"]["checksum"].update(sha256="0" * 64)),
            "extraction-tree": ("candidate/package-manifest.json", lambda v: v["package"].update(extracted_tree_sha256="0" * 64)),
        }
        for label, (relative, change) in cases.items():
            with self.subTest(label=label):
                if change is None:
                    temp, root = self.make_fixture()
                    path = root / relative
                    os.chmod(path, 0o600)
                    path.write_bytes(path.read_bytes().replace(b"schema", b"Schema", 1))
                    ledger = json.loads((root / "evidence-tree.json").read_text()); ledger["files"][relative] = meta(path); write(root / "evidence-tree.json", ledger, 0o400)
                    result = self.verify(root); temp.cleanup(); self.assertNotEqual(result.returncode, 0)
                else:
                    self.assert_denied_mutation(relative, change)
