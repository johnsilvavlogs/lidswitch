#!/usr/bin/python3
"""Run one sandbox command and fail if any descendant outlives its leader."""

from __future__ import annotations

import argparse
import ctypes
import fcntl
import hashlib
import hmac
import json
import os
import re
import resource
import signal
import stat
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import Callable


EX_IOERR = 74
TERM_GRACE_SECONDS = 2.0
POLL_SECONDS = 0.05
STABLE_EMPTY_SAMPLES = 4
OUTPUT_LIMIT_BYTES = 16 * 1024 * 1024
POST_LEADER_GRACE_SECONDS = 0.5
CLEANUP_SIGNALS = frozenset((signal.SIGHUP, signal.SIGINT, signal.SIGTERM))
PROC_PIDTBSDINFO = 3
CLEANUP_INHERITED_FD = 3
CLEANUP_SOURCE_ROOT_FD = 4
STARTUP_GATE_RELEASE = b"R"
# This fixed system-Python image is the only process allowed to exist before
# the parent has a token-bound leader/session identity.  It inherits neither
# the HMAC stdin nor any payload authority.  EOF, a malformed release, or any
# exec failure exits without ever reaching sandbox-exec or the Swift target.
STARTUP_GATE_BOOTSTRAP = """import os,sys
fd=int(sys.argv[1]); profile=sys.argv[2]; command=sys.argv[3:]
try:
    token=os.read(fd,1)
    if token!=b'R' or os.read(fd,1)!=b'': raise SystemExit(74)
    os.close(fd)
    os.execve('/usr/bin/sandbox-exec',['/usr/bin/sandbox-exec','-f',profile]+command,dict(os.environ))
except BaseException:
    try: os.close(fd)
    except OSError: pass
    raise SystemExit(74)
"""
CLEANUP_BOOTSTRAP = """import os,sys,stat,hashlib
def _verified_cleanup_bytes():
    fd=int(sys.argv[1]); root_fd=int(sys.argv[2]); source_seal=sys.argv[3]; fields=sys.argv[4].split(":"); hexchars="0123456789abcdef"
    if root_fd!=4 or len(fields)!=9 or fields[0]!=source_seal or len(fields[0])!=64 or len(fields[-1])!=64 or any(c not in hexchars for c in fields[0]+fields[-1]) or any(not value.isdigit() for value in fields[1:-1]): raise SystemExit(74)
    before=os.fstat(fd); expected=tuple(int(value) for value in fields[1:8]); observed=(before.st_dev,before.st_ino,before.st_uid,before.st_gid,stat.S_IMODE(before.st_mode),before.st_nlink,before.st_size)
    if not stat.S_ISREG(before.st_mode) or observed!=expected or before.st_uid!=os.getuid() or before.st_gid!=os.getgid() or stat.S_IMODE(before.st_mode)!=0o444 or before.st_nlink!=1 or not 0<before.st_size<=8388608: raise SystemExit(74)
    os.lseek(fd,0,os.SEEK_SET); data=bytearray()
    while len(data)<before.st_size:
        try: chunk=os.read(fd,min(131072,before.st_size-len(data)))
        except InterruptedError: continue
        if not chunk: raise SystemExit(74)
        data.extend(chunk)
    while True:
        try: extra=os.read(fd,1); break
        except InterruptedError: continue
    after=os.fstat(fd); data=bytes(data)
    if len(data)!=before.st_size or extra or (after.st_dev,after.st_ino,after.st_uid,after.st_gid,stat.S_IMODE(after.st_mode),after.st_nlink,after.st_size)!=(before.st_dev,before.st_ino,before.st_uid,before.st_gid,stat.S_IMODE(before.st_mode),before.st_nlink,before.st_size) or hashlib.sha256(data).hexdigest()!=fields[-1]: raise SystemExit(74)
    return data
data=_verified_cleanup_bytes();sys.argv=["<verified-cleanup-fd>"]+sys.argv[5:];_verified_cleanup_namespace={"__name__":"__main__","__file__":"<verified-cleanup-fd>"};exec(compile(data,"<verified-cleanup-fd>","exec"),_verified_cleanup_namespace)
"""


class ProcBsdInfo(ctypes.Structure):
    """Darwin `struct proc_bsdinfo`, from <sys/proc_info.h>."""
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32), ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32), ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32), ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32), ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32), ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32), ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16), ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32), ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32), ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32), ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64), ("pbi_start_tvusec", ctypes.c_uint64),
    ]


@dataclass(frozen=True, order=True)
class ProcessIdentity:
    pid: int
    start_seconds: int
    start_microseconds: int


@dataclass(frozen=True)
class ProcessRecord:
    identity: ProcessIdentity
    parent_pid: int
    process_group: int
    session: int


def darwin_process_identity(pid: int) -> ProcessIdentity | None:
    """Return PID plus kernel `PROC_PIDTBSDINFO` birth token, never elapsed text."""
    if sys.platform != "darwin" or not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return None
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        proc_pidinfo = libproc.proc_pidinfo
        proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        proc_pidinfo.restype = ctypes.c_int
        info = ProcBsdInfo()
        received = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, ctypes.byref(info), ctypes.sizeof(info))
    except (AttributeError, OSError):
        return None
    if received != ctypes.sizeof(info) or info.pbi_pid != pid or info.pbi_start_tvsec <= 0:
        return None
    return ProcessIdentity(pid, int(info.pbi_start_tvsec), int(info.pbi_start_tvusec))

SUPERVISOR_OUTCOMES = frozenset({
    "completed", "setup-failed", "launch-failed", "containment-failed",
    "capture-seal-failed", "interrupted",
})

# These handlers deliberately do no work beyond recording the first signal.
# In particular, they never enumerate processes, write evidence, or signal a
# child from re-entrant signal context.  The bounded cleanup owner below does
# that work only after the parent has captured the child's PID/session.
_INTERRUPT_SIGNAL = 0


def record_interruption(signum: int, _frame: object) -> None:
    global _INTERRUPT_SIGNAL
    if _INTERRUPT_SIGNAL == 0:
        _INTERRUPT_SIGNAL = signum


def install_interruption_handlers() -> None:
    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, record_interruption)


def take_interruption() -> int:
    return _INTERRUPT_SIGNAL


def startup_gate_identity_is_exact(
    leader: ProcessIdentity, *,
    identity_reader: Callable[[int], ProcessIdentity | None] = darwin_process_identity,
    group_reader: Callable[[int], int] = os.getpgid,
    session_reader: Callable[[int], int] = os.getsid,
) -> bool:
    """Authorize release only for the original new-session gate process."""
    try:
        return (
            identity_reader(leader.pid) == leader
            and group_reader(leader.pid) == leader.pid
            and session_reader(leader.pid) == leader.pid
        )
    except OSError:
        return False


def close_startup_gate(fd: int, *, closer: Callable[[int], None] = os.close) -> bool:
    """EOF is the only safe failure release; do not PID-signal an unbound gate."""
    try:
        closer(fd)
    except OSError:
        return False
    return True


