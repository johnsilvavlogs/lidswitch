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
import statistics
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import release_metrics_evidence as release_metrics

NATIVE_SCHEMA = "lidswitch-native-startup-benchmark-v2"
REPORT_SCHEMA = "lidswitch-native-startup-metrics-adaptation-v2"
HEX = re.compile(r"[0-9a-f]{64}\Z")
COMMIT = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
RESOURCE_METRICS = (
    ("app_peak_rss_bytes", "bytes", "process-observation", "peak_rss_bytes"),
    ("app_idle_cpu_percent", "percent", "process-observation", "idle_cpu_percent"),
    ("app_binary_bytes", "bytes", "filesystem-stat", "executable_bytes"),
    ("app_tree_bytes", "bytes", "filesystem-stat", "tree_bytes"),
)
LATENCIES = ("launch_to_process_ms", "launch_to_ready_ms", "launch_to_idle_ms")


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
    required = {
        "schema_version", "side", "app", "identity", "environment", "methodology", "host_state",
        "observation_window_seconds", "cold_sample", "discarded_warmup_sample", "warm_samples",
    }
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
    methodology = record["methodology"]
    if not isinstance(methodology, dict):
        raise AdapterError("invalid native benchmark methodology")
    expected_methodology = {
        "cold_samples": 1,
        "discarded_warmup_samples": 1,
        "warm_samples": len(record["warm_samples"]) if isinstance(record["warm_samples"], list) else None,
        "readiness_observer": "unique-enabled-axmenuextra-for-exact-pid",
        "idle_cpu_threshold_percent": 2.0,
        "idle_window_seconds": 1.0,
        "minimum_idle_samples": 5,
        "poll_interval_seconds": 0.1,
    }
    integer_methodology = ("cold_samples", "discarded_warmup_samples", "warm_samples", "minimum_idle_samples")
    float_methodology = ("idle_cpu_threshold_percent", "idle_window_seconds", "poll_interval_seconds")
    if (
        methodology != expected_methodology
        or any(type(methodology.get(key)) is not int for key in integer_methodology)
        or any(type(methodology.get(key)) is not float for key in float_methodology)
    ):
        raise AdapterError("invalid native benchmark methodology")
    host_state = record["host_state"]
    if not isinstance(host_state, dict) or set(host_state) != {"before", "after"} or host_state["before"] != host_state["after"]:
        raise AdapterError("native benchmark host state changed")
    observed_state = host_state["before"]
    if not isinstance(observed_state, dict) or set(observed_state) != {"power", "activation_lease", "desired_state", "applied_state"}:
        raise AdapterError("invalid native benchmark host state")
    if observed_state["power"] != {"sleep_disabled": 0, "source": "AC Power"}:
        raise AdapterError("native benchmark host power state is unsafe")
    for key in ("activation_lease", "applied_state"):
        value = observed_state[key]
        if not isinstance(value, dict) or set(value) != {"path", "state"} or value.get("state") != "absent" or not isinstance(value.get("path"), str):
            raise AdapterError("native benchmark active-state record is unsafe")
    desired_state = observed_state["desired_state"]
    if not isinstance(desired_state, dict) or desired_state.get("state") not in {"absent", "present"} or not isinstance(desired_state.get("path"), str):
        raise AdapterError("invalid native benchmark desired state")
    if desired_state["state"] == "absent":
        if set(desired_state) != {"path", "state"}:
            raise AdapterError("invalid absent desired state")
    else:
        expected_desired = {"path", "state", "device", "inode", "uid", "gid", "mode", "size", "sha256"}
        if set(desired_state) != expected_desired or not HEX.fullmatch(str(desired_state.get("sha256", ""))):
            raise AdapterError("invalid present desired state")
    window = _number(record["observation_window_seconds"], "observation window")
    if window <= 0:
        raise AdapterError("invalid observation window")
    samples = record["warm_samples"]
    if not isinstance(samples, list) or not 5 <= len(samples) <= 20:
        raise AdapterError("native benchmark requires five to twenty samples")
    def checked_sample(sample, label):
        if set(sample) != set(LATENCIES) | {"peak_rss_bytes", "idle_cpu_percent"}:
            raise AdapterError("invalid " + label + " schema")
        checked = {
            "launch_to_process_ms": _number(sample["launch_to_process_ms"], "launch_to_process_ms"),
            "launch_to_ready_ms": _number(sample["launch_to_ready_ms"], "launch_to_ready_ms"),
            "launch_to_idle_ms": _number(sample["launch_to_idle_ms"], "launch_to_idle_ms"),
            "peak_rss_bytes": _positive_integer(sample["peak_rss_bytes"], "peak_rss_bytes"),
            "idle_cpu_percent": _number(sample["idle_cpu_percent"], "idle_cpu_percent"),
        }
        if not checked["launch_to_process_ms"] <= checked["launch_to_ready_ms"] <= checked["launch_to_idle_ms"]:
            raise AdapterError("native sample lifecycle order is invalid")
        if checked["launch_to_idle_ms"] - checked["launch_to_ready_ms"] < methodology["idle_window_seconds"] * 1000:
            raise AdapterError("native sample idle window is too short")
        if checked["idle_cpu_percent"] > methodology["idle_cpu_threshold_percent"]:
            raise AdapterError("native sample idle CPU exceeds the accepted window")
        return checked
    cold = checked_sample(record["cold_sample"], "cold sample")
    warmup = checked_sample(record["discarded_warmup_sample"], "discarded warmup sample")
    checked_samples = [checked_sample(sample, "warm sample") for sample in samples]
    return {
        "app": app, "identity": identity, "environment": environment,
        "methodology": methodology, "host_state": host_state, "observation_window_seconds": window,
        "cold_sample": cold, "discarded_warmup_sample": warmup, "warm_samples": checked_samples,
    }


