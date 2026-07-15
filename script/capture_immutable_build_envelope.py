#!/usr/bin/python3
"""Capture the immutable v3 envelope consumed by the free candidate assembler.

The held launcher remains the execution authority.  This command only freezes
the already-reviewed source-manifest, held build wrapper, selected Swift binary,
and fixed local packaging-tool identities into one canonical create-once JSON
receipt; it never compiles, signs, packages, mounts, or launches anything.
"""
from __future__ import annotations
import argparse, hashlib, json, os, re, stat, sys
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
from immutable_candidate_core import CandidateError, ENVELOPE_SCHEMA, MAX_FILE, canonical, parse, read_leaf_bytes

TOOLS = ("/usr/bin/python3",)

def deny(message: str) -> None: raise ValueError(message)
def read_regular(value: str, label: str) -> tuple[Path, bytes]:
    supplied = Path(value).expanduser()
    if supplied.is_symlink(): deny("unsafe-" + label)
    path = supplied.resolve(strict=True); info = os.lstat(path)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_mode & 0o022 or info.st_size <= 0: deny("unsafe-" + label)
    data = path.read_bytes()
    if len(data) != info.st_size or os.lstat(path).st_ino != info.st_ino: deny("drift-" + label)
    return path, data
def read_swift_driver(value: str) -> tuple[Path, bytes]:
    supplied = Path(value).expanduser()
    expected = Path("/Library/Developer/CommandLineTools/usr/bin/swift")
    if supplied != expected: deny("unsafe-swift")
    link = os.lstat(supplied)
    if not stat.S_ISLNK(link.st_mode) or link.st_uid != 0 or link.st_gid != 0 or link.st_nlink != 1:
        deny("unsafe-swift")
    if os.readlink(supplied) != "swift-frontend": deny("unsafe-swift")
    path = supplied.resolve(strict=True)
    if path != expected.with_name("swift-frontend"): deny("unsafe-swift")
    info = os.lstat(path)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_gid != 0 or info.st_nlink != 1 or info.st_mode & 0o022 or info.st_size <= 0:
        deny("unsafe-swift")
    data = path.read_bytes()
    after = os.lstat(path)
    if len(data) != info.st_size or (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns) != (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns):
        deny("drift-swift")
    return supplied, data
def digest(data: bytes) -> str: return hashlib.sha256(data).hexdigest()
def require_source_manifest_binding(release_output: dict[str, object], manifest_bytes: bytes) -> None:
 if release_output.get("source_manifest_sha256")!=digest(manifest_bytes): deny("release-output-source-manifest-mismatch")
def executable(path: Path) -> dict[str, str]:
 return {"role": path.name.lower().replace(".", "-"), "path": str(path), "sha256": digest(path.read_bytes())}
def release_output_seal(entries: dict[str, tuple[int, str]]) -> str:
 return hashlib.sha256(b"".join((f"{name}|{entries[name][0]}|{entries[name][1]}\n").encode("ascii") for name in sorted(entries))).hexdigest()
def write_private_receipt(output: Path, payload: bytes) -> None:
    if output.exists() or output.is_symlink(): deny("output-must-not-exist")
    output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC
    fd = os.open(output, flags, 0o600)
    try:
        created = os.fstat(fd)
        if not stat.S_ISREG(created.st_mode) or created.st_uid != os.getuid() or created.st_nlink != 1:
            deny("output-identity-invalid")
        # Files created below Darwin's sticky /private/tmp may inherit wheel.
        # Normalize the held receipt before it becomes descriptor authority.
        if created.st_gid != os.getgid():
            os.fchown(fd, -1, os.getgid())
        os.fchmod(fd, 0o600)
        offset = 0
        interruptions = 0
        while offset < len(payload):
            try:
                written = os.write(fd, payload[offset:])
            except InterruptedError:
                interruptions += 1
                if interruptions > 16: deny("output-write-interrupted")
                continue
            if written <= 0: deny("output-write-incomplete")
            offset += written
        os.fsync(fd)
        held = os.fstat(fd)
        visible = os.lstat(output)
        identity = lambda info: (info.st_dev, info.st_ino, info.st_uid, info.st_gid,
                                 info.st_mode, info.st_nlink, info.st_size)
        if (identity(held) != identity(visible)
                or not stat.S_ISREG(held.st_mode)
                or held.st_uid != os.getuid()
                or held.st_gid != os.getgid()
                or stat.S_IMODE(held.st_mode) != 0o600
                or held.st_nlink != 1
                or held.st_size != len(payload)):
            deny("output-identity-invalid")
    finally:
        os.close(fd)
