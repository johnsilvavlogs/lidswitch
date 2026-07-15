#!/usr/bin/python3
"""Descriptor-anchored, create-once files for the safe Swift envelope.

This helper exposes bounded control, benchmark, immutable-source, capture, and
manual ad-hoc release-publication capabilities. It never resolves a
caller-supplied symlink and never replaces a file.
"""

from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
import hmac
import json
import math
import os
import plistlib
import re
import stat
import subprocess
import sys
from typing import NoReturn


EX_DATAERR = 65
EX_IOERR = 74
PRIVATE_TMP = "/private/tmp"
SAFE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,95}\Z")
SAFE_PATH_COMPONENT = re.compile(r"[A-Za-z0-9][A-Za-z0-9 ._-]{0,95}\Z")
SNAPSHOT_INPUTS = (
    ".github/workflows/ci.yml",
    "Package.swift", "Resources", "Sources", "Tests",
    "release/GeneratedReleaseHelperTrustAnchor.template.swift",
    "release/LidSwitchLaunchDaemon.plist.template",
    "script/benchmark_baseline.sh",
    "script/live_state_envelope.sh", "script/release.env",
    "script/run_swift_build_safely.sh", "script/run_swift_tests_safely.sh",
    "script/safe_file_capability.py", "script/safe_process_supervisor.py",
    "script/swift_sandbox_common.sh", "script/swift_test_sandbox.sb.in",
    "script/validate_bundle.sh", "script/validate_live_state.sh",
    "script/validate_session_safety.sh",
)
SNAPSHOT_ROOT_NAMES = ("source", "helper-source", "app-source")
RELEASE_OUTPUT_NAME = "release-output"
RELEASE_HELPER_IDENTIFIER = "com.johnsilva.lidswitch.helper"
RELEASE_APP_IDENTIFIER = "com.johnsilva.LidSwitch"
RELEASE_ANCHOR_TEMPLATE = "release/GeneratedReleaseHelperTrustAnchor.template.swift"
RELEASE_ANCHOR_SOURCE = "Sources/LidSwitch/GeneratedReleaseHelperTrustAnchor.generated.swift"
RELEASE_IDENTITY_RESOURCE = "Resources/LidSwitchReleaseIdentity.json"
RELEASE_HELPER_PATTERN = re.compile(
    r"helper-scratch/(?:arm64-apple-macosx/)?release/LidSwitchHelper\Z"
)
RELEASE_APP_PATTERN = re.compile(
    r"app-scratch/(?:arm64-apple-macosx/)?release/LidSwitch\Z"
)
RELEASE_CAPTURE_NAMES = (
    "app-bin-path", "app-build", "helper-bin-path", "helper-build",
    "helper-identity", "helper-sign", "helper-verify",
)
BENCHMARK_SCHEMA = "lidswitch-benchmark-v3"
BENCHMARK_ALLOWED_KEYS = {
    "record_type", "schema_version", "warm_samples", "fixture_root",
    "artifact_scenarios_included", "snapshot_core_context",
    "snapshot_core_limitations", "app_bundle", "installed_helper_path",
    "artifact_validation", "helper_comparison", "operating_system",
    "architecture", "scenario", "scenario_kind", "classification",
    "sample_index", "elapsed_nanoseconds", "main_thread_elapsed_nanoseconds",
    "counters", "bundle_integrity_valid", "bundle_version_valid",
    "codesign_exit_code", "bundled_helper_path", "helper_bytes_match",
    "sample_count", "median_nanoseconds", "p95_nanoseconds",
    "sample_standard_deviation_nanoseconds", "quantile",
}
BENCHMARK_SCENARIOS = {
    "fixture.power.fast-dynamic": "fixture-fast-dynamic",
    "fixture.installation.static-hit": "fixture-static-hit",
    "fixture.installation.static-drift": "fixture-static-drift",
    "fixture.installation.force-fresh": "fixture-force-fresh",
    "fixture.power.rollback-dynamic": "fixture-rollback-dynamic",
    "fixture.activation-lease.read": "fixture",
    "fixture.activation-lease.write": "fixture",
    "fixture.desired-state.read": "fixture",
    "fixture.desired-state.write": "fixture",
    "fixture.helper-status.write": "fixture",
    "fixture.helper-status.read": "fixture",
    "fixture.helper-status.churn-static-cache-hit": "fixture-status-churn",
    "fixture.applied-state.read": "fixture",
    "fixture.applied-state.write": "fixture",
    "fixture.secure-lease.read": "fixture",
    "fixture.terminal-generations.read": "fixture",
    "fixture.terminal-generations.write": "fixture",
    "fixture.diagnostics.renewal-coalesced": "fixture",
    "controller.main-actor.refresh-scheduling": "controller-main-actor",
    "artifact.app-bundle.validation": "external-app-artifact",
    "artifact.helper-byte-comparison": "external-app-artifact",
}
BENCHMARK_COUNTERS = {
    "child_process", "child_reap_waitpid_fatal", "decoded_bytes",
    "diagnostic_write", "dynamic_snapshot", "file_fsync", "file_lstat",
    "file_open", "file_read", "file_rename", "file_write",
    "helper_byte_comparison", "inspection_artifact_validation",
    "inspection_metadata_lstat", "installation_inventory_drift_invalidated",
    "installation_inventory_drift_rejected", "installation_inventory_force_fresh",
    "installation_inventory_invalidated", "installation_inventory_published",
    "installation_inventory_stale_completion_rejected",
    "installation_inventory_static_hit", "installation_inventory_static_miss_cold",
    "installation_inventory_static_miss_drift", "installation_inventory_static_miss_expired",
    "native_cfpreferences_read", "native_iokit_read", "rollback_dynamic_snapshot",
    "xpc_authenticated_reply", "xpc_authenticated_request", "xpc_identity_ns",
}
# These are production-harness invariants, not advisory labels. Each scenario
# admits only counters emitted by its current production path; named proof
# counters remain exact while byte and descriptor work stays positive.
BENCHMARK_COUNTER_CONTRACTS = {
    "fixture.power.fast-dynamic": ({"dynamic_snapshot": 1}, {"file_read", "decoded_bytes"}, {"dynamic_snapshot", "file_read", "decoded_bytes"}),
    "fixture.installation.static-hit": ({"installation_inventory_static_hit": 1}, set(), {"installation_inventory_static_hit"}),
    "fixture.installation.static-drift": ({"installation_inventory_static_miss_drift": 1, "inspection_artifact_validation": 1, "installation_inventory_published": 1}, set(), {"installation_inventory_static_miss_drift", "inspection_artifact_validation", "installation_inventory_published"}),
    "fixture.installation.force-fresh": ({"installation_inventory_force_fresh": 1, "inspection_artifact_validation": 1, "installation_inventory_published": 1}, set(), {"installation_inventory_force_fresh", "inspection_artifact_validation", "installation_inventory_published"}),
    "fixture.power.rollback-dynamic": ({"dynamic_snapshot": 1}, {"file_read", "decoded_bytes"}, {"dynamic_snapshot", "file_read", "decoded_bytes"}),
    "fixture.activation-lease.read": ({}, {"file_open", "file_read", "decoded_bytes"}, {"file_open", "file_read", "decoded_bytes"}),
    "fixture.activation-lease.write": ({}, {"file_open", "decoded_bytes"}, {"file_open", "decoded_bytes"}),
    "fixture.desired-state.read": ({}, {"file_open", "file_read", "decoded_bytes"}, {"file_open", "file_read", "decoded_bytes"}),
    "fixture.desired-state.write": ({}, {"file_open", "decoded_bytes"}, {"file_open", "decoded_bytes"}),
    "fixture.helper-status.write": ({}, set(), set()),
    "fixture.helper-status.read": ({}, {"file_read", "decoded_bytes"}, {"file_read", "decoded_bytes"}),
    "fixture.helper-status.churn-static-cache-hit": ({"installation_inventory_static_hit": 1}, {"file_read", "decoded_bytes"}, {"installation_inventory_static_hit", "file_read", "decoded_bytes"}),
    "fixture.applied-state.read": ({}, {"file_read", "decoded_bytes"}, {"file_read", "decoded_bytes"}),
    "fixture.applied-state.write": ({"file_fsync": 1, "file_rename": 1}, {"file_open", "file_write", "decoded_bytes"}, {"file_open", "file_write", "decoded_bytes", "file_fsync", "file_rename"}),
    "fixture.secure-lease.read": ({}, {"file_read", "decoded_bytes"}, {"file_read", "decoded_bytes"}),
    "fixture.terminal-generations.read": ({}, set(), set()),
    "fixture.terminal-generations.write": ({"file_fsync": 1, "file_rename": 1}, {"file_open", "file_read", "file_write", "decoded_bytes"}, {"file_open", "file_read", "file_write", "decoded_bytes", "file_fsync", "file_rename"}),
    "fixture.diagnostics.renewal-coalesced": ({"diagnostic_write": 1}, set(), {"diagnostic_write"}),
    "controller.main-actor.refresh-scheduling": ({}, set(), set()),
    "artifact.app-bundle.validation": ({"child_process": 1}, set(), {"child_process"}),
    "artifact.helper-byte-comparison": ({"file_read": 2, "helper_byte_comparison": 1}, set(), {"file_read", "helper_byte_comparison"}),
}
BENCHMARK_STATISTICS_ABSOLUTE_TOLERANCE_NANOSECONDS = 0.000001
BENCHMARK_STATISTICS_RELATIVE_TOLERANCE = 1e-15


def fail(message: str, code: int = EX_IOERR) -> NoReturn:
    print(f"safe file capability denied: {message}", file=sys.stderr)
    raise SystemExit(code)


def exact_write(fd: int, payload: bytes) -> None:
    view = memoryview(payload)
    while view:
        try:
            written = os.write(fd, view)
        except InterruptedError:
            continue
        if written <= 0:
            fail("short write")
        view = view[written:]


def read_retry(fd: int, maximum: int) -> bytes:
    while True:
        try:
            return os.read(fd, maximum)
        except InterruptedError:
            continue


def benchmark_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            fail("benchmark JSON contains a duplicate key", EX_DATAERR)
        result[key] = value
    return result


def bounded_int(value: object, maximum: int = (1 << 63) - 1) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= maximum


def bounded_string(value: object, maximum: int = 1024) -> bool:
    return isinstance(value, str) and 0 < len(value.encode("utf-8")) <= maximum and "\x00" not in value


def validate_benchmark_record(record: dict[str, object], args: argparse.Namespace) -> None:
    if not set(record).issubset(BENCHMARK_ALLOWED_KEYS):
        fail("benchmark JSON contains an unknown key", EX_DATAERR)
    if record.get("schema_version") != BENCHMARK_SCHEMA:
        fail("benchmark JSON schema is not canonical", EX_DATAERR)
    record_type = record.get("record_type")
    common = {"record_type", "schema_version"}
    if record_type == "run":
        required = common | {"warm_samples", "fixture_root", "artifact_scenarios_included", "snapshot_core_context", "snapshot_core_limitations"}
        optional = {"app_bundle", "installed_helper_path"}
        if not required.issubset(record) or not set(record).issubset(required | optional): fail("invalid benchmark run shape", EX_DATAERR)
        if not bounded_int(record["warm_samples"], 100) or record["warm_samples"] < 5: fail("invalid benchmark sample bound", EX_DATAERR)
        if not isinstance(record["artifact_scenarios_included"], bool): fail("invalid artifact flag", EX_DATAERR)
        has_artifacts = record["artifact_scenarios_included"] is True
        if has_artifacts != (set(record) & optional == optional): fail("artifact run paths are incomplete", EX_DATAERR)
        if record["snapshot_core_context"] != "test-host": fail("invalid benchmark context", EX_DATAERR)
        expected_limitation = "Default rows are isolated fixture-backed production engines; real bundle validation and helper comparison run only with an explicit artifact contract."
        if record["snapshot_core_limitations"] != expected_limitation: fail("invalid benchmark limitation", EX_DATAERR)
        if not isinstance(record["fixture_root"], str) or not record["fixture_root"].startswith(args.source_root + "/fixtures/lidswitch-benchmark-fixture-"):
            fail("benchmark fixture root is outside the execution capability", EX_DATAERR)
        if has_artifacts and (record["app_bundle"] != args.benchmark_app or record["installed_helper_path"] != args.benchmark_helper):
            fail("benchmark artifact paths do not match the explicit capability", EX_DATAERR)
    elif record_type == "methodology":
        required = common | {"snapshot_core_context", "snapshot_core_limitations", "artifact_validation", "helper_comparison"}
        if set(record) != required: fail("invalid benchmark methodology shape", EX_DATAERR)
        expected_limitation = "Default rows are isolated fixture-backed production engines; real bundle validation and helper comparison run only with an explicit artifact contract."
        if record["snapshot_core_context"] != "test-host" or record["snapshot_core_limitations"] != expected_limitation or record["artifact_validation"] != "explicit external app only; no guessed fallback" or record["helper_comparison"] != "production exact-byte comparison against installed root helper":
            fail("invalid benchmark methodology value", EX_DATAERR)
    elif record_type == "environment":
        if set(record) != common | {"operating_system", "architecture"}: fail("invalid benchmark environment shape", EX_DATAERR)
        if not bounded_string(record["operating_system"], 256) or record["architecture"] not in {"arm64", "x86_64"}: fail("invalid benchmark environment value", EX_DATAERR)
    elif record_type == "sample":
        base = common | {"scenario", "scenario_kind", "classification", "sample_index", "elapsed_nanoseconds", "main_thread_elapsed_nanoseconds", "counters", "fixture_root"}
        scenario = record.get("scenario")
        if not isinstance(scenario, str) or scenario not in BENCHMARK_SCENARIOS or record.get("scenario_kind") != BENCHMARK_SCENARIOS[scenario]: fail("unlisted benchmark scenario", EX_DATAERR)
        extra: set[str] = set()
        if scenario == "artifact.app-bundle.validation": extra = {"app_bundle", "bundle_integrity_valid", "bundle_version_valid", "codesign_exit_code"}
        if scenario == "artifact.helper-byte-comparison": extra = {"app_bundle", "bundled_helper_path", "installed_helper_path", "helper_bytes_match"}
        if set(record) != base | extra: fail("invalid benchmark sample shape", EX_DATAERR)
        if record["classification"] not in {"cold", "warm"}: fail("invalid benchmark classification", EX_DATAERR)
        for key in ("sample_index", "elapsed_nanoseconds", "main_thread_elapsed_nanoseconds"):
            if not bounded_int(record[key]): fail("invalid benchmark integer", EX_DATAERR)
        counters = record["counters"]
        if not isinstance(counters, dict) or not set(counters).issubset(BENCHMARK_COUNTERS) or any(not bounded_int(value) for value in counters.values()):
            fail("invalid benchmark counters", EX_DATAERR)
        if not isinstance(record["fixture_root"], str) or not record["fixture_root"].startswith(args.source_root + "/fixtures/lidswitch-benchmark-fixture-"):
            fail("benchmark sample fixture root is outside the execution capability", EX_DATAERR)
        if "app_bundle" in record and record["app_bundle"] != args.benchmark_app: fail("benchmark app path drifted", EX_DATAERR)
        if "installed_helper_path" in record and record["installed_helper_path"] != args.benchmark_helper: fail("benchmark helper path drifted", EX_DATAERR)
        if "bundled_helper_path" in record and record["bundled_helper_path"] != args.benchmark_app + "/Contents/Library/LaunchServices/LidSwitchHelper": fail("bundled helper path drifted", EX_DATAERR)
        for key in ("bundle_integrity_valid", "bundle_version_valid", "helper_bytes_match"):
            if key in record and not isinstance(record[key], bool): fail("invalid artifact result type", EX_DATAERR)
        if "codesign_exit_code" in record and record["codesign_exit_code"] is not None and not bounded_int(record["codesign_exit_code"], 255): fail("invalid codesign result", EX_DATAERR)
    elif record_type == "summary":
        required = common | {"scenario", "sample_count", "median_nanoseconds", "p95_nanoseconds", "sample_standard_deviation_nanoseconds", "quantile"}
        if set(record) != required or record.get("scenario") not in BENCHMARK_SCENARIOS or record.get("quantile") != "R-7 linear interpolation": fail("invalid benchmark summary shape", EX_DATAERR)
        if not bounded_int(record["sample_count"], 100) or record["sample_count"] < 5: fail("invalid summary sample count", EX_DATAERR)
        for key in ("median_nanoseconds", "p95_nanoseconds", "sample_standard_deviation_nanoseconds"):
            if not isinstance(record[key], (int, float)) or isinstance(record[key], bool) or not (0 <= record[key] <= (1 << 63) - 1): fail("invalid summary number", EX_DATAERR)
    else:
        fail("unlisted benchmark record type", EX_DATAERR)


