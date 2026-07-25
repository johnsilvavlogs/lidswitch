#!/usr/bin/python3
"""Read-only verifier for an extracted hosted candidate evidence tree."""
from __future__ import annotations
import argparse, hashlib, json, os, stat
from pathlib import Path
def sha(path):
 h=hashlib.sha256()
 with open(path,'rb',buffering=0) as f:
  while (b:=f.read(131072)): h.update(b)
 return h.hexdigest()
def main():
 p=argparse.ArgumentParser(); p.add_argument('--evidence',type=Path,required=True); a=p.parse_args(); root=a.evidence.resolve(strict=True)
 ledger=root/'evidence-tree.json'; raw=ledger.read_bytes(); v=json.loads(raw)
 if json.dumps(v,sort_keys=True,separators=(',',':')).encode()+b'\n'!=raw or v.get('schema')!='lidswitch-hosted-evidence-v1': raise SystemExit('invalid evidence ledger')
 for rel,want in v.get('files',{}).items():
  if not isinstance(rel,str) or rel.startswith('/') or '..' in rel.split('/'): raise SystemExit('unsafe ledger path')
  leaf=root/rel; s=os.lstat(leaf)
  if leaf.is_symlink() or not stat.S_ISREG(s.st_mode) or s.st_size!=want.get('size') or sha(leaf)!=want.get('sha256'): raise SystemExit('evidence mismatch: '+rel)
 print(json.dumps({'evidence_tree_sha256':hashlib.sha256(raw).hexdigest(),'files_verified':len(v['files'])},sort_keys=True,separators=(',',':')))
if __name__=='__main__': main()
