import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VERIFY = ROOT / "orchestration/verify_hosted_candidate_evidence.py"


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(value, dict): value = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()+b"\n"
    if isinstance(value, str): value = value.encode()
    path.write_bytes(value)

def meta(path):
    return {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "size": path.stat().st_size, "mode": path.stat().st_mode & 0o777, "nlink": 1}


class HostedEvidenceFixtureTests(unittest.TestCase):
    def make_fixture(self):
        import runpy
        required = runpy.run_path(str(VERIFY))["REQUIRED"]
        temp = tempfile.TemporaryDirectory(); root = Path(temp.name)
        for rel in required: write(root/rel, b"payload")
        write(root/"orchestration/workflow.yml", b"workflow")
        write(root/"orchestration/bootstrap.py", b"bootstrap")
        write(root/"orchestration/collector.py", b"collector")
        write(root/"orchestration/verifier.py", b"verifier")
        write(root/"authority/entry.py", b"entry")
        write(root/"authority/contract.json", {"roles":{"wrapper":{"sha256":"w"},"capture_package":{"sha256":"a"},"assemble_package":{"sha256":"b"},"candidate_core":{"sha256":"c"},"build_manifest":{"sha256":"d"},"package_manifest":{"sha256":"e"},"validate_candidate":{"sha256":"f"},"validate_dmg":{"sha256":"g"}}})
        contract = meta(root/"authority/contract.json"); entry = meta(root/"authority/entry.py")
        policy = {"runner":{"image_version":"image"},"source":{"commit":"c","tree":"t","wrapper_sha256":"w"},"source_manifest_sha256":"m"}; write(root/"orchestration/policy.json", policy)
        authority = {"source":{"commit":"c","tree":"t","manifest_sha256":"m"},"generated":{"entry":entry,"contract":contract}}; write(root/"authority/ledger.json", authority); authority_meta=meta(root/"authority/ledger.json")
        for role, name in {"capture_package":"capture_immutable_build_envelope.py","assemble_package":"assemble_manual_adhoc_candidate.py","candidate_core":"immutable_candidate_core.py","build_manifest":"build_immutable_candidate.py","package_manifest":"package_immutable_candidate.py","validate_candidate":"validate_immutable_candidate.py","validate_dmg":"validate_immutable_dmg.py"}.items():
            write(root/"packaging"/name, role.encode()); authority["generated"] # leaves intentionally differ; fix contract next
        contract_value=json.loads((root/"authority/contract.json").read_text())
        for role,name in {"capture_package":"capture_immutable_build_envelope.py","assemble_package":"assemble_manual_adhoc_candidate.py","candidate_core":"immutable_candidate_core.py","build_manifest":"build_immutable_candidate.py","package_manifest":"package_immutable_candidate.py","validate_candidate":"validate_immutable_candidate.py","validate_dmg":"validate_immutable_dmg.py"}.items(): contract_value["roles"][role]["sha256"]=meta(root/"packaging"/name)["sha256"]
        write(root/"authority/contract.json",contract_value); contract=meta(root/"authority/contract.json"); authority["generated"]["contract"]=contract; write(root/"authority/ledger.json",authority); authority_meta=meta(root/"authority/ledger.json")
        pre=b"host_class=idle-uninstalled\nkernel_build=25E246\n"; post=pre; write(root/"authority/preflight-state.snapshot",pre); write(root/"authority/postflight-state.snapshot",post); preh=meta(root/"authority/preflight-state.snapshot")["sha256"]; posth=meta(root/"authority/postflight-state.snapshot")["sha256"]
        receipt=(f"schema=3\nterminal=idle-uninstalled\nkernel=25E246\nchild_command_exit=0\nwrapper_exit=0\noutcome=preserved\npreflight_sha256={preh}\npostflight_sha256={posth}\n").encode(); write(root/"authority/live-state-retained.receipt",receipt); write(root/"authority/live-envelope.json",{"receipt_sha256":meta(root/"authority/live-state-retained.receipt")["sha256"],"preflight_sha256":preh,"postflight_sha256":posth})
        for rel in ("release-output/LidSwitch","release-output/LidSwitchHelper","release-output/GeneratedReleaseHelperTrustAnchor.generated.swift","candidate/LidSwitch.dmg","candidate/LidSwitchHelper"): write(root/rel, rel.encode())
        app=meta(root/"release-output/LidSwitch"); helper=meta(root/"release-output/LidSwitchHelper"); anchor=meta(root/"release-output/GeneratedReleaseHelperTrustAnchor.generated.swift")
        write(root/"release-output/build-receipt.json",{"artifacts":{"app":{"sha256":app["sha256"]},"helper":{"sha256":helper["sha256"]}}})
        release={"build_receipt_sha256":meta(root/"release-output/build-receipt.json")["sha256"],"anchor_sha256":anchor["sha256"],"app":{"sha256":app["sha256"],"size":app["size"]},"helper":{"sha256":helper["sha256"],"size":helper["size"],"cdhash":"0"*40}}
        write(root/"package/build-envelope.json",{"schema_version":"lidswitch-verified-envelope-rev19","source_commit":"c","wrapper_sha256":"w","release_output":release}); env=meta(root/"package/build-envelope.json")
        manifest={"schema_version":"lidswitch-immutable-candidate-v3","source":{"commit":"c"},"envelope":{"receipt_sha256":env["sha256"]}}; write(root/"candidate/candidate-manifest.json",manifest); write(root/"candidate/package-manifest.json",manifest)
        write(root/"candidate/LidSwitch.dmg.sha256",meta(root/"candidate/LidSwitch.dmg")["sha256"]+"  LidSwitch.dmg\n")
        write(root/"receipts/prepare.json",{"ledger":{"sha256":authority_meta["sha256"]}})
        retained={n:meta(root/"authority"/("live-envelope.json" if n=="hosted-live-envelope.json" else n)) for n in ("live-state-retained.receipt","preflight-state.snapshot","postflight-state.snapshot","hosted-live-envelope.json")}; write(root/"receipts/build.json",{"ledger":{"sha256":authority_meta["sha256"]},"retained":retained})
        context={"schema":"lidswitch-hosted-workflow-context-v2","source_commit":"c","source_tree":"t","orchestration_commit_sha":"a"*40,"workflow_file_sha256":meta(root/"orchestration/workflow.yml")["sha256"],"workflow_ref":"refs/heads/main","reviewed_orchestration_sha":"a"*40,"run_id":"1","run_attempt":"1","image_version":"image","policy_sha256":meta(root/"orchestration/policy.json")["sha256"],"release_output":"r","package_parent":"p","candidate_root":"q","sdk_version":"v","driver_sha256":"d"}; write(root/"workflow-context.json",context)
        files={rel:meta(root/rel) for rel in required}; write(root/"evidence-tree.json",{"schema":"lidswitch-hosted-evidence-v2","files":files,"inventory":sorted(files),"bindings":{}})
        return temp,root
    def test_realistic_complete_fixture_is_accepted(self):
        temp,root=self.make_fixture(); run=subprocess.run(["/usr/bin/python3",str(VERIFY),"--evidence",str(root)],capture_output=True,text=True); temp.cleanup(); self.assertEqual(run.returncode,0,run.stderr)
    def test_dmg_checksum_drift_is_rejected(self):
        temp,root=self.make_fixture(); (root/"candidate/LidSwitch.dmg.sha256").write_text("0"*64); run=subprocess.run(["/usr/bin/python3",str(VERIFY),"--evidence",str(root),],capture_output=True); temp.cleanup(); self.assertNotEqual(run.returncode,0)
    def test_missing_output_leaf_is_rejected(self):
        temp,root=self.make_fixture(); (root/"release-output/LidSwitchHelper").unlink(); run=subprocess.run(["/usr/bin/python3",str(VERIFY),"--evidence",str(root)],capture_output=True); temp.cleanup(); self.assertNotEqual(run.returncode,0)
    def test_reviewed_context_drift_is_rejected(self):
        temp,root=self.make_fixture(); value=json.loads((root/"workflow-context.json").read_text()); value["reviewed_orchestration_sha"]="b"*40; write(root/"workflow-context.json",value); run=subprocess.run(["/usr/bin/python3",str(VERIFY),"--evidence",str(root)],capture_output=True); temp.cleanup(); self.assertNotEqual(run.returncode,0)