def _receipt(value: object) -> dict[str, object]:
 if not isinstance(value,dict) or tuple(value)!=("artifacts","build","captures","inputs","schema","toolchain"): deny("release-receipt-invalid")
 if value["schema"]!="lidswitch-held-release-build-v1": deny("release-receipt-invalid")
 artifacts=value["artifacts"]
 if not isinstance(artifacts,dict) or tuple(artifacts)!=("app","helper"): deny("release-receipt-invalid")
 app,helper=artifacts["app"],artifacts["helper"]
 if not isinstance(app,dict) or tuple(app)!=("identifier","sha256","size") or not isinstance(helper,dict) or tuple(helper)!=("cdhash","identifier","sha256","signature","size","teamIdentifier","timestamp"): deny("release-receipt-invalid")
 if not isinstance(app["identifier"],str) or not isinstance(helper["identifier"],str) or app["size"]<=0 or helper["size"]<=0 or helper["signature"]!="adhoc" or helper["teamIdentifier"] is not None or helper["timestamp"] is not None: deny("release-receipt-invalid")
 for item in (app["sha256"],helper["sha256"]):
  if not isinstance(item,str) or len(item)!=64 or any(c not in "0123456789abcdef" for c in item): deny("release-receipt-invalid")
 if not isinstance(helper["cdhash"],str) or len(helper["cdhash"])!=40 or any(c not in "0123456789abcdef" for c in helper["cdhash"]): deny("release-receipt-invalid")
 if app["identifier"]!="com.johnsilva.LidSwitch" or helper["identifier"]!="com.johnsilva.lidswitch.helper": deny("release-receipt-invalid")
 build=value["build"]
 if build!={"configuration":"release","network":False,"paidLicenses":[],"releaseCandidateDefine":True,"signing":"manual-ad-hoc","stages":["helper","app"]}: deny("release-receipt-invalid")
 captures=value["captures"]; inputs=value["inputs"]; toolchain=value["toolchain"]
 if not isinstance(captures,dict) or tuple(sorted(captures))!=("app-bin-path","app-build","helper-bin-path","helper-build","helper-identity","helper-sign","helper-verify"): deny("release-receipt-invalid")
 if not isinstance(inputs,dict) or tuple(inputs)!=("appSourceSeal","baseManifestSHA256","generatedAnchorSHA256","helperSourceSeal","releaseIdentitySHA256","trustAnchorTemplateSHA256"): deny("release-receipt-invalid")
 if not isinstance(toolchain,dict) or tuple(toolchain)!=("componentSealSHA256","driverIdentity","profileSHA256","root","sdk"): deny("release-receipt-invalid")
 for item in captures.values():
  if not isinstance(item,str) or not re.fullmatch(r"[0-9a-f]{64}:[0-9a-f]{64}",item): deny("release-receipt-invalid")
 for item in list(inputs.values())+[toolchain["componentSealSHA256"],toolchain["profileSHA256"]]:
  if not isinstance(item,str) or len(item)!=64 or any(c not in "0123456789abcdef" for c in item): deny("release-receipt-invalid")
 if toolchain["root"]!="/Library/Developer/CommandLineTools" or not isinstance(toolchain["sdk"],str) or not toolchain["sdk"].startswith(toolchain["root"]+"/SDKs/") or not isinstance(toolchain["driverIdentity"],str) or not re.fullmatch(r"[0-9:]+:swift-frontend",toolchain["driverIdentity"]): deny("release-receipt-invalid")
 return value