def release_startup_gate(
    fd: int, leader: ProcessIdentity, *,
    identity_reader: Callable[[int], ProcessIdentity | None] = darwin_process_identity,
    group_reader: Callable[[int], int] = os.getpgid,
    session_reader: Callable[[int], int] = os.getsid,
    writer: Callable[[int, bytes], int] = os.write,
    closer: Callable[[int], None] = os.close,
) -> str:
    """Return released, blocked, or ambiguous without losing a write edge."""
    if not startup_gate_identity_is_exact(
        leader, identity_reader=identity_reader, group_reader=group_reader,
        session_reader=session_reader,
    ):
        close_startup_gate(fd, closer=closer)
        return "blocked"
    try:
        if writer(fd, STARTUP_GATE_RELEASE) != len(STARTUP_GATE_RELEASE):
            raise OSError("startup gate release was incomplete")
    except OSError:
        close_startup_gate(fd, closer=closer)
        return "blocked"
    if not close_startup_gate(fd, closer=closer):
        return "ambiguous"
    # The PID, birth token, process group and session survive the fixed gate's
    # exec transition; any mismatch is cleanup-only, never a PID-only signal.
    return "released" if startup_gate_identity_is_exact(
        leader, identity_reader=identity_reader, group_reader=group_reader,
        session_reader=session_reader,
    ) else "ambiguous"


def reap_blocked_startup_gate(child: object) -> None:
    """No-token failure is deliberately blocking: the gate cannot run payload."""
    waiter = getattr(child, "wait", None)
    if not callable(waiter):
        raise RuntimeError("startup gate lacks a wait handle")
    while True:
        try:
            waiter()
            return
        except InterruptedError:
            continue


def supervisor_result_state_is_valid(*, launched: object, leader_exit: object,
                                     outcome: object, capture_seal: object) -> bool:
    """Accept only result tuples the cleanup owner can actually publish.

    A post-launch result exists only after the leader was reaped and stable
    descendant absence was proved.  An unproved cleanup publishes no result;
    the wrapper therefore records child exit 256 rather than inventing one.
    """
    if not isinstance(launched, bool) or not isinstance(capture_seal, bool):
        return False
    if outcome not in SUPERVISOR_OUTCOMES:
        return False
    valid_exit = isinstance(leader_exit, int) and not isinstance(leader_exit, bool) and 0 <= leader_exit <= 255
    if outcome in {"setup-failed", "launch-failed"}:
        return launched is False and leader_exit is None and capture_seal is False
    if not launched or not valid_exit:
        return False
    if outcome == "completed":
        return capture_seal is True
    return capture_seal is False


def publish_supervisor_result_if_permitted(*, permitted: bool,
                                           publish: Callable[[], None]) -> bool:
    """One injected seam: result write failure never becomes child evidence."""
    if not permitted:
        return False
    try:
        publish()
    except Exception:
        return False
    return True


def close_nonstandard_fds() -> None:
    soft, _ = resource.getrlimit(resource.RLIMIT_NOFILE)
    maximum = 1_048_576 if soft == resource.RLIM_INFINITY else min(int(soft), 1_048_576)
    os.closerange(3, maximum)


def parse_process_table(text: str) -> dict[int, tuple[int, int]]:
    """Parse only Darwin numeric PID/PPID/PGID records."""
    rows: dict[int, tuple[int, int]] = {}
    for raw in text.splitlines():
        fields = raw.split()
        if len(fields) != 3 or not all(field.isdigit() for field in fields):
            raise RuntimeError("malformed macOS ps pid/ppid/pgid row")
        pid, parent_pid, process_group = (int(field, 10) for field in fields)
        if pid <= 0 or parent_pid < 0 or process_group <= 0:
            raise RuntimeError("invalid macOS process identity")
        if pid in rows:
            raise RuntimeError("duplicate macOS process identity")
        rows[pid] = (parent_pid, process_group)
    return rows


def process_session_id(pid: int, *, session_reader: Callable[[int], int] = os.getsid) -> int | None:
    """Read the POSIX session ID from the kernel; None means PID vanished."""
    try:
        session = session_reader(pid)
    except ProcessLookupError:
        return None
    except Exception as error:
        raise RuntimeError("could not read supervised process session") from error
    if type(session) is not int or session <= 0:
        raise RuntimeError("invalid supervised process session")
    return session


def process_table(session_id: int, observed: set[ProcessIdentity], *,
                  ps_reader: Callable[[], str] | None = None,
                  identity_reader: Callable[[int], ProcessIdentity | None] = darwin_process_identity,
                  session_reader: Callable[[int], int] = os.getsid) -> dict[int, ProcessRecord]:
    """Return only token-bound session/observed records.

    The `ps` rows supply ancestry, kernel session IDs select candidates, and
    libproc birth tokens authorize them. Reused or unprovable live PIDs fail
    closed; a PID which vanishes during enumeration is simply no longer live.
    """
    try:
        if ps_reader is None:
            result = subprocess.run(
                ["/bin/ps", "-axo", "pid=,ppid=,pgid="],
                check=True, close_fds=True, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"},
            )
            text = result.stdout
        else:
            text = ps_reader()
    except Exception:
        raise RuntimeError("could not enumerate supervised process session")
    raw_rows = parse_process_table(text)
    observed_by_pid = {identity.pid: identity for identity in observed}
    sessions = {
        pid: session for pid in raw_rows
        if (session := process_session_id(pid, session_reader=session_reader)) is not None
    }
    candidates = {
        pid for pid, session in sessions.items()
        if session == session_id or pid in observed_by_pid
    }
    # Retain the complete current descendant closure as well as the session.
    # A child which calls setsid before its first session-table sample remains a
    # token-bound candidate through its PPID chain and is classified as escape.
    while True:
        descendants = {
            pid for pid, (parent_pid, _) in raw_rows.items()
            if pid in sessions and parent_pid in candidates
        }
        expanded = candidates | descendants
        if expanded == candidates:
            break
        candidates = expanded
    records: dict[int, ProcessRecord] = {}
    for pid in candidates:
        session = process_session_id(pid, session_reader=session_reader)
        if session is None:
            continue
        identity = identity_reader(pid)
        if identity is None:
            if process_session_id(pid, session_reader=session_reader) is None:
                continue
            raise RuntimeError("supervised process birth token is unavailable")
        if identity.pid != pid:
            raise RuntimeError("supervised process birth token is unavailable")
        expected = observed_by_pid.get(pid)
        if expected is not None and identity != expected:
            raise RuntimeError("supervised PID was reused")
        parent_pid, process_group = raw_rows[pid]
        records[pid] = ProcessRecord(identity, parent_pid, process_group, session)
    return records


def session_members(session_id: int, observed: set[ProcessIdentity], *,
                    ps_reader: Callable[[], str] | None = None,
                    identity_reader: Callable[[int], ProcessIdentity | None] = darwin_process_identity,
                    session_reader: Callable[[int], int] = os.getsid) -> dict[int, ProcessRecord]:
    records = process_table(session_id, observed, ps_reader=ps_reader, identity_reader=identity_reader, session_reader=session_reader)
    escaped = {record.identity for record in records.values() if record.session != session_id}
    if escaped:
        raise RuntimeError("supervised descendant escaped its initial session")
    return {pid: record for pid, record in records.items() if record.session == session_id and pid != os.getpid()}


