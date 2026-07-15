#!/usr/bin/python3
"""Immutable candidate v3: descriptor-held evidence only (Darwin/Python 3.8)."""
from __future__ import annotations
import ctypes, errno, fcntl, hashlib, json, os, re, stat
from typing import Any, Dict, Iterable, List, Tuple

SCHEMA, ENVELOPE_SCHEMA = "lidswitch-immutable-candidate-v3", "lidswitch-verified-envelope-rev19"
BUILD_DESCRIPTOR_SCHEMA, PACKAGE_DESCRIPTOR_SCHEMA = "lidswitch-immutable-build-descriptor-v1", "lidswitch-immutable-package-descriptor-v1"
MAX_JSON, MAX_DEPTH, MAX_ENTRIES, MAX_XATTRS = 262144, 64, 100000, 128
MAX_FILE, MAX_TOTAL, MAX_XATTR_TOTAL = 1 << 30, 8 << 30, 16 << 20
HEX, CDHASH, NAME = re.compile(r"[0-9a-f]{64}\Z"), re.compile(r"[0-9a-f]{40}\Z"), re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,95}\Z")
PHASES = {
 "app-captured": ("helper-signing","anchor","build","app-signing","app-tree","validator"),
 "package-captured": ("helper-signing","anchor","build","app-signing","app-tree","validator","package","checksum","extraction"),
 "qualified": ("helper-signing","anchor","build","app-signing","app-tree","validator","package","checksum","extraction","benchmark","xpc","canary","publication"),
}
class CandidateError(Exception): pass
def fail(kind: str) -> None: raise CandidateError(kind)
def _pairs(pairs):
 out={}
 for k,v in pairs:
  if not isinstance(k,str) or k in out: fail("manifest-invalid")
  out[k]=v
 return out
def _constant(_): fail("manifest-invalid")
def _integer(text):
 if len(text)>19 or not re.fullmatch(r"0|[1-9][0-9]{0,18}",text): fail("manifest-invalid")
 return int(text)
def _float(_): fail("manifest-invalid")
def canonical(value):
 try: return (json.dumps(value,ensure_ascii=False,separators=(",",":"),allow_nan=False)+"\n").encode("utf-8")
 except (TypeError,ValueError,UnicodeError): fail("manifest-invalid")
def parse(payload):
 if not isinstance(payload,bytes) or not 1<=len(payload)<=MAX_JSON or payload[:3]==b"\xef\xbb\xbf" or b"\x00" in payload or b"\r" in payload or not payload.endswith(b"\n") or payload.count(b"\n")!=1: fail("manifest-invalid")
 try: value=json.loads(payload.decode("utf-8","strict"),object_pairs_hook=_pairs,parse_constant=_constant,parse_int=_integer,parse_float=_float)
 except (UnicodeDecodeError,ValueError,RecursionError,CandidateError): fail("manifest-invalid")
 if not isinstance(value,dict) or canonical(value)!=payload: fail("manifest-invalid")
 return value
def keys(v,w):
 if not isinstance(v,dict) or tuple(v)!=tuple(w): fail("manifest-invalid")
 return v
def string(v,n=256):
 if not isinstance(v,str) or not v or "\x00" in v or len(v.encode("utf-8"))>n: fail("manifest-invalid")
 return v
def digest(v):
 v=string(v,64)
 if not HEX.fullmatch(v): fail("manifest-invalid")
 return v
def number(v,n=MAX_TOTAL):
 if isinstance(v,bool) or not isinstance(v,int) or not 0<=v<=n: fail("manifest-invalid")
 return v
def component(v):
 v=string(v,96)
 if (not NAME.fullmatch(v) and v!="_CodeSignature") or v in (".",".."): fail("manifest-invalid")
 return v
def _same(a,b): return (a.st_dev,a.st_ino,a.st_uid,a.st_gid,a.st_mode,a.st_nlink,a.st_size)==(b.st_dev,b.st_ino,b.st_uid,b.st_gid,b.st_mode,b.st_nlink,b.st_size)
def _same_identity(a,b): return (a.st_dev,a.st_ino,a.st_uid,a.st_gid,a.st_mode,a.st_size)==(b.st_dev,b.st_ino,b.st_uid,b.st_gid,b.st_mode,b.st_size)
def _safe(info,directory=False):
 good=stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)
 if not good or info.st_uid!=os.getuid() or info.st_gid!=os.getgid() or info.st_mode&0o022 or (not directory and (info.st_nlink!=1 or info.st_size>MAX_FILE)): fail("artifact-identity-drift")