def read_release_output(value: str) -> dict[str, object]:
 supplied=Path(value).expanduser()
 if supplied.is_symlink(): deny("unsafe-release-output")
 root_fd=os.open(str(supplied.resolve(strict=True)),os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW|os.O_CLOEXEC)
 try:
  root_info=os.fstat(root_fd)
  if not stat.S_ISDIR(root_info.st_mode) or root_info.st_uid!=os.getuid() or root_info.st_gid!=os.getgid() or stat.S_IMODE(root_info.st_mode)!=0o555: deny("release-output-metadata-invalid")
  expected={"GeneratedReleaseHelperTrustAnchor.generated.swift":0o444,"LidSwitch":0o555,"LidSwitchHelper":0o555,"build-receipt.json":0o444}
  if sorted(os.listdir(root_fd))!=sorted(expected): deny("release-output-inventory-invalid")
  entries={}
  payloads={}
  for name,mode in expected.items():
   payload,info=read_leaf_bytes(root_fd,name,MAX_FILE if name in ("LidSwitch","LidSwitchHelper") else 262144)
   if stat.S_IMODE(info.st_mode)!=mode or info.st_nlink!=1 or info.st_size<=0: deny("release-output-metadata-invalid")
   entries[name]=(info.st_size,digest(payload)); payloads[name]=payload
  receipt=_receipt(parse(payloads["build-receipt.json"]))
  app,helper=receipt["artifacts"]["app"],receipt["artifacts"]["helper"]
  if entries["LidSwitch"]!=(app["size"],app["sha256"]) or entries["LidSwitchHelper"]!=(helper["size"],helper["sha256"]): deny("release-output-artifact-mismatch")
  inputs=receipt["inputs"]
  if entries["GeneratedReleaseHelperTrustAnchor.generated.swift"][1]!=inputs["generatedAnchorSHA256"]: deny("release-output-anchor-mismatch")
  return {"seal_sha256":release_output_seal(entries),"build_receipt_sha256":entries["build-receipt.json"][1],"anchor_sha256":entries["GeneratedReleaseHelperTrustAnchor.generated.swift"][1],"anchor_size":entries["GeneratedReleaseHelperTrustAnchor.generated.swift"][0],"source_manifest_sha256":inputs["baseManifestSHA256"],"release_identity_sha256":inputs["releaseIdentitySHA256"],"app":app,"helper":helper}
 finally: os.close(root_fd)
def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--source-manifest", required=True)
    parser.add_argument("--held-build-wrapper", required=True)
    parser.add_argument("--swift", required=True)
    parser.add_argument("--release-output", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args(argv)
    try:
        if len(args.source_commit) not in (40, 64) or any(c not in "0123456789abcdef" for c in args.source_commit): deny("source-commit-invalid")
        _manifest, manifest_bytes = read_regular(args.source_manifest, "source-manifest")
        wrapper, wrapper_bytes = read_regular(args.held_build_wrapper, "held-build-wrapper")
        swift, swift_bytes = read_swift_driver(args.swift)
        release_output = read_release_output(args.release_output)
        require_source_manifest_binding(release_output, manifest_bytes)
        executables = [executable(Path(item)) for item in TOOLS] + [executable(swift)]
        if len({entry["role"] for entry in executables}) != len(executables): deny("duplicate-executable-role")
        receipt = {"schema_version": ENVELOPE_SCHEMA, "wrapper_sha256": digest(wrapper_bytes),
                   "source_commit": args.source_commit, "source_tree_sha256": digest(manifest_bytes),
                   "toolchain_sha256": digest(swift_bytes), "executables": executables,
                   "environment": {"locale": "C", "timezone": "UTC", "path": "/usr/bin:/bin:/usr/sbin:/sbin"}, "release_output": release_output}
        payload = canonical(receipt)
        output = Path(args.output).expanduser()
        write_private_receipt(output, payload)
        print(json.dumps({"envelope_sha256": digest(payload), "output": str(output)}, sort_keys=True, separators=(",", ":")))
        return 0
    except (CandidateError, OSError, ValueError) as error:
        print("immutable-build-envelope-denied: " + str(error), file=sys.stderr); return 65
if __name__ == "__main__": raise SystemExit(main())