def signal_process_identity(identity: ProcessIdentity, signum: int, *,
                            identity_reader: Callable[[int], ProcessIdentity | None] = darwin_process_identity,
                            killer: Callable[[int, int], None] = os.kill) -> bool:
    """Re-read the kernel birth token immediately before the PID signal."""
    if identity_reader(identity.pid) != identity:
        return False
    try:
        killer(identity.pid, signum)
    except ProcessLookupError:
        return False
    except PermissionError:
        raise RuntimeError("lost authority over token-bound supervised process")
    return True


def signal_members(records: dict[int, ProcessRecord], signum: int, *,
                   identity_reader: Callable[[int], ProcessIdentity | None] = darwin_process_identity,
                   killer: Callable[[int, int], None] = os.kill) -> None:
    if not records:
        return
    if not all(signal_process_identity(record.identity, signum, identity_reader=identity_reader, killer=killer) for record in records.values()):
        raise RuntimeError("supervised process disappeared or was reused before signal")


def direct_containment_signal(leader: ProcessIdentity, session_id: int,
                              observed: set[ProcessIdentity], records: dict[int, ProcessRecord] | None,
                              signum: int, *,
                              identity_reader: Callable[[int], ProcessIdentity | None] = darwin_process_identity,
                              killer: Callable[[int, int], None] = os.kill,
                              group_killer: Callable[[int, int], None] = os.killpg) -> None:
    """Token-gate every PID and process-group signal.

    Group broadcast is allowed only while the current leader birth token and a
    fresh token-bound `pgid == sid == leader.pid` record prove the group cannot
    be a recycled identifier.  Otherwise only exact token-matched PIDs are
    attempted and containment fails closed.
    """
    failures: list[str] = []
    for identity in sorted(observed):
        try:
            if not signal_process_identity(identity, signum, identity_reader=identity_reader, killer=killer):
                failures.append(f"birth-token mismatch for pid {identity.pid}")
        except RuntimeError as error:
            failures.append(str(error))
    leader_record = None if records is None else records.get(leader.pid)
    group_records = [] if records is None else [
        record for record in records.values()
        if record.session == session_id and record.process_group == leader.pid
    ]
    if (
        leader_record is None or leader_record.identity != leader
        or leader_record.session != session_id or leader_record.process_group != leader.pid
        or identity_reader(leader.pid) != leader
        or not group_records
        or any(identity_reader(record.identity.pid) != record.identity for record in group_records)
    ):
        failures.append("leader token-bound process group cannot be proved")
    else:
        try:
            group_killer(leader.pid, signum)
        except ProcessLookupError:
            failures.append("leader process group disappeared before signal")
        except PermissionError:
            failures.append("lost authority over token-bound process group")
    if failures:
        raise RuntimeError("; ".join(failures))


@dataclass
class CleanupStateMachine:
    """Deterministic state owned by the parent, with injectable I/O seams."""
    leader: ProcessIdentity
    session_id: int
    observed: set[ProcessIdentity] = field(default_factory=set)
    current_records: dict[int, ProcessRecord] = field(default_factory=dict)
    phase: str = "identity-captured"
    leader_exit: int | None = None
    interrupted: bool = False
    containment_fault: bool = False
    enumeration_fault: bool = False
    direct_signal_fault: bool = False
    stable_samples: int = 0

    def __post_init__(self) -> None:
        self.observed.add(self.leader)

    def request_cleanup(self, reason: str, *, interrupted: bool = False) -> None:
        self.phase = "cleanup-owner"
        self.containment_fault = True
        self.interrupted = self.interrupted or interrupted
        if reason == "enumeration":
            self.enumeration_fault = True

    def observe_exit(self, returncode: int | None) -> None:
        if returncode is not None:
            self.leader_exit = map_returncode(returncode)

    def observe_members(self, members: dict[int, ProcessRecord]) -> None:
        self.current_records = dict(members)
        self.observed.update(record.identity for record in members.values())
        self.stable_samples = self.stable_samples + 1 if not members else 0

    def stable_absence_proved(self) -> bool:
        return self.leader_exit is not None and self.stable_samples >= STABLE_EMPTY_SAMPLES

    def terminal_outcome(self) -> str:
        if self.interrupted:
            return "interrupted"
        if self.containment_fault:
            return "containment-failed"
        return "completed"


def _cleanup_round(machine: CleanupStateMachine, *, poll_leader: Callable[[], int | None],
                   enumerate_members: Callable[[set[ProcessIdentity]], dict[int, ProcessRecord]]) -> None:
    """One non-reentrant observation round.  Enumeration failure is recorded,
    then the caller continues direct TERM/KILL and retries before trusting it."""
    try:
        machine.observe_exit(poll_leader())
    except Exception:
        machine.request_cleanup("poll")
    try:
        machine.observe_members(enumerate_members(machine.observed))
    except Exception:
        machine.request_cleanup("enumeration")


def run_cleanup_state_machine(
    machine: CleanupStateMachine,
    *,
    poll_leader: Callable[[], int | None],
    wait_leader: Callable[[float], int | None],
    enumerate_members: Callable[[set[ProcessIdentity]], dict[int, ProcessRecord]],
    signal_direct: Callable[[int], None],
    monotonic: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], None] = time.sleep,
    interrupted: Callable[[], int] = take_interruption,
) -> bool:
    """Own one launched child through proof of bounded stable absence.

    The function is both the production cleanup owner and the pure injected
    test seam.  It only returns true after the leader was reaped and four
    consecutive successful session enumerations prove no descendants remain.
    A false result means no authenticated supervisor result may be published.
    """
    post_leader_deadline: float | None = None
    while machine.phase != "cleanup-owner":
        if interrupted():
            machine.request_cleanup("interrupted", interrupted=True)
            break
        _cleanup_round(machine, poll_leader=poll_leader, enumerate_members=enumerate_members)
        if machine.leader_exit is not None:
            if machine.stable_absence_proved():
                return True
            if post_leader_deadline is None:
                post_leader_deadline = monotonic() + POST_LEADER_GRACE_SECONDS
            elif monotonic() >= post_leader_deadline:
                machine.request_cleanup("descendants-survived-leader")
                break
        sleep(POLL_SECONDS)

    # The cleanup owner always tries direct leader and process-group TERM
    # before relying on a process listing.  It then retries enumeration while
    # the bounded grace remains, so transient `ps` failure cannot become a
    # best-effort publication path.
    for signum in (signal.SIGTERM, signal.SIGKILL):
        try:
            signal_direct(signum)
        except Exception:
            machine.direct_signal_fault = True
        deadline = monotonic() + TERM_GRACE_SECONDS
        while monotonic() < deadline:
            try:
                machine.observe_exit(wait_leader(POLL_SECONDS))
            except Exception:
                machine.request_cleanup("poll", interrupted=machine.interrupted)
            try:
                machine.observe_members(enumerate_members(machine.observed))
            except Exception:
                machine.request_cleanup("enumeration", interrupted=machine.interrupted)
            if machine.stable_absence_proved():
                return True
            sleep(POLL_SECONDS)
    # No result is permitted if a SIGKILL attempt or enumeration cannot yield
    # stable absence.  The wrapper fails closed; the retained roots preserve
    # the cleanup-failure evidence instead of claiming a child outcome.
    return False


