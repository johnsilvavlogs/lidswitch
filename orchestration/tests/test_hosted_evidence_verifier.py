import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VERIFY = ROOT / "orchestration/verify_hosted_candidate_evidence.py"


def dump(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(json.dumps(value, sort_keys=True, separators=(",", ":")).encode() + b"\n")


class HostedEvidenceVerifierTests(unittest.TestCase):
    def evidence(self):
        tmp = tempfile.TemporaryDirectory(); root = Path(tmp.name)
        names = {"orchestration/workflow.yml": b"workflow", "orchestration/bootstrap.py": b"bootstrap", "orchestration/policy.json": None, "orchestration/collector.py": b"collector", "orchestration/verifier.py": b"verifier", "receipts/prepare.json": None, "receipts/build.json": None, "authority/ledger.json": None, "authority/entry.py": b"entry", "authority/contract.json": None, "authority/live-envelope.json": None, "authority/live-state-retained.receipt": b"schema=3\nterminal=idle-uninstalled\nkernel=25E246\nchild_command_exit=0\nwrapper_exit=0\noutcome=preserved\npreflight_sha256=x\npostflight_sha256=y\n", "authority/preflight-state.snapshot": b"pre", "authority/postflight-state.snapshot": b"post", "workflow-context.json": None, "source/source_snapshot_manifest.jsonl": b"manifest"}
        pre = hashlib.sha256(b"pre").hexdigest(); post = hashlib.sha256(b"post").hexdigest(); names["authority/live-state-retained.receipt"] = names["authority/live-state-retained.receipt"].replace(b"x", pre.encode()).replace(b"y", post.encode())
        policy = {"runner":{"image_version":"image"},"source":{"commit":"c","tree":"t","wrapper_sha256":"w"},"source_manifest_sha256":"m"}; names["orchestration/policy.json"] = policy
        contract = {"roles":{"wrapper":{"sha256":"w"}}}; names["authority/contract.json"] = contract
        authority = {"source":{"commit":"c","tree":"t","manifest_sha256":"m"},"generated":{"entry":{},"contract":{}}}; names["authority/ledger.json"] = authority
        context = {"old_context_key":"s"}; names["workflow-context.json"] = context
        for rel, value in names.items():
            path=root/rel
            if value is None:
                continue
            if isinstance(value, dict): dump(path,value)
            else: path.parent.mkdir(parents=True,exist_ok=True); path.write_bytes(value)
        files={}
        for path in root.rglob('*'):
            if path.is_file(): files[str(path.relative_to(root))]={"sha256":hashlib.sha256(path.read_bytes()).hexdigest(),"size":path.stat().st_size,"mode":path.stat().st_mode&0o777,"nlink":1}
        files["authority/ledger.json"]["sha256"] # force ordering clarity
        authority["generated"]["entry"]={"sha256":files["authority/entry.py"]["sha256"]}; authority["generated"]["contract"]={"sha256":files["authority/contract.json"]["sha256"]}; dump(root/"authority/ledger.json",authority)
        context["policy_sha256"]=files["orchestration/policy.json"]["sha256"]; dump(root/"workflow-context.json",context)
        for rel in ("authority/ledger.json","workflow-context.json"):
            p=root/rel; files[rel].update(sha256=hashlib.sha256(p.read_bytes()).hexdigest(),size=p.stat().st_size)
        for rel in ("receipts/prepare.json","receipts/build.json"):
            dump(root/rel,{"ledger":{"sha256":files["authority/ledger.json"]["sha256"]}})
            files[rel]={"sha256":hashlib.sha256((root/rel).read_bytes()).hexdigest(),"size":(root/rel).stat().st_size,"mode":0o644,"nlink":1}
        dump(root/"authority/live-envelope.json",{"receipt_sha256":files["authority/live-state-retained.receipt"]["sha256"],"preflight_sha256":pre,"postflight_sha256":post})
        files["authority/live-envelope.json"]={"sha256":hashlib.sha256((root/"authority/live-envelope.json").read_bytes()).hexdigest(),"size":(root/"authority/live-envelope.json").stat().st_size,"mode":0o644,"nlink":1}
        ledger={"schema":"lidswitch-hosted-evidence-v2","files":files,"inventory":sorted(files),"bindings":{}}; dump(root/"evidence-tree.json",ledger); return tmp,root
    def reject(self, mutate):
        tmp, root=self.evidence(); mutate(root); run=subprocess.run(["/usr/bin/python3",str(VERIFY),"--evidence",str(root)],capture_output=True,text=True); tmp.cleanup(); self.assertNotEqual(run.returncode,0)
    def test_rejects_empty_ledger(self): self.reject(lambda r: dump(r/"evidence-tree.json",{"schema":"lidswitch-hosted-evidence-v2","files":{},"inventory":[],"bindings":{}}))
    def test_rejects_missing_receipt(self): self.reject(lambda r: (r/"authority/live-state-retained.receipt").unlink())
    def test_rejects_extra_leaf(self): self.reject(lambda r: (r/"extra").write_text("x"))
    def test_rejects_cross_binding_mismatch(self): self.reject(lambda r: dump(r/"workflow-context.json",{"source_commit":"bad"}))
    def test_rejects_authority_hash_drift(self): self.reject(lambda r: (r/"authority/entry.py").write_text("changed"))