def validate_benchmark_jsonl(payload: bytes, args: argparse.Namespace) -> None:
    if not payload.endswith(b"\n") or b"\r" in payload or b"\x00" in payload:
        fail("benchmark JSONL framing is not canonical", EX_DATAERR)
    lines = payload[:-1].split(b"\n")
    if not lines or len(lines) > 4096 or any(not line or len(line) > 65536 for line in lines):
        fail("benchmark JSONL line bounds are invalid", EX_DATAERR)
    records: list[dict[str, object]] = []
    for encoded in lines:
        try:
            text = encoded.decode("utf-8", "strict")
            record = json.loads(text, object_pairs_hook=benchmark_object, parse_constant=lambda _: fail("non-finite benchmark number", EX_DATAERR))
        except (UnicodeDecodeError, json.JSONDecodeError):
            fail("benchmark JSONL contains invalid JSON", EX_DATAERR)
        if not isinstance(record, dict): fail("benchmark JSONL record is not an object", EX_DATAERR)
        validate_benchmark_record(record, args)
        canonical = json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)
        if canonical != text: fail("benchmark JSONL is not canonical sorted JSON", EX_DATAERR)
        records.append(record)
    validate_benchmark_corpus(records, args)


def benchmark_scenario_order(include_artifacts: bool) -> list[str]:
    scenarios = [name for name in BENCHMARK_SCENARIOS if not name.startswith("artifact.")]
    if include_artifacts:
        scenarios.extend(("artifact.app-bundle.validation", "artifact.helper-byte-comparison"))
    return scenarios


def benchmark_statistic(values: list[int], quantile: float) -> float:
    ordered = sorted(float(value) for value in values)
    position = (len(ordered) - 1) * quantile
    lower, upper = math.floor(position), math.ceil(position)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def benchmark_standard_deviation(values: list[int]) -> float:
    # Mirror BenchmarkHarness.summary exactly: UInt64 -> Double, sorted, then
    # left-to-right reduce for mean and sample variance.
    numbers = sorted(float(value) for value in values)
    total = 0.0
    for value in numbers: total += value
    mean = total / float(len(numbers))
    squared = 0.0
    for value in numbers: squared += math.pow(value - mean, 2)
    return math.sqrt(squared / float(len(numbers) - 1))


def benchmark_number_equals(actual: object, expected: float) -> bool:
    return (
        isinstance(actual, (int, float)) and not isinstance(actual, bool)
        and math.isfinite(float(actual)) and math.isclose(float(actual), expected, rel_tol=BENCHMARK_STATISTICS_RELATIVE_TOLERANCE, abs_tol=BENCHMARK_STATISTICS_ABSOLUTE_TOLERANCE_NANOSECONDS)
    )


def validate_benchmark_counter_invariants(record: dict[str, object]) -> None:
    scenario = record["scenario"]
    counters = record["counters"]
    assert isinstance(scenario, str) and isinstance(counters, dict)
    required, positive, allowed = BENCHMARK_COUNTER_CONTRACTS[scenario]
    if set(counters) != set(counters).intersection(allowed):
        fail("benchmark scenario counter key is not permitted", EX_DATAERR)
    if any(counters.get(key) != value for key, value in required.items()):
        fail("benchmark scenario counter invariant is not exact", EX_DATAERR)
    if any(not bounded_int(counters.get(key)) or counters[key] <= 0 for key in positive):
        fail("benchmark scenario counter must be positive", EX_DATAERR)


def bounded_regular(path: str, owners: set[int], maximum: int) -> tuple[int, os.stat_result]:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        fail("artifact regular file cannot be opened without following links")
    metadata = os.fstat(fd)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid not in owners or metadata.st_gid not in {0, os.getgid()} or metadata.st_nlink != 1 or metadata.st_size <= 0 or metadata.st_size > maximum or metadata.st_mode & 0o022:
        os.close(fd); fail("artifact regular-file capability is unsafe")
    return fd, metadata


def bounded_regular_at(parent_fd: int, name: str, owners: set[int], maximum: int) -> tuple[int, os.stat_result]:
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent_fd)
    except OSError:
        fail("artifact descriptor leaf cannot be opened without following links")
    metadata = os.fstat(fd)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid not in owners or metadata.st_gid not in {0, os.getgid()} or metadata.st_nlink != 1 or metadata.st_size <= 0 or metadata.st_size > maximum or metadata.st_mode & 0o022:
        os.close(fd); fail("artifact descriptor leaf is unsafe")
    return fd, metadata


SYSTEM_APPLICATION_SUPPORT = "/Library/Application Support"
SYSTEM_ADMIN_GROUP_ID = 80


def installed_helper_directory_groups(path: str) -> set[int]:
    """Allow macOS' root:admin Application Support ancestor, and only it."""
    groups = {0, os.getgid()}
    if path == SYSTEM_APPLICATION_SUPPORT:
        groups.add(SYSTEM_ADMIN_GROUP_ID)
    return groups


def bounded_directory_at(parent_fd: int, name: str, owners: set[int], *,
                         groups: set[int] | None = None) -> tuple[int, os.stat_result]:
    try:
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent_fd)
    except OSError:
        fail("artifact descriptor directory cannot be opened without following links")
    metadata = os.fstat(fd)
    allowed_groups = {0, os.getgid()} if groups is None else groups
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid not in owners or metadata.st_gid not in allowed_groups or metadata.st_nlink < 2 or metadata.st_mode & 0o022:
        os.close(fd); fail("artifact descriptor directory is unsafe")
    return fd, metadata


def bounded_descriptor_bytes(fd: int, metadata: os.stat_result, maximum: int) -> bytes:
    payload = read_exact_descriptor(fd, metadata.st_size, maximum)
    if identity9(os.fstat(fd)) != identity9(metadata):
        fail("artifact changed during bounded descriptor read")
    return payload


def descriptor_bytes_and_digest(fd: int, metadata: os.stat_result, maximum: int) -> tuple[bytes, str]:
    try:
        os.lseek(fd, 0, os.SEEK_SET)
    except OSError:
        fail("artifact descriptor cannot be rewound")
    payload = bounded_descriptor_bytes(fd, metadata, maximum)
    return payload, hashlib.sha256(payload).hexdigest()


def require_identity(fd: int, expected: tuple[int, int, int, int, int, int, int, int, int], label: str) -> os.stat_result:
    metadata = os.fstat(fd)
    if identity9(metadata) != expected:
        fail(f"artifact {label} descriptor identity changed")
    return metadata


def open_sticky_private_tmp_chain() -> tuple[int, int, int]:
    """Retain /, /private, and literal /private/tmp without path traversal."""
    try:
        root_fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        fail("filesystem root cannot be opened safely")
    root_meta = os.fstat(root_fd)
    if not stat.S_ISDIR(root_meta.st_mode) or root_meta.st_uid != 0 or root_meta.st_gid != 0 or root_meta.st_mode & 0o022:
        os.close(root_fd); fail("filesystem root capability is unsafe")
    private_fd, _ = bounded_directory_at(root_fd, "private", {0})
    try:
        try:
            tmp_fd = os.open("tmp", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=private_fd)
        except OSError:
            fail("literal /private/tmp cannot be opened without following links")
        tmp_meta = os.fstat(tmp_fd)
        if not stat.S_ISDIR(tmp_meta.st_mode) or tmp_meta.st_uid != 0 or tmp_meta.st_gid != 0 or stat.S_IMODE(tmp_meta.st_mode) != 0o1777:
            os.close(tmp_fd); fail("literal /private/tmp metadata is unsafe")
        return root_fd, private_fd, tmp_fd
    except BaseException:
        os.close(private_fd); os.close(root_fd); raise