def source_identity(metadata: os.stat_result) -> tuple[int, int, int, int, int, int]:
    return (metadata.st_dev, metadata.st_ino, metadata.st_uid, metadata.st_gid,
            stat.S_IMODE(metadata.st_mode), metadata.st_nlink)


def snapshot_identity(metadata: os.stat_result) -> tuple[int, int, int, int, int, int, int, int, int]:
    return source_identity(metadata) + (metadata.st_size, metadata.st_mtime_ns, metadata.st_ctime_ns)


def source_leaf_identity(metadata: os.stat_result) -> tuple[int, int, int, int, int, int, int]:
    return source_identity(metadata) + (metadata.st_size,)


def open_cleanup_source_root(path: str) -> int:
    """Open only a fixed sealed source root below literal /private/tmp."""
    parts = path.split("/")
    if (
        len(parts) != 5 or parts[:3] != ["", "private", "tmp"]
        or parts[4] not in ("source", "helper-source", "app-source")
    ):
        raise RuntimeError("cleanup source root is not the canonical private snapshot")
    execution_name = parts[3]
    source_name = parts[4]
    if not re.fullmatch(r"lidswitch-swift\.[A-Za-z0-9_]{6,32}", execution_name):
        raise RuntimeError("cleanup source root component is unsafe")
    root_fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        private_fd = os.open("private", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=root_fd)
        try:
            tmp_fd = os.open("tmp", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=private_fd)
            try:
                tmp_meta = os.fstat(tmp_fd)
                if tmp_meta.st_uid != 0 or tmp_meta.st_gid != 0 or stat.S_IMODE(tmp_meta.st_mode) != 0o1777:
                    raise RuntimeError("literal /private/tmp is unsafe")
                execution_fd = os.open(execution_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=tmp_fd)
                try:
                    execution_meta = os.fstat(execution_fd)
                    if execution_meta.st_uid != os.getuid() or execution_meta.st_gid != os.getgid() or stat.S_IMODE(execution_meta.st_mode) != 0o700:
                        raise RuntimeError("cleanup execution root is unsafe")
                    return os.open(source_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=execution_fd)
                finally:
                    os.close(execution_fd)
            finally:
                os.close(tmp_fd)
        finally:
            os.close(private_fd)
    finally:
        os.close(root_fd)


def cleanup_snapshot_digest(directory_fd: int) -> str:
    """Hash the immutable snapshot using descriptor-only traversal."""
    digest = hashlib.sha256()
    def visit(fd: int, prefix: str) -> None:
        directory_meta = os.fstat(fd)
        if not stat.S_ISDIR(directory_meta.st_mode) or directory_meta.st_uid != os.getuid() or directory_meta.st_gid != os.getgid() or stat.S_IMODE(directory_meta.st_mode) != 0o555:
            raise RuntimeError("cleanup source directory metadata changed")
        digest.update(("R\0" + prefix + "\0" + str(snapshot_identity(directory_meta)) + "\n").encode("ascii"))
        for name in sorted(os.listdir(fd)):
            if not re.fullmatch(r"[A-Za-z0-9._-]{1,96}", name):
                raise RuntimeError("cleanup source entry is unsafe")
            child_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            try:
                child = os.fstat(child_fd)
                path = name if not prefix else prefix + "/" + name
                if stat.S_ISDIR(child.st_mode):
                    visit(child_fd, path)
                elif stat.S_ISREG(child.st_mode):
                    if child.st_uid != os.getuid() or child.st_gid != os.getgid() or stat.S_IMODE(child.st_mode) != 0o444 or child.st_nlink != 1:
                        raise RuntimeError("cleanup source file metadata changed")
                    payload_hash = hashlib.sha256(); remaining = child.st_size
                    while remaining:
                        chunk = os.read(child_fd, min(131072, remaining))
                        if not chunk:
                            raise RuntimeError("cleanup source file ended early")
                        payload_hash.update(chunk); remaining -= len(chunk)
                    if os.read(child_fd, 1) or snapshot_identity(os.fstat(child_fd)) != snapshot_identity(child):
                        raise RuntimeError("cleanup source file changed while hashing")
                    digest.update(("F\0" + path + "\0" + str(snapshot_identity(child)) + "\0" + payload_hash.hexdigest() + "\n").encode("ascii"))
                else:
                    raise RuntimeError("cleanup source contains a special entry")
            finally:
                os.close(child_fd)
        if snapshot_identity(os.fstat(fd)) != snapshot_identity(directory_meta):
            raise RuntimeError("cleanup source directory changed while hashing")
    visit(directory_fd, "")
    return digest.hexdigest()


def cleanup_script_receipt(source_root: str, source_seal: str) -> str:
    """Return a leaf receipt only after verifying the entire immutable snapshot."""
    source_fd = open_cleanup_source_root(source_root)
    try:
        if cleanup_snapshot_digest(source_fd) != source_seal:
            raise RuntimeError("cleanup source snapshot digest changed")
        script_fd = os.open("script", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=source_fd)
        try:
            leaf_fd = os.open("safe_process_supervisor.py", os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=script_fd)
            try:
                metadata = os.fstat(leaf_fd)
                if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_gid != os.getgid() or stat.S_IMODE(metadata.st_mode) != 0o444 or metadata.st_nlink != 1:
                    raise RuntimeError("cleanup supervisor snapshot leaf is unsafe")
                digest = hashlib.sha256()
                remaining = metadata.st_size
                while remaining:
                    chunk = os.read(leaf_fd, min(131072, remaining))
                    if not chunk:
                        raise RuntimeError("cleanup supervisor snapshot leaf changed")
                    digest.update(chunk); remaining -= len(chunk)
                if os.read(leaf_fd, 1) or snapshot_identity(os.fstat(leaf_fd)) != snapshot_identity(metadata):
                    raise RuntimeError("cleanup supervisor snapshot leaf changed")
                return ":".join((source_seal, *(str(value) for value in source_leaf_identity(metadata)), digest.hexdigest()))
            finally:
                os.close(leaf_fd)
        finally:
            os.close(script_fd)
    finally:
        os.close(source_fd)


