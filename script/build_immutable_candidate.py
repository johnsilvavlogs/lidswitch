#!/usr/bin/python3
"""Publish an app-captured manifest from descriptor-held, already captured bytes.

This entry is deliberately not a compiler, signer, or source-snapshot producer.
The accepted safe-envelope producer passes only inherited descriptors and pins
their SHA-256 values at invocation time.
"""
from __future__ import annotations
import argparse, os, sys
sys.dont_write_bytecode = True
sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
from immutable_candidate_core import (CandidateError, RootCapability,
    build_manifest_from_pinned_descriptor, canonical, parse, publish,
    read_canonical_leaf, validate_manifest, verify_candidate)

def run(args, ops=None):
    capability=RootCapability.from_inherited_fd(args.candidate_root_fd)
    try:
        manifest,envelope=build_manifest_from_pinned_descriptor(
            args.envelope_receipt_fd,args.envelope_receipt_sha256,
            args.build_descriptor_fd,args.build_descriptor_sha256)
        verify_candidate(capability.root,manifest)
        payload=canonical(manifest); publish(capability.root,args.manifest,payload,ops)
        reopened,_=read_canonical_leaf(capability.root,args.manifest)
        published=validate_manifest(parse(reopened),envelope,args.envelope_receipt_sha256)
        if reopened!=payload or published["candidate_id"]!=manifest["candidate_id"]: raise CandidateError("committed-uncertain")
        verify_candidate(capability.root,published)
        return manifest
    finally:
        capability.close()

def main(argv=None):
    parser=argparse.ArgumentParser()
    parser.add_argument("--candidate-root-fd",type=int,required=True)
    parser.add_argument("--envelope-receipt-fd",type=int,required=True)
    parser.add_argument("--envelope-receipt-sha256",required=True)
    parser.add_argument("--build-descriptor-fd",type=int,required=True)
    parser.add_argument("--build-descriptor-sha256",required=True)
    parser.add_argument("--manifest",default="candidate-manifest.json")
    args=parser.parse_args(argv)
    try: run(args)
    except (CandidateError,OSError) as error:
        print(str(error),file=sys.stderr); return 65
    return 0
if __name__=="__main__": raise SystemExit(main())
