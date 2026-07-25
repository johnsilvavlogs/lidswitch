import ast
import unittest
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
        for token in ("live-state-retained.receipt", "preflight-state.snapshot", "postflight-state.snapshot", 'rows.get("terminal")!="idle-uninstalled"', 'rows.get("kernel")!="25E246"', "capture_package", "assemble_package", "candidate_core", "source-drift-before-build"):
            self.assertIn(token, self.bootstrap)

    def test_verifier_closes_the_complete_evidence_inventory(self):
        verifier = (ROOT / "orchestration/verify_hosted_candidate_evidence.py").read_text()
        for token in ("missing or extra declared evidence leaf", "package/build-envelope.json", "candidate/package-manifest.json", "release-output/build-receipt.json", 'fields.get("terminal") == "idle-uninstalled"', 'fields.get("kernel") == "25E246"'):
            self.assertIn(token, verifier)

    def test_workflow_never_executes_candidate_packaging_path(self):
        self.assertNotIn('$GITHUB_WORKSPACE/source/script/', self.workflow)
        self.assertIn('hosted_held_bootstrap.py" package', self.workflow)
        self.assertIn('verify_hosted_candidate_evidence.py" --evidence', self.workflow)

    def test_bootstrap_is_parseable(self):
        ast.parse(self.bootstrap)
