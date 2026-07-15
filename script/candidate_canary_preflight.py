#!/usr/bin/python3
"""Fail-closed, observation-only receipt seam for the manual LidSwitch canary.

This tool never starts/stops LidSwitch, changes pmset, contacts launchd, or reads
private root authority.  It only observes the declared candidate and public
machine state, then writes create-once canonical receipts supplied by the
operator.  A separate binding is required because immutable-candidate v3 has
no CDHash representation and must not be silently extended.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True

ROOT = os.path.dirname(os.path.abspath(__file__))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)
from immutable_candidate_core import CandidateError, canonical, parse, validate_manifest

BINDING_SCHEMA = "lidswitch-candidate-canary-v1"
RECEIPT_SCHEMA = "lidswitch-candidate-canary-receipt-v2"
HEX = re.compile(r"[0-9a-f]{64}\Z")
CDHASH = re.compile(r"[0-9a-f]{40}\Z")
SESSION = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\Z")
SAFE_INACTIVE_REASONS = frozenset(("legacy-migration", "legacy-migration-superseded"))
PEER_DEATH_REASON = "peer-process-invalid"
LID_OPEN_HUMAN = "human-confirmed"
LID_OPEN_IOREG = "programmatic-ioreg"
IOREG_CLAMSHELL_COMMAND = ("/usr/sbin/ioreg", "-r", "-k", "AppleClamshellState", "-d", "4")
IOREG_CLAMSHELL_ROW = re.compile(
    r'^[ \t]*\|[ \t]+"AppleClamshellState"[ \t]+=[ \t]+(Yes|No)[ \t]*$',
    flags=re.MULTILINE,
)


class PreflightError(Exception):
    pass


def fail(kind: str) -> None:
    raise PreflightError(kind)


def _keys(value, expected):
    if not isinstance(value, dict) or tuple(value) != tuple(expected):
        fail("receipt-schema-invalid")
    return value


def _text(value, maximum=512):
    if not isinstance(value, str) or not value or "\x00" in value or len(value.encode("utf-8")) > maximum:
        fail("receipt-schema-invalid")
    return value


def _hex(value):
    value = _text(value, 64)
    if not HEX.fullmatch(value):
        fail("receipt-schema-invalid")
    return value


def _cdhash(value):
    value = _text(value, 40)
    if not CDHASH.fullmatch(value):
        fail("receipt-schema-invalid")
    return value


def _canonical_json(payload: bytes):
    try:
        return parse(payload)
    except CandidateError:
        fail("receipt-noncanonical")


def _read_regular(path: str, maximum=262144) -> bytes:
    if not os.path.isabs(path):
        fail("path-not-absolute")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or not 0 < before.st_size <= maximum:
            fail("receipt-identity-drift")
        chunks, left = [], before.st_size
        while left:
            try:
                chunk = os.read(fd, min(left, 65536))
            except InterruptedError:
                continue
            if not chunk:
                fail("receipt-eof")
            chunks.append(chunk)
            left -= len(chunk)
        if os.read(fd, 1) or os.fstat(fd) != before:
            fail("receipt-identity-drift")
        return b"".join(chunks)
    finally:
        os.close(fd)


def _write_new(path: str, value: dict) -> str:
    if not os.path.isabs(path):
        fail("path-not-absolute")
    payload = canonical(value)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        if os.fstat(fd).st_mode & 0o077:
            fail("receipt-mode-unsafe")
        offset = 0
        while offset < len(payload):
            written = os.write(fd, payload[offset:])
            if written <= 0:
                fail("receipt-write-failed")
            offset += written
        os.fsync(fd)
    finally:
        os.close(fd)
    return hashlib.sha256(payload).hexdigest()


def _command(argv, runner=None, accepted=(0,)) -> str:
    if runner is None:
        completed = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, encoding="utf-8", errors="strict", check=False)
        code, output = completed.returncode, completed.stdout + completed.stderr
    else:
        code, output = runner(tuple(argv))
    if code not in accepted or not isinstance(output, str):
        fail("observation-command-failed")
    return output


def _digest_at(path: str, runner=None) -> str:
    output = _command(("/usr/bin/shasum", "-a", "256", path), runner)
    match = re.fullmatch(r"([0-9a-f]{64})  .+\n?", output)
    if not match:
        fail("digest-observation-invalid")
    return match.group(1)


def _cdhash_at(path: str, runner=None) -> str:
    output = _command(("/usr/bin/codesign", "-d", "--verbose=4", path), runner)
    hits = re.findall(r"^CDHash=([0-9a-f]{40})$", output, flags=re.MULTILINE)
    if len(hits) != 1:
        fail("codesign-observation-invalid")
    return hits[0]


def _status(path: str):
    payload = _read_regular(path, 65536).decode("utf-8", "strict")
    rows = {}
    for line in payload.splitlines():
        if not line or "=" not in line:
            fail("public-status-invalid")
        key, value = line.split("=", 1)
        if not re.fullmatch(r"[a-z_]{1,64}", key) or key in rows or not value or "\x00" in value:
            fail("public-status-invalid")
        rows[key] = value
    required = ("state", "reason", "session", "updated", "boot_id", "projection_authority", "projection_generation", "projection_token", "updated_monotonic")
    if tuple(rows) != required:
        fail("public-status-invalid")
    return rows, hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _sleep_disabled(live: str) -> int:
    rows = re.findall(r"^\s*SleepDisabled\s+([01])\s*$", live, flags=re.MULTILINE)
    if len(rows) != 1:
        fail("pmset-live-invalid")
    return int(rows[0])


def _custom_sleep(custom: str):
    active = None
    result = {}
    for raw in custom.splitlines():
        line = raw.strip()
        if line in ("AC Power:", "Battery Power:"):
            active = line[:-1]
            continue
        match = re.fullmatch(r"sleep\s+([0-9]+)", line)
        if match and active:
            if active in result:
                fail("pmset-custom-invalid")
            result[active] = int(match.group(1))
    if set(result) != {"AC Power", "Battery Power"}:
        fail("pmset-custom-invalid")
    return {
        "AC Power": result["AC Power"],
        "Battery Power": result["Battery Power"],
    }


def _lid_open_observation(mode: str, runner=None):
    if mode == LID_OPEN_HUMAN:
        return {
            "method": "human-assertion",
            "state": "open",
            "property": "lid",
            "value": "open",
            "raw_sha256": "unavailable",
        }
    if mode != LID_OPEN_IOREG:
        fail("lid-open-observation-mode-invalid")
    raw = _command(IOREG_CLAMSHELL_COMMAND, runner)
    states = IOREG_CLAMSHELL_ROW.findall(raw)
    if len(states) != 1:
        fail("lid-state-observation-invalid")
    if states[0] != "No":
        fail("lid-closed")
    return {
        "method": "ioreg-AppleClamshellState",
        "state": "open",
        "property": "AppleClamshellState",
        "value": "No",
        "raw_sha256": hashlib.sha256(raw.encode("utf-8")).hexdigest(),
    }


def _validate_lid_observation(observation):
    _keys(observation, ("method", "state", "property", "value", "raw_sha256"))
    if observation == {
        "method": "human-assertion",
        "state": "open",
        "property": "lid",
        "value": "open",
        "raw_sha256": "unavailable",
    }:
        return observation
    if (
        observation.get("method") != "ioreg-AppleClamshellState"
        or observation.get("state") != "open"
        or observation.get("property") != "AppleClamshellState"
        or observation.get("value") != "No"
    ):
        fail("receipt-schema-invalid")
    _hex(observation.get("raw_sha256"))
    return observation


def _safe_idle_status(state, reason, session):
    if state == "inactive" and reason in SAFE_INACTIVE_REASONS and session == "none":
        return True
    return (
        state == "terminal"
        and reason == "legacy-migration"
        and session == session.lower()
        and SESSION.fullmatch(session) is not None
    )


def _binding(manifest_path: str, binding_path: str):
    manifest_payload = _read_regular(manifest_path)
    manifest = _canonical_json(manifest_payload)
    try:
        validate_manifest(manifest)
    except CandidateError:
        fail("candidate-manifest-invalid")
    if manifest.get("schema_version") != "lidswitch-immutable-candidate-v3":
        fail("candidate-manifest-schema-unsupported")
    binding = _canonical_json(_read_regular(binding_path))
    _keys(binding, ("schema_version", "candidate_id", "candidate_manifest_schema", "candidate_manifest_sha256", "app", "helper", "qualified_system_build", "helper_version"))
    if binding["schema_version"] != BINDING_SCHEMA or binding["candidate_manifest_schema"] != manifest["schema_version"]:
        fail("candidate-binding-invalid")
    if binding["candidate_id"] != manifest["candidate_id"] or _hex(binding["candidate_manifest_sha256"]) != hashlib.sha256(manifest_payload).hexdigest():
        fail("candidate-binding-mismatch")
    app = _keys(binding["app"], ("installed_path", "bundle_identifier", "executable_relative_path", "executable_sha256", "executable_cdhash"))
    helper = _keys(binding["helper"], ("installed_path", "sha256", "cdhash"))
    for item in (app["installed_path"], helper["installed_path"], app["bundle_identifier"], app["executable_relative_path"], binding["qualified_system_build"], binding["helper_version"]):
        _text(item)
    if not app["installed_path"].startswith("/") or not helper["installed_path"].startswith("/") or app["executable_relative_path"] != "Contents/MacOS/LidSwitch":
        fail("candidate-binding-invalid")
    _hex(app["executable_sha256"]); _cdhash(app["executable_cdhash"]); _hex(helper["sha256"]); _cdhash(helper["cdhash"])
    return manifest, binding, hashlib.sha256(_read_regular(binding_path)).hexdigest()


def _verify_installed(binding, app_bundle: str, helper: str, runner=None):
    app_binary = os.path.join(app_bundle, binding["app"]["executable_relative_path"])
    if app_bundle != binding["app"]["installed_path"] or helper != binding["helper"]["installed_path"]:
        fail("installed-path-mismatch")
    if _digest_at(app_binary, runner) != binding["app"]["executable_sha256"] or _cdhash_at(app_binary, runner) != binding["app"]["executable_cdhash"]:
        fail("installed-app-identity-mismatch")
    if _digest_at(helper, runner) != binding["helper"]["sha256"] or _cdhash_at(helper, runner) != binding["helper"]["cdhash"]:
        fail("installed-helper-identity-mismatch")


def make_binding(args, runner=None):
    """Publish a create-once binding, then consume it through the normal path."""
    manifest_payload = _read_regular(args.candidate_manifest)
    manifest = _canonical_json(manifest_payload)
    try:
        validate_manifest(manifest)
    except CandidateError:
        fail("candidate-manifest-invalid")
    if manifest.get("schema_version") != "lidswitch-immutable-candidate-v3":
        fail("candidate-manifest-schema-unsupported")
    if manifest.get("phase") not in ("package-captured", "qualified"):
        fail("candidate-manifest-not-packaged")
    if not args.app_bundle.startswith("/") or not args.helper.startswith("/"):
        fail("path-not-absolute")
    _text(args.bundle_identifier)
    if not re.fullmatch(r"[A-Za-z0-9.-]{3,255}", args.bundle_identifier):
        fail("bundle-identifier-invalid")
    if args.bundle_identifier != manifest["app"]["identifier"]:
        fail("candidate-bundle-identifier-mismatch")
    if args.executable_relative_path != "Contents/MacOS/LidSwitch":
        fail("executable-path-invalid")
    helper_version = _read_regular(args.helper_version, 256).decode("utf-8", "strict").strip()
    _text(helper_version, 128)
    app_binary = os.path.join(args.app_bundle, args.executable_relative_path)
    app_sha256, app_cdhash = _digest_at(app_binary, runner), _cdhash_at(app_binary, runner)
    helper_sha256, helper_cdhash = _digest_at(args.helper, runner), _cdhash_at(args.helper, runner)
    if app_cdhash != manifest["app"]["cdhash"]:
        fail("candidate-app-cdhash-mismatch")
    if helper_sha256 != manifest["helper"]["sha256"] or helper_cdhash != manifest["helper"]["cdhash"]:
        fail("candidate-helper-identity-mismatch")
    binding = {
        "schema_version": BINDING_SCHEMA,
        "candidate_id": manifest["candidate_id"],
        "candidate_manifest_schema": manifest["schema_version"],
        "candidate_manifest_sha256": hashlib.sha256(manifest_payload).hexdigest(),
        "app": {
            "installed_path": args.app_bundle,
            "bundle_identifier": args.bundle_identifier,
            "executable_relative_path": args.executable_relative_path,
            "executable_sha256": app_sha256,
            "executable_cdhash": app_cdhash,
        },
        "helper": {"installed_path": args.helper, "sha256": helper_sha256, "cdhash": helper_cdhash},
        "qualified_system_build": _command(("/usr/sbin/sysctl", "-n", "kern.osversion"), runner).strip(),
        "helper_version": helper_version,
    }
    _text(binding["qualified_system_build"], 128)
    _write_new(args.binding, binding)
    _, published, _ = _binding(args.candidate_manifest, args.binding)
    _verify_installed(published, args.app_bundle, args.helper, runner)


def _observe_before(args, runner=None):
    manifest, binding, binding_sha = _binding(args.candidate_manifest, args.canary_binding)
    lid_observation = _lid_open_observation(args.lid_open_observed, runner)
    _verify_installed(binding, args.app_bundle, args.helper, runner)
    if _command(("/usr/sbin/sysctl", "-n", "kern.osversion"), runner).strip() != binding["qualified_system_build"]:
        fail("system-build-mismatch")
    if _read_regular(args.helper_version, 256).decode("utf-8", "strict").strip() != binding["helper_version"]:
        fail("helper-version-mismatch")
    if _command(("/usr/bin/pgrep", "-x", "LidSwitch"), runner, accepted=(0, 1)).strip():
        fail("app-not-idle")
    batt = _command(("/usr/bin/pmset", "-g", "batt"), runner)
    live = _command(("/usr/bin/pmset", "-g", "live"), runner)
    custom = _command(("/usr/bin/pmset", "-g", "custom"), runner)
    if "Now drawing from 'AC Power'" not in batt or _sleep_disabled(live) != 0:
        fail("power-not-safe-idle")
    sleeps = _custom_sleep(custom)
    status, status_sha = _status(args.status_file)
    if os.path.lexists(args.applied_state) or not _safe_idle_status(status["state"], status["reason"], status["session"]):
        fail("active-lease-present")
    return {
        "schema_version": RECEIPT_SCHEMA,
        "phase": "preflight",
        "receipt_id": str(uuid.uuid4()),
        "created_unix": int(time.time()),
        "candidate": {"candidate_id": manifest["candidate_id"], "manifest_sha256": hashlib.sha256(_read_regular(args.candidate_manifest)).hexdigest(), "binding_sha256": binding_sha},
        "installed": {"app_sha256": binding["app"]["executable_sha256"], "app_cdhash": binding["app"]["executable_cdhash"], "helper_sha256": binding["helper"]["sha256"], "helper_cdhash": binding["helper"]["cdhash"]},
        "lid_observation": lid_observation,
        "before": {"power_source": "AC", "sleep_disabled": 0, "applied_state_present": False, "ac_sleep_minutes": sleeps["AC Power"], "battery_sleep_minutes": sleeps["Battery Power"], "pmset_batt_sha256": hashlib.sha256(batt.encode()).hexdigest(), "pmset_live_sha256": hashlib.sha256(live.encode()).hexdigest(), "pmset_custom_sha256": hashlib.sha256(custom.encode()).hexdigest(), "status_state": status["state"], "status_reason": status["reason"], "status_session": status["session"], "status_sha256": status_sha},
    }


def _load_receipt(path, phase):
    receipt = _canonical_json(_read_regular(path))
    if receipt.get("schema_version") != RECEIPT_SCHEMA or receipt.get("phase") != phase:
        fail("receipt-phase-invalid")
    if phase == "preflight":
        _keys(receipt, ("schema_version", "phase", "receipt_id", "created_unix", "candidate", "installed", "lid_observation", "before"))
        _text(receipt["receipt_id"], 64)
        if isinstance(receipt["created_unix"], bool) or not isinstance(receipt["created_unix"], int) or receipt["created_unix"] < 0:
            fail("receipt-schema-invalid")
        candidate = _keys(receipt["candidate"], ("candidate_id", "manifest_sha256", "binding_sha256"))
        _hex(candidate["candidate_id"]); _hex(candidate["manifest_sha256"]); _hex(candidate["binding_sha256"])
        installed = _keys(receipt["installed"], ("app_sha256", "app_cdhash", "helper_sha256", "helper_cdhash"))
        _hex(installed["app_sha256"]); _cdhash(installed["app_cdhash"]); _hex(installed["helper_sha256"]); _cdhash(installed["helper_cdhash"])
        _validate_lid_observation(receipt["lid_observation"])
        before = _keys(receipt["before"], ("power_source", "sleep_disabled", "applied_state_present", "ac_sleep_minutes", "battery_sleep_minutes", "pmset_batt_sha256", "pmset_live_sha256", "pmset_custom_sha256", "status_state", "status_reason", "status_session", "status_sha256"))
        if before["power_source"] != "AC" or before["sleep_disabled"] != 0 or before["applied_state_present"] is not False or not _safe_idle_status(before["status_state"], before["status_reason"], before["status_session"]):
            fail("receipt-schema-invalid")
        for name in ("pmset_batt_sha256", "pmset_live_sha256", "pmset_custom_sha256", "status_sha256"):
            _hex(before[name])
        for name in ("ac_sleep_minutes", "battery_sleep_minutes"):
            if isinstance(before[name], bool) or not isinstance(before[name], int) or before[name] < 0:
                fail("receipt-schema-invalid")
    elif phase == "active":
        _keys(receipt, ("schema_version", "phase", "preflight_receipt_sha256", "candidate", "session_uuid", "active_status_sha256", "active_sleep_disabled"))
        _hex(receipt["preflight_receipt_sha256"]); _hex(receipt["active_status_sha256"])
        candidate = _keys(receipt["candidate"], ("candidate_id", "manifest_sha256", "binding_sha256"))
        _hex(candidate["candidate_id"]); _hex(candidate["manifest_sha256"]); _hex(candidate["binding_sha256"])
        if not SESSION.fullmatch(receipt["session_uuid"]) or receipt["active_sleep_disabled"] != 1:
            fail("receipt-schema-invalid")
    return receipt, hashlib.sha256(canonical(receipt)).hexdigest()


def bind_active(preflight_path: str, active_path: str, status_path: str, manifest_path: str, binding_path: str, app_bundle: str, helper: str, runner=None):
    preflight, preflight_sha = _load_receipt(preflight_path, "preflight")
    manifest, binding, binding_sha = _binding(manifest_path, binding_path)
    if preflight["candidate"] != {"candidate_id": manifest["candidate_id"], "manifest_sha256": hashlib.sha256(_read_regular(manifest_path)).hexdigest(), "binding_sha256": binding_sha}:
        fail("candidate-receipt-mismatch")
    _verify_installed(binding, app_bundle, helper, runner)
    live = _command(("/usr/bin/pmset", "-g", "live"), runner)
    status, status_sha = _status(status_path)
    session = status["session"]
    if _sleep_disabled(live) != 1 or status["state"] != "active" or not SESSION.fullmatch(session):
        fail("active-session-unverified")
    return _write_new(active_path, {"schema_version": RECEIPT_SCHEMA, "phase": "active", "preflight_receipt_sha256": preflight_sha, "candidate": preflight["candidate"], "session_uuid": session, "active_status_sha256": status_sha, "active_sleep_disabled": 1})


def finalize(active_path: str, final_path: str, status_path: str, manifest_path: str, binding_path: str, app_bundle: str, helper: str, runner=None):
    active, active_sha = _load_receipt(active_path, "active")
    manifest, binding, binding_sha = _binding(manifest_path, binding_path)
    if active["candidate"] != {"candidate_id": manifest["candidate_id"], "manifest_sha256": hashlib.sha256(_read_regular(manifest_path)).hexdigest(), "binding_sha256": binding_sha}:
        fail("candidate-receipt-mismatch")
    _verify_installed(binding, app_bundle, helper, runner)
    live = _command(("/usr/bin/pmset", "-g", "live"), runner)
    status, status_sha = _status(status_path)
    if _sleep_disabled(live) != 0 or status["state"] != "terminal" or status["reason"] != PEER_DEATH_REASON or status["session"] != active["session_uuid"]:
        fail("rollback-or-terminal-unverified")
    return _write_new(final_path, {"schema_version": RECEIPT_SCHEMA, "phase": "final", "active_receipt_sha256": active_sha, "candidate": active["candidate"], "session_uuid": active["session_uuid"], "rollback": {"sleep_disabled": 0, "terminal_reason": PEER_DEATH_REASON, "terminal_status_sha256": status_sha, "no_rearm_observation": "validate_live_state-post-wait"}})


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    before = sub.add_parser("preflight")
    before.add_argument("--candidate-manifest", required=True); before.add_argument("--canary-binding", required=True)
    before.add_argument("--receipt", required=True); before.add_argument("--app-bundle", required=True); before.add_argument("--helper", required=True)
    before.add_argument("--helper-version", required=True); before.add_argument("--status-file", required=True); before.add_argument("--applied-state", required=True); before.add_argument("--lid-open-observed", required=True)
    produce = sub.add_parser("make-binding", help="create a canonical binding from observations only")
    produce.add_argument("--candidate-manifest", required=True); produce.add_argument("--binding", required=True)
    produce.add_argument("--app-bundle", required=True); produce.add_argument("--helper", required=True); produce.add_argument("--helper-version", required=True)
    produce.add_argument("--bundle-identifier", required=True); produce.add_argument("--executable-relative-path", required=True)
    active = sub.add_parser("bind-active")
    active.add_argument("--preflight-receipt", required=True); active.add_argument("--active-receipt", required=True); active.add_argument("--status-file", required=True); active.add_argument("--candidate-manifest", required=True); active.add_argument("--canary-binding", required=True); active.add_argument("--app-bundle", required=True); active.add_argument("--helper", required=True)
    final = sub.add_parser("finalize")
    final.add_argument("--active-receipt", required=True); final.add_argument("--final-receipt", required=True); final.add_argument("--status-file", required=True); final.add_argument("--candidate-manifest", required=True); final.add_argument("--canary-binding", required=True); final.add_argument("--app-bundle", required=True); final.add_argument("--helper", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "make-binding":
            make_binding(args)
        elif args.command == "preflight":
            _write_new(args.receipt, _observe_before(args))
        elif args.command == "bind-active":
            bind_active(args.preflight_receipt, args.active_receipt, args.status_file, args.candidate_manifest, args.canary_binding, args.app_bundle, args.helper)
        else:
            finalize(args.active_receipt, args.final_receipt, args.status_file, args.candidate_manifest, args.canary_binding, args.app_bundle, args.helper)
    except (PreflightError, CandidateError, OSError, UnicodeError) as error:
        print("candidate-canary-preflight: %s" % error, file=sys.stderr)
        return 65
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