def open_root_literal(path):
 """Acquire and keep every parent descriptor; no lstat/open split authority."""
 if not isinstance(path,str) or not os.path.isabs(path): fail("artifact-identity-drift")
 fd=os.open("/",os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC)
 chain=[fd]
 try:
  for part in (x for x in path.split("/") if x):
   child=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW|os.O_CLOEXEC,dir_fd=fd)
   before=os.stat(part,dir_fd=fd,follow_symlinks=False); after=os.fstat(child)
   if not _same(before,after) or after.st_mode&0o022 or after.st_uid not in (0,os.getuid()): fail("artifact-identity-drift")
   fd=child; chain.append(fd)
  _safe(os.fstat(fd),True); return chain
 except Exception:
  for item in reversed(chain):
   try: os.close(item)
   except OSError: pass
  raise
def close_chain(chain):
 failed=False
 for fd in reversed(chain):
  try: os.close(fd)
  except OSError: failed=True
 if failed: fail("close-uncertain")

try:
 _xattr_lib=ctypes.CDLL(None,use_errno=True)
 _flistxattr=_xattr_lib.flistxattr
 _flistxattr.argtypes=(ctypes.c_int,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_int)
 _flistxattr.restype=ctypes.c_ssize_t
 _fgetxattr=_xattr_lib.fgetxattr
 _fgetxattr.argtypes=(ctypes.c_int,ctypes.c_char_p,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_uint32,ctypes.c_int)
 _fgetxattr.restype=ctypes.c_ssize_t
except (AttributeError,OSError):
 _flistxattr=_fgetxattr=None

def _listxattr_fd(fd):
 """Darwin system Python 3.9 omits os.listxattr; keep authority on the held FD."""
 if _flistxattr is None: fail("acl-metadata-unavailable")
 for _ in range(4):
  ctypes.set_errno(0); size=_flistxattr(fd,None,0,0)
  if size<0: fail("acl-metadata-unavailable")
  if size==0: return []
  buffer=ctypes.create_string_buffer(size)
  ctypes.set_errno(0); actual=_flistxattr(fd,buffer,size,0)
  if actual<0:
   if ctypes.get_errno()==errno.ERANGE: continue
   fail("acl-metadata-unavailable")
  raw=bytes(buffer.raw[:actual])
  if actual>size or not raw or not raw.endswith(b"\0"): fail("acl-metadata-unavailable")
  try: names=[part.decode("utf-8","strict") for part in raw[:-1].split(b"\0")]
  except UnicodeDecodeError: fail("acl-metadata-unavailable")
  if any(not name or "\0" in name for name in names) or len(set(names))!=len(names): fail("acl-metadata-unavailable")
  return names
 fail("acl-metadata-unavailable")

def _getxattr_fd(fd,name):
 if _fgetxattr is None or not isinstance(name,str) or not name: fail("acl-metadata-unavailable")
 try: encoded=name.encode("utf-8","strict")
 except UnicodeEncodeError: fail("acl-metadata-unavailable")
 ctypes.set_errno(0); size=_fgetxattr(fd,encoded,None,0,0,0)
 if size<0: fail("acl-metadata-unavailable")
 if size==0: return b""
 buffer=ctypes.create_string_buffer(size)
 ctypes.set_errno(0); actual=_fgetxattr(fd,encoded,buffer,size,0,0)
 if actual!=size: fail("acl-metadata-unavailable")
 return bytes(buffer.raw[:actual])

class RootCapability:
 """Retained literal root descriptor chain; terminal reassertion is mandatory."""
 def __init__(self,path): self.chain=open_root_literal(path); self.root=self.chain[-1]; self.closed=False
 def reassert(self):
  if self.closed: fail("close-uncertain")
  # Every descriptor remains held and must still be a safe canonical directory.
  for fd in self.chain: _safe(os.fstat(fd),True)
 def leaf(self,name_value):
  self.reassert(); return measure(self.root,name_value)
 def close(self):
  if self.closed: fail("close-uncertain")
  self.reassert(); close_chain(self.chain); self.closed=True
 @classmethod
 def from_inherited_fd(cls,fd):
  """Adopt a caller-held candidate root by descriptor, never by a mutable path."""
  try: owned=os.dup(fd)
  except OSError: fail("inherited-root-invalid")
  try:
   _safe(os.fstat(owned),True)
  except Exception:
   try: os.close(owned)
   except OSError: pass
   raise
  instance=cls.__new__(cls); instance.chain=[owned]; instance.root=owned; instance.closed=False
  return instance