class ArtifactTreeCapability:
    """Retained, no-follow app tree used across the external codesign boundary."""
    def __init__(self, app_path: str, owners: set[int]):
        prefix = PRIVATE_TMP + "/"
        pieces = app_path[len(prefix):].split("/") if app_path.startswith(prefix) else []
        if len(pieces) != 2 or not SAFE_NAME.fullmatch(pieces[0]) or not SAFE_NAME.fullmatch(pieces[1]) or not pieces[1].endswith(".app"):
            fail("benchmark app is not a canonical /private/tmp capability", EX_DATAERR)
        self.owners, self.parent_name, self.app_name = owners, pieces[0], pieces[1]
        self.root_fd, self.private_fd, self.tmp_fd = open_sticky_private_tmp_chain()
        self.fds: dict[str, int] = {"root": self.root_fd, "private": self.private_fd, "tmp": self.tmp_fd}
        self.identities: dict[str, tuple[int, int, int, int, int, int, int, int, int]] = {}
        try:
            # The direct benchmark artifact root is a caller-owned private
            # capability. Descendants may retain their documented safe-owner
            # flexibility, but this public intake boundary cannot be root- or
            # alternate-group-owned.
            parent_fd, parent_meta = bounded_directory_at(self.tmp_fd, self.parent_name, {os.getuid()})
            if parent_meta.st_uid != os.getuid() or parent_meta.st_gid != os.getgid() or stat.S_IMODE(parent_meta.st_mode) != 0o700:
                os.close(parent_fd); fail("benchmark app parent is not private")
            self.fds["parent"] = parent_fd
            app_fd, app_meta = bounded_directory_at(parent_fd, self.app_name, owners)
            self.fds["app"] = app_fd
            contents_fd, contents_meta = bounded_directory_at(app_fd, "Contents", owners)
            self.fds["contents"] = contents_fd
            info_fd, info_meta = bounded_regular_at(contents_fd, "Info.plist", owners, 1024 * 1024)
            self.fds["info"] = info_fd
            library_fd, library_meta = bounded_directory_at(contents_fd, "Library", owners)
            self.fds["library"] = library_fd
            launch_fd, launch_meta = bounded_directory_at(library_fd, "LaunchServices", owners)
            self.fds["launch_services"] = launch_fd
            helper_fd, helper_meta = bounded_regular_at(launch_fd, "LidSwitchHelper", owners, 64 * 1024 * 1024)
            self.fds["bundled_helper"] = helper_fd
            for name, metadata in (("root", os.fstat(self.root_fd)), ("private", os.fstat(self.private_fd)), ("tmp", os.fstat(self.tmp_fd)), ("parent", parent_meta), ("app", app_meta), ("contents", contents_meta), ("info", info_meta), ("library", library_meta), ("launch_services", launch_meta), ("bundled_helper", helper_meta)):
                self.identities[name] = identity9(metadata)
            self.info_bytes, self.info_sha256 = descriptor_bytes_and_digest(info_fd, info_meta, 1024 * 1024)
            self.helper_bytes, self.helper_sha256 = descriptor_bytes_and_digest(helper_fd, helper_meta, 64 * 1024 * 1024)
            self.reassert()
        except BaseException:
            self.close(); raise

    def close(self) -> None:
        for fd in list(getattr(self, "fds", {}).values())[::-1]:
            try: os.close(fd)
            except OSError: pass
        self.fds = {}

    def _assert_held(self) -> None:
        for name, fd in self.fds.items():
            require_identity(fd, self.identities[name], name)
        info_meta = require_identity(self.fds["info"], self.identities["info"], "Info.plist")
        helper_meta = require_identity(self.fds["bundled_helper"], self.identities["bundled_helper"], "bundled helper")
        info_bytes, info_hash = descriptor_bytes_and_digest(self.fds["info"], info_meta, 1024 * 1024)
        helper_bytes, helper_hash = descriptor_bytes_and_digest(self.fds["bundled_helper"], helper_meta, 64 * 1024 * 1024)
        if info_hash != self.info_sha256 or helper_hash != self.helper_sha256:
            fail("artifact held critical-leaf digest changed")
        if info_bytes != self.info_bytes or helper_bytes != self.helper_bytes:
            fail("artifact held critical-leaf content changed")

    def _reopened_matches(self, name: str, fd: int) -> None:
        require_identity(fd, self.identities[name], f"re-resolved {name}")

    def _reresolve(self) -> None:
        """Re-walk every retained ancestry component from its held parent."""
        opened: list[int] = []
        try:
            private_fd, _ = bounded_directory_at(self.fds["root"], "private", {0}); opened.append(private_fd); self._reopened_matches("private", private_fd)
            try:
                tmp_fd = os.open("tmp", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=private_fd)
            except OSError:
                fail("literal /private/tmp re-resolution failed")
            opened.append(tmp_fd); self._reopened_matches("tmp", tmp_fd)
            tmp_meta = os.fstat(tmp_fd)
            if tmp_meta.st_uid != 0 or tmp_meta.st_gid != 0 or stat.S_IMODE(tmp_meta.st_mode) != 0o1777:
                fail("literal /private/tmp re-resolution metadata changed")
            parent_fd, _ = bounded_directory_at(tmp_fd, self.parent_name, {os.getuid()}); opened.append(parent_fd); self._reopened_matches("parent", parent_fd)
            app_fd, _ = bounded_directory_at(parent_fd, self.app_name, self.owners); opened.append(app_fd); self._reopened_matches("app", app_fd)
            contents_fd, _ = bounded_directory_at(app_fd, "Contents", self.owners); opened.append(contents_fd); self._reopened_matches("contents", contents_fd)
            info_fd, info_meta = bounded_regular_at(contents_fd, "Info.plist", self.owners, 1024 * 1024); opened.append(info_fd); self._reopened_matches("info", info_fd)
            library_fd, _ = bounded_directory_at(contents_fd, "Library", self.owners); opened.append(library_fd); self._reopened_matches("library", library_fd)
            launch_fd, _ = bounded_directory_at(library_fd, "LaunchServices", self.owners); opened.append(launch_fd); self._reopened_matches("launch_services", launch_fd)
            helper_fd, helper_meta = bounded_regular_at(launch_fd, "LidSwitchHelper", self.owners, 64 * 1024 * 1024); opened.append(helper_fd); self._reopened_matches("bundled_helper", helper_fd)
            _, info_hash = descriptor_bytes_and_digest(info_fd, info_meta, 1024 * 1024)
            _, helper_hash = descriptor_bytes_and_digest(helper_fd, helper_meta, 64 * 1024 * 1024)
            if info_hash != self.info_sha256 or helper_hash != self.helper_sha256:
                fail("artifact re-resolved critical-leaf digest changed")
        finally:
            for fd in reversed(opened): os.close(fd)

    def reassert(self) -> None:
        self._assert_held()
        self._reresolve()

    def facts(self) -> dict[str, object]:
        self.reassert()
        return {"parents": tuple(self.identities[name] for name in ("root", "private", "tmp", "parent")), "app": self.identities["app"], "contents": self.identities["contents"], "info": self.identities["info"], "info_sha256": self.info_sha256, "library": self.identities["library"], "launch_services": self.identities["launch_services"], "bundled_helper": self.identities["bundled_helper"], "bundled_helper_sha256": self.helper_sha256, "info_bytes": self.info_bytes, "bundled_helper_bytes": self.helper_bytes}


class InstalledHelperCapability:
    """Retained no-follow absolute ancestry and helper leaf across comparison."""
    def __init__(self, path: str, owners: set[int]):
        pieces = path.split("/")[1:] if os.path.isabs(path) else []
        if len(pieces) < 2 or any(not SAFE_PATH_COMPONENT.fullmatch(piece) for piece in pieces):
            fail("artifact helper path is not canonical", EX_DATAERR)
        self.owners, self.pieces = owners, pieces
        try: root_fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        except OSError: fail("filesystem root cannot be opened safely")
        self.fds: list[int] = [root_fd]
        self.identities: list[tuple[int, int, int, int, int, int, int, int, int]] = [identity9(os.fstat(root_fd))]
        try:
            root_meta = os.fstat(root_fd)
            if root_meta.st_uid != 0 or root_meta.st_gid != 0 or root_meta.st_mode & 0o022: fail("filesystem root capability is unsafe")
            parent_fd = root_fd
            path_prefix = ""
            for piece in pieces[:-1]:
                path_prefix += "/" + piece
                child_fd, child_meta = bounded_directory_at(
                    parent_fd, piece, owners,
                    groups=installed_helper_directory_groups(path_prefix),
                )
                self.fds.append(child_fd); self.identities.append(identity9(child_meta)); parent_fd = child_fd
            leaf_fd, leaf_meta = bounded_regular_at(parent_fd, pieces[-1], owners, 64 * 1024 * 1024)
            self.fds.append(leaf_fd); self.identities.append(identity9(leaf_meta))
            self.payload, self.sha256 = descriptor_bytes_and_digest(leaf_fd, leaf_meta, 64 * 1024 * 1024)
            self.reassert()
        except BaseException:
            self.close(); raise

    def close(self) -> None:
        for fd in reversed(getattr(self, "fds", [])):
            try: os.close(fd)
            except OSError: pass
        self.fds = []

    def reassert(self) -> None:
        for index, fd in enumerate(self.fds): require_identity(fd, self.identities[index], "installed-helper ancestry")
        leaf_meta = require_identity(self.fds[-1], self.identities[-1], "installed helper")
        payload, digest = descriptor_bytes_and_digest(self.fds[-1], leaf_meta, 64 * 1024 * 1024)
        if digest != self.sha256 or payload != self.payload: fail("installed helper held content changed")
        opened: list[int] = []
        try:
            parent_fd = self.fds[0]
            path_prefix = ""
            for index, piece in enumerate(self.pieces[:-1], 1):
                path_prefix += "/" + piece
                child_fd, _ = bounded_directory_at(
                    parent_fd, piece, self.owners,
                    groups=installed_helper_directory_groups(path_prefix),
                ); opened.append(child_fd)
                require_identity(child_fd, self.identities[index], "re-resolved installed-helper ancestry")
                parent_fd = child_fd
            leaf_fd, reopened_meta = bounded_regular_at(parent_fd, self.pieces[-1], self.owners, 64 * 1024 * 1024); opened.append(leaf_fd)
            require_identity(leaf_fd, self.identities[-1], "re-resolved installed helper")
            _, digest = descriptor_bytes_and_digest(leaf_fd, reopened_meta, 64 * 1024 * 1024)
            if digest != self.sha256: fail("re-resolved installed helper digest changed")
        finally:
            for fd in reversed(opened): os.close(fd)


def release_identity(args: argparse.Namespace) -> dict[str, object]:
    root_fd = open_retained_root(args.source_root, args.source_identity)
    try:
        source_fd = os.open("source", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=root_fd)
        try:
            resources_fd, _ = bounded_directory_at(source_fd, "Resources", {os.getuid()})
            try:
                release_fd, release_meta = bounded_regular_at(resources_fd, "LidSwitchReleaseIdentity.json", {os.getuid()}, 65536)
                try:
                    return json.loads(bounded_descriptor_bytes(release_fd, release_meta, 65536).decode("utf-8"))
                finally:
                    os.close(release_fd)
            finally:
                os.close(resources_fd)
        finally:
            os.close(source_fd)
    finally:
        os.close(root_fd)


def host_artifact_truth(args: argparse.Namespace, *, codesign_runner=None, comparison_hook=None,
                        fixture_owners: set[int] | None = None,
                        fixture_helper_payload: bytes | None = None) -> dict[str, object]:
    """Independently reproduce the artifact facts the Swift harness emits.

    ``codesign_runner``, ``comparison_hook``, ``fixture_owners``, and the inert
    ``fixture_helper_payload`` are test-only seams.  The CLI
    always uses root-owned installed helpers and the fixed /usr/bin/codesign
    invocation below; no caller controls an executable, environment, or path.
    """
    owners = {0, os.getuid()} if fixture_owners is None else ({0} | fixture_owners)
    helper_owners = {0} if fixture_owners is None else ({0} | fixture_owners)
    app = ArtifactTreeCapability(args.benchmark_app, owners)
    helper = None
    fixture_helper = fixture_helper_payload is not None
    try:
        if fixture_helper:
            if fixture_owners is None or codesign_runner is None or comparison_hook is not None:
                fail("fixture helper payload is not enabled", EX_DATAERR)
            if not isinstance(fixture_helper_payload, bytes) or not 0 < len(fixture_helper_payload) <= 64 * 1024 * 1024:
                fail("fixture helper payload is unsafe", EX_DATAERR)
        else:
            helper = InstalledHelperCapability(args.benchmark_helper, helper_owners)
    except BaseException:
        app.close()
        raise
    try:
        app_facts = app.facts()
        release = release_identity(args)
        try:
            info = plistlib.loads(app_facts["info_bytes"])
        except (plistlib.InvalidFileException, ValueError):
            fail("artifact Info.plist is malformed", EX_DATAERR)
        if not isinstance(info, dict) or not isinstance(release, dict):
            fail("artifact Info.plist or release identity has an unsafe shape", EX_DATAERR)
        version = info.get("CFBundleIdentifier") == release.get("appBundleIdentifier") and info.get("CFBundleShortVersionString") == release.get("appVersion") and str(info.get("CFBundleVersion")) == str(release.get("appBuild"))
        # The exact held descriptors and their retained parent chain are
        # re-resolved immediately on both sides of the pathname-only tool.
        app.reassert()
        try:
            if codesign_runner is None:
                result = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", args.benchmark_app], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True, timeout=20, env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"})
                code = result.returncode
            else:
                code = codesign_runner(args.benchmark_app, app.reassert)
                if not isinstance(code, int) or isinstance(code, bool) or not 0 <= code <= 255:
                    fail("test codesign seam returned an invalid status")
        except (OSError, subprocess.TimeoutExpired):
            code = None
        app.reassert()
        if helper is not None:
            helper.reassert()
            if comparison_hook is not None:
                comparison_hook(args.benchmark_helper, helper.reassert)
            helper.reassert()
            helper_payload = helper.payload
        else:
            helper_payload = fixture_helper_payload
        if not isinstance(helper_payload, bytes):
            fail("artifact helper payload is unsafe", EX_DATAERR)
        helper_match = len(helper_payload) == len(app.helper_bytes) and hmac.compare_digest(helper_payload, app.helper_bytes)
        if helper is not None:
            helper.reassert()
        app.reassert()
        return {"bundle_integrity_valid": code == 0, "bundle_version_valid": version, "codesign_exit_code": code, "helper_bytes_match": helper_match}
    finally:
        if helper is not None:
            helper.close()
        app.close()


def validate_artifact_sample(record: dict[str, object], truth: dict[str, object]) -> None:
    scenario = record["scenario"]
    counters = record["counters"]
    assert isinstance(counters, dict)
    if scenario == "artifact.app-bundle.validation":
        if any(record[key] != truth[key] for key in ("bundle_integrity_valid", "bundle_version_valid", "codesign_exit_code")):
            fail("artifact bundle result contradicts host truth", EX_DATAERR)
        if record["bundle_integrity_valid"] is not True or record["bundle_version_valid"] is not True or record["codesign_exit_code"] != 0 or counters != {"child_process": 1}:
            fail("candidate artifact bundle must be host-valid and exact", EX_DATAERR)
    elif scenario == "artifact.helper-byte-comparison":
        if record["helper_bytes_match"] != truth["helper_bytes_match"]:
            fail("artifact helper comparison contradicts host truth", EX_DATAERR)
        if record["helper_bytes_match"] is not True or counters != {"file_read": 2, "helper_byte_comparison": 1}:
            fail("candidate artifact helper must be host-equal and exact", EX_DATAERR)


