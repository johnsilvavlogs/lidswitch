#!/usr/bin/python3
"""Freeze a hosted candidate's reviewed inputs and retained outputs into one tree."""
from __future__ import annotations
import argparse, hashlib, json, os, shutil, stat
from pathlib import Path

MAX = 1024 * 1024 * 1024
def canon(v): return json.dumps(v, sort_keys=True, separators=(",", ":")).encode()+b"\n"
def digest(p: Path):
    h=hashlib.sha256()
    with p.open("rb", buffering=0) as f:
        while True:
            b=f.read(131072)
            if not b: return h.hexdigest()
            h.update(b)
def regular(p: Path):
    s=os.lstat(p)
    if p.is_symlink() or not stat.S_ISREG(s.st_mode) or s.st_nlink != 1 or not 0 < s.st_size <= MAX: raise ValueError("unsafe evidence leaf: "+str(p))
    d=digest(p); after=os.lstat(p)
    if (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns)!=(after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns): raise ValueError("drift evidence leaf: "+str(p))
    return {"sha256":d,"size":s.st_size,"mode":stat.S_IMODE(s.st_mode)}
def copy_leaf(src:Path,dst:Path, rows):
    meta=regular(src); dst.parent.mkdir(mode=0o700,parents=True,exist_ok=True); shutil.copyfile(src,dst); os.chmod(dst,0o400)
    if regular(dst)["sha256"] != meta["sha256"]: raise ValueError("copy mismatch")
    rows[str(dst.relative_to(dst.parents[len(dst.parts)-len(dst.parts)]))] = meta
def main():
    p=argparse.ArgumentParser(); p.add_argument('--source',type=Path,required=True); p.add_argument('--authority',type=Path,required=True); p.add_argument('--package-parent',type=Path,required=True); p.add_argument('--candidate-root',type=Path,required=True); p.add_argument('--release-output',type=Path,required=True); p.add_argument('--workflow-context',type=Path,required=True); p.add_argument('--output',type=Path,required=True); a=p.parse_args()
    if a.output.exists(): raise SystemExit('evidence output already exists')
    a.output.mkdir(mode=0o700); rows={}
    wanted=[(a.source/'script/source_snapshot_manifest.jsonl','source/source_snapshot_manifest.jsonl'),(a.source/'script/release.env','source/release.env'),(a.authority/'hosted-authority-ledger.json','authority/hosted-authority-ledger.json'),(a.authority/'hosted-held-entry.py','authority/hosted-held-entry.py'),(a.authority/'hosted-held-contract.json','authority/hosted-held-contract.json'),(a.authority/'hosted-live-envelope.json','authority/hosted-live-envelope.json'),(a.package_parent/'build-envelope.json','package/build-envelope.json'),(a.workflow_context,'workflow-context.json')]
    for n in ('candidate-manifest.json','package-manifest.json','LidSwitch.dmg','LidSwitch.dmg.sha256','LidSwitchHelper'):
        wanted.append((a.candidate_root/n,'candidate/'+n))
    for n in ('LidSwitch','LidSwitchHelper','build-receipt.json','GeneratedReleaseHelperTrustAnchor.generated.swift'):
        wanted.append((a.release_output/n,'release-output/'+n))
    for src,rel in wanted:
        meta=regular(src); dst=a.output/rel; dst.parent.mkdir(mode=0o700,parents=True,exist_ok=True); shutil.copyfile(src,dst); os.chmod(dst,0o400)
        if regular(dst)['sha256']!=meta['sha256']: raise SystemExit('evidence copy mismatch')
        rows[rel]=meta
    payload=canon({'schema':'lidswitch-hosted-evidence-v1','files':rows})
    (a.output/'evidence-tree.json').write_bytes(payload); os.chmod(a.output/'evidence-tree.json',0o400)
    print(json.dumps({'evidence_tree_sha256':hashlib.sha256(payload).hexdigest(),'output':str(a.output)},sort_keys=True,separators=(',',':')))
if __name__=='__main__': main()