def open_component(parent,name_value,flags=os.O_RDONLY):
 component(name_value)
 before=os.stat(name_value,dir_fd=parent,follow_symlinks=False)
 fd=os.open(name_value,flags|os.O_NOFOLLOW|os.O_CLOEXEC,dir_fd=parent)
 if not _same(before,os.fstat(fd)): os.close(fd); fail("artifact-identity-drift")
 return fd,before
def _read_exact(fd,maximum=MAX_FILE):
 before=os.fstat(fd); _safe(before)
 if before.st_size>maximum: fail("artifact-identity-drift")
 h=hashlib.sha256(); left=before.st_size
 while left:
  try: data=os.read(fd,min(131072,left))
  except InterruptedError: continue
  if not data: fail("artifact-eof")
  h.update(data); left-=len(data)
 while True:
  try: extra=os.read(fd,1); break
  except InterruptedError: continue
 if extra or not _same(before,os.fstat(fd)): fail("artifact-identity-drift")
 return before,h.hexdigest()
def measure(parent,name_value):
 fd,before=open_component(parent,name_value)
 try:
  got,hashed=_read_exact(fd)
  if not _same(before,got) or not _same(before,os.stat(name_value,dir_fd=parent,follow_symlinks=False)): fail("artifact-identity-drift")
  return got,hashed
 finally:
  try: os.close(fd)
  except OSError: fail("close-uncertain")
def read_canonical_leaf(parent,name_value,maximum=MAX_JSON):
 """One held leaf read: exact length, EOF, fstat/name reassertion, checked close."""
 fd,before=open_component(parent,name_value)
 try:
  info,hashed=_read_exact(fd,maximum)
  try: os.lseek(fd,0,os.SEEK_SET)
  except OSError: fail("artifact-identity-drift")
  chunks=[]; left=info.st_size
  while left:
   try: bit=os.read(fd,min(65536,left))
   except InterruptedError: continue
   if not bit: fail("artifact-eof")
   chunks.append(bit); left-=len(bit)
  payload=b"".join(chunks)
  if hashlib.sha256(payload).hexdigest()!=hashed or not _same(before,os.fstat(fd)) or not _same(before,os.stat(name_value,dir_fd=parent,follow_symlinks=False)): fail("artifact-identity-drift")
  return payload,before
 finally:
  try: os.close(fd)
  except OSError: fail("close-uncertain")
def read_leaf_bytes(parent,name_value,maximum=MAX_FILE):
 """Read one held regular leaf exactly; unlike receipt reads it need not be JSON."""
 fd,before=open_component(parent,name_value)
 try:
  info,hashed=_read_exact(fd,maximum)
  try: os.lseek(fd,0,os.SEEK_SET)
  except OSError: fail("artifact-identity-drift")
  chunks=[]; left=info.st_size
  while left:
   try: bit=os.read(fd,min(65536,left))
   except InterruptedError: continue
   if not bit: fail("artifact-eof")
   chunks.append(bit); left-=len(bit)
  payload=b"".join(chunks)
  if hashlib.sha256(payload).hexdigest()!=hashed or not _same(before,os.fstat(fd)) or not _same(before,os.stat(name_value,dir_fd=parent,follow_symlinks=False)): fail("artifact-identity-drift")
  return payload,before
 finally:
  try: os.close(fd)
  except OSError: fail("close-uncertain")
def _pinned_digest(value):
 """An invocation pins an inherited immutable FD; no source constant is authority."""
 return digest(value)
def read_pinned_inherited_json(fd, expected_sha256, maximum=MAX_JSON):
 """Read exactly one inherited regular file and bind it to a caller-supplied hash."""
 expected_sha256=_pinned_digest(expected_sha256)
 try: os.lseek(fd,0,os.SEEK_SET)
 except OSError: fail("inherited-fd-not-seekable")
 info,hashed=_read_exact(fd,maximum)
 if hashed!=expected_sha256: fail("inherited-receipt-mismatch")
 try: os.lseek(fd,0,os.SEEK_SET)
 except OSError: fail("inherited-fd-not-seekable")
 data=b""; left=info.st_size
 while left:
  try: bit=os.read(fd,min(65536,left))
  except InterruptedError: continue
  if not bit: fail("artifact-eof")
  data+=bit; left-=len(bit)
 if hashlib.sha256(data).hexdigest()!=hashed: fail("artifact-identity-drift")
 return data
