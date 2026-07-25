import ast
import hashlib
import importlib.util
import json
import os
import stat
import tempfile
import unittest
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class HostedWorkflowSafetyTests(unittest.TestCase):
    def setUp(self):
        self.workflow = (ROOT / ".github/workflows/hosted-immutable-candidate.yml").read_text()
        self.bootstrap = (ROOT / "orchestration/hosted_held_bootstrap.py").read_text()

    def test_workflow_uses_clt_without_global_selection(self):
        self.assertIn("DEVELOPER_DIR=/Library/Developer/CommandLineTools", self.workflow)
        self.assertNotIn("xcode-select -p", self.workflow)

    def test_workflow_accepts_only_the_exact_policy_image(self):
        policy = json.loads((ROOT / "orchestration/hosted-runner-policy.json").read_text())
        images = policy["runner"]["image_versions"]
        self.assertEqual(images, ["20260715.0248.1", "20260720.0258.1"])
        for image in images:
            self.assertEqual(self.workflow.count(image + ") ;;"), 1)
        self.assertIn("*) exit 74 ;;", self.workflow)
        self.assertNotIn("ImageVersion:?missing ImageVersion}" + " =", self.workflow)

    def test_swift_frontend_bound_covers_current_clt_without_becoming_unbounded(self):
        self.assertIn('maximum=512 * 1024 * 1024', self.bootstrap)
        self.assertNotIn('maximum=128 * 1024 * 1024', self.bootstrap)

    def test_dispatch_is_fenced_to_reviewed_main_identity(self):
        for token in ("reviewed_orchestration_sha", "GITHUB_REPOSITORY", "johnsilvavlogs/lidswitch", "GITHUB_REF", "refs/heads/main", "GITHUB_SHA"):
            self.assertIn(token, self.workflow)
        self.assertIn("workflow_file_sha256", self.workflow)
        self.assertIn("orchestration_commit_sha", self.workflow)
        self.assertIn("REVIEWED_ORCHESTRATION_SHA: ${{ inputs.reviewed_orchestration_sha }}", self.workflow)
        for line in self.workflow.splitlines():
            if "${{ inputs.reviewed_orchestration_sha }}" in line:
                self.assertTrue(line.lstrip().startswith("REVIEWED_ORCHESTRATION_SHA:"))

    def test_shell_injection_payload_has_no_source_position(self):
        payload = "' ; touch /tmp/pwned ; #"
        self.assertNotIn(payload, self.workflow)
        self.assertIn('case "$REVIEWED_ORCHESTRATION_SHA"', self.workflow)

    def test_official_checkout_origin_without_dot_git_is_allowed(self):
        self.assertIn('"https://github.com/${GITHUB_REPOSITORY}"', self.workflow)
        self.assertIn('"https://github.com/${GITHUB_REPOSITORY}.git"', self.workflow)
        self.assertIn('"git@github.com:${GITHUB_REPOSITORY}.git"', self.workflow)

    def test_build_requires_prepare_bound_expected_values(self):
        for name in ("ledger", "entry", "contract"):
            self.assertIn('"--expected-" + role + "-sha256"', self.bootstrap)
            self.assertIn('"--expected-" + role + "-size"', self.bootstrap)
        self.assertIn("external-expected-", self.bootstrap)

    def test_entry_is_executed_by_verified_descriptor(self):
        self.assertIn('"/dev/fd/" + str(entry_fd)', self.bootstrap)
        self.assertIn("pass_fds=(contract_fd, entry_fd)", self.bootstrap)
        self.assertNotIn("authority-ledger-self-reference-invalid", self.bootstrap)

    def test_terminal_receipt_and_packaging_closure_are_bound(self):
        for token in ("live-state-retained.receipt", "preflight-state.snapshot", "postflight-state.snapshot", 'rows.get("host_preserved")!="true"', 'rows.get("error")!="none"', "capture_names=(\"app-bin-path\"", 'rows.get("control_root")!=control', "capture_package", "assemble_package", "candidate_core", "source-drift-before-build", "source-root-replacement-before-build", "held-terminal-receipt-missing", "hosted-authority-inventory=", "_sealed_package_closure", "held-packaging-inventory-drift", "held-packaging-closure-drift", "PACKAGING_PYTHON_BOOTSTRAP"):
            self.assertIn(token, self.bootstrap)

    def test_verifier_closes_the_complete_evidence_inventory(self):
        verifier = (ROOT / "orchestration/verify_hosted_candidate_evidence.py").read_text()
        for token in ("missing or extra declared evidence leaf", "package/build-envelope.json", "candidate/package-manifest.json", "release-output/build-receipt.json", "lidswitch-hosted-live-envelope-v2", "receipt_captures", "execution_root", "release_output_seal", "LidSwitchReleaseIdentity.json"):
            self.assertIn(token, verifier)

    def test_workflow_pins_match_current_authority_files(self):
        expected = {
            "hosted_held_bootstrap.py": ROOT / "orchestration/hosted_held_bootstrap.py",
            "hosted-runner-policy.json": ROOT / "orchestration/hosted-runner-policy.json",
            "collect_hosted_candidate_evidence.py": ROOT / "orchestration/collect_hosted_candidate_evidence.py",
            "verify_hosted_candidate_evidence.py": ROOT / "orchestration/verify_hosted_candidate_evidence.py",
        }
        for name, path in expected.items():
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
            needle = 'orchestration/' + name + ' | /usr/bin/awk'
            line = next(line for line in self.workflow.splitlines() if needle in line)
            self.assertIn(actual, line, name)

    def test_workflow_never_executes_candidate_packaging_path(self):
        self.assertNotIn('$GITHUB_WORKSPACE/source/script/', self.workflow)
        self.assertIn('hosted_held_bootstrap.py" package', self.workflow)
        self.assertIn('verify_hosted_candidate_evidence.py" --evidence', self.workflow)

    def test_bootstrap_is_parseable(self):
        ast.parse(self.bootstrap)

    def test_authority_root_is_frozen_after_every_leaf_exists(self):
        ledger_create = self.bootstrap.index("ledger_fd = os.open(ledger_path")
        root_freeze = self.bootstrap.index("info = checked_authority_root(authority, AUTHORITY_INITIAL_FILES)", ledger_create)
        ledger_write = self.bootstrap.index("os.write(ledger_fd, data)", root_freeze)
        self.assertLess(ledger_create, root_freeze)
        self.assertLess(root_freeze, ledger_write)


class HeldPackagingClosureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("hosted_held_bootstrap_test", ROOT / "orchestration/hosted_held_bootstrap.py")
        cls.bootstrap = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(cls.bootstrap)

    def make_sealed_closure(self):
        temp = tempfile.TemporaryDirectory()
        held = Path(temp.name) / "held-packaging"
        script = held / "script"
        resources = held / "Resources"
        script.mkdir(parents=True, mode=0o700)
        resources.mkdir(mode=0o700)
        for name in self.bootstrap.PACKAGING_SCRIPTS.values():
            payload = b"#!/usr/bin/python3\npass\n" if name.endswith(".py") else b"#!/bin/sh\nexit 0\n"
            target = script / name
            target.write_bytes(payload)
            os.chmod(target, 0o500 if name in self.bootstrap.PACKAGING_ENTRYPOINTS else 0o400)
        for name in self.bootstrap.PACKAGING_RESOURCES.values():
            target = resources / name
            target.write_bytes(b"resource\n")
            os.chmod(target, 0o400)
        os.chmod(script, 0o500)
        os.chmod(resources, 0o500)
        os.chmod(held, 0o500)
        return temp, held

    def assert_denied(self, held):
        with self.assertRaises(self.bootstrap.Denied):
            self.bootstrap._sealed_package_closure(held)

    def test_policy_rejects_every_noncanonical_image_set_shape(self):
        base = json.loads((ROOT / "orchestration/hosted-runner-policy.json").read_text())
        cases = []
        for replacement in (
            [],
            ["20260720.0258.1", "20260715.0248.1"],
            ["20260715.0248.1", "20260715.0248.1"],
            ["20260715.0248.1", "20260720.0258.1", "20260721.0000.1"],
            "20260715.0248.1",
        ):
            value = json.loads(json.dumps(base)); value["runner"]["image_versions"] = replacement; cases.append(value)
        singular = json.loads(json.dumps(base)); singular["schema"] = "lidswitch-hosted-runner-policy-v1"; singular["runner"].pop("image_versions"); singular["runner"]["image_version"] = "20260715.0248.1"; cases.append(singular)
        for index, value in enumerate(cases):
            with self.subTest(index=index):
                temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
                path = Path(temp.name) / "policy.json"
                path.write_bytes(self.bootstrap.canonical(value))
                with mock.patch.object(self.bootstrap, "descriptor", return_value={}):
                    with self.assertRaises(self.bootstrap.Denied):
                        self.bootstrap.policy(path)

    def test_system_sdk_selector_binds_root_owned_parent_symlink_and_target(self):
        path = Path("/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk")
        directory = {"dev": 1, "inode": 10, "uid": 0, "gid": 0, "mode": 0o755, "nlink": 2}
        target_directory = {**directory, "inode": 11}
        selector = os.stat_result((stat.S_IFLNK | 0o755, 12, 1, 1, 0, 0, 16, 0, 0, 0))
        with mock.patch.object(self.bootstrap, "checked_directory", side_effect=[directory, target_directory, directory]), mock.patch.object(self.bootstrap.os, "lstat", side_effect=[selector, selector]), mock.patch.object(self.bootstrap.os, "readlink", side_effect=["MacOSX26.4.sdk", "MacOSX26.4.sdk"]):
            result = self.bootstrap.checked_system_directory_selector(path)
        self.assertEqual(result["selector"]["target"], "MacOSX26.4.sdk")
        self.assertEqual(result["selector"]["type"], "symlink")
        self.assertEqual(result["target"]["path"], "/Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk")

    def test_system_sdk_selector_rejects_target_outside_root_owned_parent(self):
        path = Path("/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk")
        directory = {"dev": 1, "inode": 10, "uid": 0, "gid": 0, "mode": 0o755, "nlink": 2}
        selector = os.stat_result((stat.S_IFLNK | 0o777, 12, 1, 1, 0, 0, 20, 0, 0, 0))
        with mock.patch.object(self.bootstrap, "checked_directory", return_value=directory), mock.patch.object(self.bootstrap.os, "lstat", return_value=selector), mock.patch.object(self.bootstrap.os, "readlink", return_value="../Outside.sdk"):
            with self.assertRaisesRegex(self.bootstrap.Denied, "unsafe-system-selector-target"):
                self.bootstrap.checked_system_directory_selector(path)

    def test_prepare_freezes_authority_root_only_after_ledger_leaf_creation(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        source = Path(temp.name) / "source"
        authority = Path(temp.name) / "authority"
        source.mkdir()
        manifest_sha = "a" * 64
        directory = {"dev": 1, "inode": 10, "uid": os.getuid(), "gid": os.getgid(), "mode": 0o700, "nlink": 2}

        def checked(path):
            if Path(path) == authority:
                self.assertTrue((authority / "hosted-authority-ledger.json").exists())
            return directory

        def git_result(_source, *args):
            if args == ("rev-parse", "HEAD"):
                return self.bootstrap.SOURCE_COMMIT + "\n"
            if args == ("rev-parse", "HEAD^{tree}"):
                return self.bootstrap.SOURCE_TREE + "\n"
            return ""

        def described(path, **_kwargs):
            return {"path": str(path), "dev": 1, "inode": 1, "uid": os.getuid(), "gid": os.getgid(),
                    "mode": 0o400, "nlink": 1, "size": 1, "sha256": self.bootstrap.WRAPPER_SHA256}

        with mock.patch.object(self.bootstrap, "policy", return_value={"descriptor": described("policy"), "value": {"source_manifest_sha256": manifest_sha}}), mock.patch.object(self.bootstrap, "git", side_effect=git_result), mock.patch.object(self.bootstrap, "verify_manifest", return_value=({"sha256": manifest_sha}, manifest_sha)), mock.patch.object(self.bootstrap, "descriptor", side_effect=described), mock.patch.object(self.bootstrap, "checked_directory", side_effect=checked), mock.patch.object(self.bootstrap, "checked_system_directory_selector", return_value={"sdk": "bound"}):
            result = self.bootstrap.prepare(source, authority, Path(temp.name) / "policy.json")
        self.assertEqual(result["schema"], "lidswitch-hosted-prepare-v2")
        ledger = json.loads((authority / "hosted-authority-ledger.json").read_text())
        root = ledger["generated"]["root"]
        self.assertEqual(set(root), {"dev", "inode", "uid", "gid", "mode"})
        self.assertEqual(root["inode"], os.stat(authority, follow_symlinks=False).st_ino)

    def test_authority_root_uses_stable_identity_and_exact_staged_inventory(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        authority = Path(temp.name) / "authority"
        authority.mkdir(mode=0o700)
        for name in self.bootstrap.AUTHORITY_INITIAL_FILES:
            (authority / name).write_bytes(b"held")
        anchor = self.bootstrap.checked_authority_root(authority, self.bootstrap.AUTHORITY_INITIAL_FILES)
        self.assertEqual(set(anchor), {"dev", "inode", "uid", "gid", "mode"})
        (authority / "unexpected").write_bytes(b"no")
        with self.assertRaisesRegex(self.bootstrap.Denied, "authority-inventory-mismatch"):
            self.bootstrap.checked_authority_root(authority, self.bootstrap.AUTHORITY_INITIAL_FILES)

    def test_retained_receipt_selects_release_output_without_trusting_wrapper_stdout(self):
        authority_temp = tempfile.TemporaryDirectory()
        execution_temp = tempfile.TemporaryDirectory(prefix="lidswitch-swift.", dir="/private/tmp")
        self.addCleanup(authority_temp.cleanup)
        self.addCleanup(execution_temp.cleanup)
        authority = Path(authority_temp.name)
        execution = Path(execution_temp.name)
        release_output = execution / "release-output"
        release_output.mkdir(mode=0o700)
        rows = {
            "schema": "3", "nonce": "fixture", "outcome": "preserved", "child_command_exit": "0",
            "wrapper_exit": "0", "preflight_sha256": "1" * 64, "postflight_sha256": "2" * 64,
            "host_preserved": "true", "benchmark_published": "false", "error": "none",
            "capture_identifiers": "fixture", "control_root": "/private/tmp/lidswitch-envelope.fixture",
            "execution_root": str(execution),
        }
        receipt = authority / "live-state-retained.receipt"
        receipt.write_text("".join(f"{key}={value}\n" for key, value in rows.items()))
        os.chmod(receipt, 0o400)
        self.assertEqual(self.bootstrap.retained_release_output(authority), str(release_output))

    def test_exact_closure_records_directories_and_all_leaves(self):
        temp, held = self.make_sealed_closure()
        self.addCleanup(temp.cleanup)
        closure = self.bootstrap._sealed_package_closure(held)
        self.assertEqual(set(closure["directories"]), {"root", "script", "Resources"})
        self.assertEqual(len(closure["leaves"]), 11)
        for record in [*closure["directories"].values(), *closure["leaves"].values()]:
            self.assertEqual(record["uid"], os.getuid())
            self.assertEqual(record["gid"], os.getgid())
            self.assertIn("inode", record)
        self.assertEqual(closure["leaves"]["script/immutable_candidate_core.py"]["mode"], 0o400)
        self.assertEqual(closure["leaves"]["script/capture_immutable_build_envelope.py"]["mode"], 0o500)

    def test_extra_dot_symlink_hardlink_and_writable_nodes_are_rejected(self):
        cases = []
        for kind in ("extra", "dot", "symlink", "hardlink", "writable_leaf", "writable_dir"):
            temp, held = self.make_sealed_closure()
            cases.append(temp)
            script = held / "script"
            target = script / "immutable_candidate_core.py"
            if kind != "writable_dir":
                os.chmod(script, 0o700)
            if kind == "extra":
                (script / "unexpected.py").write_text("pass\n")
            elif kind == "dot":
                (script / ".unexpected").write_text("x")
            elif kind == "symlink":
                os.symlink(target.name, script / "unexpected-link")
            elif kind == "hardlink":
                os.unlink(target)
                os.link(script / "build_immutable_candidate.py", target)
            elif kind == "writable_leaf":
                os.chmod(target, 0o600)
            else:
                os.chmod(script, 0o700)
            if kind != "writable_dir":
                os.chmod(script, 0o500)
            self.assert_denied(held)
        for temp in cases:
            temp.cleanup()

    def test_pre_spawn_inventory_drift_is_rejected(self):
        temp, held = self.make_sealed_closure()
        self.addCleanup(temp.cleanup)
        expected = self.bootstrap._sealed_package_closure(held)
        target = held / "Resources" / "LidSwitch.icns"
        os.chmod(held / "Resources", 0o700)
        os.chmod(target, 0o600)
        target.write_bytes(b"replacement\n")
        os.chmod(target, 0o400)
        os.chmod(held / "Resources", 0o500)
        with self.assertRaises(self.bootstrap.Denied):
            self.bootstrap._require_sealed_package_closure(held, self.bootstrap.PACKAGING_SCRIPTS, expected)

    def test_source_root_path_replacement_is_rejected_before_packaging(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        source = Path(temp.name) / "source"
        authority = Path(temp.name) / "authority"
        source.mkdir()
        authority.mkdir()
        ledger = {
            "schema": "lidswitch-hosted-authority-ledger-v1",
            "source": {"commit": self.bootstrap.SOURCE_COMMIT, "tree": self.bootstrap.SOURCE_TREE, "root": {"inode": 1}},
            "generated": {"root": {"inode": 2}},
        }
        (authority / "hosted-authority-ledger.json").write_bytes(self.bootstrap.canonical(ledger))
        with mock.patch.object(self.bootstrap, "policy"), mock.patch.object(self.bootstrap, "descriptor", return_value={}), mock.patch.object(self.bootstrap, "checked_directory", return_value={"inode": 99}):
            with self.assertRaisesRegex(self.bootstrap.Denied, "source-root-replacement-before-build"):
                self.bootstrap.prepare_recheck(source, authority, Path(temp.name) / "policy.json", completed=False)

    def test_poisoned_cwd_and_pythonpath_are_ignored_for_sealed_runner(self):
        temp, held = self.make_sealed_closure()
        self.addCleanup(temp.cleanup)
        entry = held / "script" / "capture_immutable_build_envelope.py"
        os.chmod(held / "script", 0o700)
        os.chmod(entry, 0o700)
        entry.write_text(
            "import os\n"
            "assert os.getcwd() == '/'\n"
            "assert 'PYTHONPATH' not in os.environ\n"
            "assert {key: os.environ[key] for key in ('PATH', 'LC_ALL', 'DEVELOPER_DIR')} == {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LC_ALL': 'C', 'DEVELOPER_DIR': '/Library/Developer/CommandLineTools'}\n"
        )
        os.chmod(entry, 0o500)
        os.chmod(held / "script", 0o500)
        previous = os.environ.get("PYTHONPATH")
        os.environ["PYTHONPATH"] = "/tmp/poisoned"
        try:
            result = self.bootstrap._run_sealed_packaging(entry, held, [], [])
        finally:
            if previous is None:
                os.environ.pop("PYTHONPATH", None)
            else:
                os.environ["PYTHONPATH"] = previous
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("PYTHONPATH", self.bootstrap.PACKAGING_ENV)

    def test_sealed_launcher_keeps_stdlib_and_local_imports_with_real_argv(self):
        temp, held = self.make_sealed_closure()
        self.addCleanup(temp.cleanup)
        script = held / "script"
        entry = script / "capture_immutable_build_envelope.py"
        poison = Path(temp.name) / "poison"
        poison.mkdir()
        (poison / "argparse.py").write_text("raise RuntimeError('poisoned argparse')\n")
        os.chmod(script, 0o700)
        os.chmod(entry, 0o700)
        os.chmod(script / "immutable_candidate_core.py", 0o600)
        (script / "immutable_candidate_core.py").write_text("SEALED = 'local'\n")
        entry.write_text(
            "import argparse, json, pathlib, sys\n"
            "import immutable_candidate_core\n"
            "assert immutable_candidate_core.SEALED == 'local'\n"
            "assert pathlib.Path(immutable_candidate_core.__file__).resolve().parent == pathlib.Path(__file__).resolve().parent\n"
            "assert pathlib.Path(argparse.__file__).resolve().parent != pathlib.Path('/').resolve() / 'nope'\n"
            "assert str(pathlib.Path(argparse.__file__).resolve()).startswith(tuple(str(pathlib.Path(p).resolve()) for p in sys.path[1:]))\n"
            "assert sys.argv == [__file__, '--real-argument']\n"
            "assert json.dumps({'ok': True}) == '{\\\"ok\\\": true}'\n"
        )
        os.chmod(script / "immutable_candidate_core.py", 0o400)
        os.chmod(entry, 0o500)
        os.chmod(script, 0o500)
        previous = os.environ.get("PYTHONPATH")
        os.environ["PYTHONPATH"] = str(poison)
        try:
            result = self.bootstrap._run_sealed_packaging(entry, held, ["immutable_candidate_core"], ["--real-argument"])
        finally:
            if previous is None:
                os.environ.pop("PYTHONPATH", None)
            else:
                os.environ["PYTHONPATH"] = previous
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_runner_passes_only_sealed_env_cwd_and_isolated_flags(self):
        with mock.patch.object(self.bootstrap.subprocess, "run") as run:
            self.bootstrap._run_sealed_packaging(Path("/private/tmp/held/script/entry.py"), Path("/private/tmp/held"), ["immutable_candidate_core"], ["--safe"])
        command = run.call_args.args[0]
        self.assertEqual(command[:5], ["/usr/bin/python3", "-I", "-S", "-B", "-c"])
        self.assertEqual(run.call_args.kwargs["cwd"], "/")
        self.assertEqual(run.call_args.kwargs["env"], self.bootstrap.PACKAGING_ENV)
        self.assertNotIn("PYTHONPATH", run.call_args.kwargs["env"])

    def test_generated_held_entry_is_parseable(self):
        compile(self.bootstrap.ENTRY, "held-entry.py", "exec")
