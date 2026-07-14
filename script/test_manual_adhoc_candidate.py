#!/usr/bin/python3
"""Inert contract checks for the zero-cost manual-ad-hoc assembler."""
from __future__ import annotations
import importlib.util
import hashlib
import json
import os
import pathlib
import plistlib
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("manual", ROOT / "assemble_manual_adhoc_candidate.py")
manual = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(manual)
ENVELOPE_SPEC = importlib.util.spec_from_file_location("envelope", ROOT / "capture_immutable_build_envelope.py")
envelope = importlib.util.module_from_spec(ENVELOPE_SPEC); ENVELOPE_SPEC.loader.exec_module(envelope)

class ManualAdhocCandidateContractTests(unittest.TestCase):
    def test_frozen_release_output_rejects_substituted_artifact_and_stale_receipt(self):
        with tempfile.TemporaryDirectory(dir=str(pathlib.Path.home())) as raw:
            root = pathlib.Path(raw); os.chmod(root, 0o700)
            app, helper, anchor = b"app", b"helper", b"anchor"
            manifest, identity_bytes = b"manifest", b"identity"
            inputs = {name: "c" * 64 for name in ("appSourceSeal", "baseManifestSHA256", "generatedAnchorSHA256", "helperSourceSeal", "releaseIdentitySHA256", "trustAnchorTemplateSHA256")}
            inputs.update(baseManifestSHA256=hashlib.sha256(manifest).hexdigest(), generatedAnchorSHA256=hashlib.sha256(anchor).hexdigest(), releaseIdentitySHA256=hashlib.sha256(identity_bytes).hexdigest())
            receipt = {"artifacts": {"app": {"identifier": "com.johnsilva.LidSwitch", "sha256": hashlib.sha256(app).hexdigest(), "size": len(app)}, "helper": {"cdhash": "a" * 40, "identifier": "com.johnsilva.lidswitch.helper", "sha256": hashlib.sha256(helper).hexdigest(), "signature": "adhoc", "size": len(helper), "teamIdentifier": None, "timestamp": None}}, "build": {"configuration": "release", "network": False, "paidLicenses": [], "releaseCandidateDefine": True, "signing": "manual-ad-hoc", "stages": ["helper", "app"]}, "captures": {name: "b" * 64 + ":" + "c" * 64 for name in ("app-bin-path", "app-build", "helper-bin-path", "helper-build", "helper-identity", "helper-sign", "helper-verify")}, "inputs": inputs, "schema": "lidswitch-held-release-build-v1", "toolchain": {"componentSealSHA256": "d" * 64, "driverIdentity": "1:swift-frontend", "profileSHA256": "e" * 64, "root": "/Library/Developer/CommandLineTools", "sdk": "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"}}
            for name, payload, mode in (("LidSwitch", app, 0o555), ("LidSwitchHelper", helper, 0o555), ("GeneratedReleaseHelperTrustAnchor.generated.swift", anchor, 0o444), ("build-receipt.json", json.dumps(receipt, sort_keys=True, separators=(",", ":")).encode() + b"\n", 0o444)):
                path = root / name; path.write_bytes(payload); os.chmod(path, mode)
            os.chmod(root, 0o555)
            observed = envelope.read_release_output(str(root))
            self.assertEqual(observed["app"]["sha256"], hashlib.sha256(app).hexdigest())
            envelope.require_source_manifest_binding(observed, manifest)
            self.assertEqual(observed["release_identity_sha256"], hashlib.sha256(identity_bytes).hexdigest())
            with self.assertRaisesRegex(ValueError, "release-output-source-manifest-mismatch"):
                envelope.require_source_manifest_binding(observed, b"other-manifest")
            os.chmod(root, 0o700); os.chmod(root / "LidSwitch", 0o755); (root / "LidSwitch").write_bytes(b"other"); os.chmod(root / "LidSwitch", 0o555); os.chmod(root, 0o555)
            with self.assertRaisesRegex(ValueError, "release-output-artifact-mismatch"):
                envelope.read_release_output(str(root))
            os.chmod(root, 0o700); os.chmod(root / "LidSwitch", 0o755); (root / "LidSwitch").write_bytes(app); os.chmod(root / "LidSwitch", 0o555)
            stale = dict(receipt); stale["artifacts"] = dict(receipt["artifacts"]); stale["artifacts"]["helper"] = dict(receipt["artifacts"]["helper"]); stale["artifacts"]["helper"]["sha256"] = "f" * 64
            os.chmod(root / "build-receipt.json", 0o644); (root / "build-receipt.json").write_bytes(json.dumps(stale, sort_keys=True, separators=(",", ":")).encode() + b"\n"); os.chmod(root / "build-receipt.json", 0o444); os.chmod(root, 0o555)
            with self.assertRaisesRegex(ValueError, "release-output-artifact-mismatch"):
                envelope.read_release_output(str(root))
    def test_free_tool_inventory_is_exact_and_local(self):
        self.assertEqual(manual.TOOLS, {"codesign": "/usr/bin/codesign", "hdiutil": "/usr/bin/hdiutil", "ditto": "/usr/bin/ditto", "shasum": "/usr/bin/shasum"})

    def test_output_root_normalizes_private_tmp_group_and_holds_exact_identity(self):
        with tempfile.TemporaryDirectory(prefix="lidswitch-assembler-test.", dir="/private/tmp") as raw:
            parent = pathlib.Path(raw)
            os.chmod(parent, 0o700)
            output = manual.fresh_private_root(str(parent / "candidate"))
            observed = os.lstat(output)
            self.assertTrue(observed.st_mode & 0o040000)
            self.assertEqual(observed.st_uid, os.getuid())
            self.assertEqual(observed.st_gid, os.getgid())
            self.assertEqual(observed.st_mode & 0o777, 0o700)
            self.assertGreaterEqual(observed.st_nlink, 2)

    def test_paid_or_xcode_release_paths_are_absent(self):
        text = (ROOT / "assemble_manual_adhoc_candidate.py").read_text(encoding="utf-8")
        for forbidden in ("notarytool", "xcodebuild", "altool", "APPLE_ID", "TEAM_ID"):
            self.assertNotIn(forbidden, text)
        self.assertIn('"--sign", "-"', text)
        self.assertIn('"--timestamp=none"', text)

    def test_codesign_cdhash_is_read_from_success_stderr(self):
        completed = SimpleNamespace(returncode=0, stdout="", stderr="Executable=/private/tmp/LidSwitchHelper\nCDHash=" + "a" * 40 + "\n")
        with mock.patch.object(manual.subprocess, "run", return_value=completed):
            self.assertEqual(manual.cdhash(pathlib.Path("/private/tmp/LidSwitchHelper")), "a" * 40)

    def test_pre_signed_helper_verification_never_signs_the_helper(self):
        helper = pathlib.Path(__file__)
        inspection = "\n".join((
            "Identifier=com.johnsilva.lidswitch.helper",
            "Signature=adhoc",
            "TeamIdentifier=not set",
            "CDHash=" + "b" * 40,
        )) + "\n"
        commands = []

        def fake_run(argv, **kwargs):
            commands.append(argv)
            return inspection if kwargs.get("capture_stderr") else ""

        with mock.patch.object(manual, "run", side_effect=fake_run):
            measured = manual.signature_metadata(helper, "com.johnsilva.lidswitch.helper")
        self.assertEqual(measured["cdhash"], "b" * 40)
        self.assertFalse(any("--sign" in command for command in commands))
        self.assertEqual(commands[0][1:4], ["--verify", "--strict", "--verbose=2"])

    def test_helper_drift_after_outer_app_sign_is_rejected(self):
        before = {"sha256": "a" * 64, "size": 12,
                  "identifier": "com.johnsilva.lidswitch.helper", "cdhash": "b" * 40}
        after = dict(before); after["sha256"] = "c" * 64
        with self.assertRaisesRegex(manual.AssemblyError, "helper-drift-after-app-sign: sha256"):
            manual.require_unchanged_helper(before, after)

    def test_candidate_publishes_an_exact_descriptor_addressable_helper_leaf(self):
        expected = {"sha256": "a" * 64, "size": 12,
                    "identifier": "com.johnsilva.lidswitch.helper", "cdhash": "b" * 40}
        with tempfile.TemporaryDirectory(dir=str(pathlib.Path.home())) as raw:
            candidate = pathlib.Path(raw); bundled = candidate / "bundled-helper"
            bundled.write_bytes(b"helper-bytes")
            with mock.patch.object(manual, "signature_metadata", return_value=expected) as inspect:
                published = manual.publish_candidate_helper(
                    candidate, bundled, "com.johnsilva.lidswitch.helper", expected)
            self.assertEqual(published, candidate / "LidSwitchHelper")
            self.assertEqual(published.read_bytes(), b"helper-bytes")
            self.assertEqual(published.stat().st_mode & 0o777, 0o755)
            inspect.assert_called_once_with(published, "com.johnsilva.lidswitch.helper")

    def test_outer_app_is_signed_exactly_once(self):
        app = pathlib.Path("/private/tmp/LidSwitch.app")
        commands = []

        def fake_run(argv, **kwargs):
            commands.append(argv)
            return ""

        with mock.patch.object(manual, "run", side_effect=fake_run), \
             mock.patch.object(manual, "signature_identity", return_value={"identifier": "com.johnsilva.LidSwitch", "cdhash": "d" * 40}):
            self.assertEqual(manual.sign_outer_app(app, "com.johnsilva.LidSwitch"), "d" * 40)
        sign_commands = [command for command in commands if "--sign" in command]
        self.assertEqual(sign_commands, [[manual.TOOLS["codesign"], "--force", "--sign", "-", "--timestamp=none", str(app)]])

    def test_outer_app_signature_inspection_never_hashes_the_bundle_directory(self):
        app = pathlib.Path("/private/tmp/LidSwitch.app")
        with mock.patch.object(manual, "run", return_value=""), \
             mock.patch.object(manual, "signature_identity", return_value={"identifier": "com.johnsilva.LidSwitch", "cdhash": "d" * 40}) as inspect, \
             mock.patch.object(manual, "sha256_path", side_effect=AssertionError("directory hashing is forbidden")):
            self.assertEqual(manual.sign_outer_app(app, "com.johnsilva.LidSwitch"), "d" * 40)
        inspect.assert_called_once_with(app, "com.johnsilva.LidSwitch")

    def test_assembler_requires_and_declares_the_bundle_icon(self):
        text = (ROOT / "assemble_manual_adhoc_candidate.py").read_text(encoding="utf-8")
        self.assertIn('regular_input(str(ROOT.parent / "Resources" / "LidSwitch.icns"), "app-icon")', text)
        self.assertIn('"CFBundleIconFile": "LidSwitch"', text)
        self.assertIn('shutil.copyfile(icon, resources / "LidSwitch.icns")', text)

    def test_release_identity_and_menu_bar_bundle_metadata_are_preserved(self):
        identity = {"appBundleIdentifier": "com.johnsilva.LidSwitch", "appVersion": "1.2.3", "appBuild": 4}
        identity_bytes = json.dumps(identity, sort_keys=True, separators=(",", ":")).encode() + b"\n"
        origin = {"release_identity_sha256": hashlib.sha256(identity_bytes).hexdigest()}
        manual.require_release_identity_binding(origin, identity_bytes)
        with self.assertRaisesRegex(manual.AssemblyError, "bound-release-identity-digest-mismatch"):
            manual.require_release_identity_binding(origin, b"other")
        with tempfile.TemporaryDirectory(dir=str(pathlib.Path.home())) as raw:
            root = pathlib.Path(raw); app_binary = root / "app"; helper_binary = root / "helper"; icon = root / "icon"
            app_binary.write_bytes(b"app"); helper_binary.write_bytes(b"helper"); icon.write_bytes(b"icon")
            bundle, _ = manual.make_app_bundle(root, app_binary, helper_binary, icon, identity, identity_bytes)
            with (bundle / "Contents" / "Info.plist").open("rb") as handle:
                info = plistlib.load(handle)
            self.assertTrue(info["LSUIElement"])
            self.assertTrue(info["NSHighResolutionCapable"])
            self.assertEqual(info["NSPrincipalClass"], "NSApplication")
            self.assertEqual((bundle / "Contents" / "Resources" / "LidSwitchReleaseIdentity.json").read_bytes(), identity_bytes)

    def test_assembler_requires_prebuilt_held_outputs_and_envelope(self):
        self.assertEqual(manual.main([]), 65)
        self.assertEqual(manual.main(["--check-tools", "--output-root", "/private/tmp/nope"]), 65)

    def test_envelope_capture_is_observational_only(self):
        text = (ROOT / "capture_immutable_build_envelope.py").read_text(encoding="utf-8")
        for forbidden in ("subprocess", "codesign --", "hdiutil", "swift build", "xcodebuild", "os.system"):
            self.assertNotIn(forbidden, text)
        self.assertIn("source_tree_sha256", text)
        self.assertIn("toolchain_sha256", text)

    def test_envelope_receipt_normalizes_private_tmp_group(self):
        payload = b'{"schema":"fixture"}\n'
        with tempfile.TemporaryDirectory(prefix="lidswitch-envelope-test.", dir="/private/tmp") as raw:
            output = pathlib.Path(raw) / "build-envelope.json"
            envelope.write_private_receipt(output, payload)
            observed = os.lstat(output)
            self.assertEqual(output.read_bytes(), payload)
            self.assertEqual(observed.st_uid, os.getuid())
            self.assertEqual(observed.st_gid, os.getgid())
            self.assertEqual(observed.st_mode & 0o777, 0o600)
            self.assertEqual(observed.st_nlink, 1)

    def test_envelope_accepts_only_the_fixed_clt_swift_driver_symlink(self):
        path, payload = envelope.read_swift_driver("/Library/Developer/CommandLineTools/usr/bin/swift")
        self.assertEqual(path, pathlib.Path("/Library/Developer/CommandLineTools/usr/bin/swift"))
        self.assertGreater(len(payload), 0)
        with self.assertRaises(ValueError):
            envelope.read_swift_driver("/usr/bin/swift")

if __name__ == "__main__":
    unittest.main()