def read_inherited_receipt(fd, expected_sha256):
 """Envelope intake is an inherited FD plus an invocation-time SHA-256 pin."""
 receipt=parse(read_pinned_inherited_json(fd,expected_sha256))
 keys(receipt,("schema_version","wrapper_sha256","source_commit","source_tree_sha256","toolchain_sha256","executables","environment","release_output"))
 if receipt["schema_version"]!=ENVELOPE_SCHEMA: fail("manifest-invalid")
 digest(receipt["wrapper_sha256"]); digest(receipt["source_tree_sha256"]); digest(receipt["toolchain_sha256"])
 if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}",string(receipt["source_commit"],64)): fail("manifest-invalid")
 if not isinstance(receipt["executables"],list) or not 1<=len(receipt["executables"])<=16: fail("manifest-invalid")
 seen=set()
 for e in receipt["executables"]:
  keys(e,("role","path","sha256")); role=string(e["role"],64); path=string(e["path"],256)
  system_path=path.startswith(("/usr/bin/","/bin/","/usr/sbin/","/sbin/","/usr/libexec/"))
  clt_swift=role=="swift" and path=="/Library/Developer/CommandLineTools/usr/bin/swift"
  if role in seen or not (system_path or clt_swift): fail("manifest-invalid")
  seen.add(role); digest(e["sha256"])
 if receipt["environment"]!={"locale":"C","timezone":"UTC","path":"/usr/bin:/bin:/usr/sbin:/sbin"}: fail("manifest-invalid")
 release=keys(receipt["release_output"],("seal_sha256","build_receipt_sha256","anchor_sha256","anchor_size","source_manifest_sha256","release_identity_sha256","app","helper"))
 digest(release["seal_sha256"]); digest(release["build_receipt_sha256"]); digest(release["anchor_sha256"]); number(release["anchor_size"],MAX_FILE); digest(release["source_manifest_sha256"]); digest(release["release_identity_sha256"])
 app=keys(release["app"],("identifier","sha256","size")); helper=keys(release["helper"],("cdhash","identifier","sha256","signature","size","teamIdentifier","timestamp"))
 string(app["identifier"],255); digest(app["sha256"]); number(app["size"],MAX_FILE)
 string(helper["identifier"],255); digest(helper["sha256"]); number(helper["size"],MAX_FILE)
 if not CDHASH.fullmatch(string(helper["cdhash"],40)) or helper["signature"]!="adhoc" or helper["teamIdentifier"] is not None or helper["timestamp"] is not None: fail("manifest-invalid")
 return receipt
def require_rev18(fd, expected_sha256): return read_inherited_receipt(fd,expected_sha256)

def candidate_binding(m):
 """Bind captured identity, excluding receipt references to avoid a hash cycle.

 Receipt payloads bind this stable identity; the manifest separately binds the
 complete receipt chain through its non-self-referential candidate_id.
 """
 def stable_artifact(value):
  if not isinstance(value,dict): return value
  return {key:item for key,item in value.items() if key!="signature_receipt"}
 return hashlib.sha256(canonical({"envelope":m["envelope"],"release_identity":m["release_identity"],"source":m["source"],"helper":stable_artifact(m["helper"]),"app":stable_artifact(m["app"])})).hexdigest()
def leaf_artifact(v): return _artifact(v,"leaf")
def code_leaf(v): return _artifact(v,"code")
def directory_tree(v): return _artifact(v,"tree")
def dmg_artifact(v): return _artifact(v,"dmg")
def checksum_artifact(v): return _artifact(v,"checksum")
def validate_checksum(payload,dmg_name,dmg_sha256):
 expected=(dmg_sha256+"  "+dmg_name+"\n").encode("ascii")
 if payload!=expected: fail("artifact-digest-mismatch")
def verify_extracted_app(candidate_root,app_name,extracted_root,extracted_name,expected_tree):
 """External extractor capability only: compare held tree evidence, never mount."""
 _,captured=capture_tree(candidate_root,app_name)
 _,extracted=capture_tree(extracted_root,extracted_name)
 if captured!=expected_tree or extracted!=expected_tree or captured!=extracted: fail("artifact-digest-mismatch")
