#!/usr/bin/python3
"""Production-function adversarial fixtures for the safe envelope.

This file is deliberately source-only in the correction lane.  Once harmless
probes are approved, it calls the shipped Python verifier rather than a shadow
parser or a hand-written approximation of its authentication/statistics logic.
"""

from __future__ import annotations

import sys
sys.dont_write_bytecode = True

import argparse
import copy
import hashlib
import hmac
import io
import json
import math
import os
import pathlib
import plistlib
import re
import shutil
import stat
import tempfile
import types
import unittest
import uuid


ROOT = pathlib.Path(__file__).resolve().parent
EX_IOERR = 74
DEPENDENCY_LIMIT_BYTES = 8 * 1024 * 1024
MAX_EINTR_RETRIES = 16
CANONICAL_ISOLATED_BOOTSTRAP = """import os,sys,stat,hashlib
p=sys.argv[1]; expected=sys.argv[2]; fd=-1
try:
 fd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC)
 before=os.fstat(fd)
 if not (len(expected)==64 and all(c in "0123456789abcdef" for c in expected) and stat.S_ISREG(before.st_mode) and before.st_uid==os.getuid() and before.st_gid==os.getgid() and before.st_nlink==1 and 0<before.st_size<=8388608): raise SystemExit(74)
 data=bytearray()
 while len(data)<before.st_size:
  retries=0
  while True:
   try: chunk=os.read(fd,min(131072,before.st_size-len(data))); break
   except InterruptedError:
    retries+=1
    if retries>16: raise SystemExit(74)
  if not chunk: raise SystemExit(74)
  data.extend(chunk)
 retries=0
 while True:
  try: extra=os.read(fd,1); break
  except InterruptedError:
   retries+=1
   if retries>16: raise SystemExit(74)
 after=os.fstat(fd); data=bytes(data)
 if len(data)!=before.st_size or extra or (after.st_dev,after.st_ino,after.st_uid,after.st_gid,after.st_mode,after.st_nlink,after.st_size)!=(before.st_dev,before.st_ino,before.st_uid,before.st_gid,before.st_mode,before.st_nlink,before.st_size) or hashlib.sha256(data).hexdigest()!=expected: raise SystemExit(74)
 code=compile(data,"<verified-test-safe-envelope>","exec")
 owned,fd=fd,-1
 try: os.close(owned)
 except BaseException: raise SystemExit(74)
except BaseException:
 if fd>=0:
  owned,fd=fd,-1
  try: os.close(owned)
  except BaseException: raise SystemExit(74)
 if isinstance(sys.exc_info()[1],SystemExit) and sys.exc_info()[1].code==74: raise
 raise SystemExit(74)
try: sys.argv=[p]+sys.argv[3:]; exec(code,{"__name__":"__main__","__file__":p,"__lidswitch_envelope_selftest_sha256__":expected})
except BaseException:
 if isinstance(sys.exc_info()[1],SystemExit) and sys.exc_info()[1].code==74: raise
 raise SystemExit(74)"""
# Updated only from the exact frozen dependency bytes. The self-test digest is
# intentionally external: the manager bootstrap supplies it before this file
# can execute, avoiding a self-referential hash.
DEPENDENCY_FREEZE = {
    "safe_file_capability": ("1efa793bfd62d718addaa4bf588e3ba11c1e7b2d601f60b877f60801afddb96c", 118213),
    "safe_process_supervisor": ("b098e1c6b49f65ab28b33e629381c4e6bf3443358d032d3f2c13a444ceb1a291", 63684),
}
STATIC_DATA_FREEZE = {
    "script/live_state_envelope.sh": ("b7f0e2c5f18bf50182d18cb3c6cad00655aa858114a1e6822fd932d5fedbfa70", 59707),
    "script/swift_sandbox_common.sh": ("30b96d1e3b7ff73173d792fd9dfff801d6974ad21a8df982ccf78c20bdb33985", 68188),
    "script/swift_test_sandbox.sb.in": ("851794f1b655898dd2618ee880c8f9e393687b5362a3a9e81f79ef99f69e23c7", 10822),
    "script/run_swift_tests_safely.sh": ("fd7fb61dcd22bfb6c1ad20dd863978f2b847bca5cfeb03f6abd672cd43811b14", 7524),
    "script/run_swift_build_safely.sh": ("7b14608282edca96003effaf1c5c70426368aa7e4a32d5a3c9b6550032e3e260", 9563),
    "script/benchmark_baseline.sh": ("700a32f104aa0e7e849b644f0574e7dab5784173860e64f0660a0619bd6437aa", 3894),
    "script/source_snapshot_manifest.jsonl": ("5413c71ee5fe362d7c9edeadaaace57e5e3c011c383458dbece5e930fa5818ed", 3578),
    # This document embeds the external self-test digest, so embedding its own
    # digest here would create a circular freeze. It is descriptor-read as data;
    # the canonical bootstrap-provided self digest and the manager's manifest
    # correlate it to the current source freeze without treating it as code.
    "docs/VALIDATION.md": None,
}


def _close_consumed_descriptor(fd: int) -> None:
    """Close once; a close error means the descriptor is no longer reusable."""
    try:
        os.close(fd)
    except BaseException:
        raise SystemExit(EX_IOERR)


def _read_descriptor_payload(fd: int, before: os.stat_result) -> tuple[bytes, os.stat_result]:
    """Bounded EINTR-safe payload plus one-byte EOF proof from a held FD."""
    payload = bytearray()
    while len(payload) < before.st_size:
        chunk = _bounded_descriptor_read(fd, min(131072, before.st_size - len(payload)))
        if not chunk:
            raise RuntimeError("descriptor ended early")
        payload.extend(chunk)
    extra = _bounded_descriptor_read(fd, 1)
    if extra:
        raise RuntimeError("descriptor grew while reading")
    return bytes(payload), os.fstat(fd)


def _bounded_descriptor_read(fd: int, count: int) -> bytes:
    retries = 0
    while True:
        try:
            return os.read(fd, count)
        except InterruptedError:
            retries += 1
            if retries > MAX_EINTR_RETRIES:
                raise RuntimeError("descriptor read interrupted too often")


def _terminal_descriptor_failure(fd: int, directory_fd: int) -> None:
    """Consume each still-owned descriptor once and always terminate as 74."""
    if fd >= 0:
        owned_fd, fd = fd, -1
        _close_consumed_descriptor(owned_fd)
    if directory_fd >= 0:
        owned_directory_fd, directory_fd = directory_fd, -1
        _close_consumed_descriptor(owned_directory_fd)
    raise SystemExit(EX_IOERR)