def open_verified_cleanup_snapshot(source_root: str, source_seal: str, receipt: str) -> tuple[int, int]:
    """Return held source-root and supervisor descriptors after whole-tree recheck."""
    fields = receipt.split(":")
    if len(fields) != 9 or not re.fullmatch(r"[0-9a-f]{64}", fields[0]) or not re.fullmatch(r"[0-9a-f]{64}", fields[-1]) or any(not field.isdigit() for field in fields[1:-1]):
        raise RuntimeError("cleanup supervisor receipt is malformed")
    if fields[0] != source_seal:
        raise RuntimeError("cleanup supervisor receipt no longer matches immutable snapshot")
    source_fd = open_cleanup_source_root(source_root)
    try:
        if cleanup_snapshot_digest(source_fd) != source_seal:
            raise RuntimeError("cleanup source snapshot digest changed")
        script_fd = os.open("script", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=source_fd)
        try:
            leaf_fd = os.open("safe_process_supervisor.py", os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=script_fd)
        finally:
            os.close(script_fd)
    except Exception:
        os.close(source_fd)
        raise
    metadata = os.fstat(leaf_fd)
    expected = tuple(int(value, 10) for value in fields[1:8])
    if (
        not stat.S_ISREG(metadata.st_mode) or source_leaf_identity(metadata) != expected
        or metadata.st_uid != os.getuid() or metadata.st_gid != os.getgid()
        or stat.S_IMODE(metadata.st_mode) != 0o444 or metadata.st_nlink != 1
    ):
        os.close(leaf_fd)
        os.close(source_fd)
        raise RuntimeError("cleanup supervisor receipt no longer matches immutable snapshot")
    digest = hashlib.sha256(); remaining = metadata.st_size
    while remaining:
        chunk = os.read(leaf_fd, min(131072, remaining))
        if not chunk:
            os.close(leaf_fd); os.close(source_fd); raise RuntimeError("cleanup supervisor source changed")
        digest.update(chunk); remaining -= len(chunk)
    if os.read(leaf_fd, 1) or snapshot_identity(os.fstat(leaf_fd)) != snapshot_identity(metadata) or digest.hexdigest() != fields[-1]:
        os.close(leaf_fd); os.close(source_fd); raise RuntimeError("cleanup supervisor source changed")
    os.lseek(leaf_fd, 0, os.SEEK_SET)
    return source_fd, leaf_fd


def open_verified_cleanup_script(source_root: str, source_seal: str, receipt: str) -> int:
    """Return the held supervisor leaf for callers that do not need root retention."""
    source_fd, leaf_fd = open_verified_cleanup_snapshot(source_root, source_seal, receipt)
    os.close(source_fd)
    return leaf_fd


def verify_inherited_cleanup_script_fd(fd: int, source_seal: str, receipt: str) -> None:
    """Cleanup child trusts only its inherited, pre-verified script descriptor."""
    fields = receipt.split(":")
    if len(fields) != 9 or fields[0] != source_seal or not re.fullmatch(r"[0-9a-f]{64}", fields[-1]) or any(not field.isdigit() for field in fields[1:-1]):
        raise RuntimeError("inherited cleanup receipt is malformed")
    metadata = os.fstat(fd)
    expected = tuple(int(value, 10) for value in fields[1:8])
    if not stat.S_ISREG(metadata.st_mode) or source_leaf_identity(metadata) != expected or metadata.st_uid != os.getuid() or metadata.st_gid != os.getgid() or stat.S_IMODE(metadata.st_mode) != 0o444 or metadata.st_nlink != 1:
        raise RuntimeError("inherited cleanup descriptor identity changed")
    digest = hashlib.sha256(); remaining = metadata.st_size
    os.lseek(fd, 0, os.SEEK_SET)
    while remaining:
        chunk = os.read(fd, min(131072, remaining))
        if not chunk:
            raise RuntimeError("inherited cleanup descriptor changed")
        digest.update(chunk); remaining -= len(chunk)
    if os.read(fd, 1) or snapshot_identity(os.fstat(fd)) != snapshot_identity(metadata) or digest.hexdigest() != fields[-1]:
        raise RuntimeError("inherited cleanup descriptor changed")
    os.lseek(fd, 0, os.SEEK_SET)


def verify_cleanup_owner_snapshot(root_fd: int, source_seal: str) -> None:
    """Reject a changed retained source tree before durable cleanup effects."""
    if cleanup_snapshot_digest(root_fd) != source_seal:
        raise RuntimeError("inherited cleanup source snapshot changed")


def durable_cleanup_round(machine: CleanupStateMachine, *,
                          ps_reader: Callable[[], str] | None = None,
                          identity_reader: Callable[[int], ProcessIdentity | None] = darwin_process_identity,
                          session_reader: Callable[[int], int] = os.getsid,
                          killer: Callable[[int, int], None] = os.kill,
                          group_killer: Callable[[int, int], None] = os.killpg) -> bool:
    """One durable-owner attempt; false means identity/absence remains unproved."""
    try:
        records = process_table(machine.session_id, machine.observed, ps_reader=ps_reader, identity_reader=identity_reader, session_reader=session_reader)
        machine.observe_members(records)
        direct_containment_signal(machine.leader, machine.session_id, machine.observed, records, signal.SIGKILL,
                                  identity_reader=identity_reader, killer=killer, group_killer=group_killer)
    except Exception:
        machine.request_cleanup("enumeration")
        machine.stable_samples = 0
        return False
    try:
        machine.observe_members(session_members(machine.session_id, machine.observed, ps_reader=ps_reader, identity_reader=identity_reader, session_reader=session_reader))
    except Exception:
        machine.request_cleanup("enumeration")
        machine.stable_samples = 0
        return False
    return machine.stable_samples >= STABLE_EMPTY_SAMPLES


def durable_cleanup_owner(leader: ProcessIdentity, session_id: int, observed: set[ProcessIdentity], *,
                          source_seal: str, cleanup_script_receipt_value: str) -> None:
    """Post-failure owner: no evidence, no key, only bounded KILL/retry rounds.

    This process is reached only by a clean `execve` after an unproved cleanup,
    so it does not inherit the parent-private HMAC key.  It deliberately keeps
    retrying until it can establish stable absence; the wrapper cannot mistake
    it for authenticated child evidence because it never creates a result.
    """
    # The fixed `-c` bootstrap verified this inherited descriptor before it
    # compiled this source. Reassert it before handlers unblock or signals run.
    verify_inherited_cleanup_script_fd(CLEANUP_INHERITED_FD, source_seal, cleanup_script_receipt_value)
    verify_cleanup_owner_snapshot(CLEANUP_SOURCE_ROOT_FD, source_seal)
    install_interruption_handlers()
    signal.pthread_sigmask(signal.SIG_UNBLOCK, CLEANUP_SIGNALS)
    machine = CleanupStateMachine(leader=leader, session_id=session_id, observed=observed)
    while True:
        if durable_cleanup_round(machine):
            return
        time.sleep(TERM_GRACE_SECONDS)