def _artifact(v,role):
 expected=("role","name","sha256","size","mode","uid","gid","tree_sha256","signature_receipt")
 if role in ("helper","app"): expected+=("identifier","cdhash","signing_profile","team_id","notarized")
 o=keys(v,expected)
 if o["role"]!=role: fail("manifest-invalid")
 component(o["name"]); digest(o["sha256"]); number(o["size"],MAX_FILE); number(o["mode"],0o7777); number(o["uid"],1<<31); number(o["gid"],1<<31); digest(o["tree_sha256"]); digest(o["signature_receipt"]); return o
def _receipt(v):
 o=keys(v,("role","name","sha256","tool_sha256","subject_role","subject_name","subject_sha256","subject_size","source_commit","candidate_binding","previous_receipt","strict","exit"))
 string(o["role"],64); component(o["name"]); digest(o["sha256"]); digest(o["tool_sha256"]); string(o["subject_role"],64); component(o["subject_name"]); digest(o["subject_sha256"]); number(o["subject_size"],MAX_FILE); string(o["source_commit"],64); digest(o["candidate_binding"]); digest(o["previous_receipt"])
 if o["strict"] is not True or o["exit"]!=0: fail("manifest-invalid")
 return o
def receipt_payload(receipt):
 """The receipt leaf is the canonical, non-self-referential receipt claim.

 Its SHA-256 lives in the manifest, so the payload deliberately omits that
 one field. Every other manifest claim must be byte-for-byte canonicalized
 from this exact projection; neither descriptor metadata nor a generic JSON
 note can stand in for a receipt.
 """
 receipt=_receipt(receipt)
 return {key:value for key,value in receipt.items() if key!="sha256"}
def canonical_receipt_payload(receipt): return canonical(receipt_payload(receipt))
def validate_manifest(m,envelope=None,envelope_sha256=None):
 keys(m,("schema_version","candidate_id","phase","envelope","release_identity","source","helper","app","package","receipts"))
 if m["schema_version"]!=SCHEMA or m["phase"] not in PHASES: fail("manifest-invalid")
 digest(m["candidate_id"]); keys(m["envelope"],("receipt_sha256","wrapper_sha256","source_tree_sha256","toolchain_sha256","release_output")); [digest(m["envelope"][x]) for x in ("receipt_sha256","wrapper_sha256","source_tree_sha256","toolchain_sha256")]
 release=keys(m["envelope"]["release_output"],("seal_sha256","build_receipt_sha256","anchor_sha256","anchor_size","source_manifest_sha256","release_identity_sha256","app","helper"))
 digest(release["seal_sha256"]); digest(release["build_receipt_sha256"]); digest(release["anchor_sha256"]); number(release["anchor_size"],MAX_FILE); digest(release["source_manifest_sha256"]); digest(release["release_identity_sha256"])
 app_origin=keys(release["app"],("identifier","sha256","size")); helper_origin=keys(release["helper"],("cdhash","identifier","sha256","signature","size","teamIdentifier","timestamp"))
 string(app_origin["identifier"],255); digest(app_origin["sha256"]); number(app_origin["size"],MAX_FILE)
 string(helper_origin["identifier"],255); digest(helper_origin["sha256"]); number(helper_origin["size"],MAX_FILE)
 if not CDHASH.fullmatch(string(helper_origin["cdhash"],40)) or helper_origin["signature"]!="adhoc" or helper_origin["teamIdentifier"] is not None or helper_origin["timestamp"] is not None: fail("manifest-invalid")
 keys(m["release_identity"],("name","sha256","signing_profile","team_id","notarized")); component(m["release_identity"]["name"]); digest(m["release_identity"]["sha256"])
 if m["release_identity"]["signing_profile"]!="manual-adhoc" or m["release_identity"]["team_id"] is not None or m["release_identity"]["notarized"] is not False: fail("manual-adhoc-identity-mismatch")
 keys(m["source"],("commit","tree_sha256")); string(m["source"]["commit"],64); digest(m["source"]["tree_sha256"])
 if envelope and (m["envelope"]["wrapper_sha256"]!=envelope["wrapper_sha256"] or m["source"]["commit"]!=envelope["source_commit"] or m["source"]["tree_sha256"]!=envelope["source_tree_sha256"] or m["envelope"]["toolchain_sha256"]!=envelope["toolchain_sha256"] or m["envelope"]["release_output"]!=envelope["release_output"]): fail("source-drift")
 if envelope_sha256 is not None and m["envelope"]["receipt_sha256"]!=_pinned_digest(envelope_sha256): fail("source-drift")
 helper,app=_artifact(m["helper"],"helper"),_artifact(m["app"],"app")
 for artifact in (helper,app):
  string(artifact["identifier"],255)
  if not CDHASH.fullmatch(artifact["cdhash"]) or artifact["signing_profile"]!="manual-adhoc" or artifact["team_id"] is not None or artifact["notarized"] is not False: fail("manual-adhoc-identity-mismatch")
 if app["sha256"]!=app["tree_sha256"]: fail("manifest-invalid")
 keys(m["package"],("dmg","checksum","extraction_receipt","extracted_tree_sha256"))
 if m["phase"]=="app-captured":
  if m["package"]!={"dmg":None,"checksum":None,"extraction_receipt":None,"extracted_tree_sha256":None}: fail("candidate-phase-incomplete")
 else:
  _artifact(m["package"]["dmg"],"package"); _artifact(m["package"]["checksum"],"checksum"); digest(m["package"]["extraction_receipt"]); digest(m["package"]["extracted_tree_sha256"])
 if not isinstance(m["receipts"],list) or len(m["receipts"])!=len(PHASES[m["phase"]]): fail("candidate-phase-incomplete")
 receipts=[_receipt(x) for x in m["receipts"]]
 if tuple(x["role"] for x in receipts)!=PHASES[m["phase"]] or len({x["name"] for x in receipts})!=len(receipts): fail("candidate-phase-incomplete")
 bind=candidate_binding(m); previous="0"*64
 for r in receipts:
  if r["candidate_binding"]!=bind or r["source_commit"]!=m["source"]["commit"] or r["previous_receipt"]!=previous: fail("consumer-manifest-mismatch")
  previous=r["sha256"]
 if helper["signature_receipt"]!=receipts[0]["sha256"] or app["signature_receipt"]!=receipts[3]["sha256"] or (m["phase"]!="app-captured" and m["package"]["extraction_receipt"]!=receipts[8]["sha256"]): fail("consumer-manifest-mismatch")
 clone=dict(m); clone.pop("candidate_id")
 if m["candidate_id"]!=hashlib.sha256(canonical(clone)).hexdigest(): fail("consumer-manifest-mismatch")
 return m