def validate_benchmark_corpus(records: list[dict[str, object]], args: argparse.Namespace) -> None:
    """Accept exactly the one stream emitted by BenchmarkHarness.run()."""
    if len(records) < 4 or [record["record_type"] for record in records[:3]] != ["run", "methodology", "environment"]:
        fail("benchmark control records are missing, repeated, or reordered", EX_DATAERR)
    run, methodology, environment = records[:3]
    if run["fixture_root"] == "" or not isinstance(run["fixture_root"], str):
        fail("benchmark canonical fixture root is invalid", EX_DATAERR)
    if any(record["record_type"] in {"run", "methodology", "environment"} for record in records[3:]):
        fail("benchmark control record appears outside canonical prefix", EX_DATAERR)
    if methodology["snapshot_core_context"] != run["snapshot_core_context"] or methodology["snapshot_core_limitations"] != run["snapshot_core_limitations"]:
        fail("benchmark run and methodology disagree", EX_DATAERR)
    if not isinstance(environment["operating_system"], str) or not isinstance(environment["architecture"], str):
        fail("benchmark environment contains noncanonical text", EX_DATAERR)

    include_artifacts = run["artifact_scenarios_included"] is True
    artifact_truth = host_artifact_truth(args) if include_artifacts else None
    scenarios = benchmark_scenario_order(include_artifacts)
    warm_samples = run["warm_samples"]
    assert isinstance(warm_samples, int) and not isinstance(warm_samples, bool)
    expected: list[tuple[str, str, int]] = [(scenario, "cold", 0) for scenario in scenarios]
    expected.extend((scenario, "warm", index) for index in range(1, warm_samples + 1) for scenario in scenarios)
    sample_records = [record for record in records[3:] if record["record_type"] == "sample"]
    if len(sample_records) != len(expected):
        fail("benchmark sample corpus is missing, duplicated, or oversized", EX_DATAERR)
    samples: dict[str, list[int]] = {scenario: [] for scenario in scenarios}
    for record, (scenario, classification, index) in zip(sample_records, expected):
        if (record["scenario"], record["classification"], record["sample_index"]) != (scenario, classification, index):
            fail("benchmark sample order, scenario, classification, or index is not canonical", EX_DATAERR)
        if record["fixture_root"] != run["fixture_root"]:
            fail("benchmark sample fixture root drifted", EX_DATAERR)
        validate_benchmark_counter_invariants(record)
        if artifact_truth is not None and scenario.startswith("artifact."):
            validate_artifact_sample(record, artifact_truth)
        if classification == "warm":
            samples[scenario].append(record["elapsed_nanoseconds"])

    summary_records = [record for record in records[3:] if record["record_type"] == "summary"]
    if len(summary_records) != len(scenarios):
        fail("benchmark summaries are missing, duplicated, or extra", EX_DATAERR)
    if records[3 + len(sample_records):] != summary_records:
        fail("benchmark summaries must follow every canonical sample", EX_DATAERR)
    for record, scenario in zip(summary_records, sorted(scenarios)):
        values = samples[scenario]
        if record["scenario"] != scenario or record["sample_count"] != warm_samples or len(values) != warm_samples:
            fail("benchmark summary scenario or sample count disagrees", EX_DATAERR)
        expected_median = benchmark_statistic(values, 0.5)
        expected_p95 = benchmark_statistic(values, 0.95)
        expected_deviation = benchmark_standard_deviation(values)
        if not (
            benchmark_number_equals(record["median_nanoseconds"], expected_median)
            and benchmark_number_equals(record["p95_nanoseconds"], expected_p95)
            and benchmark_number_equals(record["sample_standard_deviation_nanoseconds"], expected_deviation)
        ):
            fail("benchmark summary statistics do not equal canonical samples", EX_DATAERR)


def identity6(metadata: os.stat_result) -> tuple[int, int, int, int, int, int]:
    return (
        metadata.st_dev, metadata.st_ino, metadata.st_uid, metadata.st_gid,
        stat.S_IMODE(metadata.st_mode), metadata.st_nlink,
    )


def identity9(metadata: os.stat_result) -> tuple[int, int, int, int, int, int, int, int, int]:
    return identity6(metadata) + (metadata.st_size, metadata.st_mtime_ns, metadata.st_ctime_ns)


def private_tmp_fd() -> int:
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    try:
        fd = os.open(PRIVATE_TMP, flags)
    except OSError:
        fail("literal /private/tmp is unavailable")
    metadata = os.fstat(fd)
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != 0
        or metadata.st_gid != 0
        or stat.S_IMODE(metadata.st_mode) != 0o1777
    ):
        os.close(fd)
        fail("literal /private/tmp metadata is unsafe")
    return fd


def direct_private_child(path: str) -> str:
    prefix = PRIVATE_TMP + "/"
    if not path.startswith(prefix):
        fail("root is not below literal /private/tmp", EX_DATAERR)
    name = path[len(prefix) :]
    if not SAFE_NAME.fullmatch(name):
        fail("root is not one literal /private/tmp child", EX_DATAERR)
    return name


def parse_identity(raw: str) -> tuple[int, int, int, int, int, int]:
    pieces = raw.split(":")
    if len(pieces) != 6 or any(not piece.isdigit() for piece in pieces):
        fail("malformed retained root identity", EX_DATAERR)
    device, inode, uid, gid = (int(piece, 10) for piece in pieces[:4])
    mode, nlink = int(pieces[4], 8), int(pieces[5], 10)
    # Directories have their mandatory dot link (and may have controlled child
    # directories); exact nlink remains part of the retained identity.
    if device <= 0 or inode <= 0 or uid != os.getuid() or gid != os.getgid() or mode != 0o700 or nlink < 2:
        fail("unsafe retained root identity", EX_DATAERR)
    return device, inode, uid, gid, mode, nlink


def open_retained_root(path: str, raw_identity: str, *, allow_nlink_growth: bool = False) -> int:
    expected = parse_identity(raw_identity)
    root = private_tmp_fd()
    try:
        fd = os.open(
            direct_private_child(path),
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=root,
        )
    except OSError:
        os.close(root)
        fail("retained root cannot be opened without following links")
    os.close(root)
    metadata = os.fstat(fd)
    observed = identity6(metadata)
    identity_matches = observed == expected
    if allow_nlink_growth:
        identity_matches = observed[:5] == expected[:5] and observed[5] >= expected[5]
    if not stat.S_ISDIR(metadata.st_mode) or not identity_matches:
        os.close(fd)
        fail("retained root identity changed")
    return fd


def create_new_at(parent_fd: int, name: str) -> int:
    if not SAFE_NAME.fullmatch(name):
        fail("unsafe output filename", EX_DATAERR)
    try:
        os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        pass
    except OSError:
        fail("output target cannot be inspected")
    else:
        fail("output target already exists")
    try:
        fd = os.open(
            name,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | os.O_NOFOLLOW
            | os.O_CLOEXEC,
            0o600,
            dir_fd=parent_fd,
        )
    except OSError:
        fail("output target could not be created exclusively")
    metadata = os.fstat(fd)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or metadata.st_gid != os.getgid()
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or metadata.st_nlink != 1
        or metadata.st_size != 0
    ):
        unlink_created_if_same(parent_fd, name, fd)
        os.close(fd)
        fail("new output metadata is unsafe")
    return fd


def durable_finish(file_fd: int, parent_fd: int, expected_size: int) -> None:
    os.fsync(file_fd)
    f_fullfsync = getattr(fcntl, "F_FULLFSYNC", None)
    if f_fullfsync is None: fail("macOS F_FULLFSYNC is unavailable")
    fcntl.fcntl(file_fd, f_fullfsync)
    metadata = os.fstat(file_fd)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.getuid() or metadata.st_gid != os.getgid()
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or metadata.st_nlink != 1
        or metadata.st_size != expected_size
    ):
        fail("completed output metadata is unsafe")
    os.fsync(parent_fd)
    fcntl.fcntl(parent_fd, f_fullfsync)


def verify_named_file(parent_fd: int, name: str, file_fd: int) -> None:
    descriptor = os.fstat(file_fd)
    try:
        named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError:
        fail("completed output is no longer reachable through its retained parent")
    expected = (
        descriptor.st_dev, descriptor.st_ino, descriptor.st_mode,
        descriptor.st_uid, descriptor.st_gid, descriptor.st_nlink, descriptor.st_size,
    )
    observed = (
        named.st_dev, named.st_ino, named.st_mode,
        named.st_uid, named.st_gid, named.st_nlink, named.st_size,
    )
    if observed != expected:
        fail("completed output name no longer identifies the created file")


def unlink_created_if_same(parent_fd: int, name: str, file_fd: int) -> None:
    try:
        descriptor = os.fstat(file_fd)
        named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if (named.st_dev, named.st_ino) != (descriptor.st_dev, descriptor.st_ino):
            return
        os.unlink(name, dir_fd=parent_fd)
        os.fsync(parent_fd)
    except OSError:
        pass


def write_new(args: argparse.Namespace) -> None:
    payload = sys.stdin.buffer.read(args.max_bytes + 1)
    if len(payload) > args.max_bytes:
        fail("receipt exceeds its bounded size", EX_DATAERR)
    root_fd = open_retained_root(
        args.root, args.identity, allow_nlink_growth=args.allow_root_nlink_growth,
    )
    output_fd = -1
    created = False
    completed = False
    try:
        output_fd = create_new_at(root_fd, args.name)
        created = True
        exact_write(output_fd, payload)
        durable_finish(output_fd, root_fd, len(payload))
        verification_fd = open_retained_root(
            args.root, args.identity, allow_nlink_growth=args.allow_root_nlink_growth,
        )
        try:
            verify_named_file(verification_fd, args.name, output_fd)
        finally:
            os.close(verification_fd)
        completed = True
    finally:
        if created and not completed and output_fd >= 0:
            unlink_created_if_same(root_fd, args.name, output_fd)
        if output_fd >= 0:
            os.close(output_fd)
        os.close(root_fd)


def open_private_destination(
    path: str, raw_identity: str, *, allow_nlink_growth: bool = False,
) -> tuple[int, str]:
    parent_path, name = os.path.split(path)
    if not SAFE_NAME.fullmatch(name):
        fail("unsafe benchmark destination filename", EX_DATAERR)
    root = private_tmp_fd()
    try:
        parent_name = direct_private_child(parent_path)
        parent_fd = os.open(
            parent_name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=root,
        )
    except OSError:
        os.close(root)
        fail("benchmark destination parent is unsafe")
    os.close(root)
    metadata = os.fstat(parent_fd)
    expected = parse_identity(raw_identity)
    observed = identity6(metadata)
    mismatch = observed != expected
    if allow_nlink_growth:
        # Creating the one authorized output leaf can increase an APFS
        # directory's reported link count. Preserve every stable identity
        # field and permit only monotonic growth during the post-write reopen.
        mismatch = observed[:5] != expected[:5] or observed[5] < expected[5]
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or mismatch
    ):
        os.close(parent_fd)
        fail("benchmark destination parent must be current-user/current-group mode 0700")
    return parent_fd, name


def copy_new(args: argparse.Namespace) -> None:
    root_fd = open_retained_root(args.source_root, args.source_identity)
    try:
        try:
            benchmark_fd = os.open(
                "benchmark",
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=root_fd,
            )
        except OSError:
            fail("internal benchmark directory is unsafe")
        benchmark_meta = os.fstat(benchmark_fd)
        if (
            not stat.S_ISDIR(benchmark_meta.st_mode)
            or benchmark_meta.st_uid != os.getuid()
            or stat.S_IMODE(benchmark_meta.st_mode) != 0o700
        ):
            os.close(benchmark_fd)
            fail("internal benchmark directory metadata is unsafe")
        try:
            source_fd = os.open(
                "results.jsonl",
                os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=benchmark_fd,
            )
        except OSError:
            os.close(benchmark_fd)
            fail("internal benchmark output is missing or unsafe")
        os.close(benchmark_fd)
        source_meta = os.fstat(source_fd)
        if (
            not stat.S_ISREG(source_meta.st_mode)
            or source_meta.st_uid != os.getuid() or source_meta.st_gid != os.getgid()
            or stat.S_IMODE(source_meta.st_mode) != 0o600
            or source_meta.st_nlink != 1
            or source_meta.st_size <= 0
            or source_meta.st_size > args.max_bytes
        ):
            os.close(source_fd)
            fail("internal benchmark output metadata is unsafe")

        payload = bytearray()
        remaining = source_meta.st_size
        while remaining:
            chunk = read_retry(source_fd, min(131072, remaining))
            if not chunk:
                fail("internal benchmark output ended early")
            payload.extend(chunk)
            remaining -= len(chunk)
        if read_retry(source_fd, 1):
            fail("internal benchmark output grew during publication")
        source_after = os.fstat(source_fd)
        source_identity = lambda value: (
            value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_gid,
            value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns,
        )
        if source_identity(source_after) != source_identity(source_meta):
            fail("internal benchmark output changed during publication")
        validate_benchmark_jsonl(bytes(payload), args)

        parent_fd, name = open_private_destination(args.destination, args.destination_identity)
        output_fd = -1
        created = False
        completed = False
        try:
            output_fd = create_new_at(parent_fd, name)
            created = True
            exact_write(output_fd, payload)
            durable_finish(output_fd, parent_fd, source_meta.st_size)
            verification_fd, verification_name = open_private_destination(
                args.destination, args.destination_identity, allow_nlink_growth=True,
            )
            try:
                verify_named_file(verification_fd, verification_name, output_fd)
            finally:
                os.close(verification_fd)
            completed = True
        finally:
            if created and not completed and output_fd >= 0:
                unlink_created_if_same(parent_fd, name, output_fd)
            if output_fd >= 0:
                os.close(output_fd)
            os.close(parent_fd)
            os.close(source_fd)
    finally:
        os.close(root_fd)


def verified_directory(fd: int, *, writable: bool) -> os.stat_result:
    metadata = os.fstat(fd)
    expected_mode = 0o700 if writable else 0o555
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or metadata.st_gid != os.getgid()
        or stat.S_IMODE(metadata.st_mode) != expected_mode
        or metadata.st_nlink < 2
    ):
        fail("snapshot directory metadata is unsafe")
    return metadata


def verified_source_metadata(metadata: os.stat_result) -> None:
    if metadata.st_uid != os.getuid() or metadata.st_gid != os.getgid():
        fail("snapshot input ownership is unsafe")
    if stat.S_IMODE(metadata.st_mode) & 0o022:
        fail("snapshot input is group/world writable")
    if stat.S_ISREG(metadata.st_mode):
        if metadata.st_nlink != 1 or metadata.st_size < 0:
            fail("snapshot input regular file is multiply linked or malformed")
    elif not stat.S_ISDIR(metadata.st_mode):
        fail("snapshot input is a symlink, FIFO, device, or socket")


