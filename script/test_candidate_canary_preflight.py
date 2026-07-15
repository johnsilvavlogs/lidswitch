"""Private-temp, injected-command fixtures for candidate_canary_preflight."""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import candidate_canary_preflight as preflight


def canonical(value):
    return json.dumps(value, separators=(",", ":"), sort_keys=False).encode("utf-8") + b"\n"


STATUS_KEYS = ("state", "reason", "session", "updated", "boot_id", "projection_authority", "projection_generation", "projection_token", "updated_monotonic")
IOREG_OPEN_OUTPUT = (
    "+-o IOPMrootDomain  <class IOPMrootDomain, id 0x100000285>\n"
    "  | {\n"
    '  |   "AppleClamshellState" = No\n'
    "  | }\n"
)


def status(state, reason, session):
    values = (state, reason, session, "1", "boot", "1", "1", "token", "public")
    return "".join("%s=%s\n" % row for row in zip(STATUS_KEYS, values))


class CandidateCanaryPreflightFixtures(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir="/private/tmp")
        self.root = pathlib.Path(self.temp.name)
        self.manifest = self.root / "candidate-manifest.json"
        self.binding = self.root / "candidate-canary-binding.json"
        self.status = self.root / "helper-status"
        self.version = self.root / "helper-version"
        self.receipt = self.root / "preflight.json"
        self.active = self.root / "active.json"
        self.final = self.root / "final.json"
        self.produced_binding = self.root / "produced-candidate-canary-binding.json"
        self.manifest.write_bytes(canonical({
            "schema_version": "lidswitch-immutable-candidate-v3", "candidate_id": "a" * 64,
            "phase": "package-captured",
            "app": {"identifier": "com.johnsilva.LidSwitch", "cdhash": "c" * 40},
            "helper": {"sha256": "d" * 64, "cdhash": "e" * 40},
        }))
        self.binding_value = {
            "schema_version": preflight.BINDING_SCHEMA,
            "candidate_id": "a" * 64,
            "candidate_manifest_schema": "lidswitch-immutable-candidate-v3",
            "candidate_manifest_sha256": hashlib.sha256(self.manifest.read_bytes()).hexdigest(),
            "app": {"installed_path": "/Applications/LidSwitch.app", "bundle_identifier": "com.johnsilva.LidSwitch", "executable_relative_path": "Contents/MacOS/LidSwitch", "executable_sha256": "b" * 64, "executable_cdhash": "c" * 40},
            "helper": {"installed_path": "/Library/Application Support/LidSwitch/Current/LidSwitchHelper", "sha256": "d" * 64, "cdhash": "e" * 40},
            "qualified_system_build": "25F84",
            "helper_version": "5",
        }
        self.binding.write_bytes(canonical(self.binding_value))
        self.version.write_text("5\n", encoding="utf-8")
        self.status.write_text(status("inactive", "legacy-migration", "none"), encoding="utf-8")
        self.commands = []
        self.original_validate = preflight.validate_manifest
        preflight.validate_manifest = lambda value: value

    def tearDown(self):
        preflight.validate_manifest = self.original_validate
        self.temp.cleanup()

    def runner(self, argv):
        self.commands.append(argv)
        values = {
            ("/usr/bin/shasum", "-a", "256", "/Applications/LidSwitch.app/Contents/MacOS/LidSwitch"): (0, "b" * 64 + "  app\n"),
            ("/usr/bin/codesign", "-d", "--verbose=4", "/Applications/LidSwitch.app/Contents/MacOS/LidSwitch"): (0, "CDHash=" + "c" * 40 + "\n"),
            ("/usr/bin/shasum", "-a", "256", "/Library/Application Support/LidSwitch/Current/LidSwitchHelper"): (0, "d" * 64 + "  helper\n"),
            ("/usr/bin/codesign", "-d", "--verbose=4", "/Library/Application Support/LidSwitch/Current/LidSwitchHelper"): (0, "CDHash=" + "e" * 40 + "\n"),
            ("/usr/sbin/sysctl", "-n", "kern.osversion"): (0, "25F84\n"),
            ("/usr/bin/pgrep", "-x", "LidSwitch"): (1, ""),
            ("/usr/bin/pmset", "-g", "batt"): (0, "Now drawing from 'AC Power'\n"),
            ("/usr/bin/pmset", "-g", "live"): (0, " SleepDisabled 0\n"),
            ("/usr/bin/pmset", "-g", "custom"): (0, "Battery Power:\n sleep 10\nAC Power:\n sleep 0\n"),
        }
        return values[argv]

    def runner_with_ioreg(self, output, code=0):
        def injected(argv):
            if argv == preflight.IOREG_CLAMSHELL_COMMAND:
                self.commands.append(argv)
                return code, output
            return self.runner(argv)
        return injected

    def args(self):
        class Args:
            candidate_manifest = str(self.manifest)
            canary_binding = str(self.binding)
            app_bundle = "/Applications/LidSwitch.app"
            helper = "/Library/Application Support/LidSwitch/Current/LidSwitchHelper"
            helper_version = str(self.version)
            status_file = str(self.status)
            applied_state = str(self.root / "missing-applied-state")
            lid_open_observed = "human-confirmed"
        return Args()

    def binding_args(self, output=None):
        class Args:
            candidate_manifest = str(self.manifest)
            binding = str(output or self.produced_binding)
            app_bundle = "/Applications/LidSwitch.app"
            helper = "/Library/Application Support/LidSwitch/Current/LidSwitchHelper"
            helper_version = str(self.version)
            bundle_identifier = "com.johnsilva.LidSwitch"
            executable_relative_path = "Contents/MacOS/LidSwitch"
        return Args()

    def test_make_binding_publishes_then_rereads_the_normal_consumer_contract(self):
        preflight.make_binding(self.binding_args(), self.runner)
        _, binding, _ = preflight._binding(str(self.manifest), str(self.produced_binding))
        self.assertEqual(binding["app"]["executable_sha256"], "b" * 64)
        self.assertEqual(binding["helper"]["cdhash"], "e" * 40)
        self.assertEqual(binding["qualified_system_build"], "25F84")
        self.assertGreaterEqual(self.commands.count(("/usr/bin/shasum", "-a", "256", "/Applications/LidSwitch.app/Contents/MacOS/LidSwitch")), 2)

    def test_make_binding_is_create_once(self):
        preflight.make_binding(self.binding_args(), self.runner)
        with self.assertRaises(FileExistsError):
            preflight.make_binding(self.binding_args(), self.runner)

    def test_make_binding_rejects_identity_drift_during_publish_reread(self):
        calls = [0]
        app_digest = ("/usr/bin/shasum", "-a", "256", "/Applications/LidSwitch.app/Contents/MacOS/LidSwitch")
        def changing_runner(argv):
            if argv == app_digest:
                calls[0] += 1
                return (0, ("b" if calls[0] == 1 else "f") * 64 + "  app\n")
            return self.runner(argv)
        with self.assertRaisesRegex(preflight.PreflightError, "installed-app-identity-mismatch"):
            preflight.make_binding(self.binding_args(), changing_runner)
        self.assertTrue(self.produced_binding.exists())

    def test_make_binding_rejects_a_different_internally_consistent_candidate(self):
        app_cdhash = ("/usr/bin/codesign", "-d", "--verbose=4", "/Applications/LidSwitch.app/Contents/MacOS/LidSwitch")
        helper_digest = ("/usr/bin/shasum", "-a", "256", "/Library/Application Support/LidSwitch/Current/LidSwitchHelper")
        helper_cdhash = ("/usr/bin/codesign", "-d", "--verbose=4", "/Library/Application Support/LidSwitch/Current/LidSwitchHelper")
        def other_candidate_runner(argv):
            if argv == app_cdhash:
                return (0, "CDHash=" + "f" * 40 + "\n")
            if argv == helper_digest:
                return (0, "1" * 64 + "  other-helper\n")
            if argv == helper_cdhash:
                return (0, "CDHash=" + "2" * 40 + "\n")
            return self.runner(argv)
        with self.assertRaisesRegex(preflight.PreflightError, "candidate-app-cdhash-mismatch"):
            preflight.make_binding(self.binding_args(), other_candidate_runner)
        self.assertFalse(self.produced_binding.exists())

    def test_make_binding_requires_packaged_manifest_and_manifest_bundle_identifier(self):
        app_captured = json.loads(self.manifest.read_text(encoding="utf-8"))
        app_captured["phase"] = "app-captured"
        self.manifest.write_bytes(canonical(app_captured))
        with self.assertRaisesRegex(preflight.PreflightError, "candidate-manifest-not-packaged"):
            preflight.make_binding(self.binding_args(), self.runner)
        app_captured["phase"] = "package-captured"
        app_captured["app"]["identifier"] = "com.example.other"
        self.manifest.write_bytes(canonical(app_captured))
        with self.assertRaisesRegex(preflight.PreflightError, "candidate-bundle-identifier-mismatch"):
            preflight.make_binding(self.binding_args(), self.runner)

    def test_preflight_then_exact_session_final_receipts_use_only_injected_observations(self):
        value = preflight._observe_before(self.args(), self.runner)
        preflight._write_new(str(self.receipt), value)
        self.assertEqual(value["schema_version"], "lidswitch-candidate-canary-receipt-v2")
        self.assertEqual(value["lid_observation"], {
            "method": "human-assertion", "state": "open", "property": "lid",
            "value": "open", "raw_sha256": "unavailable",
        })
        self.assertEqual(value["before"]["sleep_disabled"], 0)
        self.status.write_text(status("active", "steady", "12345678-1234-1234-1234-123456789abc"), encoding="utf-8")
        active_runner = lambda argv: (0, " SleepDisabled 1\n") if argv == ("/usr/bin/pmset", "-g", "live") else self.runner(argv)
        preflight.bind_active(str(self.receipt), str(self.active), str(self.status), str(self.manifest), str(self.binding), "/Applications/LidSwitch.app", "/Library/Application Support/LidSwitch/Current/LidSwitchHelper", active_runner)
        self.status.write_text(status("terminal", "peer-process-invalid", "12345678-1234-1234-1234-123456789abc"), encoding="utf-8")
        final_runner = lambda argv: (0, " SleepDisabled 0\n") if argv == ("/usr/bin/pmset", "-g", "live") else self.runner(argv)
        preflight.finalize(str(self.active), str(self.final), str(self.status), str(self.manifest), str(self.binding), "/Applications/LidSwitch.app", "/Library/Application Support/LidSwitch/Current/LidSwitchHelper", final_runner)
        final = preflight._canonical_json(self.final.read_bytes())
        self.assertEqual(final["session_uuid"], "12345678-1234-1234-1234-123456789abc")
        self.assertEqual(final["rollback"]["terminal_reason"], "peer-process-invalid")
        self.assertTrue(all(command[0] in {"/usr/bin/shasum", "/usr/bin/codesign", "/usr/sbin/sysctl", "/usr/bin/pgrep", "/usr/bin/pmset"} for command in self.commands))
        self.assertNotIn(("/usr/bin/pmset", "-a", "disablesleep", "0"), self.commands)

    def test_custom_sleep_accepts_both_native_section_orders_and_canonicalizes(self):
        expected = {"AC Power": 0, "Battery Power": 10}
        self.assertEqual(
            preflight._custom_sleep("AC Power:\n sleep 0\nBattery Power:\n sleep 10\n"),
            expected,
        )
        self.assertEqual(
            preflight._custom_sleep("Battery Power:\n sleep 10\nAC Power:\n sleep 0\n"),
            expected,
        )

    def test_preflight_rejects_unknown_lid_mode_and_binding_hash(self):
        bad = self.args(); bad.lid_open_observed = "yes"
        with self.assertRaisesRegex(preflight.PreflightError, "lid-open-observation-mode-invalid"):
            preflight._observe_before(bad, self.runner)
        self.binding_value["candidate_manifest_sha256"] = "f" * 64
        self.binding.write_bytes(canonical(self.binding_value))
        with self.assertRaisesRegex(preflight.PreflightError, "candidate-binding-mismatch"):
            preflight._binding(str(self.manifest), str(self.binding))

    def test_preflight_accepts_programmatic_open_lid_and_binds_exact_observation(self):
        args = self.args(); args.lid_open_observed = preflight.LID_OPEN_IOREG
        value = preflight._observe_before(args, self.runner_with_ioreg(IOREG_OPEN_OUTPUT))
        self.assertEqual(value["lid_observation"], {
            "method": "ioreg-AppleClamshellState",
            "state": "open",
            "property": "AppleClamshellState",
            "value": "No",
            "raw_sha256": hashlib.sha256(IOREG_OPEN_OUTPUT.encode("utf-8")).hexdigest(),
        })
        self.assertIn(preflight.IOREG_CLAMSHELL_COMMAND, self.commands)
        preflight._write_new(str(self.receipt), value)
        loaded, _ = preflight._load_receipt(str(self.receipt), "preflight")
        self.assertEqual(loaded["lid_observation"], value["lid_observation"])
        forged = json.loads(json.dumps(value))
        forged["lid_observation"]["value"] = "Yes"
        forged_path = self.root / "forged-lid-observation.json"
        preflight._write_new(str(forged_path), forged)
        with self.assertRaisesRegex(preflight.PreflightError, "receipt-schema-invalid"):
            preflight._load_receipt(str(forged_path), "preflight")

    def test_programmatic_lid_parser_rejects_closed_malformed_and_ambiguous_evidence(self):
        cases = (
            ("closed", IOREG_OPEN_OUTPUT.replace(" = No", " = Yes"), "lid-closed"),
            ("missing", "+-o IOPMrootDomain\n  | {\n  | }\n", "lid-state-observation-invalid"),
            ("malformed", "AppleClamshellState = No\n", "lid-state-observation-invalid"),
            ("ambiguous", IOREG_OPEN_OUTPUT + '  |   "AppleClamshellState" = Yes\n', "lid-state-observation-invalid"),
        )
        for label, output, error in cases:
            with self.subTest(label=label):
                args = self.args(); args.lid_open_observed = preflight.LID_OPEN_IOREG
                with self.assertRaisesRegex(preflight.PreflightError, error):
                    preflight._observe_before(args, self.runner_with_ioreg(output))

    def test_preflight_accepts_only_exact_production_safe_idle_status(self):
        accepted = (
            ("inactive", "pristine", "none"),
            ("inactive", "legacy-migration", "none"),
            ("inactive", "legacy-migration-superseded", "none"),
            ("terminal", "legacy-migration", "12345678-1234-1234-9234-123456789abc"),
        )
        for state_name, reason, session in accepted:
            with self.subTest(accepted=(state_name, reason, session)):
                self.status.write_text(status(state_name, reason, session), encoding="utf-8")
                observed = preflight._observe_before(self.args(), self.runner)
                self.assertEqual(observed["before"]["status_state"], state_name)
                self.assertEqual(observed["before"]["status_reason"], reason)
                self.assertEqual(observed["before"]["status_session"], session)
        rejected = (
            ("idle", "safe-idle", "none"),
            ("inactive", "unknown", "none"),
            ("inactive", "pristine", "12345678-1234-1234-1234-123456789abc"),
            ("terminal", "pristine", "12345678-1234-1234-9234-123456789abc"),
            ("inactive", "legacy-migration", "12345678-1234-1234-1234-123456789abc"),
            ("terminal", "legacy-migration", "none"),
            ("terminal", "legacy-migration-superseded", "12345678-1234-1234-9234-123456789abc"),
            ("terminal", "legacy-migration", "12345678-1234-1234-9234-123456789ABC"),
            ("terminal", "peer-process-invalid", "none"),
        )
        for state_name, reason, session in rejected:
            with self.subTest(rejected=(state_name, reason, session)):
                self.status.write_text(status(state_name, reason, session), encoding="utf-8")
                with self.assertRaisesRegex(preflight.PreflightError, "active-lease-present"):
                    preflight._observe_before(self.args(), self.runner)

        self.status.write_text(status("inactive", "legacy-migration", "none"), encoding="utf-8")
        forged = preflight._observe_before(self.args(), self.runner)
        forged["before"]["status_reason"] = "unknown"
        preflight._write_new(str(self.receipt), forged)
        with self.assertRaisesRegex(preflight.PreflightError, "receipt-schema-invalid"):
            preflight._load_receipt(str(self.receipt), "preflight")

    def test_preflight_rejects_stale_applied_state_and_has_no_mutating_command_source(self):
        pathlib.Path(self.args().applied_state).write_text("stale\n", encoding="utf-8")
        with self.assertRaisesRegex(preflight.PreflightError, "active-lease-present"):
            preflight._observe_before(self.args(), self.runner)
        source = (pathlib.Path(__file__).resolve().parent / "candidate_canary_preflight.py").read_text(encoding="utf-8")
        for forbidden in ("pmset -a", "launchctl", "sudo ", "/bin/kill"):
            self.assertNotIn(forbidden, source)

    def test_receipts_are_create_once_and_final_requires_the_same_session(self):
        preflight._write_new(str(self.receipt), preflight._observe_before(self.args(), self.runner))
        with self.assertRaises(FileExistsError):
            preflight._write_new(str(self.receipt), {"reused": True})
        self.status.write_text(status("active", "steady", "12345678-1234-1234-1234-123456789abc"), encoding="utf-8")
        preflight.bind_active(str(self.receipt), str(self.active), str(self.status), str(self.manifest), str(self.binding), "/Applications/LidSwitch.app", "/Library/Application Support/LidSwitch/Current/LidSwitchHelper", lambda argv: (0, " SleepDisabled 1\n") if argv == ("/usr/bin/pmset", "-g", "live") else self.runner(argv))
        self.status.write_text(status("terminal", "peer-process-invalid", "aaaaaaaa-1234-1234-1234-123456789abc"), encoding="utf-8")
        with self.assertRaisesRegex(preflight.PreflightError, "rollback-or-terminal-unverified"):
            preflight.finalize(str(self.active), str(self.final), str(self.status), str(self.manifest), str(self.binding), "/Applications/LidSwitch.app", "/Library/Application Support/LidSwitch/Current/LidSwitchHelper", lambda argv: (0, " SleepDisabled 0\n") if argv == ("/usr/bin/pmset", "-g", "live") else self.runner(argv))

    def test_live_script_requires_receipt_chain_without_removing_existing_rollback_checks(self):
        source = (pathlib.Path(__file__).resolve().parent / "validate_live_state.sh").read_text(encoding="utf-8")
        for token in ("LIDSWITCH_CANARY_PREFLIGHT_RECEIPT", "LIDSWITCH_CANARY_ACTIVE_RECEIPT", "LIDSWITCH_CANARY_FINAL_RECEIPT", "bind-active", "finalize", "kill -KILL", "system sleep did not restore", "sleep override rearmed"):
            self.assertIn(token, source)

    def test_peer_death_reason_is_bound_to_the_helper_source_contract(self):
        root = pathlib.Path(__file__).resolve().parent.parent
        helper = (root / "Sources/LidSwitchHelper/HelperControlService.swift").read_text(encoding="utf-8")
        canary = (root / "script/candidate_canary_preflight.py").read_text(encoding="utf-8")
        live = (root / "script/validate_live_state.sh").read_text(encoding="utf-8")
        self.assertIn('restoreActive(reason: "peer-process-invalid"', helper)
        self.assertIn('PEER_DEATH_REASON = "peer-process-invalid"', canary)
        self.assertIn('"peer-process-invalid"', live)
        self.assertNotIn("-".join(("peer", "invalidation")), canary + live)


if __name__ == "__main__":
    unittest.main(verbosity=2)