def _candidate_id(manifest):
 clone=dict(manifest); clone.pop("candidate_id",None)
 return hashlib.sha256(canonical(clone)).hexdigest()
def _manifest_from_build_descriptor(descriptor,envelope,envelope_sha256):
 """Turn a held build-result descriptor into an app-captured manifest, without tools."""
 keys(descriptor,("schema_version","phase","release_identity","source","helper","app","package","receipts"))
 if descriptor["schema_version"]!=BUILD_DESCRIPTOR_SCHEMA or descriptor["phase"]!="app-captured": fail("manifest-invalid")
 manifest={
  "schema_version":SCHEMA, "candidate_id":"0"*64, "phase":"app-captured",
  "envelope":{"receipt_sha256":_pinned_digest(envelope_sha256),"wrapper_sha256":envelope["wrapper_sha256"],"source_tree_sha256":envelope["source_tree_sha256"],"toolchain_sha256":envelope["toolchain_sha256"],"release_output":envelope["release_output"]},
  "release_identity":descriptor["release_identity"], "source":descriptor["source"],
  "helper":descriptor["helper"], "app":descriptor["app"], "package":descriptor["package"], "receipts":descriptor["receipts"],
 }
 manifest["candidate_id"]=_candidate_id(manifest)
 return validate_manifest(manifest,envelope,envelope_sha256)
def _manifest_from_package_descriptor(app_manifest,descriptor,envelope,envelope_sha256):
 """Extend an app-captured manifest with package evidence; app bytes never re-enter a build path."""
 validate_manifest(app_manifest,envelope,envelope_sha256)
 if app_manifest["phase"]!="app-captured": fail("candidate-phase-incomplete")
 keys(descriptor,("schema_version","base_candidate_id","package","receipts"))
 if descriptor["schema_version"]!=PACKAGE_DESCRIPTOR_SCHEMA or descriptor["base_candidate_id"]!=app_manifest["candidate_id"]: fail("consumer-manifest-mismatch")
 manifest=dict(app_manifest); manifest["candidate_id"]="0"*64; manifest["phase"]="package-captured"; manifest["package"]=descriptor["package"]; manifest["receipts"]=descriptor["receipts"]
 manifest["candidate_id"]=_candidate_id(manifest)
 return validate_manifest(manifest,envelope,envelope_sha256)
