#!/usr/bin/python3
"""Fail-closed adapter for canonical native startup benchmark observations.

The native startup harness owns process observations.  This adapter only
validates two immutable records and derives deterministic, release-metrics-
compatible app resource records plus native UX latency deltas.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import pathlib
import re
import stat
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import release_metrics_evidence as release_metrics

NATIVE_SCHEMA = "lidswitch-native-startup-benchmark-v1"
REPORT_SCHEMA = "lidswitch-native-startup-metrics-adaptation-v1"
HEX = re.compile(r"[0-9a-f]{64}\Z")
COMMIT = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
RESOURCE_METRICS = (
    ("app_peak_rss_bytes", "bytes", "process-observation", "peak_rss_bytes"),
    ("app_idle_cpu_percent", "percent", "process-observation", "idle_cpu_percent"),
    ("app_binary_bytes", "bytes", "filesystem-stat", "executable_bytes"),
    ("app_tree_bytes", "bytes", "filesystem-stat", "tree_bytes"),
)
LATENCIES = ("launch_to_process_ms", "launch_to_idle_ms")


class AdapterError(ValueError):
    pass


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise AdapterError("duplicate JSON key")
        result[key] = value
    return result


def _constant(_):
    raise AdapterError("non-finite JSON number")


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)


def _string(value, label, maximum=1024):
    if not isinstance(value, str) or not value or "\x00" in value or len(value.encode("utf-8")) > maximum:
        raise AdapterError("invalid " + label)
    return value


def _digest(value, label):
    value = _string(value, label, 64)
    if not HEX.fullmatch(value):
        raise AdapterError("invalid " + label)
    return value


def _integer(value, label):
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise AdapterError("invalid " + label)
    return value


def _positive_integer(value, label):
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise AdapterError("invalid " + label)
    return value


def _number(value, label):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value)) or value < 0:
        raise AdapterError("invalid " + label)
    return float(value)


def load_canonical(path):
    raw = pathlib.Path(path).read_bytes()
    if not raw or not raw.endswith(b"\n") or b"\r" in raw or b"\x00" in raw:
        raise AdapterError("native benchmark must be canonical newline-terminated JSON")
    try:
        record = json.loads(raw[:-1].decode("utf-8", "strict"), object_pairs_hook=_pairs, parse_constant=_constant)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AdapterError("invalid native benchmark JSON") from error
    if not isinstance(record, dict) or canonical(record).encode("utf-8") + b"\n" != raw:
        raise AdapterError("native benchmark is not canonical JSON")
    return record, hashlib.sha256(raw).hexdigest()


def validate(record, side):
    required = {"schema_version", "side", "app", "identity", "environment", "observation_window_seconds", "samples"}
    if set(record) != required or record.get("schema_version") != NATIVE_SCHEMA or record.get("side") != side:
        raise AdapterError("invalid native benchmark shape")
    app = record["app"]
    if set(app) != {"path", "version", "build", "executable_sha256", "executable_bytes", "tree_bytes", "tree_sha256"}:
        raise AdapterError("invalid app identity schema")
    path = _string(app["path"], "app path", 4096)
    if not path.startswith("/") or not path.endswith(".app"):
        raise AdapterError("invalid app path")
    _string(app["version"], "app version", 256)
    _string(app["build"], "app build", 256)
    _digest(app["executable_sha256"], "app executable sha256")
    _digest(app["tree_sha256"], "app tree sha256")
    _positive_integer(app["executable_bytes"], "app executable bytes")
    _positive_integer(app["tree_bytes"], "app tree bytes")
    identity = record["identity"]
    if set(identity) != {"artifact_commit", "harness_sha256", "machine"}:
        raise AdapterError("invalid native identity schema")
    if not isinstance(identity["artifact_commit"], str) or not COMMIT.fullmatch(identity["artifact_commit"]):
        raise AdapterError("invalid artifact commit")
    _digest(identity["harness_sha256"], "harness sha256")
    _string(identity["machine"], "machine", 256)
    environment = record["environment"]
    if set(environment) != {"architecture", "operating_system", "power_state"}:
        raise AdapterError("invalid native environment schema")
    _string(environment["architecture"], "architecture", 256)
    _string(environment["operating_system"], "operating system", 256)
    if environment["power_state"] != "AC":
        raise AdapterError("native benchmark is not on AC power")
    window = _number(record["observation_window_seconds"], "observation window")
    if window <= 0:
        raise AdapterError("invalid observation window")
    samples = record["samples"]
    if not isinstance(samples, list) or not 5 <= len(samples) <= 20:
        raise AdapterError("native benchmark requires five to twenty samples")
    checked_samples = []
    for sample in samples:
        if set(sample) != set(LATENCIES) | {"peak_rss_bytes", "idle_cpu_percent"}:
            raise AdapterError("invalid native sample schema")
        checked_samples.append({
            "launch_to_process_ms": _number(sample["launch_to_process_ms"], "launch_to_process_ms"),
            "launch_to_idle_ms": _number(sample["launch_to_idle_ms"], "launch_to_idle_ms"),
            "peak_rss_bytes": _positive_integer(sample["peak_rss_bytes"], "peak_rss_bytes"),
            "idle_cpu_percent": _number(sample["idle_cpu_percent"], "idle_cpu_percent"),
        })
    return {"app": app, "identity": identity, "environment": environment, "observation_window_seconds": window, "samples": checked_samples}


def _percent(before, after):
    return None if before == 0 else ((after - before) / before) * 100.0


def _percentile(values, quantile):
    ordered = sorted(float(value) for value in values)
    position = (len(ordered) - 1) * quantile
    lower, upper = math.floor(position), math.ceil(position)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def _private_output_path(value):
    path = pathlib.Path(value)
    if not path.is_absolute() or path.name in {"", ".", ".."}:
        raise AdapterError("output must be an absolute file path")
    try:
        parent_info = os.lstat(path.parent)
    except OSError as error:
        raise AdapterError("output parent is unavailable") from error
    if (stat.S_ISLNK(parent_info.st_mode) or not stat.S_ISDIR(parent_info.st_mode) or path.parent.parent != pathlib.Path("/private/tmp")
            or parent_info.st_uid != os.getuid() or stat.S_IMODE(parent_info.st_mode) != 0o700):
        raise AdapterError("output parent must be a private direct child of /private/tmp")
    try:
        os.lstat(path)
    except FileNotFoundError:
        return path
    raise AdapterError("output already exists")


def _write_once(path, payload):
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        view = memoryview(payload)
        while view:
            written = os.write(fd, view)
            if written <= 0:
                raise AdapterError("output write failed")
            view = view[written:]
        os.fsync(fd)
    finally:
        os.close(fd)


def _external(checked, side):
    identity = checked["identity"]
    environment = checked["environment"]
    app = checked["app"]
    samples = checked["samples"]
    metrics = []
    for name, unit, method, source in RESOURCE_METRICS:
        values = [sample[source] for sample in samples] if source in {"peak_rss_bytes", "idle_cpu_percent"} else [float(app[source])]
        metrics.append({"name": name, "unit": unit, "method": method, "samples": values, "observation_window_seconds": checked["observation_window_seconds"], "status": "measured", "reason": None})
    record = {"schema_version": release_metrics.SCHEMA, "side": side, "identity": {"commit": identity["artifact_commit"], "harness_identity": NATIVE_SCHEMA, "harness_sha256": identity["harness_sha256"], "environment": {"machine": identity["machine"], "operating_system": environment["operating_system"], "architecture": environment["architecture"], "power_state": environment["power_state"]}, "artifact_sha256": app["tree_sha256"]}, "metrics": metrics}
    release_metrics.validate(record)
    return record


def adapt(baseline, candidate, baseline_sha256, candidate_sha256):
    comparable = ("harness_sha256", "machine")
    if any(baseline["identity"][key] != candidate["identity"][key] for key in comparable) or baseline["environment"] != candidate["environment"]:
        raise AdapterError("baseline/candidate harness or environment mismatch")
    if len(baseline["samples"]) != len(candidate["samples"]):
        raise AdapterError("baseline/candidate sample counts differ")
    baseline_external, candidate_external = _external(baseline, "baseline"), _external(candidate, "candidate")
    latency_deltas = []
    for name in LATENCIES:
        before = [sample[name] for sample in baseline["samples"]]
        after = [sample[name] for sample in candidate["samples"]]
        baseline_median, candidate_median = _percentile(before, .5), _percentile(after, .5)
        latency_deltas.append({"metric": name, "unit": "milliseconds", "percentile": "R-7 linear interpolation", "baseline_samples": before, "candidate_samples": after, "baseline_median": baseline_median, "candidate_median": candidate_median, "median_percent_delta": _percent(baseline_median, candidate_median)})
    return {"schema_version": REPORT_SCHEMA, "baseline": {"native_sha256": baseline_sha256, "external_metrics": baseline_external}, "candidate": {"native_sha256": candidate_sha256, "external_metrics": candidate_external}, "ux_latency_deltas": latency_deltas}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--output")
    parser.add_argument("--baseline-external-output")
    parser.add_argument("--candidate-external-output")
    args = parser.parse_args(argv)
    try:
        baseline_raw, baseline_sha = load_canonical(args.baseline)
        candidate_raw, candidate_sha = load_canonical(args.candidate)
        result = adapt(validate(baseline_raw, "baseline"), validate(candidate_raw, "candidate"), baseline_sha, candidate_sha)
        payload = (canonical(result) + "\n").encode("utf-8")
        if bool(args.baseline_external_output) != bool(args.candidate_external_output):
            raise AdapterError("both external metric outputs are required together")
        destinations = [args.output] if args.output else []
        if args.baseline_external_output:
            destinations.extend((args.baseline_external_output, args.candidate_external_output))
        checked_destinations = [_private_output_path(path) for path in destinations]
        if len(set(checked_destinations)) != len(checked_destinations):
            raise AdapterError("output paths must be distinct")
        if args.output:
            _write_once(checked_destinations.pop(0), payload)
        else:
            sys.stdout.write(payload.decode("utf-8"))
        if args.baseline_external_output:
            _write_once(checked_destinations[0], (canonical(result["baseline"]["external_metrics"]) + "\n").encode("utf-8"))
            _write_once(checked_destinations[1], (canonical(result["candidate"]["external_metrics"]) + "\n").encode("utf-8"))
        return 0
    except (AdapterError, release_metrics.MetricsError, OSError) as error:
        print("native startup metrics adaptation denied: " + str(error), file=sys.stderr)
        return 65


if __name__ == "__main__":
    raise SystemExit(main())
