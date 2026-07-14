#!/usr/bin/python3
"""Private-temp, pure-Python fixtures for immutable candidate descriptor intake."""
from __future__ import annotations
import argparse, ctypes, errno, hashlib, importlib.util, os, pathlib, sys, tempfile, unittest

ROOT=pathlib.Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT))
import immutable_candidate_core as core

def sha(data): return hashlib.sha256(data).hexdigest()
def load(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/(name+".py")); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module

class RenameOnly:
    """Injected publication adapter: no tool runner, no shell, no overwrite."""
    def sync(self,fd): os.fsync(fd)
    def close(self,fd): os.close(fd)
    def rename_exclusive(self,root,temp,final):
        try: os.stat(final,dir_fd=root,follow_symlinks=False)
        except FileNotFoundError: os.rename(temp,final,src_dir_fd=root,dst_dir_fd=root)
        else: raise OSError(errno.EEXIST,"exists")
    def stat(self,name,root): return os.stat(name,dir_fd=root,follow_symlinks=False)
    def reopen(self,name,root): return core.open_component(root,name)

class ImmutableCandidateFixtures(unittest.TestCase):
    def setUp(self):
        self.injected_xattrs=not hasattr(core.os,"listxattr")
        if self.injected_xattrs:
            core.os.listxattr=lambda _fd: []
            core.os.getxattr=lambda _fd,_name: b""
        self.temp=tempfile.TemporaryDirectory(dir=str(pathlib.Path.home()))
        self.root=pathlib.Path(self.temp.name); os.chmod(self.root,0o700)
        self.release_output={"seal_sha256":"6"*64,"build_receipt_sha256":"7"*64,"anchor_sha256":"8"*64,"anchor_size":9,"source_manifest_sha256":"b"*64,"release_identity_sha256":"d"*64,"app":{"identifier":"io.lidswitch.fixture.app","sha256":"9"*64,"size":10},"helper":{"cdhash":"c"*40,"identifier":"io.lidswitch.fixture.helper","sha256":"a"*64,"signature":"adhoc","size":11,"teamIdentifier":None,"timestamp":None}}
        self.envelope={"schema_version":core.ENVELOPE_SCHEMA,"wrapper_sha256":"1"*64,"source_commit":"2"*40,"source_tree_sha256":"3"*64,"toolchain_sha256":"4"*64,"executables":[{"role":"python","path":"/usr/bin/python3","sha256":"5"*64},{"role":"swift","path":"/Library/Developer/CommandLineTools/usr/bin/swift","sha256":"4"*64}],"environment":{"locale":"C","timezone":"UTC","path":"/usr/bin:/bin:/usr/sbin:/sbin"},"release_output":self.release_output}
        self.envelope_bytes=core.canonical(self.envelope); self.envelope_hash=sha(self.envelope_bytes)
        self.write("envelope.json",self.envelope_bytes)
        self.write("identity.json",core.canonical({"channel":"test"}))
        self.write("helper.bin",b"helper-bytes")
        app=self.root/"LidSwitch.app"/"Contents"/"MacOS"; app.mkdir(parents=True); os.chmod(self.root/"LidSwitch.app",0o700); os.chmod(self.root/"LidSwitch.app"/"Contents",0o700); os.chmod(app,0o700)
        self.write("LidSwitch.app/Contents/MacOS/LidSwitch",b"app-bytes")
    def tearDown(self):
        self.temp.cleanup()
        if self.injected_xattrs:
            del core.os.listxattr
            del core.os.getxattr
    def write(self,name,data):
        path=self.root/name; path.parent.mkdir(parents=True,exist_ok=True); path.write_bytes(data); os.chmod(path,0o600)
    def fd(self,name,flags=os.O_RDONLY): return os.open(self.root/name,flags|os.O_CLOEXEC)
    def artifact(self,role,name,receipt):
        if role=="app":
            root_fd=os.open(str(self.root),os.O_RDONLY|os.O_DIRECTORY)
            try: size,tree=core.capture_tree(root_fd,name)
            finally: os.close(root_fd)
            digest=tree
        else:
            data=(self.root/name).read_bytes(); size=len(data); digest=sha(data); tree=digest
        artifact={"role":role,"name":name,"sha256":digest,"size":size,"mode":0o600,"uid":os.getuid(),"gid":os.getgid(),"tree_sha256":tree,"signature_receipt":receipt}
        if role in ("helper","app"): artifact.update({"identifier":"io.lidswitch.fixture."+role,"cdhash":"c"*40,"signing_profile":"manual-adhoc","team_id":None,"notarized":False})
        return artifact
    def receipt(self,role,index,binding,previous):
        name="receipt-%02d.json"%index
        receipt={"role":role,"name":name,"sha256":"0"*64,"tool_sha256":"a"*64,"subject_role":"fixture","subject_name":"identity.json","subject_sha256":sha((self.root/"identity.json").read_bytes()),"subject_size":(self.root/"identity.json").stat().st_size,"source_commit":self.envelope["source_commit"],"candidate_binding":binding,"previous_receipt":previous,"strict":True,"exit":0}
        payload=core.canonical_receipt_payload(receipt); receipt["sha256"]=sha(payload); self.write(name,payload)
        return receipt
    def build_descriptor(self):
        identity_sha=sha((self.root/"identity.json").read_bytes())
        preliminary={"envelope":{"receipt_sha256":self.envelope_hash,"wrapper_sha256":self.envelope["wrapper_sha256"],"source_tree_sha256":self.envelope["source_tree_sha256"],"toolchain_sha256":self.envelope["toolchain_sha256"],"release_output":self.release_output},"release_identity":{"name":"identity.json","sha256":identity_sha,"signing_profile":"manual-adhoc","team_id":None,"notarized":False},"source":{"commit":self.envelope["source_commit"],"tree_sha256":self.envelope["source_tree_sha256"]},"helper":self.artifact("helper","helper.bin","0"*64),"app":self.artifact("app","LidSwitch.app","0"*64)}
        binding=core.candidate_binding(preliminary)
        receipts=[]; previous="0"*64
        for index,role in enumerate(core.PHASES["app-captured"]):
            receipt=self.receipt(role,index,binding,previous); receipts.append(receipt); previous=receipt["sha256"]
        return {"schema_version":core.BUILD_DESCRIPTOR_SCHEMA,"phase":"app-captured","release_identity":preliminary["release_identity"],"source":preliminary["source"],"helper":self.artifact("helper","helper.bin",receipts[0]["sha256"]),"app":self.artifact("app","LidSwitch.app",receipts[3]["sha256"]),"package":{"dmg":None,"checksum":None,"extraction_receipt":None,"extracted_tree_sha256":None},"receipts":receipts}
    def descriptor_fd(self,name,value):
        data=core.canonical(value); self.write(name,data); return self.fd(name),sha(data)
    def test_pinned_receipt_has_no_source_constant_gate(self):
        fd=self.fd("envelope.json")
        try: self.assertEqual(core.read_inherited_receipt(fd,self.envelope_hash)["source_commit"],self.envelope["source_commit"])
        finally: os.close(fd)
        fd=self.fd("envelope.json")
        try:
            with self.assertRaises(core.CandidateError): core.read_inherited_receipt(fd,"0"*64)
        finally: os.close(fd)

    def test_darwin_descriptor_xattr_adapter_round_trips_without_path_authority(self):
        path=self.root/"xattr-fixture"; path.write_bytes(b"fixture"); os.chmod(path,0o600)
        fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC)
        name=b"com.johnsilva.lidswitch.fixture"; value=b"descriptor-bound"
        libc=ctypes.CDLL(None,use_errno=True); fsetxattr=libc.fsetxattr
        fsetxattr.argtypes=(ctypes.c_int,ctypes.c_char_p,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_uint32,ctypes.c_int)
        fsetxattr.restype=ctypes.c_int
        buffer=ctypes.create_string_buffer(value)
        try:
            self.assertEqual(fsetxattr(fd,name,buffer,len(value),0,0),0)
            self.assertIn(name.decode(),core._listxattr_fd(fd))
            self.assertEqual(core._getxattr_fd(fd,name.decode()),value)
        finally: os.close(fd)

    def test_component_allows_only_the_standard_codesign_directory_exception(self):
        self.assertEqual(core.component("_CodeSignature"),"_CodeSignature")
        for rejected in ("_CodeResources","_Other",".",".."):
            with self.assertRaises(core.CandidateError): core.component(rejected)

    def test_envelope_accepts_only_the_exact_command_line_tools_swift_path(self):
        alternate=dict(self.envelope)
        alternate["executables"]=[dict(item) for item in self.envelope["executables"]]
        alternate["executables"][1]["path"]="/Library/Developer/CommandLineTools/usr/bin/swiftc"
        payload=core.canonical(alternate)
        self.write("alternate-swift-envelope.json",payload)
        fd=self.fd("alternate-swift-envelope.json")
        try:
            with self.assertRaises(core.CandidateError): core.read_inherited_receipt(fd,sha(payload))
        finally: os.close(fd)
    def test_release_output_binding_rejects_stale_receipt_claim(self):
        stale=dict(self.envelope); stale["release_output"]=dict(self.release_output); stale["release_output"]["seal_sha256"]="f"*64
        self.write("stale-envelope.json",core.canonical(stale))
        fd=self.fd("stale-envelope.json")
        try:
            parsed=core.read_inherited_receipt(fd,sha(core.canonical(stale)))
            self.assertNotEqual(parsed["release_output"]["seal_sha256"],self.envelope["release_output"]["seal_sha256"])
        finally: os.close(fd)
    def test_build_publish_and_observational_validator_are_descriptor_only(self):
        build=load("build_immutable_candidate"); validator=load("validate_immutable_candidate")
        descriptor=self.build_descriptor(); descriptor_fd,descriptor_hash=self.descriptor_fd("build-descriptor.json",descriptor); root_fd=os.open(str(self.root),os.O_RDONLY|os.O_DIRECTORY)
        envelope_fd=self.fd("envelope.json")
        args=argparse.Namespace(candidate_root_fd=root_fd,envelope_receipt_fd=envelope_fd,envelope_receipt_sha256=self.envelope_hash,build_descriptor_fd=descriptor_fd,build_descriptor_sha256=descriptor_hash,manifest="candidate-manifest.json")
        try: manifest=build.run(args,RenameOnly())
        finally:
            for fd in (root_fd,envelope_fd,descriptor_fd):
                try: os.close(fd)
                except OSError: pass
        self.assertEqual(manifest["phase"],"app-captured"); self.assertEqual(manifest["envelope"]["receipt_sha256"],self.envelope_hash)
        root_fd=os.open(str(self.root),os.O_RDONLY|os.O_DIRECTORY); envelope_fd=self.fd("envelope.json")
        try: observed=validator.run(argparse.Namespace(candidate_root_fd=root_fd,envelope_receipt_fd=envelope_fd,envelope_receipt_sha256=self.envelope_hash,manifest="candidate-manifest.json"))
        finally:
            for fd in (root_fd,envelope_fd):
                try: os.close(fd)
                except OSError: pass
        self.assertEqual(observed["candidate_id"],manifest["candidate_id"])
    def test_package_phase_preserves_app_binding_and_checks_checksum(self):
        descriptor=self.build_descriptor(); envelope_fd=self.fd("envelope.json"); descriptor_fd,descriptor_hash=self.descriptor_fd("build-descriptor.json",descriptor)
        try: app_manifest,envelope=core.build_manifest_from_pinned_descriptor(envelope_fd,self.envelope_hash,descriptor_fd,descriptor_hash)
        finally: os.close(envelope_fd); os.close(descriptor_fd)
        app_payload=core.canonical(app_manifest); self.write("candidate-manifest.json",app_payload)
        self.write("LidSwitch.dmg",b"fixed-dmg")
        dmg_sha=sha(b"fixed-dmg"); self.write("LidSwitch.dmg.sha256",(dmg_sha+"  LidSwitch.dmg\n").encode("ascii"))
        binding=core.candidate_binding(app_manifest); receipts=list(descriptor["receipts"])
        previous=receipts[-1]["sha256"]
        for index,role in enumerate(core.PHASES["package-captured"][6:],6):
            receipt=self.receipt(role,index,binding,previous); receipts.append(receipt); previous=receipt["sha256"]
        package={"dmg":self.artifact("package","LidSwitch.dmg",receipts[6]["sha256"]),"checksum":self.artifact("checksum","LidSwitch.dmg.sha256",receipts[7]["sha256"]),"extraction_receipt":receipts[8]["sha256"],"extracted_tree_sha256":app_manifest["app"]["tree_sha256"]}
        descriptor={"schema_version":core.PACKAGE_DESCRIPTOR_SCHEMA,"base_candidate_id":app_manifest["candidate_id"],"package":package,"receipts":receipts}
        efd=self.fd("envelope.json"); afd=self.fd("candidate-manifest.json"); dfd,dhash=self.descriptor_fd("package-descriptor.json",descriptor)
        try: package_manifest,_=core.package_manifest_from_pinned_descriptor(efd,self.envelope_hash,afd,sha(app_payload),dfd,dhash)
        finally: os.close(efd); os.close(afd); os.close(dfd)
        root_fd=os.open(str(self.root),os.O_RDONLY|os.O_DIRECTORY)
        try: core.verify_candidate(root_fd,package_manifest)
        finally: os.close(root_fd)
        self.assertEqual(core.candidate_binding(app_manifest),core.candidate_binding(package_manifest)); self.assertNotEqual(app_manifest["candidate_id"],package_manifest["candidate_id"])
        extracted=self.root/"extracted"/"LidSwitch.app"/"Contents"/"MacOS"; extracted.mkdir(parents=True)
        for directory in (self.root/"extracted",self.root/"extracted"/"LidSwitch.app",self.root/"extracted"/"LidSwitch.app"/"Contents",extracted): os.chmod(directory,0o700)
        extracted.joinpath("LidSwitch").write_bytes(b"app-bytes"); os.chmod(extracted/"LidSwitch",0o600)
        packager=load("package_immutable_candidate"); dmg_validator=load("validate_immutable_dmg")
        fds=[os.open(str(self.root),os.O_RDONLY|os.O_DIRECTORY),os.open(str(self.root/"extracted"),os.O_RDONLY|os.O_DIRECTORY),self.fd("envelope.json"),self.fd("candidate-manifest.json"),self.fd("package-descriptor.json")]
        try:
            published=packager.run(argparse.Namespace(candidate_root_fd=fds[0],extracted_app_root_fd=fds[1],extracted_app_name="LidSwitch.app",envelope_receipt_fd=fds[2],envelope_receipt_sha256=self.envelope_hash,app_manifest_fd=fds[3],app_manifest_sha256=sha(app_payload),package_descriptor_fd=fds[4],package_descriptor_sha256=dhash,manifest="package-manifest.json"),RenameOnly())
        finally:
            for fd in fds:
                try: os.close(fd)
                except OSError: pass
        fds=[os.open(str(self.root),os.O_RDONLY|os.O_DIRECTORY),os.open(str(self.root/"extracted"),os.O_RDONLY|os.O_DIRECTORY),self.fd("envelope.json")]
        try:
            observed=dmg_validator.run(argparse.Namespace(candidate_root_fd=fds[0],extracted_app_root_fd=fds[1],extracted_app_name="LidSwitch.app",envelope_receipt_fd=fds[2],envelope_receipt_sha256=self.envelope_hash,manifest="package-manifest.json"))
        finally:
            for fd in fds:
                try: os.close(fd)
                except OSError: pass
        self.assertEqual(observed["candidate_id"],published["candidate_id"])
        self.write("LidSwitch.dmg.sha256",b"wrong\n")
        root_fd=os.open(str(self.root),os.O_RDONLY|os.O_DIRECTORY)
        try:
            with self.assertRaises(core.CandidateError): core.verify_candidate(root_fd,package_manifest)
        finally: os.close(root_fd)
    def test_unrelated_canonical_receipt_payload_is_not_receipt_authority(self):
        descriptor=self.build_descriptor(); envelope_fd=self.fd("envelope.json"); descriptor_fd,descriptor_hash=self.descriptor_fd("build-descriptor.json",descriptor)
        try: manifest,_=core.build_manifest_from_pinned_descriptor(envelope_fd,self.envelope_hash,descriptor_fd,descriptor_hash)
        finally: os.close(envelope_fd); os.close(descriptor_fd)
        unrelated=core.canonical({"unrelated":"canonical-json"}); self.write("receipt-00.json",unrelated)
        manifest["receipts"][0]["sha256"]=sha(unrelated); manifest["helper"]["signature_receipt"]=sha(unrelated)
        root_fd=os.open(str(self.root),os.O_RDONLY|os.O_DIRECTORY)
        try:
            with self.assertRaises(core.CandidateError): core.verify_candidate(root_fd,manifest)
        finally: os.close(root_fd)
    def test_tree_digest_binds_relative_layout(self):
        for name,layout in (("One.app",(("a/file",b"one"),("b",None))), ("Two.app",(("a",None),("b/file",b"one")))):
            for child,data in layout:
                path=self.root/name/child
                if data is None: path.mkdir(parents=True); os.chmod(path,0o700)
                else: path.parent.mkdir(parents=True,exist_ok=True); path.write_bytes(data); os.chmod(path,0o600)
            os.chmod(self.root/name,0o700)
        root_fd=os.open(str(self.root),os.O_RDONLY|os.O_DIRECTORY)
        try: self.assertNotEqual(core.capture_tree(root_fd,"One.app")[1],core.capture_tree(root_fd,"Two.app")[1])
        finally: os.close(root_fd)
    def test_entries_expose_no_build_sign_package_runner(self):
        for filename in ("build_immutable_candidate.py","package_immutable_candidate.py","validate_immutable_candidate.py","validate_immutable_dmg.py"):
            text=(ROOT/filename).read_text(encoding="utf-8")
            for token in ("subprocess", "hdiutil", "codesign", "swift build", "xcodebuild", "os.system"):
                self.assertNotIn(token,text)
            self.assertIn("candidate-root-fd",text)

if __name__=="__main__": unittest.main()