def build_manifest_from_pinned_descriptor(envelope_fd,envelope_sha256,descriptor_fd,descriptor_sha256):
 envelope=read_inherited_receipt(envelope_fd,envelope_sha256)
 descriptor=parse(read_pinned_inherited_json(descriptor_fd,descriptor_sha256))
 return _manifest_from_build_descriptor(descriptor,envelope,envelope_sha256),envelope
def package_manifest_from_pinned_descriptor(envelope_fd,envelope_sha256,app_manifest_fd,app_manifest_sha256,descriptor_fd,descriptor_sha256):
 envelope=read_inherited_receipt(envelope_fd,envelope_sha256)
 app_manifest=parse(read_pinned_inherited_json(app_manifest_fd,app_manifest_sha256))
 descriptor=parse(read_pinned_inherited_json(descriptor_fd,descriptor_sha256))
 return _manifest_from_package_descriptor(app_manifest,descriptor,envelope,envelope_sha256),envelope
def refuse_legacy_root(path):
 """A candidate root is a fresh private evidence root, never inherited dist output."""
 if os.path.basename(os.path.normpath(path))=="dist": fail("legacy-artifact-refused")
def verify_candidate(root,m):
 """Observationally prove every declared artifact and canonical receipt leaf."""
 seen=set(); objects=[m["release_identity"],m["helper"]]
 if m["phase"]!="app-captured": objects += [m["package"]["dmg"],m["package"]["checksum"]]
 for obj in objects:
  n=obj["name"]
  if n in seen: fail("manifest-invalid")
  seen.add(n); info,actual=measure(root,n)
  if actual!=obj["sha256"] or info.st_size!=obj.get("size",info.st_size): fail("artifact-digest-mismatch")
 app=m["app"]
 if app["name"] in seen: fail("manifest-invalid")
 seen.add(app["name"]); app_total,app_tree=capture_tree(root,app["name"])
 if app_tree!=app["tree_sha256"] or app_tree!=app["sha256"] or app_total!=app["size"]: fail("artifact-digest-mismatch")
 if m["phase"]!="app-captured":
  checksum_payload,_=read_leaf_bytes(root,m["package"]["checksum"]["name"])
  validate_checksum(checksum_payload,m["package"]["dmg"]["name"],m["package"]["dmg"]["sha256"])
 for receipt in m["receipts"]:
  n=receipt["name"]
  if n in seen: fail("manifest-invalid")
  seen.add(n); payload,_=read_canonical_leaf(root,n)
  parsed=parse(payload)
  if hashlib.sha256(payload).hexdigest()!=receipt["sha256"] or payload!=canonical_receipt_payload(receipt) or parsed!=receipt_payload(receipt): fail("artifact-digest-mismatch")
def capture_tree(root,bundle):
 """One descriptor per entry; records root-relative paths, flags and all xattrs."""
 total=0; records=[]
 def walk(parent,label,relative,depth):
  nonlocal total
  if depth>MAX_DEPTH: fail("tree-limit")
  fd,before=open_component(parent,label,os.O_RDONLY|os.O_DIRECTORY)
  try:
   try:
    with os.scandir(fd) as it: children=sorted(list(it),key=lambda e:e.name)
   except OSError: fail("artifact-identity-drift")
   for child in children:
    if len(records)>=MAX_ENTRIES: fail("tree-limit")
    item=component(child.name); child_fd,meta=open_component(fd,item,os.O_RDONLY|(os.O_DIRECTORY if child.is_dir(follow_symlinks=False) else 0))
    try:
     if stat.S_ISLNK(meta.st_mode) or not (stat.S_ISREG(meta.st_mode) or stat.S_ISDIR(meta.st_mode)) or (stat.S_ISREG(meta.st_mode) and meta.st_nlink!=1): fail("artifact-identity-drift")
     attributes=sorted(_listxattr_fd(child_fd))
     if len(attributes)>MAX_XATTRS or any(a.startswith("com.apple.system.Security") or a.startswith("system.posix_acl") for a in attributes): fail("acl-or-security-metadata")
     xsum=0; xrecords=[]
     for attribute in attributes:
      value=_getxattr_fd(child_fd,attribute); xsum+=len(value)
      if len(value)>MAX_FILE or xsum>MAX_XATTR_TOTAL: fail("tree-limit")
      xrecords.append((attribute,hashlib.sha256(value).hexdigest(),len(value)))
     child_relative=relative+"/"+item
     if stat.S_ISDIR(meta.st_mode):
      walk(fd,item,child_relative,depth+1); records.append((child_relative,"d",meta.st_mode&0o7777,meta.st_uid,meta.st_gid,getattr(meta,"st_flags",0),tuple(xrecords)))
     else:
      got,hashed=_read_exact(child_fd); total+=got.st_size
      if total>MAX_TOTAL: fail("tree-limit")
      records.append((child_relative,"f",meta.st_mode&0o7777,meta.st_uid,meta.st_gid,getattr(meta,"st_flags",0),got.st_size,hashed,tuple(xrecords)))
     if not _same(meta,os.stat(item,dir_fd=fd,follow_symlinks=False)): fail("artifact-identity-drift")
    finally: os.close(child_fd)
   if not _same(before,os.fstat(fd)) or not _same(before,os.stat(label,dir_fd=parent,follow_symlinks=False)): fail("artifact-identity-drift")
  finally: os.close(fd)
 walk(root,bundle,bundle,0)
 return total,hashlib.sha256(canonical({"ownership_policy":"uid-gid-mode-flags-exact","records":records})).hexdigest()
