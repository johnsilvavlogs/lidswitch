#!/usr/bin/python3
"""Observe exact package evidence and an externally extracted app tree; never mount/create."""
from __future__ import annotations
import argparse, os, sys
sys.dont_write_bytecode = True
sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
from immutable_candidate_core import (CandidateError, RootCapability, component,
    parse, read_canonical_leaf, read_inherited_receipt, validate_manifest,
    verify_candidate, verify_extracted_app)

def run(args):
    envelope=read_inherited_receipt(args.envelope_receipt_fd,args.envelope_receipt_sha256)
    candidate=RootCapability.from_inherited_fd(args.candidate_root_fd)
    extracted=RootCapability.from_inherited_fd(args.extracted_app_root_fd)
    try:
        component(args.manifest); payload,_=read_canonical_leaf(candidate.root,args.manifest)
        manifest=validate_manifest(parse(payload),envelope,args.envelope_receipt_sha256)
        if manifest["phase"] not in ("package-captured","qualified"): raise CandidateError("candidate-phase-incomplete")
        verify_candidate(candidate.root,manifest)
        verify_extracted_app(candidate.root,manifest["app"]["name"],extracted.root,args.extracted_app_name,manifest["package"]["extracted_tree_sha256"])
        return manifest
    finally:
        try: extracted.close()
        finally: candidate.close()

def main(argv=None):
    parser=argparse.ArgumentParser(); parser.add_argument("--candidate-root-fd",type=int,required=True); parser.add_argument("--extracted-app-root-fd",type=int,required=True); parser.add_argument("--extracted-app-name",required=True); parser.add_argument("--envelope-receipt-fd",type=int,required=True); parser.add_argument("--envelope-receipt-sha256",required=True); parser.add_argument("--manifest",default="package-manifest.json")
    args=parser.parse_args(argv)
    try: run(args)
    except (CandidateError,OSError) as error:
        print(str(error),file=sys.stderr); return 65
    return 0
if __name__=="__main__": raise SystemExit(main())
