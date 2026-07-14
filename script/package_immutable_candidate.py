#!/usr/bin/python3
"""Publish package evidence for a captured app; this module never packages or signs."""
from __future__ import annotations
import argparse, os, sys
sys.dont_write_bytecode = True
sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
from immutable_candidate_core import (CandidateError, RootCapability, canonical,
    package_manifest_from_pinned_descriptor, parse, publish, read_canonical_leaf,
    validate_manifest, verify_candidate, verify_extracted_app)

def run(args, ops=None):
    candidate=RootCapability.from_inherited_fd(args.candidate_root_fd)
    extracted=RootCapability.from_inherited_fd(args.extracted_app_root_fd)
    try:
        manifest,envelope=package_manifest_from_pinned_descriptor(
            args.envelope_receipt_fd,args.envelope_receipt_sha256,
            args.app_manifest_fd,args.app_manifest_sha256,
            args.package_descriptor_fd,args.package_descriptor_sha256)
        verify_candidate(candidate.root,manifest)
        verify_extracted_app(candidate.root,manifest["app"]["name"],extracted.root,args.extracted_app_name,manifest["package"]["extracted_tree_sha256"])
        payload=canonical(manifest); publish(candidate.root,args.manifest,payload,ops)
        reopened,_=read_canonical_leaf(candidate.root,args.manifest)
        published=validate_manifest(parse(reopened),envelope,args.envelope_receipt_sha256)
        if reopened!=payload or published["candidate_id"]!=manifest["candidate_id"]: raise CandidateError("committed-uncertain")
        verify_candidate(candidate.root,published)
        return manifest
    finally:
        try: extracted.close()
        finally: candidate.close()

def main(argv=None):
    parser=argparse.ArgumentParser()
    parser.add_argument("--candidate-root-fd",type=int,required=True)
    parser.add_argument("--extracted-app-root-fd",type=int,required=True)
    parser.add_argument("--extracted-app-name",required=True)
    parser.add_argument("--envelope-receipt-fd",type=int,required=True)
    parser.add_argument("--envelope-receipt-sha256",required=True)
    parser.add_argument("--app-manifest-fd",type=int,required=True)
    parser.add_argument("--app-manifest-sha256",required=True)
    parser.add_argument("--package-descriptor-fd",type=int,required=True)
    parser.add_argument("--package-descriptor-sha256",required=True)
    parser.add_argument("--manifest",default="package-manifest.json")
    args=parser.parse_args(argv)
    try: run(args)
    except (CandidateError,OSError) as error:
        print(str(error),file=sys.stderr); return 65
    return 0
if __name__=="__main__": raise SystemExit(main())