def durable_cleanup_spawn_plan(machine: CleanupStateMachine, *, cleanup_source_root: str,
                               source_seal: str, cleanup_script_receipt_value: str) -> tuple[int, int, list[str]]:
    """Hold the verified script descriptor through the mutable-path race window."""
    observed = ",".join(
        f"{identity.pid}:{identity.start_seconds}:{identity.start_microseconds}"
        for identity in sorted(machine.observed)
    )
    source_fd, cleanup_fd = open_verified_cleanup_snapshot(cleanup_source_root, source_seal, cleanup_script_receipt_value)
    # Keep both source capabilities CLOEXEC in the parent and above their fixed
    # child slots.  POSIX_SPAWN_DUP2 deliberately clears CLOEXEC only on child
    # descriptors 3/4 for the fixed bootstrap.
    retained_source_fd: int | None = None
    retained_cleanup_fd: int | None = None
    try:
        retained_source_fd = fcntl.fcntl(source_fd, fcntl.F_DUPFD_CLOEXEC, 5)
        retained_cleanup_fd = fcntl.fcntl(cleanup_fd, fcntl.F_DUPFD_CLOEXEC, 5)
        os.close(source_fd); source_fd = -1
        os.close(cleanup_fd); cleanup_fd = -1
        # Reassert the duplicate capabilities immediately before the spawn
        # boundary. The child repeats these checks before containment work.
        verify_inherited_cleanup_script_fd(retained_cleanup_fd, source_seal, cleanup_script_receipt_value)
        if cleanup_snapshot_digest(retained_source_fd) != source_seal:
            raise RuntimeError("cleanup source snapshot changed before durable owner spawn")
    except Exception:
        for fd in (source_fd, cleanup_fd, retained_source_fd, retained_cleanup_fd):
            if fd is not None and fd >= 0:
                try:
                    os.close(fd)
                except OSError:
                    pass
        raise
    return retained_source_fd, retained_cleanup_fd, [
        "/usr/bin/python3", "-I", "-S", "-B", "-c", CLEANUP_BOOTSTRAP,
        str(CLEANUP_INHERITED_FD), str(CLEANUP_SOURCE_ROOT_FD), source_seal, cleanup_script_receipt_value,
        "--cleanup-owner", "--cleanup-leader", f"{machine.leader.pid}:{machine.leader.start_seconds}:{machine.leader.start_microseconds}",
        "--cleanup-session-id", str(machine.session_id),
        "--cleanup-observed", observed,
        "--source-seal", source_seal,
        "--cleanup-script-receipt", cleanup_script_receipt_value,
    ]


def start_durable_cleanup_owner(machine: CleanupStateMachine, *, cleanup_source_root: str,
                                source_seal: str, cleanup_script_receipt_value: str) -> None:
    """Spawn a clean cleanup-only image from a deliberately inherited FD."""
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, CLEANUP_SIGNALS)
    try:
        # Python 3.8's Darwin posix_spawn supports setsigmask; the child begins
        # blocked, installs its flag-only handlers, then explicitly unblocks.
        source_fd, cleanup_fd, argv = durable_cleanup_spawn_plan(
            machine, cleanup_source_root=cleanup_source_root, source_seal=source_seal,
            cleanup_script_receipt_value=cleanup_script_receipt_value,
        )
        try:
            os.posix_spawn(
                "/usr/bin/python3",
                argv,
                {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"},
                file_actions=[
                    (os.POSIX_SPAWN_CLOSE, 0), (os.POSIX_SPAWN_CLOSE, 1),
                    (os.POSIX_SPAWN_CLOSE, 2),
                    (os.POSIX_SPAWN_DUP2, cleanup_fd, CLEANUP_INHERITED_FD),
                    (os.POSIX_SPAWN_DUP2, source_fd, CLEANUP_SOURCE_ROOT_FD),
                ],
                setsigmask=CLEANUP_SIGNALS,
            )
        finally:
            os.close(source_fd)
            os.close(cleanup_fd)
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)


def map_returncode(returncode: int) -> int:
    if returncode >= 0:
        return min(returncode, 255)
    return min(128 + abs(returncode), 255)


def stable_capture_metadata(fd: int) -> os.stat_result:
    """Validate the supervisor-held capture descriptor, never a pathname."""
    metadata = os.fstat(fd)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or metadata.st_gid != os.getgid()
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or metadata.st_nlink != 1
        or metadata.st_size < 0
        or metadata.st_size > OUTPUT_LIMIT_BYTES
    ):
        raise RuntimeError("captured output descriptor metadata changed")
    return metadata


def capture_identity(metadata: os.stat_result) -> tuple[int, int, int, int, int, int, int]:
    return (
        metadata.st_dev, metadata.st_ino, metadata.st_uid, metadata.st_gid,
        stat.S_IMODE(metadata.st_mode), metadata.st_nlink, metadata.st_size,
    )


def verify_capture_name(path: str, metadata: os.stat_result) -> None:
    """The retained name must still be the exact descriptor we sealed."""
    named = os.stat(path, follow_symlinks=False)
    if capture_identity(named) != capture_identity(metadata):
        raise RuntimeError("captured output pathname no longer names held descriptor")


def capture_digest(fd: int, metadata: os.stat_result) -> str:
    """Hash a bounded held descriptor and reject every concurrent mutation."""
    os.lseek(fd, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    remaining = metadata.st_size
    while remaining:
        chunk = os.read(fd, min(131072, remaining))
        if not chunk:
            raise RuntimeError("captured output ended before its sealed size")
        digest.update(chunk)
        remaining -= len(chunk)
    if os.read(fd, 1):
        raise RuntimeError("captured output grew while hashing")
    after = stable_capture_metadata(fd)
    if capture_identity(after) != capture_identity(metadata):
        raise RuntimeError("captured output changed while hashing")
    return digest.hexdigest()


def read_authentication_key() -> bytes:
    """Read exactly one parent-private 256-bit key from supervisor stdin."""
    encoded = sys.stdin.buffer.read(65)
    if len(encoded) != 65 or not encoded.endswith(b"\n") or not re.fullmatch(rb"[0-9a-f]{64}\n", encoded):
        raise RuntimeError("capture authentication key is malformed")
    return bytes.fromhex(encoded[:-1].decode("ascii"))


def capture_context(args: argparse.Namespace) -> dict[str, str]:
    context = {
        "capture": args.capture, "control_identity": args.control_identity,
        "execution_identity": args.execution_identity, "nonce": args.nonce,
        "profile_seal": args.profile_seal, "source_seal": args.source_seal,
    }
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", context["capture"]):
        raise RuntimeError("capture authentication context is malformed")
    if not re.fullmatch(r"[0-9a-f-]{36}", context["nonce"]):
        raise RuntimeError("capture authentication nonce is malformed")
    if not re.fullmatch(r"[0-9a-f]{64}", context["source_seal"]) or not re.fullmatch(r"[0-9:|a-f]{80,256}", context["profile_seal"]):
        raise RuntimeError("capture authentication seal is malformed")
    return context


def canonical_capture_payload(document: dict[str, object]) -> bytes:
    return json.dumps(document, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode("utf-8")


def create_capture_seal(path: str, captures: dict[str, tuple[object, str]], key: bytes, context: dict[str, str]) -> None:
    """Create one host-only, canonical capability after stable absence only."""
    parent, name = os.path.split(path)
    if not parent or not name or "/" in name or not name.endswith(".seal"):
        raise RuntimeError("capture seal pathname is unsafe")
    parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        parent_meta = os.fstat(parent_fd)
        if (
            not stat.S_ISDIR(parent_meta.st_mode)
            or parent_meta.st_uid != os.getuid()
            or parent_meta.st_gid != os.getgid()
            or stat.S_IMODE(parent_meta.st_mode) != 0o700
            or parent_meta.st_nlink < 2
        ):
            raise RuntimeError("capture seal parent is unsafe")
        document: dict[str, object] = {"schema": "lidswitch-capture-seal-v2", **context}
        for stream in ("stdout", "stderr"):
            handle, capture_path = captures[stream]
            metadata = stable_capture_metadata(handle.fileno())
            verify_capture_name(capture_path, metadata)
            document[stream] = {
                "dev": metadata.st_dev, "gid": metadata.st_gid,
                "inode": metadata.st_ino, "mode": stat.S_IMODE(metadata.st_mode),
                "nlink": metadata.st_nlink, "sha256": capture_digest(handle.fileno(), metadata),
                "size": metadata.st_size, "uid": metadata.st_uid,
            }
            verify_capture_name(capture_path, stable_capture_metadata(handle.fileno()))
        document["context_sha256"] = hashlib.sha256(canonical_capture_payload(document)).hexdigest()
        document["auth_hmac"] = hmac.new(key, canonical_capture_payload(document), hashlib.sha256).hexdigest()
        payload = canonical_capture_payload(document) + b"\n"
        seal_fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=parent_fd)
        try:
            seal_meta = os.fstat(seal_fd)
            if not stat.S_ISREG(seal_meta.st_mode) or seal_meta.st_uid != os.getuid() or seal_meta.st_gid != os.getgid() or stat.S_IMODE(seal_meta.st_mode) != 0o600 or seal_meta.st_nlink != 1:
                raise RuntimeError("capture seal metadata is unsafe")
            view = memoryview(payload)
            while view:
                written = os.write(seal_fd, view)
                if written <= 0:
                    raise RuntimeError("capture seal write was incomplete")
                view = view[written:]
            os.fsync(seal_fd)
            if os.fstat(seal_fd).st_size != len(payload):
                raise RuntimeError("capture seal write was incomplete")
        finally:
            os.close(seal_fd)
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)


