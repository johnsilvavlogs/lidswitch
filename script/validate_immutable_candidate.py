#!/usr/bin/python3
"""Observational validator for one descriptor-held app-captured candidate."""
from __future__ import annotations
import argparse, os, sys
sys.dont_write_bytecode = True
sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
from immutable_candidate_core import (CandidateError, RootCapability, component,
    parse, read_canonical_leaf, read_inherited_receipt, validate_manifest,
    verify_candidate)

def run(args):
    envelope=read_inherited_receipt(args.envelope_receipt_fd,args.envelope_receipt_sha256)
    root=RootCapability.from_inherited_fd(args.candidate_root_fd)
    try:
        component(args.manifest); payload,_=read_canonical_leaf(root.root,args.manifest)
        manifest=validate_manifest(parse(payload),envelope,args.envelope_receipt_sha256)
        if manifest["phase"]!="app-captured": raise CandidateError("candidate-phase-incomplete")
        verify_candidate(root.root,manifest)
        return manifest
    finally: root.close()

def main(argv=None):
    parser=argparse.ArgumentParser(); parser.add_argument("--candidate-root-fd",type=int,required=True); parser.add_argument("--envelope-receipt-fd",type=int,required=True); parser.add_argument("--envelope-receipt-sha256",required=True); parser.add_argument("--manifest",default="candidate-manifest.json")
    args=parser.parse_args(argv)
    try: run(args)
    except (CandidateError,OSError) as error:
        print(str(error),file=sys.stderr); return 65
    return 0
if __name__=="__main__": raise SystemExit(main())
