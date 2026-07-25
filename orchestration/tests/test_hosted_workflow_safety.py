import ast
import hashlib
import importlib.util
import os
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
        for token in ("live-state-retained.receipt", "preflight-state.snapshot", "postflight-state.snapshot", 'rows.get("host_preserved")!="true"', 'rows.get("control_root")!=control', "capture_package", "assemble_package", "candidate_core", "source-drift-before-build", "source-root-replacement-before-build", "_sealed_package_closure", "held-packaging-inventory-drift", "held-packaging-closure-drift", "PACKAGING_PYTHON_BOOTSTRAP"):
            self.assertIn(token, self.bootstrap)

    def test_verifier_closes_the_complete_evidence_inventory(self):
        verifier = (ROOT / "orchestration/verify_hosted_candidate_evidence.py").read_text()
        for token in ("missing or extra declared evidence leaf", "package/build-envelope.json", "candidate/package-manifest.json", "release-output/build-receipt.json", "lidswitch-hosted-live-envelope-v2", "release_output_seal", "LidSwitchReleaseIdentity.json"):
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
                self.bootstrap.prepare_recheck(source, authority, Path(temp.name) / "policy.json")

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