def create_supervisor_result(path: str, key: bytes, context: dict[str, str], *, launched: bool, leader_exit: int | None, outcome: str, capture_seal: bool) -> None:
    """Write the one host-only child-outcome capability before descriptors close."""
    parent, name = os.path.split(path)
    if name != f"supervisor-{context['capture']}.result" or not parent:
        raise RuntimeError("supervisor result pathname is unsafe")
    if not supervisor_result_state_is_valid(
        launched=launched, leader_exit=leader_exit, outcome=outcome,
        capture_seal=capture_seal,
    ):
        raise RuntimeError("supervisor result state is unreachable")
    parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        parent_meta = os.fstat(parent_fd)
        if not stat.S_ISDIR(parent_meta.st_mode) or parent_meta.st_uid != os.getuid() or parent_meta.st_gid != os.getgid() or stat.S_IMODE(parent_meta.st_mode) != 0o700 or parent_meta.st_nlink < 2:
            raise RuntimeError("supervisor result parent is unsafe")
        document: dict[str, object] = {
            "schema": "lidswitch-supervisor-result-v1", **context,
            "launched": launched, "leader_exit": leader_exit,
            "outcome": outcome, "capture_seal": capture_seal,
        }
        document["context_sha256"] = hashlib.sha256(canonical_capture_payload(document)).hexdigest()
        document["auth_hmac"] = hmac.new(key, canonical_capture_payload(document), hashlib.sha256).hexdigest()
        payload = canonical_capture_payload(document) + b"\n"
        result_fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=parent_fd)
        try:
            metadata = os.fstat(result_fd)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_gid != os.getgid() or stat.S_IMODE(metadata.st_mode) != 0o600 or metadata.st_nlink != 1:
                raise RuntimeError("supervisor result metadata is unsafe")
            view = memoryview(payload)
            while view:
                written = os.write(result_fd, view)
                if written <= 0: raise RuntimeError("supervisor result write was incomplete")
                view = view[written:]
            os.fsync(result_fd)
            if os.fstat(result_fd).st_size != len(payload): raise RuntimeError("supervisor result write was incomplete")
        finally:
            os.close(result_fd)
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)


def parse_process_identity(value: str) -> ProcessIdentity:
    fields = value.split(":")
    if len(fields) != 3 or not all(re.fullmatch(r"[1-9][0-9]*", field) for field in fields):
        raise RuntimeError("process birth token is malformed")
    return ProcessIdentity(*(int(field, 10) for field in fields))