def verified_dependency_bytes(name: str) -> bytes:
    """Descriptor-read a frozen production dependency without bytecode fallback."""
    fd = directory_fd = -1
    try:
        frozen = DEPENDENCY_FREEZE.get(name)
        if frozen is None:
            raise RuntimeError("dependency digest is unavailable")
        expected, expected_size = frozen
        if not re.fullmatch(r"[0-9a-f]{64}", expected) or not isinstance(expected_size, int) or not 0 < expected_size <= DEPENDENCY_LIMIT_BYTES:
            raise RuntimeError("dependency digest is unavailable")
        directory_fd = os.open(str(ROOT), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        fd = os.open(name + ".py", os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=directory_fd)
        owned_directory_fd, directory_fd = directory_fd, -1
        _close_consumed_descriptor(owned_directory_fd)
        before = os.fstat(fd)
        identity = (before.st_dev, before.st_ino, before.st_uid, before.st_gid, before.st_mode, before.st_nlink, before.st_size)
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_gid != os.getgid() or before.st_nlink != 1 or before.st_size != expected_size:
            raise RuntimeError("dependency descriptor metadata is unsafe")
        verified, after = _read_descriptor_payload(fd, before)
        if (after.st_dev, after.st_ino, after.st_uid, after.st_gid, after.st_mode, after.st_nlink, after.st_size) != identity:
            raise RuntimeError("dependency descriptor changed while reading")
        if hashlib.sha256(verified).hexdigest() != expected:
            raise RuntimeError("dependency digest does not match frozen source")
        owned_fd, fd = fd, -1
        _close_consumed_descriptor(owned_fd)
        return verified
    except BaseException:
        _terminal_descriptor_failure(fd, directory_fd)


def verified_static_data_bytes(relative: str) -> bytes:
    """Read static assertion data atomically; only frozen Python becomes code."""
    fd = directory_fd = -1
    try:
        expected = STATIC_DATA_FREEZE.get(relative)
        if relative not in STATIC_DATA_FREEZE:
            raise RuntimeError("static data is not part of the envelope freeze")
        components = relative.split("/")
        if not components or any(not re.fullmatch(r"[A-Za-z0-9._-]{1,96}", component) for component in components):
            raise RuntimeError("static data path is unsafe")
        directory_fd = os.open(str(ROOT.parent), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        for component in components[:-1]:
            child_fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=directory_fd)
            owned_directory_fd, directory_fd = directory_fd, child_fd
            _close_consumed_descriptor(owned_directory_fd)
        fd = os.open(components[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=directory_fd)
        owned_directory_fd, directory_fd = directory_fd, -1
        _close_consumed_descriptor(owned_directory_fd)
        before = os.fstat(fd)
        identity = (before.st_dev, before.st_ino, before.st_uid, before.st_gid, before.st_mode, before.st_nlink, before.st_size)
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_gid != os.getgid() or before.st_nlink != 1 or not 0 < before.st_size <= DEPENDENCY_LIMIT_BYTES:
            raise RuntimeError("static data descriptor metadata is unsafe")
        if expected is not None and before.st_size != expected[1]:
            raise RuntimeError("static data size does not match frozen source")
        verified, after = _read_descriptor_payload(fd, before)
        if (after.st_dev, after.st_ino, after.st_uid, after.st_gid, after.st_mode, after.st_nlink, after.st_size) != identity:
            raise RuntimeError("static data descriptor changed while reading")
        if expected is not None and hashlib.sha256(verified).hexdigest() != expected[0]:
            raise RuntimeError("static data digest does not match frozen source")
        owned_fd, fd = fd, -1
        _close_consumed_descriptor(owned_fd)
        return verified
    except BaseException:
        _terminal_descriptor_failure(fd, directory_fd)


def verified_static_text(relative: str) -> str:
    try:
        return verified_static_data_bytes(relative).decode("utf-8")
    except BaseException:
        raise SystemExit(EX_IOERR)


def load(name: str):
    module = None
    try:
        source = verified_dependency_bytes(name)
        module = types.ModuleType(name)
        module.__file__ = f"<verified-{name}>"
        module.__cached__ = None
        module.__verified_source_bytes__ = source
        sys.modules[name] = module
        exec(compile(source, module.__file__, "exec"), module.__dict__)
        return module
    except BaseException:
        if module is not None:
            sys.modules.pop(name, None)
        raise SystemExit(EX_IOERR)


FILES = load("safe_file_capability")
SUPERVISOR = load("safe_process_supervisor")


def root_identity(path: str) -> str:
    metadata = os.stat(path, follow_symlinks=False)
    return ":".join((str(metadata.st_dev), str(metadata.st_ino), str(metadata.st_uid),
                     str(metadata.st_gid), format(metadata.st_mode & 0o7777, "o"), str(metadata.st_nlink)))


def increment_root_identity_nlink(identity: str) -> str:
    """Return a distinct six-field root identity with only decimal nlink changed."""
    fields = identity.split(":")
    if len(fields) != 6 or any(not field.isdecimal() for field in fields):
        raise RuntimeError("fixture root identity is malformed")
    fields[-1] = str(int(fields[-1], 10) + 1)
    mutated = ":".join(fields)
    if mutated == identity:
        raise RuntimeError("fixture root identity mutation was ineffective")
    return mutated


def write_private(path: str, payload: bytes) -> None:
    with open(path, "wb") as handle:
        handle.write(payload)
    os.chmod(path, 0o600)


def create_fixture_private_root(prefix: str) -> tuple[str, tuple[int, int, int, int, int]]:
    """Create a direct /private/tmp test root matching production intake."""
    path = tempfile.mkdtemp(prefix=prefix, dir="/private/tmp")
    os.chown(path, os.getuid(), os.getgid())
    os.chmod(path, 0o700)
    metadata = os.stat(path, follow_symlinks=False)
    token = (metadata.st_dev, metadata.st_ino, metadata.st_uid, metadata.st_gid, stat.S_IMODE(metadata.st_mode))
    if (
        os.path.dirname(path) != "/private/tmp"
        or not stat.S_ISDIR(metadata.st_mode)
        or token[2:] != (os.getuid(), os.getgid(), 0o700)
    ):
        raise RuntimeError("fixture private root is not canonical")
    return path, token


def remove_fixture_private_root(path: str, token: tuple[int, int, int, int, int]) -> None:
    """Restore permissions and remove only the exact root this fixture created."""
    metadata = os.stat(path, follow_symlinks=False)
    observed = (metadata.st_dev, metadata.st_ino, metadata.st_uid, metadata.st_gid, stat.S_IMODE(metadata.st_mode))
    if (
        os.path.dirname(path) != "/private/tmp"
        or not stat.S_ISDIR(metadata.st_mode)
        or observed != token
        or observed[2:4] != (os.getuid(), os.getgid())
    ):
        raise RuntimeError("refusing to remove an unowned fixture root")
    for parent, directories, files in os.walk(path, topdown=False, followlinks=False):
        parent_metadata = os.stat(parent, follow_symlinks=False)
        if (
            os.path.commonpath((path, parent)) != path
            or not stat.S_ISDIR(parent_metadata.st_mode)
            or parent_metadata.st_uid != os.getuid()
            or parent_metadata.st_gid != os.getgid()
            or (parent == path and (parent_metadata.st_dev, parent_metadata.st_ino, parent_metadata.st_uid, parent_metadata.st_gid, stat.S_IMODE(parent_metadata.st_mode)) != token)
        ):
            raise RuntimeError("fixture cleanup parent escaped its owned root")
        # Child unlink/rmdir permission belongs to the parent, not its leaf.
        os.chmod(parent, stat.S_IMODE(parent_metadata.st_mode) | 0o700)
        for name in files:
            child = os.path.join(parent, name)
            child_metadata = os.stat(child, follow_symlinks=False)
            if stat.S_ISLNK(child_metadata.st_mode):
                os.unlink(child)
            elif stat.S_ISREG(child_metadata.st_mode):
                os.chmod(child, stat.S_IMODE(child_metadata.st_mode) | 0o600)
                os.unlink(child)
            else:
                raise RuntimeError("fixture cleanup found an unsafe non-regular leaf")
        for name in directories:
            child = os.path.join(parent, name)
            child_metadata = os.stat(child, follow_symlinks=False)
            if stat.S_ISLNK(child_metadata.st_mode):
                os.unlink(child)
            elif stat.S_ISDIR(child_metadata.st_mode):
                os.chmod(child, stat.S_IMODE(child_metadata.st_mode) | 0o700)
                os.rmdir(child)
            else:
                raise RuntimeError("fixture cleanup found an unsafe non-directory child")
    os.chmod(path, stat.S_IMODE(metadata.st_mode) | 0o700)
    os.rmdir(path)


class SafeEnvelopeProductionFixtures(unittest.TestCase):
    def setUp(self):
        self.work, self._work_token = create_fixture_private_root("lidswitch-envelope-")

    def fixture_private_root(self, prefix: str) -> str:
        path, root_identity = create_fixture_private_root(prefix)
        self.addCleanup(remove_fixture_private_root, path, root_identity)
        return path

    def tearDown(self):
        remove_fixture_private_root(self.work, self._work_token)

    def args(self):
        return argparse.Namespace(source_root="/private/tmp/envelope", benchmark_app="/private/tmp/Candidate.app", benchmark_helper="/Library/Application Support/LidSwitch/Current/LidSwitchHelper")

    def canonical_records(self):
        fixture = "/private/tmp/envelope/fixtures/lidswitch-benchmark-fixture-fixture"
        warm = 5
        limitation = "Default rows are isolated fixture-backed production engines; real bundle validation and helper comparison run only with an explicit artifact contract."
        records = [
            {"record_type": "run", "schema_version": FILES.BENCHMARK_SCHEMA, "warm_samples": warm, "fixture_root": fixture, "artifact_scenarios_included": False, "snapshot_core_context": "test-host", "snapshot_core_limitations": limitation},
            {"record_type": "methodology", "schema_version": FILES.BENCHMARK_SCHEMA, "snapshot_core_context": "test-host", "snapshot_core_limitations": limitation, "artifact_validation": "explicit external app only; no guessed fallback", "helper_comparison": "production exact-byte comparison against installed root helper"},
            {"record_type": "environment", "schema_version": FILES.BENCHMARK_SCHEMA, "operating_system": "macOS fixture", "architecture": "arm64"},
        ]
        values: dict[str, list[int]] = {}
        scenarios = FILES.benchmark_scenario_order(False)
        for classification, indexes in (("cold", [0]), ("warm", range(1, warm + 1))):
            for index in indexes:
                for number, scenario in enumerate(scenarios, 1):
                    exact, positive, _ = FILES.BENCHMARK_COUNTER_CONTRACTS[scenario]
                    counters = dict(exact); counters.update({key: 1 for key in positive})
                    elapsed = 1000 + number * 10 + index
                    records.append({"record_type": "sample", "schema_version": FILES.BENCHMARK_SCHEMA, "scenario": scenario, "scenario_kind": FILES.BENCHMARK_SCENARIOS[scenario], "classification": classification, "sample_index": index, "elapsed_nanoseconds": elapsed, "main_thread_elapsed_nanoseconds": 0, "counters": counters, "fixture_root": fixture})
                    if classification == "warm": values.setdefault(scenario, []).append(elapsed)
        for scenario in sorted(scenarios):
            samples = values[scenario]
            records.append({"record_type": "summary", "schema_version": FILES.BENCHMARK_SCHEMA, "scenario": scenario, "sample_count": warm, "median_nanoseconds": FILES.benchmark_statistic(samples, .5), "p95_nanoseconds": FILES.benchmark_statistic(samples, .95), "sample_standard_deviation_nanoseconds": FILES.benchmark_standard_deviation(samples), "quantile": "R-7 linear interpolation"})
        return records

    def payload(self, records):
        return b"".join(json.dumps(record, sort_keys=True, separators=(",", ":")).encode() + b"\n" for record in records)

    def capture_fixture(self):
        control = self.fixture_private_root("lidswitch-control-")
        execution = self.fixture_private_root("lidswitch-execution-")
        logs = os.path.join(execution, "logs")
        os.mkdir(logs, 0o700); os.chown(logs, os.getuid(), os.getgid()); os.chmod(logs, 0o700)
        stdout = b"authentic stdout\n"; stderr = b"authentic stderr\n"
        for stream, payload in (("stdout", stdout), ("stderr", stderr)):
            write_private(os.path.join(execution, "logs", f"test-main.{stream}"), payload)
        key = bytes.fromhex("01" * 32)
        # Both fixed control names exist before root identity is captured: APFS
        # directory link count is part of the production retained-root seal.
        seal_path = os.path.join(control, "capture-test-main.seal")
        result_path = os.path.join(control, "supervisor-test-main.result")
        write_private(seal_path, b"{}\n")
        write_private(result_path, b"{}\n")
        args = argparse.Namespace(control_root=control, control_identity=root_identity(control), exec_root=execution, exec_identity=root_identity(execution), capture="test-main", stream="stdout", nonce="01234567-89ab-4cde-8fab-0123456789ab", profile_seal="1:2:3:4:600:1|" + "a" * 64, source_seal="b" * 64)
        def entry(stream):
            metadata = os.stat(os.path.join(execution, "logs", f"test-main.{stream}"), follow_symlinks=False)
            return {"dev": metadata.st_dev, "inode": metadata.st_ino, "uid": metadata.st_uid, "gid": metadata.st_gid, "mode": metadata.st_mode & 0o7777, "nlink": metadata.st_nlink, "size": metadata.st_size, "sha256": hashlib.sha256(open(os.path.join(execution, "logs", f"test-main.{stream}"), "rb").read()).hexdigest()}
        seal = {"schema": "lidswitch-capture-seal-v2", "capture": args.capture, "control_identity": args.control_identity, "execution_identity": args.exec_identity, "nonce": args.nonce, "profile_seal": args.profile_seal, "source_seal": args.source_seal, "stdout": entry("stdout"), "stderr": entry("stderr")}
        seal["context_sha256"] = hashlib.sha256(SUPERVISOR.canonical_capture_payload(seal)).hexdigest()
        seal["auth_hmac"] = hmac.new(key, SUPERVISOR.canonical_capture_payload(seal), hashlib.sha256).hexdigest()
        write_private(seal_path, json.dumps(seal, sort_keys=True, separators=(",", ":")).encode() + b"\n")
        return args, key, seal, stdout

    def replace_capture_seal(self, args, seal, key, *, raw=None):
        if raw is None:
            unsigned = {field: value for field, value in seal.items() if field != "auth_hmac"}
            seal["auth_hmac"] = hmac.new(key, SUPERVISOR.canonical_capture_payload(unsigned), hashlib.sha256).hexdigest()
            raw = json.dumps(seal, sort_keys=True, separators=(",", ":")).encode() + b"\n"
        write_private(os.path.join(args.control_root, "capture-test-main.seal"), raw)

    def supervisor_result_fixture(self, args, key, *, launched=True, leader_exit=0, outcome="completed", capture_seal=True):
        result = {"schema": "lidswitch-supervisor-result-v1", "capture": args.capture, "control_identity": args.control_identity, "execution_identity": args.exec_identity, "nonce": args.nonce, "profile_seal": args.profile_seal, "source_seal": args.source_seal, "launched": launched, "leader_exit": leader_exit, "outcome": outcome, "capture_seal": capture_seal}
        result["context_sha256"] = hashlib.sha256(SUPERVISOR.canonical_capture_payload(result)).hexdigest()
        result["auth_hmac"] = hmac.new(key, SUPERVISOR.canonical_capture_payload(result), hashlib.sha256).hexdigest()
        write_private(os.path.join(args.control_root, f"supervisor-{args.capture}.result"), json.dumps(result, sort_keys=True, separators=(",", ":")).encode() + b"\n")
        return result

    def signed_supervisor_result(self, args, key, *, launched, leader_exit, outcome, capture_seal):
        """Write a semantically selected, correctly authenticated result."""
        return self.supervisor_result_fixture(
            args, key, launched=launched, leader_exit=leader_exit,
            outcome=outcome, capture_seal=capture_seal,
        )

    def test_production_capture_verifier_round_trip_and_adversarial_mutations(self):
        dynamic_control = self.fixture_private_root("lidswitch-control-")
        sealed_control_identity = root_identity(dynamic_control)
        write_private(os.path.join(dynamic_control, "expected-control-leaf"), b"fixed\n")
        control_fd = FILES.open_retained_root(
            dynamic_control, sealed_control_identity, allow_nlink_growth=True,
        )
        os.close(control_fd)
        strict_execution = self.fixture_private_root("lidswitch-execution-")
        sealed_execution_identity = root_identity(strict_execution)
        write_private(os.path.join(strict_execution, "unexpected-root-leaf"), b"deny\n")
        with self.assertRaises(SystemExit):
            FILES.open_retained_root(strict_execution, sealed_execution_identity)

        args, key, seal, stdout = self.capture_fixture()
        descriptor, _, _ = FILES.open_sealed_capture(args, key)  # real no-follow verifier entry point
        os.close(descriptor)
        FILES.capture_verify(args, key)
        read_fd, write_fd = os.pipe()
        try:
            FILES.capture_read(args, key, write_fd)
            os.close(write_fd); write_fd = -1
            self.assertEqual(os.read(read_fd, 1024), stdout)
        finally:
            os.close(read_fd)
            if write_fd >= 0: os.close(write_fd)
        mutations = [
            lambda a, s, k: FILES.capture_verify(a, b"\x02" * 32),
            lambda a, s, k: FILES.capture_verify(argparse.Namespace(**{**vars(a), "nonce": a.nonce[:-1] + "c"}), k),
            lambda a, s, k: FILES.capture_verify(argparse.Namespace(**{**vars(a), "capture": "other"}), k),
            lambda a, s, k: FILES.capture_verify(argparse.Namespace(**{**vars(a), "profile_seal": "x" * len(a.profile_seal)}), k),
            lambda a, s, k: FILES.capture_verify(argparse.Namespace(**{**vars(a), "source_seal": "c" * 64}), k),
            lambda a, s, k: self.replace_capture_seal(a, {**s, "auth_hmac": "0" * 64}, k, raw=json.dumps({**s, "auth_hmac": "0" * 64}, sort_keys=True, separators=(",", ":")).encode() + b"\n"),
            lambda a, s, k: self.replace_capture_seal(a, {**s, "unexpected": 1}, k),
            lambda a, s, k: self.replace_capture_seal(a, s, k, raw=b"{}\n"),
            lambda a, s, k: self.replace_capture_seal(a, s, k, raw=b'{"schema":"lidswitch-capture-seal-v2","schema":"lidswitch-capture-seal-v2"}\n'),
            lambda a, s, k: self.replace_capture_seal(a, s, k, raw=json.dumps(s, sort_keys=True, indent=1).encode() + b"\n"),
        ]
        for mutation in mutations:
            args, key, seal, _ = self.capture_fixture()
            with self.assertRaises(SystemExit):
                mutation(args, copy.deepcopy(seal), key)
                FILES.capture_verify(args, key)
        for field in ("control_identity", "exec_identity"):
            args, key, _, _ = self.capture_fixture()
            mutated = increment_root_identity_nlink(getattr(args, field))
            self.assertNotEqual(mutated, getattr(args, field))
            with self.assertRaises(SystemExit):
                FILES.capture_verify(argparse.Namespace(**{**vars(args), field: mutated}), key)
        for encoded in (b"", ("01" * 32).encode(), (("01" * 32) + "\nextra").encode(), b"g" * 64 + b"\n"):
            with self.assertRaises(SystemExit): FILES.capture_authentication_key_from_bytes(encoded)
        first_args, first_key, _, _ = self.capture_fixture()
        second_args, _, _, _ = self.capture_fixture()
        with open(os.path.join(second_args.control_root, "capture-test-main.seal"), "rb") as handle:
            write_private(os.path.join(first_args.control_root, "capture-test-main.seal"), handle.read())
        with self.assertRaises(SystemExit): FILES.capture_verify(first_args, first_key)
        for attack in ("replace", "hardlink", "symlink", "size", "hash"):
            args, key, seal, _ = self.capture_fixture()
            path = os.path.join(args.exec_root, "logs", "test-main.stdout")
            if attack == "replace": write_private(path + ".new", b"substitute\n"); os.replace(path + ".new", path)
            elif attack == "hardlink": os.link(path, path + ".link")
            elif attack == "symlink": os.unlink(path); os.symlink("test-main.stderr", path)
            elif attack == "size": write_private(path, b"different size\n")
            else: write_private(path, b"AUTHENTIC stdout\n")
            with self.assertRaises(SystemExit): FILES.capture_verify(args, key)

    def test_production_supervisor_result_capability_rejects_untrusted_child_exit(self):
        args, key, _, _ = self.capture_fixture()
        result = self.supervisor_result_fixture(args, key)
        self.assertEqual(FILES.open_supervisor_result(args, key)["leader_exit"], 0)
        self.supervisor_result_fixture(args, key, launched=False, leader_exit=None, outcome="launch-failed", capture_seal=False)
        self.assertEqual(FILES.open_supervisor_result(args, key)["outcome"], "launch-failed")
        for mutate in (
            lambda value: value.__setitem__("auth_hmac", "0" * 64),
            lambda value: value.__setitem__("nonce", "01234567-89ab-4cde-8fab-0123456789ac"),
        ):
            candidate = copy.deepcopy(result); mutate(candidate)
            write_private(os.path.join(args.control_root, "supervisor-test-main.result"), json.dumps(candidate, sort_keys=True, separators=(",", ":")).encode() + b"\n")
            with self.assertRaises(SystemExit): FILES.open_supervisor_result(args, key)
        valid = (
            (False, None, "setup-failed", False),
            (False, None, "launch-failed", False),
            (True, 0, "completed", True),
            (True, 137, "interrupted", False),
            (True, 9, "containment-failed", False),
            (True, 9, "capture-seal-failed", False),
        )
        for launched, leader_exit, outcome, capture_seal in valid:
            self.signed_supervisor_result(args, key, launched=launched, leader_exit=leader_exit, outcome=outcome, capture_seal=capture_seal)
            self.assertTrue(SUPERVISOR.supervisor_result_state_is_valid(launched=launched, leader_exit=leader_exit, outcome=outcome, capture_seal=capture_seal))
            opened = FILES.open_supervisor_result(args, key)
            self.assertEqual(opened["outcome"], outcome)
            self.assertEqual(FILES.supervisor_wrapper_mapping(opened), (256 if not launched else leader_exit, outcome == "completed"))
        impossible = (
            (True, 0, "launch-failed", False),
            (True, 0, "setup-failed", False),
            (False, None, "interrupted", False),
            (True, None, "containment-failed", False),
            (True, 0, "capture-seal-failed", True),
            (True, 0, "completed", False),
            (False, 0, "completed", True),
            (True, True, "completed", True),
        )
        for launched, leader_exit, outcome, capture_seal in impossible:
            self.signed_supervisor_result(args, key, launched=launched, leader_exit=leader_exit, outcome=outcome, capture_seal=capture_seal)
            self.assertFalse(SUPERVISOR.supervisor_result_state_is_valid(launched=launched, leader_exit=leader_exit, outcome=outcome, capture_seal=capture_seal))
            with self.assertRaises(SystemExit): FILES.open_supervisor_result(args, key)
        self.supervisor_result_fixture(args, key)
        path = os.path.join(args.control_root, "supervisor-test-main.result")
        os.link(path, path + ".link")
        with self.assertRaises(SystemExit): FILES.open_supervisor_result(args, key)
        os.unlink(path + ".link")
        os.chmod(path, 0o644)
        with self.assertRaises(SystemExit): FILES.open_supervisor_result(args, key)
        os.chmod(path, 0o600)
        alternate_uid = 0 if os.getuid() != 0 else 1
        try:
            os.chown(path, alternate_uid, os.getgid())
        except PermissionError:
            pass  # A non-privileged fixture still exercises mode/link/context paths.
        else:
            try:
                with self.assertRaises(SystemExit): FILES.open_supervisor_result(args, key)
            finally:
                os.chown(path, os.getuid(), os.getgid())
        write_private(path, b"{}\n")
        with self.assertRaises(SystemExit): FILES.open_supervisor_result(args, key)
        os.unlink(path)
        with self.assertRaises(SystemExit): FILES.open_supervisor_result(args, key)
        second_args, _, _, _ = self.capture_fixture()
        self.supervisor_result_fixture(second_args, key)
        with open(os.path.join(second_args.control_root, "supervisor-test-main.result"), "rb") as handle:
            write_private(path, handle.read())
        with self.assertRaises(SystemExit): FILES.open_supervisor_result(args, key)

    def test_production_cleanup_state_machine_injected_failures(self):
        """Exercise the actual supervisor state machine without launching a child."""
        class Clock:
            def __init__(self): self.value = 0.0
            def now(self): return self.value
            def sleep(self, seconds): self.value += seconds

        leader = SUPERVISOR.ProcessIdentity(4242, 100, 7)
        def run(*, interrupted=lambda: 0, poll=lambda: 0, wait=lambda _: 0,
                members=lambda _: {}, signal=lambda _: None):
            clock = Clock()
            machine = SUPERVISOR.CleanupStateMachine(leader=leader, session_id=4242)
            proved = SUPERVISOR.run_cleanup_state_machine(
                machine, poll_leader=poll, wait_leader=wait,
                enumerate_members=members, signal_direct=signal,
                monotonic=clock.now, sleep=clock.sleep, interrupted=interrupted,
            )
            return proved, machine

        proved, machine = run()
        self.assertTrue(proved); self.assertEqual(machine.terminal_outcome(), "completed")

        signals = []
        proved, machine = run(interrupted=lambda: 15, wait=lambda _: -15, signal=lambda signum: signals.append(signum))
        self.assertTrue(proved); self.assertEqual(machine.terminal_outcome(), "interrupted")
        self.assertEqual(signals[0], SUPERVISOR.signal.SIGTERM)  # pre-spawn flag is cleaned after identity capture
        proved, machine = run(interrupted=lambda: 2, wait=lambda _: -2)
        self.assertTrue(proved); self.assertEqual(machine.terminal_outcome(), "interrupted")  # signal after Popen/identity capture

        cleanup_trace = []
        kill_seen = {"value": False}
        def ignores_term(signum):
            cleanup_trace.append(("signal", signum))
            kill_seen["value"] = kill_seen["value"] or signum == SUPERVISOR.signal.SIGKILL
        def reap_after_kill(timeout):
            cleanup_trace.append(("wait", kill_seen["value"], timeout))
            return -9 if kill_seen["value"] else None
        def session_until_kill(_):
            cleanup_trace.append(("members", kill_seen["value"]))
            return {} if kill_seen["value"] else {
                leader.pid: SUPERVISOR.ProcessRecord(leader, 1, leader.pid, leader.pid),
            }
        proved, machine = run(interrupted=lambda: 2, poll=lambda: None,
                              wait=reap_after_kill, members=session_until_kill,
                              signal=ignores_term)
        self.assertTrue(proved); self.assertEqual(machine.leader_exit, 137)  # TERM-ignoring child reaches bounded KILL/reap
        self.assertEqual([event for event in cleanup_trace if event[0] == "signal"], [("signal", SUPERVISOR.signal.SIGTERM), ("signal", SUPERVISOR.signal.SIGKILL)])
        self.assertIn(("wait", True, SUPERVISOR.POLL_SECONDS), cleanup_trace)
        self.assertGreaterEqual(
            sum(event == ("members", True) for event in cleanup_trace),
            SUPERVISOR.STABLE_EMPTY_SAMPLES,
        )

        calls = {"value": 0}
        def transient_ps(_):
            calls["value"] += 1
            if calls["value"] <= 2: raise RuntimeError("injected ps failure")
            return {}
        proved, machine = run(interrupted=lambda: 2, wait=lambda _: -9, members=transient_ps)
        self.assertTrue(proved); self.assertTrue(machine.enumeration_fault); self.assertEqual(machine.terminal_outcome(), "interrupted")

        def failing_poll(): raise OSError("injected leader poll failure")
        proved, machine = run(interrupted=lambda: 2, poll=failing_poll, wait=lambda _: -9)
        self.assertTrue(proved); self.assertTrue(machine.containment_fault)

        survivor_calls = {"value": 0}
        def surviving_descendant(_):
            survivor_calls["value"] += 1
            descendant = SUPERVISOR.ProcessIdentity(4243, 101, 9)
            return {4243: SUPERVISOR.ProcessRecord(descendant, 4242, 4242, 4242)} if survivor_calls["value"] <= 12 else {}
        proved, machine = run(poll=lambda: 0, wait=lambda _: 0, members=surviving_descendant)
        self.assertTrue(proved); self.assertEqual(machine.terminal_outcome(), "containment-failed")

        proved, machine = run(interrupted=lambda: 2, poll=lambda: None, wait=lambda _: None, members=lambda _: {4242: SUPERVISOR.ProcessRecord(leader, 1, 4242, 4242)}, signal=lambda signum: (_ for _ in ()).throw(RuntimeError("injected SIGKILL failure")) if signum == SUPERVISOR.signal.SIGKILL else None)
        self.assertFalse(proved); self.assertTrue(machine.direct_signal_fault)  # no stable absence means no result
        self.assertFalse(SUPERVISOR.publish_supervisor_result_if_permitted(permitted=False, publish=lambda: None))
        self.assertFalse(SUPERVISOR.publish_supervisor_result_if_permitted(permitted=True, publish=lambda: (_ for _ in ()).throw(OSError("injected result write failure"))))

    def test_production_token_bound_process_table_and_signal_selection(self):
        """No injected reuse case may emit a PID, PGID, or SID signal."""
        leader = SUPERVISOR.ProcessIdentity(4242, 100, 7)
        descendant = SUPERVISOR.ProcessIdentity(4243, 101, 9)
        rows = "1 0 1\n4242 1 4242\n4243 4242 4242\n"
        identities = {4242: leader, 4243: descendant}
        sessions = {1: 1, 4242: 4242, 4243: 4242}
        records = SUPERVISOR.process_table(4242, {leader}, ps_reader=lambda: rows, identity_reader=lambda pid: identities.get(pid), session_reader=lambda pid: sessions[pid])
        self.assertNotIn(1, records)
        self.assertEqual(records[4242].identity, leader)
        self.assertEqual(SUPERVISOR.session_members(4242, {leader}, ps_reader=lambda: rows, identity_reader=lambda pid: identities.get(pid), session_reader=lambda pid: sessions[pid])[4243].identity, descendant)

        def assert_no_signal_for_reuse(replacement, observed={leader}, table=rows):
            calls = []
            stale = {4242: replacement, 4243: descendant}
            with self.assertRaises(RuntimeError):
                SUPERVISOR.direct_containment_signal(
                    leader, 4242, observed, records, SUPERVISOR.signal.SIGKILL,
                    identity_reader=lambda pid: stale.get(pid),
                    killer=lambda pid, sig: calls.append(("pid", pid, sig)),
                    group_killer=lambda pgid, sig: calls.append(("group", pgid, sig)),
                )
            self.assertEqual(calls, [])

        # Leader reuse and a reuse discovered after enumeration both reject the
        # exact token before either per-PID or process-group delivery.
        assert_no_signal_for_reuse(SUPERVISOR.ProcessIdentity(4242, 200, 1))
        with self.assertRaises(RuntimeError):
            SUPERVISOR.process_table(4242, {leader}, ps_reader=lambda: rows, identity_reader=lambda pid: None if pid == 4242 else descendant, session_reader=lambda pid: sessions[pid])

        # Escaped/reused descendants are classification faults; no session-wide
        # broadcast is selected from untrusted process-table text.
        escaped_rows = "4242 1 4242\n4243 4242 4242\n"
        escaped_sessions = {4242: 4242, 4243: 9999}
        with self.assertRaises(RuntimeError):
            SUPERVISOR.session_members(4242, {leader, descendant}, ps_reader=lambda: escaped_rows, identity_reader=lambda pid: {4242: leader, 4243: SUPERVISOR.ProcessIdentity(4243, 202, 3)}.get(pid), session_reader=lambda pid: escaped_sessions[pid])
        with self.assertRaises(RuntimeError):
            SUPERVISOR.session_members(4242, {leader}, ps_reader=lambda: escaped_rows, identity_reader=lambda pid: {4242: leader, 4243: descendant}.get(pid), session_reader=lambda pid: escaped_sessions[pid])
        calls = []
        with self.assertRaises(RuntimeError):
            SUPERVISOR.direct_containment_signal(leader, 4242, {leader, descendant}, records, SUPERVISOR.signal.SIGTERM, identity_reader=lambda pid: {4242: leader, 4243: SUPERVISOR.ProcessIdentity(4243, 202, 3)}.get(pid), killer=lambda pid, sig: calls.append(("pid", pid)), group_killer=lambda pgid, sig: calls.append(("group", pgid)))
        self.assertNotIn(("pid", 4243), calls)
        self.assertFalse(any(kind == "group" for kind, _ in calls))

        # Durable repetition takes the same production selection path. A token
        # failure stays an unproved containment classification, never a signal.
        machine = SUPERVISOR.CleanupStateMachine(leader=leader, session_id=4242)
        self.assertFalse(SUPERVISOR.durable_cleanup_round(
            machine, identity_reader=lambda _pid: None, ps_reader=lambda: rows,
            session_reader=lambda pid: sessions[pid],
            killer=lambda pid, sig: (_ for _ in ()).throw(AssertionError("must not signal")),
            group_killer=lambda pgid, sig: (_ for _ in ()).throw(AssertionError("must not signal")),
        ))
        self.assertFalse(SUPERVISOR.durable_cleanup_round(
            machine, identity_reader=lambda _pid: None, ps_reader=lambda: rows,
            session_reader=lambda pid: sessions[pid],
            killer=lambda pid, sig: (_ for _ in ()).throw(AssertionError("must not signal")),
            group_killer=lambda pgid, sig: (_ for _ in ()).throw(AssertionError("must not signal")),
        ))
        self.assertTrue(machine.containment_fault)
        self.assertEqual(machine.terminal_outcome(), "containment-failed")

    def test_production_startup_gate_blocks_unbound_payload_and_classifies_release_edges(self):
        """Drive real gate functions with injected I/O; no process is launched."""
        leader = SUPERVISOR.ProcessIdentity(4242, 100, 7)
        identities = {4242: leader}
        writes, closes = [], []
        exact = lambda pid: identities.get(pid)
        exact_group = lambda pid: 4242
        exact_session = lambda pid: 4242
        self.assertEqual(
            SUPERVISOR.release_startup_gate(
                8, leader, identity_reader=exact, group_reader=exact_group,
                session_reader=exact_session,
                writer=lambda fd, payload: writes.append((fd, payload)) or len(payload),
                closer=lambda fd: closes.append(fd),
            ),
            "released",
        )
        self.assertEqual(writes, [(8, SUPERVISOR.STARTUP_GATE_RELEASE)])
        self.assertEqual(closes, [8])

        # Reused PID, session/group transition mismatch, unavailable token and
        # write failure cannot deliver the release byte to a target marker.
        for reader, group, session, writer in (
            (lambda _pid: SUPERVISOR.ProcessIdentity(4242, 200, 1), exact_group, exact_session, None),
            (exact, lambda _pid: 9999, exact_session, None),
            (exact, exact_group, lambda _pid: 9999, None),
            (exact, exact_group, exact_session, lambda _fd, _payload: (_ for _ in ()).throw(OSError("write"))),
        ):
            target_marker, local_closes = [], []
            release_writer = writer or (lambda _fd, payload: target_marker.append(payload) or len(payload))
            self.assertEqual(
                SUPERVISOR.release_startup_gate(
                    9, leader, identity_reader=reader, group_reader=group,
                    session_reader=session, writer=release_writer,
                    closer=lambda fd: local_closes.append(fd),
                ),
                "blocked",
            )
            self.assertEqual(target_marker, [])
            self.assertEqual(local_closes, [9])

        # A close error after a successful write is deliberately ambiguous and
        # must enter token-bound cleanup rather than publishing a result.
        self.assertEqual(
            SUPERVISOR.release_startup_gate(
                10, leader, identity_reader=exact, group_reader=exact_group,
                session_reader=exact_session, writer=lambda _fd, payload: len(payload),
                closer=lambda _fd: (_ for _ in ()).throw(OSError("close")),
            ),
            "ambiguous",
        )
        self.assertFalse(SUPERVISOR.publish_supervisor_result_if_permitted(
            permitted=False, publish=lambda: (_ for _ in ()).throw(AssertionError("receipt sink")),
        ))

        class BlockedChild:
            def __init__(self): self.calls = 0
            def wait(self):
                self.calls += 1
                if self.calls == 1: raise InterruptedError()
                return 74
        blocked = BlockedChild()
        SUPERVISOR.reap_blocked_startup_gate(blocked)
        self.assertEqual(blocked.calls, 2)  # child exited while gate remained blocked
        self.assertTrue(SUPERVISOR.supervisor_result_state_is_valid(
            launched=False, leader_exit=None, outcome="setup-failed", capture_seal=False,
        ))
        self.assertFalse(SUPERVISOR.supervisor_result_state_is_valid(
            launched=False, leader_exit=0, outcome="setup-failed", capture_seal=False,
        ))

    def test_production_cleanup_snapshot_receipt_rejects_mutable_reexec_authority(self):
        """The real receipt verifier, not __file__, authorizes durable cleanup."""
        manifest_rows = [json.loads(line) for line in verified_static_text("script/source_snapshot_manifest.jsonl").splitlines()]
        self.assertEqual(
            [row["path"] for row in manifest_rows],
            [
                ".github/workflows/ci.yml", "Package.swift", "Resources", "Sources", "Tests",
                "release/GeneratedReleaseHelperTrustAnchor.template.swift",
                "release/LidSwitchLaunchDaemon.plist.template",
                "script/benchmark_baseline.sh", "script/live_state_envelope.sh", "script/release.env",
                "script/run_swift_build_safely.sh", "script/run_swift_tests_safely.sh",
                "script/safe_file_capability.py", "script/safe_process_supervisor.py",
                "script/swift_sandbox_common.sh", "script/swift_test_sandbox.sb.in",
                "script/validate_bundle.sh", "script/validate_live_state.sh",
                "script/validate_session_safety.sh",
            ],
        )
        supervisor_row = next(row for row in manifest_rows if row["path"] == "script/safe_process_supervisor.py")
        self.assertEqual(
            supervisor_row,
            {
                "mode": 0o644,
                "path": "script/safe_process_supervisor.py",
                "schema": "lidswitch-source-manifest-v1",
                "sha256": DEPENDENCY_FREEZE["safe_process_supervisor"][0],
                "size": DEPENDENCY_FREEZE["safe_process_supervisor"][1],
                "type": "file",
            },
        )
        safe_file_source = FILES.__verified_source_bytes__.decode("utf-8")
        self.assertIn(
            "required_entries = list(SNAPSHOT_INPUTS)",
            safe_file_source,
        )
        self.assertIn('parts[4] not in ("source", "helper-source", "app-source")', SUPERVISOR.__verified_source_bytes__.decode("utf-8"))
        execution = self.fixture_private_root("lidswitch-swift._")
        source = os.path.join(execution, "source"); script = os.path.join(source, "script")
        os.makedirs(script, mode=0o700)
        leaf = os.path.join(script, "safe_process_supervisor.py")
        with open(leaf, "wb") as handle: handle.write(b"immutable supervisor fixture\n")
        os.chmod(leaf, 0o444); os.chmod(script, 0o555); os.chmod(source, 0o555)
        source_fd = SUPERVISOR.open_cleanup_source_root(source)
        try:
            seal = SUPERVISOR.cleanup_snapshot_digest(source_fd)
        finally:
            os.close(source_fd)
        receipt = SUPERVISOR.cleanup_script_receipt(source, seal)
        descriptor = SUPERVISOR.open_verified_cleanup_script(source, seal, receipt)
        try:
            self.assertEqual(os.fstat(descriptor).st_ino, os.stat(leaf, follow_symlinks=False).st_ino)
        finally:
            os.close(descriptor)
        # Same-size leaf substitution and an inode/mode change each invalidate
        # the whole-snapshot digest or exact leaf receipt before owner spawn.
        os.chmod(source, 0o700); os.chmod(script, 0o700)
        replacement = leaf + ".replacement"
        write_private(replacement, b"mutable-- supervisor fixture\n")
        os.chmod(replacement, 0o444); os.replace(replacement, leaf)
        os.chmod(script, 0o555); os.chmod(source, 0o555)
        with self.assertRaises(RuntimeError): SUPERVISOR.open_verified_cleanup_script(source, seal, receipt)
        self.assertNotIn("os.path.abspath(__file__)", SUPERVISOR.__verified_source_bytes__.decode("utf-8"))

    def _documented_bootstrap_audit_body(self) -> str:
        """Extract documentation as descriptor-read audit data, never code authority."""
        validation = verified_static_text("docs/VALIDATION.md")
        prefix = "/usr/bin/python3 -I -S -B -c '"
        start = validation.index(prefix) + len(prefix)
        end = validation.index("\n' script/test_safe_envelope.py ", start)
        return validation[start:end]

    def _exercise_documentation_bootstrap(self, *, early_eof: bool, close_failure: bool = False,
                                          namespace_exit: bool = False,
                                          extra_interruption: bool = False,
                                          close_reuse: bool = False) -> None:
        """Execute only the frozen bootstrap literal with deterministic FD faults."""
        nonce = uuid.uuid4().hex
        path = os.path.join(self.work, "bootstrap-" + nonce + ".py")
        sentinel_path = os.path.join(self.work, "bootstrap-close-reuse-sentinel-" + nonce)
        payload = b"raise SystemExit(7)\n" if namespace_exit else b"documentation_bootstrap_marker=True\n"
        write_private(path, payload); os.chmod(path, 0o444)
        write_private(sentinel_path, b"descriptor reuse sentinel\n"); os.chmod(sentinel_path, 0o444)
        original_open, original_read, original_close, original_fstat, saved_argv = os.open, os.read, os.close, os.fstat, list(sys.argv)
        captured = []; interrupted = [False]; close_fault = [close_failure or close_reuse]; sentinel_fd = [None]
        def capture_open(candidate, flags, *args, **kwargs):
            descriptor = original_open(candidate, flags, *args, **kwargs)
            if candidate == path:
                captured.append(descriptor)
            return descriptor
        def scripted_read(descriptor, count):
            if captured and descriptor == captured[-1]:
                if early_eof and count > 1:
                    return b""
                if (count == 1 if extra_interruption else count > 1) and not interrupted[0]:
                    interrupted[0] = True
                    raise InterruptedError()
            return original_read(descriptor, count)
        def scripted_close(descriptor):
            if captured and descriptor == captured[0] and close_fault[0]:
                close_fault[0] = False
                if close_reuse:
                    original_close(descriptor)
                    sentinel_fd[0] = original_open(sentinel_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
                    self.assertEqual(sentinel_fd[0], descriptor)
                    raise OSError("injected bootstrap close-after-retire failure")
                raise OSError("injected bootstrap close failure")
            return original_close(descriptor)
        try:
            os.open, os.read, os.close = capture_open, scripted_read, scripted_close
            sys.argv = ["-c", path, hashlib.sha256(payload).hexdigest()]
            namespace = {"__name__": "__bootstrap__"}
            if early_eof or close_failure or namespace_exit or close_reuse:
                with self.assertRaises(SystemExit) as failure:
                    exec(compile(CANONICAL_ISOLATED_BOOTSTRAP, "<frozen-isolated-bootstrap>", "exec"), namespace)
                self.assertEqual(failure.exception.code, 74)
            else:
                exec(compile(CANONICAL_ISOLATED_BOOTSTRAP, "<frozen-isolated-bootstrap>", "exec"), namespace)
                self.assertTrue(interrupted[0])
            self.assertEqual(len(captured), 1)
            if close_reuse:
                self.assertIsNotNone(sentinel_fd[0])
                self.assertTrue(stat.S_ISREG(original_fstat(sentinel_fd[0]).st_mode))
            elif close_failure:
                self.assertTrue(stat.S_ISREG(original_fstat(captured[0]).st_mode))
                original_close(captured[0])
                captured[0] = -1
            else:
                with self.assertRaises(OSError): original_fstat(captured[0])
        finally:
            sys.argv = saved_argv
            os.open, os.read, os.close = original_open, original_read, original_close
            if sentinel_fd[0] is not None:
                original_close(sentinel_fd[0])

    def _exercise_verified_loader(self, loader, target_size: int, *, early_eof: bool,
                                  close_failure: bool = False,
                                  directory_close_failure: bool = False,
                                  extra_interruption: bool = False) -> None:
        """Inject read faults through actual dependency/static-data loader FDs."""
        original_open, original_read, original_close, original_fstat = os.open, os.read, os.close, os.fstat
        captured, opened, interrupted = [], [], [False]
        close_fault = [close_failure or directory_close_failure]

        def capture_open(*args, **kwargs):
            descriptor = original_open(*args, **kwargs)
            metadata = original_fstat(descriptor)
            opened.append(descriptor)
            if stat.S_ISREG(metadata.st_mode) and metadata.st_size == target_size:
                captured.append(descriptor)
            return descriptor

        def scripted_read(descriptor, count):
            if captured and descriptor == captured[-1]:
                if early_eof and count > 1:
                    return b""
                if not early_eof and (count == 1 if extra_interruption else count > 1) and not interrupted[0]:
                    interrupted[0] = True
                    raise InterruptedError()
            return original_read(descriptor, count)

        def scripted_close(descriptor):
            metadata = original_fstat(descriptor)
            fail_leaf = close_failure and captured and descriptor == captured[-1]
            fail_directory = directory_close_failure and stat.S_ISDIR(metadata.st_mode)
            if close_fault[0] and (fail_leaf or fail_directory):
                close_fault[0] = False
                raise OSError("injected loader close failure")
            return original_close(descriptor)

        try:
            os.open, os.read, os.close = capture_open, scripted_read, scripted_close
            if early_eof or close_failure or directory_close_failure:
                with self.assertRaises(SystemExit) as failure:
                    loader()
                self.assertEqual(failure.exception.code, EX_IOERR)
            else:
                self.assertTrue(loader())
                self.assertTrue(interrupted[0])
            if directory_close_failure:
                self.assertLessEqual(len(captured), 1)
            else:
                self.assertEqual(len(captured), 1)
        finally:
            os.open, os.read, os.close = original_open, original_read, original_close
            for descriptor in opened:
                try:
                    original_close(descriptor)
                except OSError:
                    pass

    def _exercise_cleanup_bootstrap(self, *, early_eof: bool) -> None:
        """Exercise the real inherited-FD bootstrap against EOF and EINTR."""
        path = os.path.join(self.work, "cleanup-bootstrap-" + uuid.uuid4().hex + ".py")
        payload = b"verified_cleanup_marker=True\n"
        write_private(path, payload); os.chmod(path, 0o444)
        saved_argv = list(sys.argv); original_read = os.read
        source_fd = None
        try: saved_fd = os.dup(SUPERVISOR.CLEANUP_INHERITED_FD)
        except OSError: saved_fd = None
        try:
            source_fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
            if source_fd == SUPERVISOR.CLEANUP_INHERITED_FD:
                replacement = os.dup(source_fd); os.close(source_fd); source_fd = replacement
            metadata = os.fstat(source_fd)
            receipt = ":".join(("a" * 64, str(metadata.st_dev), str(metadata.st_ino), str(metadata.st_uid), str(metadata.st_gid), str(stat.S_IMODE(metadata.st_mode)), str(metadata.st_nlink), str(metadata.st_size), hashlib.sha256(payload).hexdigest()))
            interrupted = [False]
            def scripted_read(descriptor, count):
                if descriptor == SUPERVISOR.CLEANUP_INHERITED_FD and count > 1:
                    if early_eof:
                        return b""
                    if not interrupted[0]:
                        interrupted[0] = True
                        raise InterruptedError()
                return original_read(descriptor, count)
            os.dup2(source_fd, SUPERVISOR.CLEANUP_INHERITED_FD)
            os.read = scripted_read
            sys.argv = ["-c", str(SUPERVISOR.CLEANUP_INHERITED_FD), str(SUPERVISOR.CLEANUP_SOURCE_ROOT_FD), "a" * 64, receipt]
            namespace = {"__name__": "__bootstrap__"}
            if early_eof:
                with self.assertRaises(SystemExit) as failure:
                    exec(compile(SUPERVISOR.CLEANUP_BOOTSTRAP, "<cleanup-bootstrap>", "exec"), namespace)
                self.assertEqual(failure.exception.code, 74)
            else:
                exec(compile(SUPERVISOR.CLEANUP_BOOTSTRAP, "<cleanup-bootstrap>", "exec"), namespace)
                self.assertTrue(interrupted[0])
                self.assertTrue(namespace["_verified_cleanup_namespace"]["verified_cleanup_marker"])
        finally:
            sys.argv = saved_argv
            os.read = original_read
            if saved_fd is None:
                try: os.close(SUPERVISOR.CLEANUP_INHERITED_FD)
                except OSError: pass
            else:
                os.dup2(saved_fd, SUPERVISOR.CLEANUP_INHERITED_FD); os.close(saved_fd)
            if source_fd is not None:
                try: os.close(source_fd)
                except OSError: pass

    def test_bootstrap_early_eof_and_interruption_regressions(self):
        self._exercise_documentation_bootstrap(early_eof=True)
        self._exercise_documentation_bootstrap(early_eof=False)
        self._exercise_documentation_bootstrap(early_eof=False, extra_interruption=True)
        self._exercise_documentation_bootstrap(early_eof=False, close_failure=True)
        self._exercise_documentation_bootstrap(early_eof=False, close_reuse=True)
        self._exercise_documentation_bootstrap(early_eof=False, namespace_exit=True)
        for loader, target_size in (
            (lambda: verified_dependency_bytes("safe_file_capability"), DEPENDENCY_FREEZE["safe_file_capability"][1]),
            (lambda: verified_static_data_bytes("script/swift_sandbox_common.sh"), STATIC_DATA_FREEZE["script/swift_sandbox_common.sh"][1]),
        ):
            self._exercise_verified_loader(loader, target_size, early_eof=False)
            self._exercise_verified_loader(loader, target_size, early_eof=False, extra_interruption=True)
            self._exercise_verified_loader(loader, target_size, early_eof=True)
            self._exercise_verified_loader(loader, target_size, early_eof=False, close_failure=True)
            self._exercise_verified_loader(loader, target_size, early_eof=False, directory_close_failure=True)
        self._exercise_cleanup_bootstrap(early_eof=True)
        self._exercise_cleanup_bootstrap(early_eof=False)

    def test_explicit_runner_rejects_private_namespace_zero_discovery_and_result_classes(self):
        """Exercise the production runner rather than a source-string substitute."""
        private_namespace = {"__name__": "__main__"}
        exec(
            "import unittest\n"
            "class PrivateFixture(unittest.TestCase):\n"
            "    def test_exact(self): pass\n",
            private_namespace,
        )
        private_case = private_namespace["PrivateFixture"]
        original_main = sys.modules["__main__"]
        try:
            # `unittest.main()` / TestProgram consults this module, not private
            # exec globals, precisely reproducing the former false-green bug.
            sys.modules["__main__"] = types.ModuleType("__main__")
            program = unittest.TestProgram(
                module=None,
                argv=["safe-envelope-private-namespace"],
                exit=False,
                testRunner=unittest.TextTestRunner(stream=io.StringIO(), verbosity=0),
            )
        finally:
            sys.modules["__main__"] = original_main
        self.assertEqual(program.result.testsRun, 0)

        expected = ("test_exact",)
        suite = build_explicit_safe_envelope_suite(private_case, expected)
        self.assertEqual(suite.countTestCases(), 1)
        self.assertEqual(run_explicit_safe_envelope_suite(private_case, expected, io.StringIO()).testsRun, 1)

        with self.assertRaises(RuntimeError):
            build_explicit_safe_envelope_suite(private_case, ("test_missing",))
        private_extra = type(
            "PrivateExtra",
            (unittest.TestCase,),
            {"test_exact": lambda self: None, "test_extra": lambda self: None},
        )
        with self.assertRaises(RuntimeError):
            build_explicit_safe_envelope_suite(private_extra, expected)
        with self.assertRaises(RuntimeError):
            build_explicit_safe_envelope_suite(private_case, ("test_exact", "test_exact"))

        def assert_terminal_rejection(case: type[unittest.TestCase]) -> None:
            with self.assertRaises(SystemExit) as exit_context:
                run_explicit_safe_envelope_suite(case, ("test_exact",), io.StringIO())
            self.assertEqual(exit_context.exception.code, EX_IOERR)

        skipped = type(
            "PrivateSkipped", (unittest.TestCase,),
            {"test_exact": unittest.skip("fixture skip")(lambda self: None)},
        )
        failed = type(
            "PrivateFailed", (unittest.TestCase,),
            {"test_exact": lambda self: self.fail("fixture failure")},
        )
        expected_failed = type(
            "PrivateExpectedFailure", (unittest.TestCase,),
            {"test_exact": unittest.expectedFailure(lambda self: self.fail("fixture expected failure"))},
        )
        unexpected_success = type(
            "PrivateUnexpectedSuccess", (unittest.TestCase,),
            {"test_exact": unittest.expectedFailure(lambda self: None)},
        )
        def fixture_error(self):
            raise RuntimeError("fixture error")
        errored = type("PrivateErrored", (unittest.TestCase,), {"test_exact": fixture_error})
        for case in (skipped, failed, expected_failed, unexpected_success, errored):
            assert_terminal_rejection(case)

    def test_production_cleanup_fd_plan_executes_verified_bytes_after_path_swap(self):
        """A replacement path cannot become cleanup source after descriptor planning."""
        execution = self.fixture_private_root("lidswitch-swift._")
        source = os.path.join(execution, "source"); script = os.path.join(source, "script")
        os.makedirs(script, mode=0o700)
        leaf = os.path.join(script, "safe_process_supervisor.py")
        write_private(leaf, b"verified_cleanup_marker=True\n"); os.chmod(leaf, 0o444)
        os.chmod(script, 0o555); os.chmod(source, 0o555)
        source_fd = SUPERVISOR.open_cleanup_source_root(source)
        try: seal = SUPERVISOR.cleanup_snapshot_digest(source_fd)
        finally: os.close(source_fd)
        receipt = SUPERVISOR.cleanup_script_receipt(source, seal)
        machine = SUPERVISOR.CleanupStateMachine(leader=SUPERVISOR.ProcessIdentity(4242, 100, 7), session_id=4242)
        source_descriptor, descriptor, argv = SUPERVISOR.durable_cleanup_spawn_plan(machine, cleanup_source_root=source, source_seal=seal, cleanup_script_receipt_value=receipt)
        self.assertNotIn(source, argv)
        self.assertNotIn("os.open(", SUPERVISOR.CLEANUP_BOOTSTRAP)
        os.chmod(source, 0o700); os.chmod(script, 0o700)
        os.rename(leaf, leaf + ".authentic")
        write_private(leaf + ".replacement", b"replacement_cleanup_marker=True\n")
        os.chmod(leaf + ".replacement", 0o444); os.replace(leaf + ".replacement", leaf)
        os.chmod(script, 0o555); os.chmod(source, 0o555)
        saved_argv = list(sys.argv)
        try:
            try: saved_fd = os.dup(SUPERVISOR.CLEANUP_INHERITED_FD)
            except OSError: saved_fd = None
            try: saved_root_fd = os.dup(SUPERVISOR.CLEANUP_SOURCE_ROOT_FD)
            except OSError: saved_root_fd = None
            os.dup2(descriptor, SUPERVISOR.CLEANUP_INHERITED_FD)
            os.dup2(source_descriptor, SUPERVISOR.CLEANUP_SOURCE_ROOT_FD)
            sys.argv = ["-c", str(SUPERVISOR.CLEANUP_INHERITED_FD), str(SUPERVISOR.CLEANUP_SOURCE_ROOT_FD), seal, receipt]
            namespace = {"__name__": "__bootstrap__"}
            exec(compile(SUPERVISOR.CLEANUP_BOOTSTRAP, "<production-cleanup-bootstrap>", "exec"), namespace)
            loaded = namespace["_verified_cleanup_namespace"]
            self.assertTrue(loaded["verified_cleanup_marker"])
            self.assertNotIn("replacement_cleanup_marker", loaded)
            with self.assertRaises(RuntimeError):
                SUPERVISOR.verify_cleanup_owner_snapshot(SUPERVISOR.CLEANUP_SOURCE_ROOT_FD, seal)
            order = []
            original_leaf = SUPERVISOR.verify_inherited_cleanup_script_fd
            original_snapshot = SUPERVISOR.verify_cleanup_owner_snapshot
            original_handlers = SUPERVISOR.install_interruption_handlers
            original_round = SUPERVISOR.durable_cleanup_round
            try:
                SUPERVISOR.verify_inherited_cleanup_script_fd = lambda *_: order.append("leaf")
                def reject_snapshot(*_):
                    order.append("snapshot")
                    raise RuntimeError("changed snapshot")
                SUPERVISOR.verify_cleanup_owner_snapshot = reject_snapshot
                SUPERVISOR.install_interruption_handlers = lambda: (_ for _ in ()).throw(AssertionError("handler reached"))
                SUPERVISOR.durable_cleanup_round = lambda _: (_ for _ in ()).throw(AssertionError("containment reached"))
                with self.assertRaises(RuntimeError):
                    SUPERVISOR.durable_cleanup_owner(
                        machine.leader, machine.session_id, machine.observed,
                        source_seal=seal, cleanup_script_receipt_value=receipt,
                    )
                self.assertEqual(order, ["leaf", "snapshot"])
            finally:
                SUPERVISOR.verify_inherited_cleanup_script_fd = original_leaf
                SUPERVISOR.verify_cleanup_owner_snapshot = original_snapshot
                SUPERVISOR.install_interruption_handlers = original_handlers
                SUPERVISOR.durable_cleanup_round = original_round
        finally:
            sys.argv = saved_argv
            if saved_fd is None: os.close(SUPERVISOR.CLEANUP_INHERITED_FD)
            else:
                os.dup2(saved_fd, SUPERVISOR.CLEANUP_INHERITED_FD); os.close(saved_fd)
            if saved_root_fd is None: os.close(SUPERVISOR.CLEANUP_SOURCE_ROOT_FD)
            else:
                os.dup2(saved_root_fd, SUPERVISOR.CLEANUP_SOURCE_ROOT_FD); os.close(saved_root_fd)
            os.close(source_descriptor)
            if descriptor != SUPERVISOR.CLEANUP_INHERITED_FD: os.close(descriptor)

    def test_production_parser_corpus_counter_and_swift_order_statistics(self):
        records = self.canonical_records()
        FILES.validate_benchmark_jsonl(self.payload(records), self.args())
        for mutate in (lambda r: r.__setitem__(0, r[1]), lambda r: r.pop(4), lambda r: r.__setitem__(4, {**r[4], "sample_index": 2}), lambda r: r.__setitem__(4, {**r[4], "fixture_root": "/private/tmp/other/fixtures/lidswitch-benchmark-fixture-x"}), lambda r: r.__setitem__(-1, {**r[-1], "p95_nanoseconds": 0})):
            candidate = copy.deepcopy(records); mutate(candidate)
            with self.assertRaises(SystemExit): FILES.validate_benchmark_jsonl(self.payload(candidate), self.args())
        empty_counter_contracts = []
        for index, record in enumerate(records):
            if record["record_type"] == "sample":
                required, positive, _ = FILES.BENCHMARK_COUNTER_CONTRACTS[record["scenario"]]
                if required or positive:
                    candidate = copy.deepcopy(records); candidate[index]["counters"] = {}
                    with self.assertRaises(SystemExit): FILES.validate_benchmark_jsonl(self.payload(candidate), self.args())
                else:
                    empty_counter_contracts.append(record["scenario"])
                    self.assertEqual(record["counters"], {})
        self.assertTrue(empty_counter_contracts)
        FILES.validate_benchmark_jsonl(self.payload(records), self.args())
        values = [1, 9007199254740991, 1, 1, 1]
        sorted_values = sorted(float(value) for value in values)
        swift_mean = sum(sorted_values) / len(sorted_values)
        swift_deviation = math.sqrt(sum(math.pow(value - swift_mean, 2) for value in sorted_values) / (len(sorted_values) - 1))
        unsorted_mean = sum(float(value) for value in values) / len(values)
        unsorted_deviation = math.sqrt(sum(math.pow(float(value) - unsorted_mean, 2) for value in values) / (len(values) - 1))
        self.assertEqual(FILES.benchmark_standard_deviation(values), swift_deviation)
        self.assertNotEqual(unsorted_deviation, swift_deviation)

    def artifact_fixture(self):
        artifact_root = self.fixture_private_root("lidswitch-artifact-")
        app = os.path.join(artifact_root, "Candidate.app"); contents = os.path.join(app, "Contents")
        launch = os.path.join(contents, "Library", "LaunchServices")
        installed = os.path.join(self.work, "installed-" + uuid.uuid4().hex); os.mkdir(installed, 0o700)
        os.makedirs(launch, mode=0o700)
        identity_root = self.fixture_private_root("lidswitch-source-")
        resources = os.path.join(identity_root, "source", "Resources"); os.makedirs(resources, mode=0o700)
        release = {"appBundleIdentifier": "com.example.LidSwitch", "appVersion": "1.0", "appBuild": "1"}
        with open(os.path.join(contents, "Info.plist"), "wb") as handle: plistlib.dump({"CFBundleIdentifier": "com.example.LidSwitch", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"}, handle)
        for directory in (app, contents, os.path.join(contents, "Library"), launch, installed): os.chmod(directory, 0o700)
        helper = b"bounded helper bytes\n"
        for path in (os.path.join(launch, "LidSwitchHelper"), os.path.join(installed, "LidSwitchHelper"), os.path.join(resources, "LidSwitchReleaseIdentity.json")):
            payload = json.dumps(release, sort_keys=True).encode() if path.endswith(".json") else helper
            with open(path, "wb") as handle: handle.write(payload)
            os.chmod(path, 0o444)
        # Fixture content is complete before the identity tree becomes read-only;
        # reversing these lines deterministically denies the JSON creation.
        os.chmod(resources, 0o555); os.chmod(os.path.join(identity_root, "source"), 0o555)
        return artifact_root, argparse.Namespace(source_root=identity_root, source_identity=root_identity(identity_root), benchmark_app=app, benchmark_helper=os.path.join(installed, "LidSwitchHelper"), fixture_helper_payload=helper)

    def fixture_artifact_truth(self, args, *, codesign_runner, fixture_helper_payload=None):
        return FILES.host_artifact_truth(
            args,
            codesign_runner=codesign_runner,
            fixture_owners={os.getuid()},
            fixture_helper_payload=(args.fixture_helper_payload if fixture_helper_payload is None else fixture_helper_payload),
        )

    def test_production_artifact_capabilities_reject_tree_swaps_and_false_rows(self):
        self.assertEqual(FILES.installed_helper_directory_groups("/Library"), {0, os.getgid()})
        self.assertEqual(FILES.installed_helper_directory_groups("/Library/Application Support"), {0, os.getgid(), 80})
        self.assertEqual(FILES.installed_helper_directory_groups("/Library/Application Support/LidSwitch"), {0, os.getgid()})
        artifact_root, args = self.artifact_fixture()
        with self.assertRaises(SystemExit):
            FILES.InstalledHelperCapability(args.benchmark_helper, {os.getuid()})
        with self.assertRaises(SystemExit):
            FILES.host_artifact_truth(args, codesign_runner=lambda _, __: 0,
                                      fixture_helper_payload=args.fixture_helper_payload)
        truth = self.fixture_artifact_truth(args, codesign_runner=lambda _, __: 0)
        self.assertEqual(truth, {"bundle_integrity_valid": True, "bundle_version_valid": True, "codesign_exit_code": 0, "helper_bytes_match": True})
        mismatch = self.fixture_artifact_truth(args, codesign_runner=lambda _, __: 0,
                                               fixture_helper_payload=b"different fixture helper\n")
        self.assertFalse(mismatch["helper_bytes_match"])
        bundle = {"scenario": "artifact.app-bundle.validation", "counters": {"child_process": 1}, **{key: truth[key] for key in ("bundle_integrity_valid", "bundle_version_valid", "codesign_exit_code")}}
        helper = {"scenario": "artifact.helper-byte-comparison", "counters": {"file_read": 2, "helper_byte_comparison": 1}, "helper_bytes_match": True}
        FILES.validate_artifact_sample(bundle, truth); FILES.validate_artifact_sample(helper, truth)
        for row in ({**bundle, "codesign_exit_code": 1}, {**bundle, "bundle_integrity_valid": False}, {**helper, "helper_bytes_match": False}, {**helper, "counters": {"file_read": 2}}):
            with self.assertRaises(SystemExit): FILES.validate_artifact_sample(row, truth)
        def swap(_, reassert):
            replacement = args.benchmark_app + ".replacement"
            displaced = args.benchmark_app + ".displaced"
            shutil.copytree(args.benchmark_app, replacement)
            os.rename(args.benchmark_app, displaced)
            os.rename(replacement, args.benchmark_app)
            try:
                reassert()
            finally:
                os.rename(args.benchmark_app, replacement)
                os.rename(displaced, args.benchmark_app)
                shutil.rmtree(replacement)
            return 0
        with self.assertRaises(SystemExit): self.fixture_artifact_truth(args, codesign_runner=swap)
        artifact_root, args = self.artifact_fixture()
        def ancestor_symlink(_, reassert):
            parked = artifact_root + ".parked"
            os.rename(artifact_root, parked)
            os.symlink(parked, artifact_root)
            try:
                reassert()
            finally:
                os.unlink(artifact_root); os.rename(parked, artifact_root)
            return 0
        with self.assertRaises(SystemExit): self.fixture_artifact_truth(args, codesign_runner=ancestor_symlink)
        artifact_root, args = self.artifact_fixture()
        def replace_info(_, reassert):
            info = os.path.join(args.benchmark_app, "Contents", "Info.plist")
            write_private(info + ".new", b"replacement plist\n"); os.replace(info + ".new", info)
            reassert()
            return 0
        with self.assertRaises(SystemExit): self.fixture_artifact_truth(args, codesign_runner=replace_info)
        artifact_root, args = self.artifact_fixture()
        def link_helper(_, reassert):
            helper_path = os.path.join(args.benchmark_app, "Contents", "Library", "LaunchServices", "LidSwitchHelper")
            os.link(helper_path, helper_path + ".link")
            reassert()
            return 0
        with self.assertRaises(SystemExit): self.fixture_artifact_truth(args, codesign_runner=link_helper)
        artifact_root, args = self.artifact_fixture()
        def mode_drift(_, reassert):
            os.chmod(os.path.join(args.benchmark_app, "Contents", "Library", "LaunchServices", "LidSwitchHelper"), 0o644)
            reassert()
            return 0
        with self.assertRaises(SystemExit): self.fixture_artifact_truth(args, codesign_runner=mode_drift)

    def test_benchmark_app_intake_uses_the_production_private_tmp_capability(self):
        artifact_root, args = self.artifact_fixture()
        capability = FILES.ArtifactTreeCapability(args.benchmark_app, {0, os.getuid()})
        capability.close()
        for path in (
            "/tmp/lidswitch-artifact/Candidate.app",
            "/private/tmp/not-a-private-benchmark-root/Candidate.app",
            "/Applications/LidSwitch.app",
            os.path.join(artifact_root, "nested", "Candidate.app"),
            "/private/tmp/unsafe component/Candidate.app",
        ):
            with self.assertRaises(SystemExit): FILES.ArtifactTreeCapability(path, {0, os.getuid()})
        os.chmod(artifact_root, 0o755)
        try:
            with self.assertRaises(SystemExit): FILES.ArtifactTreeCapability(args.benchmark_app, {0, os.getuid()})
        finally:
            os.chmod(artifact_root, 0o700)
        linked_root = "/private/tmp/lidswitch-artifact-link-" + uuid.uuid4().hex
        os.symlink(artifact_root, linked_root)
        self.addCleanup(os.unlink, linked_root)
        with self.assertRaises(SystemExit): FILES.ArtifactTreeCapability(linked_root + "/Candidate.app", {0, os.getuid()})

    def test_benchmark_private_tmp_name_boundaries_and_public_intake_are_exact(self):
        """Exercise the production capability parser at its 96-byte boundary."""
        identity = root_identity(self.work)
        destination_fd, destination_name = FILES.open_private_destination(
            os.path.join(self.work, "n" * 96), identity
        )
        self.assertEqual(destination_name, "n" * 96)
        os.close(destination_fd)
        for name in ("n" * 97, "unsafe name"):
            with self.assertRaises(SystemExit):
                FILES.open_private_destination(os.path.join(self.work, name), identity)

        artifact_root, args = self.artifact_fixture()
        boundary_app = os.path.join(artifact_root, "a" * 92 + ".app")
        os.rename(args.benchmark_app, boundary_app)
        args.benchmark_app = boundary_app
        capability = FILES.ArtifactTreeCapability(boundary_app, {0, os.getuid()})
        capability.close()
        with self.assertRaises(SystemExit):
            FILES.ArtifactTreeCapability(os.path.join(artifact_root, "a" * 93 + ".app"), {0, os.getuid()})

        alternate_gid = next((gid for gid in os.getgroups() if gid != os.getgid()), None)
        if alternate_gid is not None:
            try:
                os.chown(artifact_root, os.getuid(), alternate_gid)
            except PermissionError:
                pass  # The fixture is still valid where the account has one group.
            else:
                try:
                    with self.assertRaises(SystemExit): FILES.ArtifactTreeCapability(boundary_app, {0, os.getuid()})
                finally:
                    os.chown(artifact_root, os.getuid(), os.getgid())

        common = verified_static_text("script/swift_sandbox_common.sh")
        baseline = verified_static_text("script/benchmark_baseline.sh")
        test_wrapper = verified_static_text("script/run_swift_tests_safely.sh")
        validation = verified_static_text("docs/VALIDATION.md")
        for source, samples in ((common, '"$samples" -le 100'), (baseline, '"$SAMPLES" -le 100')):
            self.assertIn(samples, source)
            self.assertIn("[A-Za-z0-9._-]{0,91}\\.app", source)
            self.assertIn("[A-Za-z0-9._-]{0,95}", source)
            self.assertIn("%u:%g:%p", source)
            self.assertIn("/usr/bin/id -g", source)
            self.assertIn("0:0:41777", source)
        self.assertIn("$parent_name", common)
        self.assertIn("$PARENT_NAME", baseline)
        self.assertNotIn("run_swift_tests_safely.sh", baseline)
        self.assertIn("manager-held benchmark required", baseline)
        for marker in ("--benchmark-output", "--benchmark-app-bundle", "--benchmark-samples"):
            self.assertIn(marker, test_wrapper)
        self.assertIn("partial benchmark request is forbidden", test_wrapper)
        self.assertIn("benchmark request requires the exact benchmark test", test_wrapper)
        self.assertIn('LIDSWITCH_BENCHMARK_OUTPUT="$LIDSWITCH_SWIFT_BENCHMARK_OUTPUT"', common)
        self.assertIn('LIDSWITCH_BENCHMARK_APP_BUNDLE="$LIDSWITCH_SWIFT_BENCHMARK_APP"', common)
        self.assertIn("1...96 bytes", validation)
        self.assertIn("5` through\n`100`", validation)

    def test_trusted_isolated_python_gate_source_contract(self):
        """Startup isolation is an invocation property, not a post-start claim."""
        canonical_gate = "/usr/bin/python3 -I -S -B -c"
        validation = verified_static_text("docs/VALIDATION.md")
        self.assertIn(canonical_gate, validation)
        self.assertIn("os.open(p,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC)", validation)
        self.assertIn("data=bytearray()", validation)
        self.assertIn("except InterruptedError:", validation)
        self.assertIn("if retries>16: raise SystemExit(74)", validation)
        self.assertIn("if not chunk: raise SystemExit(74)", validation)
        self.assertIn("owned,fd=fd,-1", validation)
        self.assertIn("except BaseException: raise SystemExit(74)", validation)
        self.assertIn('code=compile(data,"<verified-test-safe-envelope>","exec")', validation)
        self.assertIn("try: sys.argv=[p]+sys.argv[3:]; exec(code", validation)
        self.assertIn("and sys.exc_info()[1].code==74", validation)
        self.assertEqual(
            self._documented_bootstrap_audit_body().encode("utf-8"),
            CANONICAL_ISOLATED_BOOTSTRAP.encode("utf-8"),
        )
        expected_self_digest = globals().get("__lidswitch_envelope_selftest_sha256__")
        self.assertIsInstance(expected_self_digest, str)
        self.assertRegex(expected_self_digest, r"^[0-9a-f]{64}$")
        self.assertIn(f"script/test_safe_envelope.py {expected_self_digest}", validation)
        self.assertIn("Property-to-proof coverage", validation)
        self.assertIn("An authentic gate run prints each of those 16 test names", validation)
        for method in EXPECTED_TEST_METHODS:
            self.assertIn(method, validation)
        self.assertIn("does **not** dynamically prove Swift, real Darwin process", validation)
        self.assertIn("intentionally excludes\n`native.power-inspector`", validation)
        self.assertNotRegex(validation, r"(?m)^\s*(?:python3|/usr/bin/env\s+python3?)\s+script/test_safe_envelope\.py\s*$")
        sources = [
            "script/live_state_envelope.sh", "script/swift_sandbox_common.sh",
            "script/run_swift_tests_safely.sh", "script/run_swift_build_safely.sh",
            "script/benchmark_baseline.sh",
        ]
        for source in sources:
            for line in verified_static_text(source).splitlines():
                if "python3" not in line:
                    continue
                self.assertIn("/usr/bin/python3 -I -S", line, f"untrusted Python invocation in {source}: {line}")
                self.assertNotIn("/usr/bin/env python", line)
        common = verified_static_text("script/swift_sandbox_common.sh")
        envelope = verified_static_text("script/live_state_envelope.sh")
        self.assertIn("swift_sandbox_verified_python", common)
        self.assertIn("SWIFT_SANDBOX_VERIFIED_HELPER_BOOTSTRAP", common)
        self.assertNotIn('/usr/bin/python3 -I -S "$ROOT_DIR/script/', common)
        self.assertNotIn('/usr/bin/python3 -I -S "$ROOT_DIR/script/', envelope)
        self.assertIn("not source-credible for\nexecution authorization", validation)
        for source in (FILES.__verified_source_bytes__, SUPERVISOR.__verified_source_bytes__):
            self.assertEqual(source.splitlines()[0], b"#!/usr/bin/python3")
        supervisor = SUPERVISOR.__verified_source_bytes__.decode("utf-8")
        self.assertIn("os.posix_spawn", supervisor)
        self.assertIn('"/usr/bin/python3", "-I", "-S", "-B", "-c", CLEANUP_BOOTSTRAP', supervisor)
        self.assertIn("os.POSIX_SPAWN_DUP2", supervisor)
        self.assertIn("CLEANUP_INHERITED_FD", supervisor)
        self.assertIn("CLEANUP_SOURCE_ROOT_FD", supervisor)
        self.assertIn("data=bytearray()", supervisor)
        self.assertIn("except InterruptedError: continue", supervisor)
        self.assertIn("if not chunk: raise SystemExit(74)", supervisor)
        self.assertIn("STARTUP_GATE_BOOTSTRAP", supervisor)
        self.assertIn("release_startup_gate", supervisor)
        self.assertIn("reap_blocked_startup_gate", supervisor)
        self.assertTrue(sys.dont_write_bytecode)
        self.assertIn("verified_dependency_bytes", globals())
        self.assertIn("verified_static_data_bytes", globals())
        self.assertEqual(EX_IOERR, 74)
        self.assertIn("_read_descriptor_payload", globals())
        self.assertIn("_terminal_descriptor_failure", globals())

    def test_selected_clt_capability_contract_rejects_inherited_or_alternate_roots(self):
        """Release builds use sealed CLT; tests use sealed local Xcode XCTest."""
        common = verified_static_text("script/swift_sandbox_common.sh")
        profile = verified_static_text("script/swift_test_sandbox.sb.in")
        test_wrapper = verified_static_text("script/run_swift_tests_safely.sh")
        build_wrapper = verified_static_text("script/run_swift_build_safely.sh")
        self.assertIn('swift_sandbox_reject_inherited_paths', common)
        self.assertIn('swift_sandbox_capture_developer_toolchain', common)
        self.assertIn('swift_sandbox_assert_developer_toolchain', common)
        self.assertIn('swift_sandbox_capture_xcode_test_toolchain', common)
        self.assertIn('swift_sandbox_assert_xcode_test_toolchain', common)
        self.assertIn('LIDSWITCH_SWIFT_DEVELOPER_SEAL', common)
        self.assertIn('LIDSWITCH_SWIFT_CLT_ROOT=/Library/Developer/CommandLineTools', common)
        self.assertIn('LIDSWITCH_SWIFT_XCODE_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer', common)
        self.assertIn('LIDSWITCH_SWIFT_XCODE_TOOLCHAIN_ROOT="$LIDSWITCH_SWIFT_XCODE_DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain"', common)
        self.assertIn('LIDSWITCH_SWIFT_XCODE_PLATFORM_DEVELOPER="$LIDSWITCH_SWIFT_XCODE_DEVELOPER_DIR/Platforms/MacOSX.platform/Developer"', common)
        self.assertIn('LIDSWITCH_SWIFT_XCODE_SHARED_FRAMEWORKS=/Applications/Xcode.app/Contents/SharedFrameworks', common)
        self.assertIn('LIDSWITCH_SWIFT_XCODE_PLATFORM_FRAMEWORKS="$LIDSWITCH_SWIFT_XCODE_PLATFORM_DEVELOPER/Library/Frameworks"', common)
        self.assertIn('LIDSWITCH_SWIFT_XCODE_PLATFORM_PRIVATE_FRAMEWORKS="$LIDSWITCH_SWIFT_XCODE_PLATFORM_DEVELOPER/Library/PrivateFrameworks"', common)
        self.assertIn('LIDSWITCH_SWIFT_XCODE_PLATFORM_USR_LIB="$LIDSWITCH_SWIFT_XCODE_PLATFORM_DEVELOPER/usr/lib"', common)
        self.assertIn('LIDSWITCH_SWIFT_XCODE_LIBXCRUN="$LIDSWITCH_SWIFT_XCODE_DEVELOPER_DIR/usr/lib/libxcrun.dylib"', common)
        self.assertIn('LIDSWITCH_SWIFT_XCODE_SWIFT_PLUGIN_SERVER="$LIDSWITCH_SWIFT_XCODE_PLATFORM_DEVELOPER/usr/bin/swift-plugin-server"', common)
        self.assertIn('swift_sandbox_resolve_clt_path', common)
        self.assertIn('swift_sandbox_resolve_xcode_path', common)
        self.assertIn('/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C DEVELOPER_DIR="$LIDSWITCH_SWIFT_CLT_ROOT" /usr/bin/xcrun --sdk macosx --show-sdk-path', common)
        self.assertIn('/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C DEVELOPER_DIR="$LIDSWITCH_SWIFT_XCODE_DEVELOPER_DIR" /usr/bin/xcrun --sdk macosx --show-sdk-path', common)
        self.assertIn('DEVELOPER_DIR="$selected_developer"', common)
        self.assertIn('SDKROOT="$selected_sdk"', common)
        self.assertIn('SWIFTPM_PLATFORM_PATH_macosx="${LIDSWITCH_SWIFT_XCODE_PLATFORM_DEVELOPER%/Developer}"', common)
        self.assertIn('SWIFTPM_SECURITY_PATH SWIFTPM_PLATFORM_PATH_macosx SWIFT_TESTING_ENABLED', common)
        self.assertIn('PATH="$selected_path"', common)
        self.assertNotIn('xcode-select', common)
        self.assertNotIn('xcodebuild', common)
        self.assertIn('--build-tests', test_wrapper)
        self.assertIn('swift_sandbox_run test-build build test-build', test_wrapper)
        self.assertIn('swift_sandbox_run_xctest test-main "$selector"', test_wrapper)
        self.assertIn('LIDSWITCH_SWIFT_EXEC_ID="$LIDSWITCH_SWIFT_EXEC_ID"', common)
        self.assertIn('capture_names=(test-build)', test_wrapper)
        self.assertIn('capture_names+=(test-main)', test_wrapper)
        self.assertIn('swift_sandbox_reassert_before_sensitive_host_action "${capture_names[@]}"', test_wrapper)
        self.assertNotIn('swift_sandbox_run test-main test ordinary', test_wrapper)
        self.assertIn('--enable-xctest \\\n  --disable-swift-testing', test_wrapper)
        self.assertIn('-Xswiftc -F \\\n  -Xswiftc "$LIDSWITCH_SWIFT_XCODE_PLATFORM_FRAMEWORKS"', test_wrapper)
        self.assertIn('-Xswiftc -I \\\n  -Xswiftc "$LIDSWITCH_SWIFT_XCODE_PLATFORM_USR_LIB"', test_wrapper)
        self.assertIn('-Xswiftc -L \\\n  -Xswiftc "$LIDSWITCH_SWIFT_XCODE_PLATFORM_USR_LIB"', test_wrapper)
        self.assertIn('-Xcc -F \\\n  -Xcc "$LIDSWITCH_SWIFT_XCODE_PLATFORM_FRAMEWORKS"', test_wrapper)
        self.assertNotIn('(deny file-rename)', profile)
        self.assertNotIn('@XCODEBUILD_TOOL@', profile)
        for placeholder in (
            '@CLT_ROOT@', '@SDKROOT@', '@SWIFT_TOOL@', '@SWIFTC_TOOL@',
            '@SWIFT_FRONTEND_TOOL@', '@CLANG_TOOL@', '@CLANGXX_TOOL@',
            '@LD_TOOL@', '@DSYMUTIL_TOOL@', '@XCODE_DEVELOPER@',
            '@XCODE_TOOLCHAIN@', '@XCODE_SHARED_FRAMEWORKS@',
            '@XCODE_PLATFORM_FRAMEWORKS@',
            '@XCODE_PLATFORM_PRIVATE_FRAMEWORKS@', '@XCODE_PLATFORM_USR_LIB@',
            '@XCODE_LIBXCRUN@', '@XCODE_LIBTOOL_TOOL@',
            '@XCODE_SWIFT_PLUGIN_SERVER@',
            '@XCODE_SDKROOT@', '@XCODE_SWIFT_TOOL@',
            '@XCODE_SWIFTC_TOOL@', '@XCODE_SWIFT_FRONTEND_TOOL@',
            '@XCODE_CLANG_TOOL@', '@XCODE_CLANGXX_TOOL@', '@XCODE_LD_TOOL@',
            '@XCODE_DSYMUTIL_TOOL@', '@XCODE_XCTEST_TOOL@',
            '@XCODE_XCTEST_FRAMEWORK@', '@XCODE_XCTEST_MODULE@',
            '@XCODE_XCTEST_SUPPORT@',
        ):
            self.assertIn(placeholder, profile)
        self.assertIn('(allow file-read-data (literal "/"))', profile)
        self.assertIn('(allow file-read-metadata (literal "/"))', profile)
        self.assertIn('(allow file-read-metadata (literal "/usr"))', profile)
        self.assertIn('(allow file-read-metadata (literal "/private"))', profile)
        self.assertIn('(allow file-read-metadata (literal "/private/tmp"))', profile)
        self.assertIn('(allow file-read-metadata (literal "@BENCHMARK_PARENT@"))', profile)
        self.assertIn('(allow file-read-metadata (literal "/Library"))', profile)
        self.assertIn('(allow file-read-metadata (literal "/Library/Developer"))', profile)
        self.assertIn('(allow file-read-metadata (literal "@CLT_ROOT@"))', profile)
        self.assertIn('(allow file-read-metadata (literal "/Applications"))', profile)
        self.assertIn('(allow file-read-metadata (literal "/Applications/Xcode.app"))', profile)
        self.assertIn('(allow file-read-metadata (literal "@XCODE_DEVELOPER@"))', profile)
        self.assertIn('(allow file-read-metadata (subpath "@XCODE_DEVELOPER@"))', profile)
        self.assertIn('(allow file-read* (literal "@XCODE_TOOLCHAIN@"))', profile)
        self.assertIn('(allow file-read-metadata (literal "@XCODE_SHARED_FRAMEWORKS@"))', profile)
        self.assertIn('(allow file-read* (subpath "@XCODE_SHARED_FRAMEWORKS@"))', profile)
        self.assertIn('(allow file-read* (subpath "@XCODE_PLATFORM_FRAMEWORKS@"))', profile)
        self.assertIn('(allow file-read* (subpath "@XCODE_PLATFORM_PRIVATE_FRAMEWORKS@"))', profile)
        self.assertIn('(allow file-read* (subpath "@XCODE_PLATFORM_USR_LIB@"))', profile)
        self.assertIn('(allow file-read* (literal "@XCODE_LIBXCRUN@"))', profile)
        self.assertIn('(allow file-read* (literal "@XCODE_SWIFT_PLUGIN_SERVER@"))', profile)
        self.assertIn('(allow file-read* (subpath "/Library/Apple/System/Library"))', profile)
        self.assertIn('(allow file-read* (subpath "@XCODE_TOOLCHAIN@"))', profile)
        self.assertIn('(allow file-read* (subpath "@XCODE_SDKROOT@"))', profile)
        self.assertIn('(allow file-read* (subpath "@XCODE_XCTEST_FRAMEWORK@"))', profile)
        self.assertIn('(allow file-read* (subpath "@XCODE_XCTEST_MODULE@"))', profile)
        self.assertIn('(allow file-read* (literal "@XCODE_XCTEST_SUPPORT@"))', profile)
        self.assertIn('(allow file-read* (literal "@EXEC_ROOT@"))', profile)
        self.assertIn('(allow file-read* (subpath "@EXEC_ROOT@"))', profile)
        self.assertIn('(allow sysctl-read)', profile)
        self.assertIn('(allow process-exec (literal "@CLT_ROOT@/usr/bin/swift-test"))', profile)
        self.assertIn('(allow process-exec (literal "@CLT_ROOT@/usr/bin/swift-build"))', profile)
        self.assertIn('(allow process-exec (literal "@CLT_ROOT@/usr/bin/swift-package"))', profile)
        self.assertIn('(allow process-exec (literal "@CLT_ROOT@/usr/bin/swift-driver"))', profile)
        self.assertIn('(allow process-exec (literal "@CLT_ROOT@/usr/bin/swiftc"))', profile)
        self.assertIn('(allow process-exec (literal "@CLT_ROOT@/usr/bin/clang++"))', profile)
        self.assertIn('(allow process-exec (literal "@DSYMUTIL_TOOL@"))', profile)
        self.assertIn('(allow process-exec (literal "@XCODE_SWIFT_TOOL@"))', profile)
        self.assertIn('(allow process-exec (literal "@XCODE_SWIFTC_TOOL@"))', profile)
        self.assertIn('(allow process-exec (literal "@XCODE_SWIFT_FRONTEND_TOOL@"))', profile)
        self.assertIn('(allow process-exec (literal "@XCODE_CLANG_TOOL@"))', profile)
        self.assertIn('(allow process-exec (literal "@XCODE_CLANGXX_TOOL@"))', profile)
        self.assertIn('(allow process-exec (literal "@XCODE_LD_TOOL@"))', profile)
        self.assertIn('(allow process-exec (literal "@XCODE_DSYMUTIL_TOOL@"))', profile)
        self.assertIn('(allow process-exec (literal "@XCODE_LIBTOOL_TOOL@"))', profile)
        self.assertIn('(allow process-exec (literal "@XCODE_SWIFT_PLUGIN_SERVER@"))', profile)
        self.assertIn('(allow process-exec (literal "@XCODE_XCTEST_TOOL@"))', profile)
        self.assertIn('(allow process-exec (literal "/usr/bin/codesign"))', profile)
        self.assertIn('(allow mach-lookup (global-name "com.apple.diagnosticd"))', profile)
        self.assertIn('swift_subcommand" --disable-sandbox --package-path', common)
        self.assertIn('/usr/bin/arch -arm64 "$selected_swift" "$swift_subcommand"', common)
        self.assertNotIn('/usr/bin/arch -arm64 /usr/bin/swift', common)
        self.assertIn('/Library /Library/Developer "$LIDSWITCH_SWIFT_CLT_ROOT"', common)
        self.assertIn('"$LIDSWITCH_SWIFT_CLT_ROOT/usr/bin/$tool"', common)
        self.assertIn('"$LIDSWITCH_SWIFT_CLT_ROOT/SDKs"', common)
        self.assertIn('"$LIDSWITCH_SWIFT_CLT_ROOT/SDKs" && "$sdk" == *.sdk', common)
        self.assertIn('swift_sandbox_resolve_clt_path "$LIDSWITCH_SWIFT_CLT_ROOT/usr/bin/$tool" file', common)
        self.assertIn('for tool in swiftc swift-frontend clang clang++ ld dsymutil; do', common)
        self.assertIn('LIDSWITCH_SWIFT_TOOL_dsymutil', common)
        self.assertIn('swift_sandbox_resolve_clt_path "$sdk" directory', common)
        self.assertIn('[[ "$expected_kind" == file || "$expected_kind" == directory ]]', common)
        self.assertIn('swift_sandbox_clt_driver_identity', common)
        self.assertIn('[[ "$target" == swift-frontend ]]', common)
        self.assertIn('LIDSWITCH_SWIFT_TOOL_swift="$driver"', common)
        self.assertIn('[A-Za-z0-9_]{6,32}', common)
        self.assertNotIn('lidswitch-swift\\.[A-Za-z0-9]{6}', common)
        # The source binds Library, Developer, CLT, exact tools and the xcrun
        # SDK result, so writable/symlink/foreign-owned substitutions cannot
        # survive capture then reassertion as the selected capability.
        self.assertIn('! -L "$path"', common)
        self.assertIn(':0:0:', common)
        self.assertIn('8#022', common)
        self.assertIn('"$LIDSWITCH_SWIFT_DEVELOPER_DIR" == "$LIDSWITCH_SWIFT_CLT_ROOT"', common)
        self.assertIn('[[ "$execution_mode" == test-build || "$execution_mode" == release-helper || "$execution_mode" == release-app ]]', common)
        self.assertNotIn('test:ordinary', common)
        self.assertIn('selected_path="$LIDSWITCH_SWIFT_XCODE_TOOLCHAIN_ROOT/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin"', common)
        self.assertIn('selected_developer="$LIDSWITCH_SWIFT_XCODE_DEVELOPER_DIR"', common)
        self.assertIn('selected_sdk="$LIDSWITCH_SWIFT_XCODE_SDKROOT"', common)
        self.assertIn('selected_swift="$LIDSWITCH_SWIFT_XCODE_TOOL_swift"', common)
        self.assertIn('selected_path="$LIDSWITCH_SWIFT_CLT_ROOT/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin"', common)
        self.assertIn('selected_developer="$LIDSWITCH_SWIFT_DEVELOPER_DIR"', common)
        self.assertIn('selected_sdk="$LIDSWITCH_SWIFT_SDKROOT"', common)
        self.assertIn('selected_swift="$LIDSWITCH_SWIFT_TOOL_swift"', common)
        self.assertIn('LIDSWITCH_SWIFT_XCODE_TOOL_xctest="$xctest"', common)
        self.assertIn('[[ "$xctest" == "$LIDSWITCH_SWIFT_XCODE_PLATFORM_DEVELOPER/Library/Xcode/Agents/xctest" ]]', common)
        self.assertIn('LidSwitchPackageTests.xctest', common)
        self.assertIn('command=(/usr/bin/arch -arm64 "$LIDSWITCH_SWIFT_XCODE_TOOL_xctest")', common)
        self.assertIn('command+=(-XCTest "$selector")', common)
        self.assertIn('LIDSWITCH_RELEASE_CANDIDATE=1', common)
        self.assertIn('swift_sandbox_setup "$ROOT_DIR" release', build_wrapper)
        self.assertIn('swift_sandbox_run helper-build build release-helper', build_wrapper)
        self.assertIn('swift_sandbox_run app-build build release-app', build_wrapper)
        self.assertIn('--identifier com.johnsilva.lidswitch.helper --timestamp=none', common)
        self.assertIn('release-derive-source', common)
        self.assertIn('release-publish', common)
        self.assertIn('(deny file-write* (subpath "@HELPER_SOURCE_ROOT@"))', profile)
        self.assertIn('(deny file-write* (subpath "@APP_SOURCE_ROOT@"))', profile)
        self.assertNotIn('Developer ID', build_wrapper + common)
        self.assertNotIn('notarytool', build_wrapper + common)
        self.assertIn('/usr/bin/arch -arm64 "$selected_swift" "$swift_subcommand"', common)
        self.assertNotIn('/usr/bin/arch -arm64 /usr/bin/swift', common)

    def test_receipt_status_matrix_and_terminal_call_ordering(self):
        envelope = verified_static_text("script/live_state_envelope.sh")
        validation = verified_static_text("docs/VALIDATION.md")
        safe_file = FILES.__verified_source_bytes__.decode("utf-8")
        self.assertIn('body == "state = running" || body == "state = not running"', envelope)
        self.assertNotIn('body ~ /^state = [a-z-]+$/', envelope)
        self.assertIn('print (signature == "" ? "none" : signature)', envelope)
        self.assertNotIn('print signature == "" ? "none" : signature', envelope)
        self.assertNotRegex(envelope, r'print\s+(?:signature|count|found)\b')
        projection_signature = "boot_id,projection_authority,projection_generation,projection_token,updated_monotonic"
        self.assertIn(f'"$LIVE_STATUS_EVIDENCE_SIGNATURE" == "{projection_signature}"', envelope)
        candidate_projection_branches = (
            ("true:active:uuid)", "false:active:uuid)"),
            ("true:inactive:none)", "true:terminal:uuid)"),
            ("true:terminal:uuid)", "true:recovery-required:none)"),
            ("true:recovery-required:none)", "true:recovery-required:uuid)"),
            ("true:recovery-required:uuid)", "false:inactive:none|false:inactive:uuid)"),
        )
        for start, end in candidate_projection_branches:
            branch = envelope[envelope.index(start) : envelope.index(end)]
            self.assertIn(f'"$LIVE_STATUS_EVIDENCE_SIGNATURE" == "{projection_signature}"', branch)
        for key in ("projection_authority", "projection_generation", "projection_token"):
            self.assertIn(f'key != "{key}"', envelope)
            self.assertIn(f'live_envelope_kv_optional {key}', envelope)
        self.assertIn('[[ "$projection_authority" =~ ^[0-9a-f]{16}$ ]]', envelope)
        self.assertIn('live_envelope_canonical_uint "$projection_generation"', envelope)
        self.assertIn('live_envelope_canonical_uuid "$projection_token"', envelope)
        self.assertIn('--allow-root-nlink-growth', envelope)
        self.assertIn('write.add_argument("--allow-root-nlink-growth", action="store_true")', safe_file)
        self.assertEqual(safe_file.count('allow_nlink_growth=args.allow_root_nlink_growth'), 2)
        self.assertIn('live_envelope_capture_legacy_lease', envelope)
        self.assertIn('"${phase}.expired" "$real_home" none expired', envelope)
        self.assertIn('"$LIVE_LEASE_EXPIRES" -le "$now"', envelope)
        self.assertIn('expires <= current', envelope)
        self.assertIn('[[ "$LIVE_PLIST_CONTRACT" == "legacy-watchpaths"', envelope)
        self.assertIn('live_envelope_legacy_idle_status_is_not_future', envelope)
        self.assertIn('live_envelope_durable_terminal_status_is_not_future', envelope)
        terminal_reasons = envelope[
            envelope.index('LIDSWITCH_CANDIDATE_TERMINAL_SESSION_REASONS=') :
            envelope.index('LIDSWITCH_CANDIDATE_RECOVERY_SESSION_REASONS=')
        ]
        self.assertIn(' peer-restore ', terminal_reasons)
        self.assertNotIn(' peer-process-invalid-peer-restore ', terminal_reasons)
        durable_terminal = envelope[
            envelope.index('live_envelope_durable_terminal_status_is_not_future()') :
            envelope.index('live_envelope_override_evidence_is_exact()')
        ]
        self.assertIn('"$LIVE_STATUS_SCHEMA" == "canonical-v2"', durable_terminal)
        self.assertIn('"$LIVE_STATUS_BOOT_ID" == "$LIVE_KERNEL_BOOT"', durable_terminal)
        self.assertIn('[[ "$wall_age" -ge -2 ]]', durable_terminal)
        self.assertIn('if ((now - then) < -2) exit 74', durable_terminal)
        candidate_terminal = envelope[
            envelope.index('true:terminal:uuid)') :
            envelope.index('true:recovery-required:none)')
        ]
        self.assertEqual(candidate_terminal.count('live_envelope_durable_terminal_status_is_not_future'), 1)
        self.assertNotIn('live_envelope_status_is_current', candidate_terminal)
        self.assertIn('LIVE_STATUS_LEGACY_STALE_IDLE=true', envelope)
        self.assertIn('"$LIVE_POWER_SOURCE" == "ac" && "$LIVE_AC_SLEEP" == "0"', envelope)
        stale_idle = envelope[envelope.index('if [[ "$LIVE_STATUS_LEGACY_STALE_IDLE" == true ]]') : envelope.index('LIVE_AUTHORITY_KIND="none"')]
        self.assertIn('[[ "$LIVE_PLIST_CONTRACT" == "legacy-watchpaths" ]]', stale_idle)
        self.assertIn('case "$LIVE_LAUNCHD_PRESENCE" in', stale_idle)
        self.assertIn('"$LIVE_LAUNCHD_STATE" == "not running" && "$LIVE_LAUNCHD_PID" == "none"', stale_idle)
        self.assertIn('"$LIVE_LAUNCHD_STATE" == "none" && "$LIVE_LAUNCHD_PID" == "none" && "$LIVE_LAUNCHD_PROGRAM" == "none"', stale_idle)
        self.assertNotIn('[[ -e "$real_home/Library/Application Support/LidSwitch/activation-lease"', stale_idle)
        self.assertIn('if [[ "$LIVE_PLIST_CONTRACT" == "legacy-watchpaths" && ( -e "$real_home/Library/Application Support/LidSwitch/activation-lease"', stale_idle)
        self.assertIn('live_envelope_capture_idle_lease "$real_home"', stale_idle)
        self.assertIn('"${phase}.expired" "$real_home" none expired', envelope)
        matrix = {
            ("preserved", 0, 0): "true",
            ("command-failed-host-preserved", 1, 1): "true",
            ("benchmark-publication-failed-host-unverified", 0, 74): "false",
            ("preflight-denied", 256, 74): "false",
            ("host-drift", 0, 74): "false",
            ("envelope-failed-host-unverified", 0, 74): "false",
            ("envelope-final-reassert-failed-host-unverified", 256, 74): "false",
        }
        self.assertIn("schema=3", envelope)
        self.assertIn("child_command_exit=", envelope)
        self.assertIn("wrapper_exit=", envelope)
        self.assertIn('case "$outcome" in', envelope)
        self.assertIn('preserved)', envelope)
        self.assertIn('command-failed-host-preserved)', envelope)
        self.assertIn('host_preserved=true', envelope)
        self.assertNotIn("benchmark-publication-failed-host-preserved", envelope)
        for (outcome, child_exit, wrapper_exit), preserved in matrix.items():
            self.assertEqual(preserved, "true" if outcome in {"preserved", "command-failed-host-preserved"} else "false")
            self.assertIn(outcome, envelope if outcome in {"preflight-denied", "host-drift"} else verified_static_text("script/run_swift_tests_safely.sh") + verified_static_text("script/run_swift_build_safely.sh"))
            self.assertEqual(wrapper_exit, 74 if preserved == "false" else child_exit)
        self.assertIn('[[ "$child_command_exit" == 256 && "$wrapper_exit" == 74 ]]', envelope)
        self.assertIn('[[ "$child_command_exit" == 0 && "$wrapper_exit" == 74 ]]', envelope)
        self.assertIn('[[ "$child_command_exit" -le 256 && "$wrapper_exit" == 74 ]]', envelope)
        self.assertIn("swift_sandbox_read_supervisor_result", verified_static_text("script/swift_sandbox_common.sh"))
        preflight = envelope[envelope.index("live_envelope_preflight()") : envelope.index("live_envelope_postflight()")]
        postflight = envelope[envelope.index("live_envelope_postflight()") : envelope.index("live_envelope_finalize_terminal_receipt()")]
        self.assertNotIn("live_envelope_write_receipt", preflight)
        self.assertNotIn("live_envelope_write_receipt", postflight)
        for name in ("script/run_swift_tests_safely.sh", "script/run_swift_build_safely.sh"):
            wrapper = verified_static_text(name)
            receipt = wrapper.rindex("live_envelope_finalize_terminal_receipt")
            reassert = wrapper.rindex("swift_sandbox_reassert_before_sensitive_host_action", 0, receipt)
            self.assertLess(reassert, receipt)
            self.assertIn("trap '' HUP INT TERM", wrapper[receipt - 200:receipt])
            self.assertIn('live_envelope_finalize_terminal_receipt "$command_status" "$status"', wrapper)
            self.assertTrue(wrapper.rstrip().endswith('trap - EXIT HUP INT TERM\nexit "$status"'))
        normalized_validation = " ".join(validation.split())
        self.assertIn("not independently tamper-evident against an arbitrary same-UID process after wrapper exit", normalized_validation)
        self.assertIn("external manager/release evidence ledger immediately on wrapper return", normalized_validation)
        self.assertIn("not offline-verifiable", normalized_validation)
        self.assertIn("root-owned collector or externally anchored verifier key", normalized_validation)


EXPECTED_TEST_METHODS = (
    "test_benchmark_app_intake_uses_the_production_private_tmp_capability",
    "test_benchmark_private_tmp_name_boundaries_and_public_intake_are_exact",
    "test_bootstrap_early_eof_and_interruption_regressions",
    "test_explicit_runner_rejects_private_namespace_zero_discovery_and_result_classes",
    "test_production_artifact_capabilities_reject_tree_swaps_and_false_rows",
    "test_production_capture_verifier_round_trip_and_adversarial_mutations",
    "test_production_cleanup_fd_plan_executes_verified_bytes_after_path_swap",
    "test_production_cleanup_snapshot_receipt_rejects_mutable_reexec_authority",
    "test_production_cleanup_state_machine_injected_failures",
    "test_production_parser_corpus_counter_and_swift_order_statistics",
    "test_production_startup_gate_blocks_unbound_payload_and_classifies_release_edges",
    "test_production_supervisor_result_capability_rejects_untrusted_child_exit",
    "test_production_token_bound_process_table_and_signal_selection",
    "test_receipt_status_matrix_and_terminal_call_ordering",
    "test_selected_clt_capability_contract_rejects_inherited_or_alternate_roots",
    "test_trusted_isolated_python_gate_source_contract",
)


def _validated_test_inventory(test_case: type[unittest.TestCase], expected: tuple[str, ...]) -> tuple[str, ...]:
    """Fail closed unless loader discovery is exactly the frozen gate inventory."""
    if not expected or len(expected) != len(set(expected)) or tuple(sorted(expected)) != expected:
        raise RuntimeError("safe envelope expected test inventory is malformed")
    discovered = tuple(unittest.TestLoader().getTestCaseNames(test_case))
    if not discovered or len(discovered) != len(set(discovered)) or discovered != expected:
        raise RuntimeError("safe envelope test discovery does not match the frozen inventory")
    return discovered


def build_explicit_safe_envelope_suite(
    test_case: type[unittest.TestCase] = SafeEnvelopeProductionFixtures,
    expected: tuple[str, ...] = EXPECTED_TEST_METHODS,
) -> unittest.TestSuite:
    """Construct the suite without consulting sys.modules['__main__']."""
    names = _validated_test_inventory(test_case, expected)
    suite = unittest.TestSuite(test_case(name) for name in names)
    if suite.countTestCases() != len(expected) or suite.countTestCases() == 0:
        raise RuntimeError("safe envelope explicit suite count is invalid")
    return suite


def run_explicit_safe_envelope_suite(
    test_case: type[unittest.TestCase] = SafeEnvelopeProductionFixtures,
    expected: tuple[str, ...] = EXPECTED_TEST_METHODS,
    stream=None,
) -> unittest.result.TestResult:
    """Run only the frozen nonzero suite; every non-success class is denial."""
    suite = build_explicit_safe_envelope_suite(test_case, expected)
    result = unittest.TextTestRunner(stream=stream or sys.stderr, verbosity=2).run(suite)
    if (
        result.testsRun != len(expected)
        or result.failures
        or result.errors
        or result.skipped
        or result.expectedFailures
        or result.unexpectedSuccesses
    ):
        raise SystemExit(EX_IOERR)
    return result


if __name__ == "__main__":
    try:
        run_explicit_safe_envelope_suite()
    except (RuntimeError, TypeError, ValueError):
        raise SystemExit(EX_IOERR)