def open_source_at(parent_fd: int, name: str) -> tuple[int, os.stat_result]:
    try:
        before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError:
        fail("snapshot input disappeared")
    verified_source_metadata(before)
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
    if stat.S_ISDIR(before.st_mode):
        flags |= os.O_DIRECTORY
    else:
        flags |= os.O_NONBLOCK
    try:
        fd = os.open(name, flags, dir_fd=parent_fd)
    except OSError:
        fail("snapshot input cannot be opened without following links")
    after = os.fstat(fd)
    compared = lambda value: (
        value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_gid,
        value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns,
    )
    if compared(before) != compared(after):
        os.close(fd)
        fail("snapshot input changed while opening")
    return fd, after


def destination_directory_at(parent_fd: int, name: str) -> int:
    try:
        os.mkdir(name, 0o700, dir_fd=parent_fd)
    except FileExistsError:
        pass
    except OSError:
        fail("snapshot destination directory cannot be created")
    try:
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent_fd)
    except OSError:
        fail("snapshot destination directory is unsafe")
    verified_directory(fd, writable=True)
    return fd


def copy_snapshot_node(source_parent: int, destination_parent: int, name: str) -> None:
    source_fd, source_before = open_source_at(source_parent, name)
    try:
        if stat.S_ISDIR(source_before.st_mode):
            destination_fd = destination_directory_at(destination_parent, name)
            try:
                for child in sorted(os.listdir(source_fd)):
                    if child in (".", "..") or "/" in child or "\x00" in child:
                        fail("snapshot input contains an unsafe basename")
                    copy_snapshot_node(source_fd, destination_fd, child)
            finally:
                os.close(destination_fd)
            if identity9(os.fstat(source_fd)) != identity9(source_before):
                fail("snapshot input directory changed while copying")
            return
        try:
            destination_fd = os.open(
                name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                0o600,
                dir_fd=destination_parent,
            )
        except OSError:
            fail("snapshot destination file cannot be created exclusively")
        try:
            remaining = source_before.st_size
            while remaining:
                chunk = read_retry(source_fd, min(131072, remaining))
                if not chunk:
                    fail("snapshot input ended early")
                exact_write(destination_fd, chunk)
                remaining -= len(chunk)
            if read_retry(source_fd, 1):
                fail("snapshot input grew while copying")
            source_after = os.fstat(source_fd)
            stable = lambda value: (
                value.st_dev, value.st_ino, value.st_mode, value.st_uid,
                value.st_gid, value.st_nlink, value.st_size,
                value.st_mtime_ns, value.st_ctime_ns,
            )
            if stable(source_before) != stable(source_after):
                fail("snapshot input changed while copying")
            os.fchmod(destination_fd, 0o444)
            os.fsync(destination_fd)
            destination_meta = os.fstat(destination_fd)
            if (
                not stat.S_ISREG(destination_meta.st_mode)
                or destination_meta.st_uid != os.getuid()
                or destination_meta.st_gid != os.getgid()
                or stat.S_IMODE(destination_meta.st_mode) != 0o444
                or destination_meta.st_nlink != 1
                or destination_meta.st_size != source_before.st_size
            ):
                fail("snapshot destination file metadata is unsafe")
        finally:
            os.close(destination_fd)
    finally:
        os.close(source_fd)


def copy_snapshot_relative(repo_fd: int, source_root_fd: int, relative: str, required: bool) -> None:
    pieces = relative.split("/")
    source_parent = os.dup(repo_fd)
    destination_parent = os.dup(source_root_fd)
    try:
        for piece in pieces[:-1]:
            next_source, metadata = open_source_at(source_parent, piece)
            if not stat.S_ISDIR(metadata.st_mode):
                os.close(next_source)
                fail("snapshot input parent is not a directory")
            os.close(source_parent)
            source_parent = next_source
            next_destination = destination_directory_at(destination_parent, piece)
            os.close(destination_parent)
            destination_parent = next_destination
        try:
            os.stat(pieces[-1], dir_fd=source_parent, follow_symlinks=False)
        except FileNotFoundError:
            if required:
                fail("required snapshot input is missing")
            return
        except OSError:
            fail("snapshot input cannot be inspected")
        copy_snapshot_node(source_parent, destination_parent, pieces[-1])
    finally:
        os.close(source_parent)
        os.close(destination_parent)


def freeze_snapshot_tree(directory_fd: int) -> None:
    for name in sorted(os.listdir(directory_fd)):
        child_fd, metadata = open_source_at(directory_fd, name)
        try:
            if stat.S_ISDIR(metadata.st_mode):
                freeze_snapshot_tree(child_fd)
                os.fchmod(child_fd, 0o555)
            elif stat.S_IMODE(metadata.st_mode) != 0o444:
                fail("snapshot regular file was not frozen")
        finally:
            os.close(child_fd)
    os.fsync(directory_fd)


def snapshot_digest(directory_fd: int) -> str:
    digest = hashlib.sha256()
    def visit(fd: int, prefix: str) -> None:
        directory_meta = os.fstat(fd)
        if (
            not stat.S_ISDIR(directory_meta.st_mode)
            or directory_meta.st_uid != os.getuid()
            or directory_meta.st_gid != os.getgid()
            or stat.S_IMODE(directory_meta.st_mode) != 0o555
        ):
            fail("sealed snapshot directory metadata changed")
        digest.update(("R\0" + prefix + "\0" + str(identity9(directory_meta)) + "\n").encode())
        for name in sorted(os.listdir(fd)):
            child_fd, metadata = open_source_at(fd, name)
            path = name if not prefix else prefix + "/" + name
            try:
                if stat.S_ISDIR(metadata.st_mode):
                    visit(child_fd, path)
                else:
                    if stat.S_IMODE(metadata.st_mode) != 0o444 or metadata.st_nlink != 1:
                        fail("sealed snapshot file metadata changed")
                    payload_hash = hashlib.sha256()
                    remaining = metadata.st_size
                    while remaining:
                        chunk = read_retry(child_fd, min(131072, remaining))
                        if not chunk:
                            fail("sealed snapshot file ended early")
                        payload_hash.update(chunk)
                        remaining -= len(chunk)
                    if read_retry(child_fd, 1):
                        fail("sealed snapshot file grew")
                    after = os.fstat(child_fd)
                    if identity9(after) != identity9(metadata):
                        fail("sealed snapshot file identity changed")
                    digest.update(("F\0" + path + "\0" + str(identity9(metadata)) + "\0" + payload_hash.hexdigest() + "\n").encode())
            finally:
                os.close(child_fd)
        if identity9(os.fstat(fd)) != identity9(directory_meta):
            fail("sealed snapshot directory changed during verification")
    visit(directory_fd, "")
    return digest.hexdigest()


def checked_snapshot_name(value: str) -> str:
    if value not in SNAPSHOT_ROOT_NAMES:
        fail("source snapshot name is outside the fixed inventory", EX_DATAERR)
    return value


def open_snapshot_root(exec_fd: int, writable: bool, name: str = "source") -> int:
    name = checked_snapshot_name(name)
    try:
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=exec_fd)
    except OSError:
        fail("execution source snapshot is unavailable")
    verified_directory(fd, writable=writable)
    return fd


def snapshot_copy(args: argparse.Namespace) -> None:
    exec_fd = open_retained_root(args.exec_root, args.exec_identity)
    try:
        source_fd = open_snapshot_root(exec_fd, writable=True, name=args.snapshot_name)
        try:
            if os.listdir(source_fd):
                fail("execution source snapshot is not initially empty")
            try:
                repo_fd = os.dup(args.repo_fd)
            except OSError:
                fail("held repository descriptor is unavailable")
            try:
                repo_meta = os.fstat(repo_fd)
                verified_source_metadata(repo_meta)
                entries, manifest_rows = snapshot_manifest_list(args.manifest_fd, repo_fd)
                for relative in entries:
                    copy_snapshot_relative(repo_fd, source_fd, relative, True)
            finally:
                os.close(repo_fd)
            freeze_snapshot_tree(source_fd)
            os.fchmod(source_fd, 0o555)
            validate_manifest_rows(manifest_rows, source_fd, frozen=True)
        finally:
            os.close(source_fd)
        verify_fd = open_snapshot_root(exec_fd, writable=False, name=args.snapshot_name)
        try:
            print(snapshot_digest(verify_fd))
        finally:
            os.close(verify_fd)
    finally:
        os.close(exec_fd)


def snapshot_manifest_list(manifest_fd: int, repo_fd: int) -> list[str]:
    try:
        metadata = os.fstat(manifest_fd)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_gid != os.getgid() or stat.S_IMODE(metadata.st_mode) != 0o644 or metadata.st_nlink != 1 or not 0 < metadata.st_size <= 1024 * 1024:
            fail("source manifest metadata is unsafe")
        os.lseek(manifest_fd, 0, os.SEEK_SET)
        payload = bytearray()
        while len(payload) < metadata.st_size:
            chunk = os.read(manifest_fd, min(131072, metadata.st_size - len(payload)))
            if not chunk:
                fail("source manifest ended early")
            payload.extend(chunk)
        final_meta = os.fstat(manifest_fd)
        if os.read(manifest_fd, 1) or (final_meta.st_dev, final_meta.st_ino, final_meta.st_uid, final_meta.st_gid, stat.S_IMODE(final_meta.st_mode), final_meta.st_nlink, final_meta.st_size) != (metadata.st_dev, metadata.st_ino, metadata.st_uid, metadata.st_gid, stat.S_IMODE(metadata.st_mode), metadata.st_nlink, metadata.st_size):
            fail("source manifest changed")
    except OSError:
        fail("source manifest is unavailable")
    try:
        lines = bytes(payload).decode("utf-8", "strict").splitlines()
        rows = [json.loads(line) for line in lines]
    except (UnicodeDecodeError, json.JSONDecodeError):
        fail("source manifest is not canonical JSONL")
    if not rows or any(json.dumps(row, sort_keys=True, separators=(",", ":")) != line for row, line in zip(rows, lines)):
        fail("source manifest is noncanonical")
    entries = [row.get("path") for row in rows]
    required_entries = list(SNAPSHOT_INPUTS)
    if entries != sorted(entries) or len(entries) != len(set(entries)) or any(row.get("schema") != "lidswitch-source-manifest-v1" or row.get("type") not in ("file", "tree") or not isinstance(row.get("path"), str) or row["path"] not in required_entries for row in rows):
        fail("source manifest is incomplete or unsafe")
    if entries != required_entries:
        fail("snapshot inventory lacks required build, source, test, policy, or cleanup inputs")
    validate_manifest_rows(rows, repo_fd, frozen=False)
    return entries, rows


def manifest_identity(metadata: os.stat_result) -> tuple[int, int, int, int, int, int, int, int, int]:
    return (metadata.st_dev, metadata.st_ino, metadata.st_uid, metadata.st_gid,
            stat.S_IMODE(metadata.st_mode), metadata.st_nlink, metadata.st_size,
            metadata.st_mtime_ns, metadata.st_ctime_ns)


def validate_manifest_rows(rows: list[dict[str, object]], root_fd: int, *, frozen: bool) -> None:
    for row in rows:
        relative = row["path"]
        try:
            fd = os.open(relative, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=root_fd)
        except OSError:
            fail("manifest input is unavailable")
        try:
            metadata = os.fstat(fd)
            if row["type"] == "file":
                payload_hash = hashlib.sha256(); remaining = metadata.st_size
                while remaining:
                    chunk = os.read(fd, min(131072, remaining))
                    if not chunk:
                        fail("manifest input ended early")
                    payload_hash.update(chunk); remaining -= len(chunk)
                if os.read(fd, 1) or not stat.S_ISREG(metadata.st_mode) or (not frozen and stat.S_IMODE(metadata.st_mode) != row.get("mode")) or metadata.st_size != row.get("size") or payload_hash.hexdigest() != row.get("sha256") or manifest_identity(os.fstat(fd)) != manifest_identity(metadata):
                    fail("manifest file binding changed")
            else:
                if not stat.S_ISDIR(metadata.st_mode) or manifest_tree_digest(fd, relative) != row.get("sha256") or manifest_identity(os.fstat(fd)) != manifest_identity(metadata):
                    fail("manifest tree binding changed")
        finally:
            os.close(fd)