def main() -> None:
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("--profile")
    parser.add_argument("--stdout")
    parser.add_argument("--stderr")
    parser.add_argument("--seal")
    parser.add_argument("--result")
    parser.add_argument("--capture")
    parser.add_argument("--control-identity")
    parser.add_argument("--execution-identity")
    parser.add_argument("--nonce")
    parser.add_argument("--profile-seal")
    parser.add_argument("--source-seal")
    parser.add_argument("--cleanup-source-root")
    parser.add_argument("--cleanup-script-receipt")
    parser.add_argument("--cleanup-owner", action="store_true")
    parser.add_argument("--cleanup-leader")
    parser.add_argument("--cleanup-session-id")
    parser.add_argument("--cleanup-observed")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.cleanup_owner:
        values = (args.cleanup_leader, args.cleanup_session_id, args.cleanup_observed,
                  args.source_seal, args.cleanup_script_receipt)
        if args.command or any(value is None for value in values) or not re.fullmatch(r"[1-9][0-9]*", args.cleanup_session_id):
            parser.error("cleanup owner arguments are malformed")
        try:
            leader = parse_process_identity(args.cleanup_leader)
            observed = {parse_process_identity(value) for value in args.cleanup_observed.split(",")}
        except RuntimeError:
            parser.error("cleanup owner birth token is malformed")
        if leader not in observed:
            parser.error("cleanup owner lacks the leader birth token")
        durable_cleanup_owner(
            leader, int(args.cleanup_session_id, 10), observed,
            source_seal=args.source_seal,
            cleanup_script_receipt_value=args.cleanup_script_receipt,
        )
        return
    if any(value is None for value in (
        args.profile, args.stdout, args.stderr, args.seal, args.result,
        args.capture, args.control_identity, args.execution_identity, args.nonce,
        args.profile_seal, args.source_seal, args.cleanup_source_root,
    )):
        parser.error("supervised invocation arguments are incomplete")
    if not args.command or args.command[0] != "/usr/bin/arch":
        parser.error("the supervised command must begin with literal /usr/bin/arch")

    try:
        authentication_key = read_authentication_key()
        context = capture_context(args)
        cleanup_receipt = cleanup_script_receipt(args.cleanup_source_root, args.source_seal)
    except RuntimeError as error:
        print(f"safe process supervisor authentication failure: {error}", file=sys.stderr)
        raise SystemExit(EX_IOERR)
    # Arm flag-only handlers before any child exists.  A signal in setup is
    # observed before Popen; a signal between Popen and identity capture is
    # observed by the cleanup owner immediately after `child.pid` is known.
    install_interruption_handlers()
    launched = False
    leader_exit: int | None = None
    outcome = "setup-failed"
    capture_seal = False
    supervisor_status = EX_IOERR
    stdout: object | None = None
    stderr: object | None = None
    result_publishable = True
    close_nonstandard_fds()
    # The only child-visible egress is these exclusive regular files. Apply a
    # kernel-enforced ceiling before launching so a hostile test cannot fill
    # the execution volume through stdout/stderr.
    def output(path: str) -> object:
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        meta = os.fstat(fd)
        if not stat.S_ISREG(meta.st_mode) or meta.st_uid != os.getuid() or meta.st_gid != os.getgid() or stat.S_IMODE(meta.st_mode) != 0o600 or meta.st_nlink != 1 or meta.st_size != 0: raise RuntimeError("unsafe captured output")
        return os.fdopen(fd, "wb", buffering=0)
    try:
        try:
            resource.setrlimit(resource.RLIMIT_FSIZE, (OUTPUT_LIMIT_BYTES, OUTPUT_LIMIT_BYTES))
            stdout, stderr = output(args.stdout), output(args.stderr)
        except (OSError, RuntimeError, ValueError) as error:
            print(f"safe process supervisor setup failure: {error}", file=sys.stderr)
        else:
            if take_interruption():
                print("safe process supervisor interrupted before launch", file=sys.stderr)
            else:
                gate_read = gate_write = -1
                try:
                    gate_read, gate_write = os.pipe()
                    child = subprocess.Popen(
                        ["/usr/bin/python3", "-I", "-S", "-B", "-c", STARTUP_GATE_BOOTSTRAP,
                         str(gate_read), args.profile, *args.command],
                        close_fds=True, pass_fds=(gate_read,), start_new_session=True,
                        stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                        env=os.environ.copy(),
                    )
                except OSError as error:
                    outcome = "launch-failed"
                    print(f"safe process supervisor could not start startup gate: {error}", file=sys.stderr)
                    if gate_read >= 0:
                        close_startup_gate(gate_read)
                    if gate_write >= 0:
                        close_startup_gate(gate_write)
                else:
                    # The parent does not retain a writer-readable payload path:
                    # this pipe is the sole release authority for the fixed gate.
                    # The parent read end grants no release authority. It is
                    # best-effort closed after pass_fds duplicates it in child;
                    # only the parent write end controls payload execution.
                    close_startup_gate(gate_read)
                    gate_read = -1
                    leader = darwin_process_identity(child.pid)
                    if leader is None:
                        # Closing the gate makes the fixed bootstrap exit before
                        # sandbox-exec; wait rather than return with any child.
                        if gate_write >= 0:
                            close_startup_gate(gate_write)
                            gate_write = -1
                        reap_blocked_startup_gate(child)
                        outcome = "setup-failed"
                        result_publishable = False
                        print("safe process supervisor could not capture leader birth token", file=sys.stderr)
                        continue_cleanup = False
                    else:
                        machine = CleanupStateMachine(leader=leader, session_id=child.pid)
                        if take_interruption():
                            if gate_write >= 0:
                                close_startup_gate(gate_write)
                                gate_write = -1
                            reap_blocked_startup_gate(child)
                            outcome = "setup-failed"
                            continue_cleanup = False
                        else:
                            gate_state = release_startup_gate(gate_write, leader)
                            gate_write = -1
                            if gate_state == "blocked":
                                # No release byte was accepted: fixed gate EOFs
                                # and the payload remains unreachable.
                                reap_blocked_startup_gate(child)
                                outcome = "setup-failed"
                                continue_cleanup = False
                            else:
                                # Once a release byte may have crossed the pipe,
                                # ordinary token-bound cleanup owns the child.
                                launched = True
                                continue_cleanup = True
                                if gate_state != "released":
                                    machine.request_cleanup("startup-transition")

                    if not continue_cleanup:
                        pass
                    else:

                        def poll_leader() -> int | None:
                            return child.poll()

                        def wait_leader(timeout: float) -> int | None:
                            try:
                                return child.wait(timeout=timeout)
                            except subprocess.TimeoutExpired:
                                return None

                        def enumerate_members(observed: set[ProcessIdentity]) -> dict[int, ProcessRecord]:
                            return session_members(machine.session_id, observed)

                        def signal_direct(signum: int) -> None:
                            # Fresh token-bound records are required for a group
                            # signal.  On enumeration failure, exact PID signals
                            # remain token-gated but group broadcast is skipped.
                            try:
                                records = process_table(machine.session_id, machine.observed)
                                machine.observe_members(records)
                            except Exception:
                                records = None
                            direct_containment_signal(machine.leader, machine.session_id, machine.observed, records, signum)
                            if records is not None:
                                signal_members(records, signum)

                        contained = run_cleanup_state_machine(
                            machine,
                            poll_leader=poll_leader,
                            wait_leader=wait_leader,
                            enumerate_members=enumerate_members,
                            signal_direct=signal_direct,
                        )
                        leader_exit = machine.leader_exit
                        if not contained:
                            # An unproved cleanup never gets a result capability:
                            # wrapper-side parsing maps absent evidence to 256/74.
                            outcome = "containment-failed"
                            result_publishable = False
                            try:
                                start_durable_cleanup_owner(
                                    machine, cleanup_source_root=args.cleanup_source_root,
                                    source_seal=args.source_seal,
                                    cleanup_script_receipt_value=cleanup_receipt,
                                )
                            except Exception:
                                print("safe process supervisor could not retain durable cleanup owner", file=sys.stderr)
                            print("safe process supervisor could not prove bounded descendant absence", file=sys.stderr)
                        else:
                            outcome = machine.terminal_outcome()
                            if outcome == "completed":
                                try:
                                    create_capture_seal(args.seal, {"stdout": (stdout, args.stdout), "stderr": (stderr, args.stderr)}, authentication_key, context)
                                    capture_seal = True
                                    supervisor_status = 0
                                except (OSError, RuntimeError) as error:
                                    outcome = "capture-seal-failed"
                                    print(f"safe process supervisor capture sealing failure: {error}", file=sys.stderr)
        if result_publishable:
            published = publish_supervisor_result_if_permitted(
                permitted=True,
                publish=lambda: create_supervisor_result(
                    args.result, authentication_key, context, launched=launched,
                    leader_exit=leader_exit, outcome=outcome,
                    capture_seal=capture_seal,
                ),
            )
            if not published:
                # Result creation is deliberately before capture descriptors close:
                # it binds the supervisor's contemporaneous observation, while the
                # separately created capture seal still binds stream content.
                print("safe process supervisor result sealing failure", file=sys.stderr)
                supervisor_status = EX_IOERR
    finally:
        if stdout is not None: stdout.close()
        if stderr is not None: stderr.close()
    raise SystemExit(supervisor_status)


if __name__ == "__main__":
    main()