def _percent(before, after):
    return None if before == 0 else ((after - before) / before) * 100.0


def _percentile(values, quantile):
    ordered = sorted(float(value) for value in values)
    position = (len(ordered) - 1) * quantile
    lower, upper = math.floor(position), math.ceil(position)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def _stats(values):
    return {
        "median": _percentile(values, .5),
        "p95": _percentile(values, .95),
        "population_standard_deviation": statistics.pstdev(float(value) for value in values),
    }


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
    samples = checked["warm_samples"]
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
    if baseline["host_state"] != candidate["host_state"]:
        raise AdapterError("baseline/candidate host states differ")
    if baseline["methodology"] != candidate["methodology"]:
        raise AdapterError("baseline/candidate methodologies differ")
    if len(baseline["warm_samples"]) != len(candidate["warm_samples"]):
        raise AdapterError("baseline/candidate sample counts differ")
    baseline_external, candidate_external = _external(baseline, "baseline"), _external(candidate, "candidate")
    latency_deltas = []
    for name in LATENCIES:
        before = [sample[name] for sample in baseline["warm_samples"]]
        after = [sample[name] for sample in candidate["warm_samples"]]
        baseline_stats, candidate_stats = _stats(before), _stats(after)
        baseline_cold, candidate_cold = baseline["cold_sample"][name], candidate["cold_sample"][name]
        latency_deltas.append({
            "metric": name,
            "unit": "milliseconds",
            "percentile": "R-7 linear interpolation",
            "cold": {
                "baseline": baseline_cold,
                "candidate": candidate_cold,
                "percent_delta": _percent(baseline_cold, candidate_cold),
            },
            "warm": {
                "baseline_samples": before,
                "candidate_samples": after,
                "baseline": baseline_stats,
                "candidate": candidate_stats,
                "median_percent_delta": _percent(baseline_stats["median"], candidate_stats["median"]),
                "p95_percent_delta": _percent(baseline_stats["p95"], candidate_stats["p95"]),
            },
        })
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