def manifest_tree_digest(directory_fd: int, prefix: str) -> str:
    digest = hashlib.sha256()
    def visit(fd: int, name: str) -> None:
        directory_meta = os.fstat(fd)
        for child_name in sorted(os.listdir(fd)):
            if child_name.startswith(".") or not re.fullmatch(r"[A-Za-z0-9._+-]{1,128}", child_name):
                fail("manifest tree contains unsafe name")
            child_fd = os.open(child_name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            try:
                metadata = os.fstat(child_fd)
                child_path = name + "/" + child_name
                if stat.S_ISDIR(metadata.st_mode):
                    visit(child_fd, child_path)
                elif stat.S_ISREG(metadata.st_mode) and metadata.st_nlink == 1 and not stat.S_IMODE(metadata.st_mode) & 0o022:
                    file_hash = hashlib.sha256(); remaining = metadata.st_size
                    while remaining:
                        chunk = os.read(child_fd, min(131072, remaining))
                        if not chunk:
                            fail("manifest tree file ended early")
                        file_hash.update(chunk); remaining -= len(chunk)
                    if os.read(child_fd, 1) or manifest_identity(os.fstat(child_fd)) != manifest_identity(metadata):
                        fail("manifest tree file grew")
                    digest.update((child_path + "|" + str(metadata.st_size) + "|" + file_hash.hexdigest() + "\n").encode("utf-8"))
                else:
                    fail("manifest tree node is unsafe")
            finally:
                os.close(child_fd)
        if manifest_identity(os.fstat(fd)) != manifest_identity(directory_meta):
            fail("manifest tree directory changed")
    visit(directory_fd, prefix)
    return digest.hexdigest()


def snapshot_verify(args: argparse.Namespace) -> None:
    if not re.fullmatch(r"[0-9a-f]{64}", args.expected_sha256):
        fail("malformed source snapshot seal", EX_DATAERR)
    exec_fd = open_retained_root(args.exec_root, args.exec_identity)
    try:
        source_fd = open_snapshot_root(exec_fd, writable=False, name=args.snapshot_name)
        try:
            if snapshot_digest(source_fd) != args.expected_sha256:
                fail("source snapshot identity or content changed")
        finally:
            os.close(source_fd)
    finally:
        os.close(exec_fd)


def release_relative_components(relative: str) -> list[str]:
    pieces = relative.split("/")
    if (
        not pieces or any(not re.fullmatch(r"[A-Za-z0-9._+-]{1,128}", piece) for piece in pieces)
        or relative.startswith("/") or "//" in relative or "/./" in relative or "/../" in relative
    ):
        fail("release relative path is unsafe", EX_DATAERR)
    return pieces


def open_relative_parent(root_fd: int, relative: str, *, writable: bool) -> tuple[int, str]:
    pieces = release_relative_components(relative)
    parent_fd = os.dup(root_fd)
    try:
        for piece in pieces[:-1]:
            next_fd = os.open(
                piece,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=parent_fd,
            )
            metadata = os.fstat(next_fd)
            mode = stat.S_IMODE(metadata.st_mode)
            if (
                not stat.S_ISDIR(metadata.st_mode)
                or metadata.st_uid != os.getuid() or metadata.st_gid != os.getgid()
                or metadata.st_nlink < 2
                or (writable and (mode & 0o022 or not mode & 0o200))
                or (not writable and mode != 0o555)
            ):
                os.close(next_fd)
                fail("release source parent metadata is unsafe")
            os.close(parent_fd)
            parent_fd = next_fd
        return parent_fd, pieces[-1]
    except BaseException:
        os.close(parent_fd)
        raise


def open_release_regular(root_fd: int, relative: str, *, frozen: bool, executable: bool,
                         maximum: int = 268435456) -> tuple[int, os.stat_result]:
    parent_fd, name = open_relative_parent(root_fd, relative, writable=False if frozen else True)
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent_fd)
    except OSError:
        os.close(parent_fd)
        fail("release input cannot be opened without following links")
    os.close(parent_fd)
    metadata = os.fstat(fd)
    mode = stat.S_IMODE(metadata.st_mode)
    expected_mode = 0o444 if frozen and not executable else None
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.getuid() or metadata.st_gid != os.getgid()
        or metadata.st_nlink != 1 or not 0 < metadata.st_size <= maximum
        or mode & 0o022
        or (expected_mode is not None and mode != expected_mode)
        or (executable and not mode & 0o111)
    ):
        os.close(fd)
        fail("release input metadata is unsafe")
    return fd, metadata


def stable_descriptor_digest(fd: int, metadata: os.stat_result, *, include_bytes: bool,
                             maximum: int = 268435456) -> tuple[str, bytes | None]:
    if not 0 < metadata.st_size <= maximum:
        fail("release input size is outside its bound")
    os.lseek(fd, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    payload = bytearray() if include_bytes else None
    remaining = metadata.st_size
    while remaining:
        chunk = read_retry(fd, min(131072, remaining))
        if not chunk:
            fail("release input ended early")
        digest.update(chunk)
        if payload is not None:
            payload.extend(chunk)
        remaining -= len(chunk)
    if read_retry(fd, 1) or identity9(os.fstat(fd)) != identity9(metadata):
        fail("release input changed while hashing")
    return digest.hexdigest(), bytes(payload) if payload is not None else None


def held_manifest_digest(manifest_fd: int) -> str:
    try:
        duplicate = os.dup(manifest_fd)
    except OSError:
        fail("held release manifest descriptor is unavailable")
    try:
        metadata = os.fstat(duplicate)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid() or metadata.st_gid != os.getgid()
            or stat.S_IMODE(metadata.st_mode) != 0o644 or metadata.st_nlink != 1
            or not 0 < metadata.st_size <= 1048576
        ):
            fail("held release manifest metadata is unsafe")
        digest, payload = stable_descriptor_digest(duplicate, metadata, include_bytes=True, maximum=1048576)
        assert payload is not None
        lines = payload.decode("utf-8", "strict").splitlines()
        rows = [json.loads(line) for line in lines]
        if (
            not payload.endswith(b"\n") or payload.endswith(b"\n\n")
            or not rows
            or any(json.dumps(row, sort_keys=True, separators=(",", ":")) != line for row, line in zip(rows, lines))
            or [row.get("path") for row in rows] != list(SNAPSHOT_INPUTS)
        ):
            fail("held release manifest is noncanonical or incomplete")
        return digest
    except (UnicodeDecodeError, json.JSONDecodeError):
        fail("held release manifest is not UTF-8 canonical JSONL")
    finally:
        os.close(duplicate)


def validate_release_identity(payload: bytes) -> dict[str, object]:
    try:
        value = json.loads(payload.decode("utf-8", "strict"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        fail("release identity resource is malformed")
    expected_keys = {
        "schemaVersion", "appVersion", "appBuild", "helperVersion",
        "xpcProtocolVersion", "enrollmentPolicyProtocolVersion", "releaseTag",
        "appBundleIdentifier", "helperLabel", "machService",
        "qualifiedSystemBuild", "channel",
    }
    if not isinstance(value, dict) or set(value) != expected_keys:
        fail("release identity resource has an unexpected schema")
    version = value.get("appVersion")
    if (
        value.get("schemaVersion") != 1
        or not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version)
        or value.get("releaseTag") != "v" + version
        or value.get("appBundleIdentifier") != RELEASE_APP_IDENTIFIER
        or value.get("helperLabel") != RELEASE_HELPER_IDENTIFIER
        or value.get("machService") != RELEASE_HELPER_IDENTIFIER + ".control"
        or value.get("channel") != "manual-ad-hoc"
        or any(not isinstance(value.get(key), int) or isinstance(value.get(key), bool) or value[key] <= 0
               for key in ("appBuild", "helperVersion", "xpcProtocolVersion", "enrollmentPolicyProtocolVersion"))
        or not isinstance(value.get("qualifiedSystemBuild"), str)
        or not re.fullmatch(r"[0-9A-Z]{3,16}", value["qualifiedSystemBuild"])
    ):
        fail("release identity resource is not the manual ad-hoc identity")
    return value


def write_frozen_file(parent_fd: int, name: str, payload: bytes, mode: int) -> None:
    if mode not in (0o444, 0o555) or not payload:
        fail("release output mode or payload is unsafe")
    fd = create_new_at(parent_fd, name)
    try:
        exact_write(fd, payload)
        os.fchmod(fd, mode)
        os.fsync(fd)
        full = getattr(fcntl, "F_FULLFSYNC", None)
        if full is None:
            fail("macOS F_FULLFSYNC is unavailable")
        fcntl.fcntl(fd, full)
        metadata = os.fstat(fd)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid() or metadata.st_gid != os.getgid()
            or stat.S_IMODE(metadata.st_mode) != mode or metadata.st_nlink != 1
            or metadata.st_size != len(payload)
        ):
            fail("frozen release output metadata is unsafe")
        verify_named_file(parent_fd, name, fd)
        os.fsync(parent_fd)
        fcntl.fcntl(parent_fd, full)
    finally:
        os.close(fd)


def copy_frozen_descriptor(parent_fd: int, name: str, source_fd: int,
                           source_meta: os.stat_result, mode: int) -> None:
    os.lseek(source_fd, 0, os.SEEK_SET)
    output_fd = create_new_at(parent_fd, name)
    try:
        remaining = source_meta.st_size
        while remaining:
            chunk = read_retry(source_fd, min(131072, remaining))
            if not chunk:
                fail("release artifact ended early while publishing")
            exact_write(output_fd, chunk)
            remaining -= len(chunk)
        if read_retry(source_fd, 1) or identity9(os.fstat(source_fd)) != identity9(source_meta):
            fail("release artifact changed while publishing")
        os.fchmod(output_fd, mode)
        os.fsync(output_fd)
        full = getattr(fcntl, "F_FULLFSYNC", None)
        if full is None:
            fail("macOS F_FULLFSYNC is unavailable")
        fcntl.fcntl(output_fd, full)
        output_meta = os.fstat(output_fd)
        if (
            not stat.S_ISREG(output_meta.st_mode)
            or output_meta.st_uid != os.getuid() or output_meta.st_gid != os.getgid()
            or stat.S_IMODE(output_meta.st_mode) != mode or output_meta.st_nlink != 1
            or output_meta.st_size != source_meta.st_size
        ):
            fail("published release artifact metadata is unsafe")
        verify_named_file(parent_fd, name, output_fd)
        os.fsync(parent_fd)
        fcntl.fcntl(parent_fd, full)
    finally:
        os.close(output_fd)


def render_release_anchor(template: bytes, helper_sha256: str, helper_size: int,
                          helper_cdhash: str, identity_sha256: str,
                          identity: dict[str, object]) -> bytes:
    try:
        text = template.decode("utf-8", "strict")
    except UnicodeDecodeError:
        fail("release trust-anchor template is not UTF-8")
    replacements = {
        "__LIDSWITCH_HELPER_SHA256_BASE64__": base64.b64encode(bytes.fromhex(helper_sha256)).decode("ascii"),
        "__LIDSWITCH_HELPER_SIZE__": str(helper_size),
        "__LIDSWITCH_HELPER_IDENTIFIER__": RELEASE_HELPER_IDENTIFIER,
        "__LIDSWITCH_HELPER_CDHASH_BASE64__": base64.b64encode(bytes.fromhex(helper_cdhash)).decode("ascii"),
        "__LIDSWITCH_RELEASE_IDENTITY_SHA256_BASE64__": base64.b64encode(bytes.fromhex(identity_sha256)).decode("ascii"),
    }
    for token, replacement in replacements.items():
        if text.count(token) != 1:
            fail("release trust-anchor template placeholder inventory changed")
        text = text.replace(token, replacement)
    if re.search(r"__LIDSWITCH_[A-Z0-9_]+__", text) or f'releaseIdentityVersion: "{identity["appVersion"]}"' not in text:
        fail("release trust-anchor template is inconsistent with release identity")
    return text.encode("utf-8")


def release_derive_source(args: argparse.Namespace) -> None:
    if (
        args.helper_identifier != RELEASE_HELPER_IDENTIFIER
        or not re.fullmatch(r"[0-9a-f]{40}", args.helper_cdhash)
        or not re.fullmatch(r"[0-9a-f]{64}", args.helper_source_seal)
        or RELEASE_HELPER_PATTERN.fullmatch(args.helper_relative) is None
    ):
        fail("measured helper identity or path is outside the release contract", EX_DATAERR)
    exec_fd = open_retained_root(args.exec_root, args.exec_identity)
    try:
        helper_source = open_snapshot_root(exec_fd, writable=False, name="helper-source")
        app_source = open_snapshot_root(exec_fd, writable=True, name="app-source")
        helper_fd = -1
        try:
            if snapshot_digest(helper_source) != args.helper_source_seal:
                fail("helper source snapshot changed before anchor generation")
            if os.listdir(app_source):
                fail("app source snapshot is not initially empty")
            for name in sorted(os.listdir(helper_source)):
                copy_snapshot_node(helper_source, app_source, name)

            helper_fd, helper_meta = open_release_regular(
                exec_fd, args.helper_relative, frozen=False, executable=True
            )
            helper_sha256, _ = stable_descriptor_digest(helper_fd, helper_meta, include_bytes=False)

            template_fd, template_meta = open_release_regular(
                helper_source, RELEASE_ANCHOR_TEMPLATE, frozen=True, executable=False, maximum=1048576
            )
            try:
                template_sha256, template = stable_descriptor_digest(
                    template_fd, template_meta, include_bytes=True, maximum=1048576
                )
            finally:
                os.close(template_fd)
            identity_fd, identity_meta = open_release_regular(
                helper_source, RELEASE_IDENTITY_RESOURCE, frozen=True, executable=False, maximum=1048576
            )
            try:
                identity_sha256, identity_payload = stable_descriptor_digest(
                    identity_fd, identity_meta, include_bytes=True, maximum=1048576
                )
            finally:
                os.close(identity_fd)
            assert template is not None and identity_payload is not None
            identity = validate_release_identity(identity_payload)
            anchor = render_release_anchor(
                template, helper_sha256, helper_meta.st_size, args.helper_cdhash,
                identity_sha256, identity,
            )
            anchor_parent, anchor_name = open_relative_parent(app_source, RELEASE_ANCHOR_SOURCE, writable=True)
            try:
                write_frozen_file(anchor_parent, anchor_name, anchor, 0o444)
            finally:
                os.close(anchor_parent)
            freeze_snapshot_tree(app_source)
            os.fchmod(app_source, 0o555)
            app_source_seal = snapshot_digest(app_source)
            manifest_sha256 = held_manifest_digest(args.manifest_fd)
            anchor_sha256 = hashlib.sha256(anchor).hexdigest()
            print(
                "schema=lidswitch-release-derive-v1\n"
                f"helper_sha256={helper_sha256}\nhelper_size={helper_meta.st_size}\n"
                f"helper_cdhash={args.helper_cdhash}\nrelease_identity_sha256={identity_sha256}\n"
                f"template_sha256={template_sha256}\nanchor_sha256={anchor_sha256}\n"
                f"manifest_sha256={manifest_sha256}\napp_source_seal={app_source_seal}"
            )
        finally:
            if helper_fd >= 0:
                os.close(helper_fd)
            os.close(app_source)
            os.close(helper_source)
    finally:
        os.close(exec_fd)