def _fullsync(fd):
 try: os.fsync(fd); fcntl.fcntl(fd,fcntl.F_FULLFSYNC)
 except AttributeError: fail("fullfsync-unsupported")
 except OSError: fail("fullfsync-failed")
class DarwinAdapter:
 """SDK-backed adapter: sys/stdio.h declares renameatx_np(..., unsigned int); RENAME_EXCL=0x4."""
 RENAME_EXCL=0x00000004  # MacOSX15.4.sdk/usr/include/sys/stdio.h:37
 def __init__(self):
  self.lib=ctypes.CDLL(None,use_errno=True)
  self.renameatx_np=self.lib.renameatx_np
  self.renameatx_np.argtypes=(ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_uint)
  self.renameatx_np.restype=ctypes.c_int
 def rename_exclusive(self,root,temp,final):
  if self.renameatx_np(root,temp.encode("ascii"),root,final.encode("ascii"),self.RENAME_EXCL)!=0: raise OSError(ctypes.get_errno(),"renameatx_np")
 def sync(self,fd): _fullsync(fd)
 def close(self,fd): os.close(fd)
 def stat(self,name,root): return os.stat(name,dir_fd=root,follow_symlinks=False)
 def reopen(self,name,root): return open_component(root,name)
def publish(root,name_value,payload,ops=None):
 """Explicit states: precommit-failed, committed, committed-uncertain, close-uncertain."""
 if not isinstance(payload,bytes) or not payload or len(payload)>MAX_JSON: fail("manifest-invalid")
 ops=ops or DarwinAdapter(); component(name_value); temp=".immutable-tmp-"+os.urandom(24).hex(); fd=-1; temp_info=None; committed=False
 try:
  fd=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW|os.O_CLOEXEC,0o600,dir_fd=root); temp_info=os.fstat(fd); _safe(temp_info)
  view=memoryview(payload)
  while view:
   try: wrote=os.write(fd,view)
   except InterruptedError: continue
   if wrote<=0: fail("precommit-failed")
   view=view[wrote:]
  ops.sync(fd)
  temp_info=os.fstat(fd)
  _safe(temp_info)
  try: ops.close(fd)
  except OSError: fd=-1; fail("close-uncertain")
  fd=-1
  try: ops.rename_exclusive(root,temp,name_value)
  except OSError as e:
   if e.errno==errno.EEXIST: fail("candidate-phase-incomplete")
   fail("precommit-failed")
  committed=True
  # rename consumes the only verified temp name; no unlink/check race exists.
  new=ops.stat(name_value,root)
  if not _same(new,temp_info) or new.st_nlink!=1: fail("committed-uncertain")
  ops.sync(root)
  final,now=ops.reopen(name_value,root)
  try:
   got,actual=_read_exact(final,MAX_JSON)
   if not _same_identity(now,temp_info) or got.st_nlink!=1 or got.st_size!=len(payload) or actual!=hashlib.sha256(payload).hexdigest(): fail("committed-uncertain")
  finally: os.close(final)
 except CandidateError: raise
 finally:
  if fd>=0:
   try: os.close(fd)
   except OSError: fail("close-uncertain")
  # Precommit residue is evidence. Never delete a possibly replaced temp.