def parse_release_captures(raw: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for entry in raw.split(","):
        name, separator, value = entry.partition("=")
        if not separator or name in result or not re.fullmatch(r"[0-9a-f]{64}:[0-9a-f]{64}", value):
            fail("release capture identifier set is malformed", EX_DATAERR)
        result[name] = value
    if tuple(sorted(result)) != RELEASE_CAPTURE_NAMES:
        fail("release capture identifier set is incomplete", EX_DATAERR)
    return result


def release_output_digest(directory_fd: int) -> str:
    expected_modes = {
        "GeneratedReleaseHelperTrustAnchor.generated.swift": 0o444,
        "LidSwitch": 0o555,
        "LidSwitchHelper": 0o555,
        "build-receipt.json": 0o444,
    }
    if sorted(os.listdir(directory_fd)) != sorted(expected_modes):
        fail("frozen release output inventory changed")
    digest = hashlib.sha256()
    for name in sorted(expected_modes):
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=directory_fd)
        try:
            metadata = os.fstat(fd)
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != os.getuid() or metadata.st_gid != os.getgid()
                or stat.S_IMODE(metadata.st_mode) != expected_modes[name]
                or metadata.st_nlink != 1 or metadata.st_size <= 0
            ):
                fail("frozen release output metadata changed")
            payload_sha256, _ = stable_descriptor_digest(fd, metadata, include_bytes=False)
            digest.update(f"{name}|{metadata.st_size}|{payload_sha256}\n".encode("ascii"))
        finally:
            os.close(fd)
    return digest.hexdigest()


def open_release_output_root(exec_fd: int, *, writable: bool) -> int:
    try:
        fd = os.open(
            RELEASE_OUTPUT_NAME,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=exec_fd,
        )
    except OSError:
        fail("release output root is unavailable")
    verified_directory(fd, writable=writable)
    return fd


def release_publish(args: argparse.Namespace) -> None:
    if (
        RELEASE_HELPER_PATTERN.fullmatch(args.helper_relative) is None
        or RELEASE_APP_PATTERN.fullmatch(args.app_relative) is None
        or any(re.fullmatch(r"[0-9a-f]{64}", value) is None for value in (
            args.helper_source_seal, args.app_source_seal, args.helper_sha256,
            args.anchor_sha256, args.template_sha256, args.release_identity_sha256, args.manifest_sha256,
            args.profile_sha256, args.toolchain_seal_sha256,
        ))
        or not args.helper_size.isdigit() or int(args.helper_size) <= 0
        or not re.fullmatch(r"[0-9a-f]{40}", args.helper_cdhash)
        or args.toolchain_root != "/Library/Developer/CommandLineTools"
        or not args.toolchain_sdk.startswith(args.toolchain_root + "/SDKs/")
        or not re.fullmatch(r"[0-9:]+:swift-frontend", args.toolchain_driver_seal)
    ):
        fail("release publication arguments are malformed", EX_DATAERR)
    captures = parse_release_captures(args.capture_identifiers)
    exec_fd = open_retained_root(args.exec_root, args.exec_identity)
    helper_fd = app_fd = anchor_fd = identity_fd = template_fd = -1
    try:
        helper_source = open_snapshot_root(exec_fd, writable=False, name="helper-source")
        app_source = open_snapshot_root(exec_fd, writable=False, name="app-source")
        output_fd = open_release_output_root(exec_fd, writable=True)
        try:
            if snapshot_digest(helper_source) != args.helper_source_seal or snapshot_digest(app_source) != args.app_source_seal:
                fail("release source snapshot changed before publication")
            if os.listdir(output_fd):
                fail("release output root is not initially empty")

            helper_fd, helper_meta = open_release_regular(exec_fd, args.helper_relative, frozen=False, executable=True)
            helper_sha256, _ = stable_descriptor_digest(helper_fd, helper_meta, include_bytes=False)
            if helper_sha256 != args.helper_sha256 or helper_meta.st_size != int(args.helper_size):
                fail("signed helper changed after anchor generation")
            app_fd, app_meta = open_release_regular(exec_fd, args.app_relative, frozen=False, executable=True)
            app_sha256, _ = stable_descriptor_digest(app_fd, app_meta, include_bytes=False)
            anchor_fd, anchor_meta = open_release_regular(
                app_source, RELEASE_ANCHOR_SOURCE, frozen=True, executable=False, maximum=1048576
            )
            anchor_sha256, anchor_payload = stable_descriptor_digest(
                anchor_fd, anchor_meta, include_bytes=True, maximum=1048576
            )
            if anchor_sha256 != args.anchor_sha256:
                fail("generated release trust anchor changed")
            identity_fd, identity_meta = open_release_regular(
                app_source, RELEASE_IDENTITY_RESOURCE, frozen=True, executable=False, maximum=1048576
            )
            identity_sha256, _ = stable_descriptor_digest(
                identity_fd, identity_meta, include_bytes=False, maximum=1048576
            )
            template_fd, template_meta = open_release_regular(
                app_source, RELEASE_ANCHOR_TEMPLATE, frozen=True, executable=False, maximum=1048576
            )
            template_sha256, _ = stable_descriptor_digest(
                template_fd, template_meta, include_bytes=False, maximum=1048576
            )
            if (
                identity_sha256 != args.release_identity_sha256
                or template_sha256 != args.template_sha256
                or held_manifest_digest(args.manifest_fd) != args.manifest_sha256
            ):
                fail("release identity or base manifest changed")
            assert anchor_payload is not None

            copy_frozen_descriptor(output_fd, "LidSwitchHelper", helper_fd, helper_meta, 0o555)
            copy_frozen_descriptor(output_fd, "LidSwitch", app_fd, app_meta, 0o555)
            write_frozen_file(
                output_fd, "GeneratedReleaseHelperTrustAnchor.generated.swift", anchor_payload, 0o444
            )
            receipt = {
                "artifacts": {
                    "app": {"identifier": RELEASE_APP_IDENTIFIER, "sha256": app_sha256, "size": app_meta.st_size},
                    "helper": {
                        "cdhash": args.helper_cdhash, "identifier": RELEASE_HELPER_IDENTIFIER,
                        "sha256": helper_sha256, "signature": "adhoc",
                        "size": helper_meta.st_size, "teamIdentifier": None, "timestamp": None,
                    },
                },
                "build": {
                    "configuration": "release", "network": False,
                    "paidLicenses": [], "releaseCandidateDefine": True,
                    "signing": "manual-ad-hoc", "stages": ["helper", "app"],
                },
                "captures": captures,
                "inputs": {
                    "appSourceSeal": args.app_source_seal,
                    "baseManifestSHA256": args.manifest_sha256,
                    "generatedAnchorSHA256": anchor_sha256,
                    "helperSourceSeal": args.helper_source_seal,
                    "releaseIdentitySHA256": identity_sha256,
                    "trustAnchorTemplateSHA256": args.template_sha256,
                },
                "schema": "lidswitch-held-release-build-v1",
                "toolchain": {
                    "componentSealSHA256": args.toolchain_seal_sha256,
                    "driverIdentity": args.toolchain_driver_seal,
                    "profileSHA256": args.profile_sha256,
                    "root": args.toolchain_root, "sdk": args.toolchain_sdk,
                },
            }
            receipt_payload = json.dumps(receipt, sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"
            write_frozen_file(output_fd, "build-receipt.json", receipt_payload, 0o444)
            os.fsync(output_fd)
            os.fchmod(output_fd, 0o555)
            os.fsync(output_fd)
            full = getattr(fcntl, "F_FULLFSYNC", None)
            if full is None:
                fail("macOS F_FULLFSYNC is unavailable")
            fcntl.fcntl(output_fd, full)
            seal = release_output_digest(output_fd)
            print(
                "schema=lidswitch-release-output-v1\n"
                f"release_output={args.exec_root}/{RELEASE_OUTPUT_NAME}\n"
                f"release_output_seal={seal}\napp_sha256={app_sha256}\napp_size={app_meta.st_size}"
            )
        finally:
            if output_fd >= 0:
                os.close(output_fd)
            os.close(app_source)
            os.close(helper_source)
    finally:
        for fd in (template_fd, identity_fd, anchor_fd, app_fd, helper_fd):
            if fd >= 0:
                os.close(fd)
        os.close(exec_fd)


def read_exact_descriptor(fd: int, size: int, maximum: int) -> bytes:
    if size < 0 or size > maximum:
        fail("sealed capture size is outside its bound", EX_DATAERR)
    payload = bytearray()
    while len(payload) < size:
        chunk = read_retry(fd, min(131072, size - len(payload)))
        if not chunk:
            fail("sealed capture ended early")
        payload.extend(chunk)
    if read_retry(fd, 1):
        fail("sealed capture grew while reopening")
    return bytes(payload)


def capture_seal_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    return benchmark_object(pairs)


def supervisor_result_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    return benchmark_object(pairs)


SUPERVISOR_RESULT_OUTCOMES = frozenset({
    "completed", "setup-failed", "launch-failed", "containment-failed",
    "capture-seal-failed", "interrupted",
})


def supervisor_result_state_is_valid(*, launched: object, leader_exit: object,
                                     outcome: object, capture_seal: object) -> bool:
    """Mirror the producer's reachable authenticated result matrix.

    Post-launch evidence is emitted only after reaping the leader and proving
    stable descendant absence.  Therefore an unavailable exit is represented
    by an absent/invalid result at the wrapper boundary, not an invented tuple.
    """
    if not isinstance(launched, bool) or not isinstance(capture_seal, bool):
        return False
    if outcome not in SUPERVISOR_RESULT_OUTCOMES:
        return False
    valid_exit = isinstance(leader_exit, int) and not isinstance(leader_exit, bool) and 0 <= leader_exit <= 255
    if outcome in {"setup-failed", "launch-failed"}:
        return launched is False and leader_exit is None and capture_seal is False
    if not launched or not valid_exit:
        return False
    if outcome == "completed":
        return capture_seal is True
    return capture_seal is False


def capture_authentication_key_from_bytes(encoded: bytes) -> bytes:
    if len(encoded) != 65 or not encoded.endswith(b"\n") or not re.fullmatch(rb"[0-9a-f]{64}\n", encoded):
        fail("capture authentication key is malformed", EX_DATAERR)
    return bytes.fromhex(encoded[:-1].decode("ascii"))


def read_capture_authentication_key() -> bytes:
    return capture_authentication_key_from_bytes(sys.stdin.buffer.read(65))


def canonical_capture_payload(document: dict[str, object]) -> bytes:
    return json.dumps(document, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode("utf-8")


def sealed_capture_entry(value: object) -> dict[str, object]:
    keys = {"dev", "gid", "inode", "mode", "nlink", "sha256", "size", "uid"}
    if not isinstance(value, dict) or set(value) != keys:
        fail("capture seal entry shape is unsafe", EX_DATAERR)
    for key in keys - {"sha256"}:
        if not bounded_int(value[key]):
            fail("capture seal integer is unsafe", EX_DATAERR)
    if value["dev"] <= 0 or value["inode"] <= 0 or value["uid"] != os.getuid() or value["gid"] != os.getgid() or value["mode"] != 0o600 or value["nlink"] != 1 or value["size"] > 16 * 1024 * 1024:
        fail("capture seal metadata is unsafe", EX_DATAERR)
    if not isinstance(value["sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", value["sha256"]):
        fail("capture seal digest is unsafe", EX_DATAERR)
    return value


def open_sealed_capture(args: argparse.Namespace, authentication_key: bytes | None = None) -> tuple[int, dict[str, object], dict[str, object]]:
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", args.capture) or args.stream not in {"stdout", "stderr"}:
        fail("capture selector is unsafe", EX_DATAERR)
    control_fd = open_retained_root(args.control_root, args.control_identity, allow_nlink_growth=True)
    try:
        try:
            seal_fd = os.open(f"capture-{args.capture}.seal", os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=control_fd)
        except OSError:
            fail("capture seal cannot be opened without following links")
        try:
            seal_meta = os.fstat(seal_fd)
            if not stat.S_ISREG(seal_meta.st_mode) or seal_meta.st_uid != os.getuid() or seal_meta.st_gid != os.getgid() or stat.S_IMODE(seal_meta.st_mode) != 0o600 or seal_meta.st_nlink != 1 or seal_meta.st_size <= 0 or seal_meta.st_size > 8192:
                fail("capture seal file metadata is unsafe")
            seal_payload = read_exact_descriptor(seal_fd, seal_meta.st_size, 8192)
            if os.fstat(seal_fd).st_size != seal_meta.st_size:
                fail("capture seal changed while reading")
        finally:
            os.close(seal_fd)
    finally:
        os.close(control_fd)
    try:
        text = seal_payload.decode("utf-8", "strict")
        if not text.endswith("\n"):
            fail("capture seal framing is noncanonical", EX_DATAERR)
        seal = json.loads(text[:-1], object_pairs_hook=capture_seal_object, parse_constant=lambda _: fail("capture seal contains non-finite number", EX_DATAERR))
    except (UnicodeDecodeError, json.JSONDecodeError):
        fail("capture seal JSON is malformed", EX_DATAERR)
    required = {"schema", "capture", "control_identity", "execution_identity", "nonce", "profile_seal", "source_seal", "context_sha256", "auth_hmac", "stdout", "stderr"}
    if not isinstance(seal, dict) or set(seal) != required or seal.get("schema") != "lidswitch-capture-seal-v2":
        fail("capture seal schema is unsafe", EX_DATAERR)
    if canonical_capture_payload(seal).decode("utf-8") + "\n" != text:
        fail("capture seal JSON is not canonical", EX_DATAERR)
    expected_context = {
        "capture": args.capture, "control_identity": args.control_identity,
        "execution_identity": args.exec_identity, "nonce": args.nonce,
        "profile_seal": args.profile_seal, "source_seal": args.source_seal,
    }
    if any(seal.get(key) != value for key, value in expected_context.items()):
        fail("capture seal context does not match this wrapper", EX_DATAERR)
    if not isinstance(seal["context_sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", seal["context_sha256"]):
        fail("capture seal context identifier is malformed", EX_DATAERR)
    unsigned = dict(seal); supplied_hmac = unsigned.pop("auth_hmac")
    if not isinstance(supplied_hmac, str) or not re.fullmatch(r"[0-9a-f]{64}", supplied_hmac):
        fail("capture seal authentication is malformed", EX_DATAERR)
    context_document = dict(unsigned); context_document.pop("context_sha256")
    expected_context_sha256 = hashlib.sha256(canonical_capture_payload(context_document)).hexdigest()
    if not hmac.compare_digest(seal["context_sha256"], expected_context_sha256):
        fail("capture seal context identifier does not match", EX_DATAERR)
    key = read_capture_authentication_key() if authentication_key is None else authentication_key
    if not isinstance(key, bytes) or len(key) != 32:
        fail("capture authentication key is malformed", EX_DATAERR)
    if not hmac.compare_digest(supplied_hmac, hmac.new(key, canonical_capture_payload(unsigned), hashlib.sha256).hexdigest()):
        fail("capture seal HMAC authentication failed", EX_DATAERR)
    entry = sealed_capture_entry(seal[args.stream])
    exec_fd = open_retained_root(args.exec_root, args.exec_identity)
    try:
        try:
            logs_fd = os.open("logs", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=exec_fd)
        except OSError:
            fail("capture log directory cannot be opened without following links")
        try:
            logs_meta = os.fstat(logs_fd)
            if not stat.S_ISDIR(logs_meta.st_mode) or logs_meta.st_uid != os.getuid() or logs_meta.st_gid != os.getgid() or stat.S_IMODE(logs_meta.st_mode) != 0o700:
                fail("capture logs directory is unsafe")
            try:
                capture_fd = os.open(f"{args.capture}.{args.stream}", os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=logs_fd)
            except OSError:
                fail("capture stream cannot be opened without following links")
        finally:
            os.close(logs_fd)
    finally:
        os.close(exec_fd)
    metadata = os.fstat(capture_fd)
    observed = {"dev": metadata.st_dev, "gid": metadata.st_gid, "inode": metadata.st_ino, "mode": stat.S_IMODE(metadata.st_mode), "nlink": metadata.st_nlink, "size": metadata.st_size, "uid": metadata.st_uid}
    if observed != {key: entry[key] for key in observed}:
        os.close(capture_fd)
        fail("capture no-follow reopen identity does not match host seal")
    return capture_fd, entry, seal


def capture_verify(args: argparse.Namespace, authentication_key: bytes | None = None) -> None:
    capture_fd, entry, _ = open_sealed_capture(args, authentication_key)
    try:
        payload = read_exact_descriptor(capture_fd, int(entry["size"]), 16 * 1024 * 1024)
        if hashlib.sha256(payload).hexdigest() != entry["sha256"] or os.fstat(capture_fd).st_size != entry["size"]:
            fail("capture content does not match host seal")
    finally:
        os.close(capture_fd)


def capture_read(args: argparse.Namespace, authentication_key: bytes | None = None, output_fd: int | None = None) -> None:
    capture_fd, entry, _ = open_sealed_capture(args, authentication_key)
    try:
        payload = read_exact_descriptor(capture_fd, int(entry["size"]), 16 * 1024 * 1024)
        if hashlib.sha256(payload).hexdigest() != entry["sha256"] or os.fstat(capture_fd).st_size != entry["size"]:
            fail("capture content does not match host seal")
        exact_write(sys.stdout.fileno() if output_fd is None else output_fd, payload)
    finally:
        os.close(capture_fd)


def capture_identifier(args: argparse.Namespace) -> None:
    capture_fd, _, seal = open_sealed_capture(args)
    try:
        # open_sealed_capture has already authenticated the exact seal and
        # context; return only nonsecret correlation identifiers for receipts.
        pass
    finally:
        os.close(capture_fd)
    print(f"{seal['context_sha256']}:{seal['auth_hmac']}")


def open_supervisor_result(args: argparse.Namespace, authentication_key: bytes | None = None) -> dict[str, object]:
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", args.capture):
        fail("supervisor result selector is unsafe", EX_DATAERR)
    control_fd = open_retained_root(args.control_root, args.control_identity, allow_nlink_growth=True)
    try:
        try:
            result_fd = os.open(f"supervisor-{args.capture}.result", os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=control_fd)
        except OSError:
            fail("supervisor result cannot be opened without following links")
        try:
            metadata = os.fstat(result_fd)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_gid != os.getgid() or stat.S_IMODE(metadata.st_mode) != 0o600 or metadata.st_nlink != 1 or metadata.st_size <= 0 or metadata.st_size > 4096:
                fail("supervisor result file metadata is unsafe")
            payload = read_exact_descriptor(result_fd, metadata.st_size, 4096)
            if os.fstat(result_fd).st_size != metadata.st_size: fail("supervisor result changed while reading")
        finally:
            os.close(result_fd)
    finally:
        os.close(control_fd)
    try:
        text = payload.decode("utf-8", "strict")
        if not text.endswith("\n"): fail("supervisor result framing is noncanonical", EX_DATAERR)
        result = json.loads(text[:-1], object_pairs_hook=supervisor_result_object, parse_constant=lambda _: fail("supervisor result contains non-finite number", EX_DATAERR))
    except (UnicodeDecodeError, json.JSONDecodeError):
        fail("supervisor result JSON is malformed", EX_DATAERR)
    required = {"schema", "capture", "control_identity", "execution_identity", "nonce", "profile_seal", "source_seal", "launched", "leader_exit", "outcome", "capture_seal", "context_sha256", "auth_hmac"}
    if not isinstance(result, dict) or set(result) != required or result.get("schema") != "lidswitch-supervisor-result-v1":
        fail("supervisor result schema is unsafe", EX_DATAERR)
    if canonical_capture_payload(result).decode("utf-8") + "\n" != text: fail("supervisor result JSON is not canonical", EX_DATAERR)
    expected_context = {"capture": args.capture, "control_identity": args.control_identity, "execution_identity": args.exec_identity, "nonce": args.nonce, "profile_seal": args.profile_seal, "source_seal": args.source_seal}
    if any(result.get(key) != value for key, value in expected_context.items()): fail("supervisor result context does not match this wrapper", EX_DATAERR)
    unsigned = dict(result); supplied_hmac = unsigned.pop("auth_hmac")
    if not isinstance(supplied_hmac, str) or not re.fullmatch(r"[0-9a-f]{64}", supplied_hmac): fail("supervisor result authentication is malformed", EX_DATAERR)
    context_document = dict(unsigned); context_document.pop("context_sha256")
    expected_context_sha256 = hashlib.sha256(canonical_capture_payload(context_document)).hexdigest()
    if not isinstance(result["context_sha256"], str) or not hmac.compare_digest(result["context_sha256"], expected_context_sha256): fail("supervisor result context identifier does not match", EX_DATAERR)
    key = read_capture_authentication_key() if authentication_key is None else authentication_key
    if not isinstance(key, bytes) or len(key) != 32 or not hmac.compare_digest(supplied_hmac, hmac.new(key, canonical_capture_payload(unsigned), hashlib.sha256).hexdigest()): fail("supervisor result HMAC authentication failed", EX_DATAERR)
    if not supervisor_result_state_is_valid(
        launched=result["launched"], leader_exit=result["leader_exit"],
        outcome=result["outcome"], capture_seal=result["capture_seal"],
    ):
        fail("supervisor result state is unreachable", EX_DATAERR)
    return result


def supervisor_wrapper_mapping(result: dict[str, object]) -> tuple[int, bool]:
    """The authenticated child/wrapper boundary consumed by both shell wrappers."""
    if not supervisor_result_state_is_valid(
        launched=result.get("launched"), leader_exit=result.get("leader_exit"),
        outcome=result.get("outcome"), capture_seal=result.get("capture_seal"),
    ):
        fail("supervisor result cannot map to wrapper status", EX_DATAERR)
    child_exit = result["leader_exit"] if result["launched"] else 256
    if not bounded_int(child_exit, 256):
        fail("supervisor result mapped child exit is unsafe", EX_DATAERR)
    completed = result["outcome"] == "completed"
    return int(child_exit), completed


def supervisor_result(args: argparse.Namespace, authentication_key: bytes | None = None) -> None:
    result = open_supervisor_result(args, authentication_key)
    leader_exit = "none" if result["leader_exit"] is None else str(result["leader_exit"])
    child_exit, completed = supervisor_wrapper_mapping(result)
    print(f"launched={'true' if result['launched'] else 'false'}\nleader_exit={leader_exit}\noutcome={result['outcome']}\ncapture_seal={'true' if result['capture_seal'] else 'false'}\nchild_command_exit={child_exit}\ncompleted={'true' if completed else 'false'}")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(allow_abbrev=False)
    commands = result.add_subparsers(dest="command", required=True)
    write = commands.add_parser("write-new", allow_abbrev=False)
    write.add_argument("--root", required=True)
    write.add_argument("--identity", required=True)
    write.add_argument("--name", required=True)
    write.add_argument("--max-bytes", type=int, default=65536)
    write.add_argument("--allow-root-nlink-growth", action="store_true")
    write.set_defaults(action=write_new)
    copy = commands.add_parser("copy-new", allow_abbrev=False)
    copy.add_argument("--source-root", required=True)
    copy.add_argument("--source-identity", required=True)
    copy.add_argument("--destination", required=True)
    copy.add_argument("--destination-identity", required=True)
    copy.add_argument("--benchmark-app", required=True)
    copy.add_argument("--benchmark-helper", required=True)
    copy.add_argument("--max-bytes", type=int, default=33554432)
    copy.set_defaults(action=copy_new)
    snapshot = commands.add_parser("snapshot-copy", allow_abbrev=False)
    snapshot.add_argument("--repo-fd", type=int, required=True)
    snapshot.add_argument("--manifest-fd", type=int, required=True)
    snapshot.add_argument("--exec-root", required=True)
    snapshot.add_argument("--exec-identity", required=True)
    snapshot.add_argument("--snapshot-name", choices=SNAPSHOT_ROOT_NAMES, default="source")
    snapshot.set_defaults(action=snapshot_copy)
    verify = commands.add_parser("snapshot-verify", allow_abbrev=False)
    verify.add_argument("--exec-root", required=True)
    verify.add_argument("--exec-identity", required=True)
    verify.add_argument("--expected-sha256", required=True)
    verify.add_argument("--snapshot-name", choices=SNAPSHOT_ROOT_NAMES, default="source")
    verify.set_defaults(action=snapshot_verify)
    derive = commands.add_parser("release-derive-source", allow_abbrev=False)
    derive.add_argument("--exec-root", required=True)
    derive.add_argument("--exec-identity", required=True)
    derive.add_argument("--manifest-fd", type=int, required=True)
    derive.add_argument("--helper-source-seal", required=True)
    derive.add_argument("--helper-relative", required=True)
    derive.add_argument("--helper-identifier", required=True)
    derive.add_argument("--helper-cdhash", required=True)
    derive.set_defaults(action=release_derive_source)
    publish = commands.add_parser("release-publish", allow_abbrev=False)
    publish.add_argument("--exec-root", required=True)
    publish.add_argument("--exec-identity", required=True)
    publish.add_argument("--manifest-fd", type=int, required=True)
    publish.add_argument("--helper-source-seal", required=True)
    publish.add_argument("--app-source-seal", required=True)
    publish.add_argument("--helper-relative", required=True)
    publish.add_argument("--app-relative", required=True)
    publish.add_argument("--helper-sha256", required=True)
    publish.add_argument("--helper-size", required=True)
    publish.add_argument("--helper-cdhash", required=True)
    publish.add_argument("--anchor-sha256", required=True)
    publish.add_argument("--template-sha256", required=True)
    publish.add_argument("--release-identity-sha256", required=True)
    publish.add_argument("--manifest-sha256", required=True)
    publish.add_argument("--capture-identifiers", required=True)
    publish.add_argument("--profile-sha256", required=True)
    publish.add_argument("--toolchain-root", required=True)
    publish.add_argument("--toolchain-sdk", required=True)
    publish.add_argument("--toolchain-driver-seal", required=True)
    publish.add_argument("--toolchain-seal-sha256", required=True)
    publish.set_defaults(action=release_publish)
    for command, action in (("capture-verify", capture_verify), ("capture-read", capture_read), ("capture-identifier", capture_identifier)):
        capture = commands.add_parser(command, allow_abbrev=False)
        capture.add_argument("--control-root", required=True)
        capture.add_argument("--control-identity", required=True)
        capture.add_argument("--exec-root", required=True)
        capture.add_argument("--exec-identity", required=True)
        capture.add_argument("--capture", required=True)
        capture.add_argument("--stream", required=True)
        capture.add_argument("--nonce", required=True)
        capture.add_argument("--profile-seal", required=True)
        capture.add_argument("--source-seal", required=True)
        capture.set_defaults(action=action)
    supervisor_result_parser = commands.add_parser("supervisor-result", allow_abbrev=False)
    supervisor_result_parser.add_argument("--control-root", required=True)
    supervisor_result_parser.add_argument("--control-identity", required=True)
    supervisor_result_parser.add_argument("--exec-root", required=True)
    supervisor_result_parser.add_argument("--exec-identity", required=True)
    supervisor_result_parser.add_argument("--capture", required=True)
    supervisor_result_parser.add_argument("--nonce", required=True)
    supervisor_result_parser.add_argument("--profile-seal", required=True)
    supervisor_result_parser.add_argument("--source-seal", required=True)
    supervisor_result_parser.set_defaults(action=supervisor_result)
    return result


def main() -> None:
    args = parser().parse_args()
    if hasattr(args, "max_bytes") and args.max_bytes <= 0:
        fail("invalid size bound", EX_DATAERR)
    args.action(args)


if __name__ == "__main__":
    main()
