#!/usr/bin/python3
"""Canonical, source-independent release-metrics evidence records.

This module deliberately does not sample processes, invoke build tools, or walk
artifacts.  An external measurement owner records the observation here, and the
comparison driver validates and compares the resulting immutable JSON input.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import pathlib
import re
import sys

SCHEMA = "lidswitch-external-release-metrics-v1"
HEX = re.compile(r"[0-9a-f]{64}\Z")
COMMIT = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,95}\Z")
METRICS = {
    "build_elapsed_seconds": ("seconds", "lower", "process-accounting"),
    "test_elapsed_seconds": ("seconds", "lower", "process-accounting"),
    "build_cpu_seconds": ("seconds", "lower", "process-accounting"),
    "test_cpu_seconds": ("seconds", "lower", "process-accounting"),
    "app_peak_rss_bytes": ("bytes", "lower", "process-observation"),
    "helper_peak_rss_bytes": ("bytes", "lower", "process-observation"),
    "app_idle_cpu_percent": ("percent", "lower", "process-observation"),
    "helper_idle_cpu_percent": ("percent", "lower", "process-observation"),
    "app_binary_bytes": ("bytes", "lower", "filesystem-stat"),
    "helper_binary_bytes": ("bytes", "lower", "filesystem-stat"),
    "app_tree_bytes": ("bytes", "lower", "filesystem-stat"),
    "dmg_bytes": ("bytes", "lower", "filesystem-stat"),
    "site_transfer_bytes": ("bytes", "lower", "site-browser"),
    "site_eager_image_bytes": ("bytes", "lower", "site-browser"),
    "site_render_ms": ("milliseconds", "lower", "site-browser"),
}
REQUIRED = frozenset(METRICS) - {"site_transfer_bytes", "site_eager_image_bytes", "site_render_ms"}


class MetricsError(ValueError):
    pass


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise MetricsError("duplicate JSON key")
        result[key] = value
    return result


def _constant(_):
    raise MetricsError("non-finite JSON number")


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)


def _string(value, label, maximum=1024):
    if not isinstance(value, str) or not value or "\x00" in value or len(value.encode("utf-8")) > maximum:
        raise MetricsError("invalid " + label)
    return value


def _digest(value, label):
    value = _string(value, label, 64)
    if not HEX.fullmatch(value):
        raise MetricsError("invalid " + label)
    return value


def _commit(value):
    value = _string(value, "commit", 64)
    if not COMMIT.fullmatch(value):
        raise MetricsError("invalid commit")
    return value


def _number(value, label):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value)) or float(value) < 0:
        raise MetricsError("invalid " + label)
    return float(value)


def load_canonical(path):
    raw = pathlib.Path(path).read_bytes()
    if not raw or not raw.endswith(b"\n") or b"\r" in raw or b"\x00" in raw:
        raise MetricsError("metrics evidence must be one canonical newline-terminated JSON object")
    try:
        value = json.loads(raw[:-1].decode("utf-8", "strict"), object_pairs_hook=_pairs, parse_constant=_constant)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise MetricsError("invalid metrics JSON") from error
    if not isinstance(value, dict) or canonical(value).encode("utf-8") + b"\n" != raw:
        raise MetricsError("metrics evidence is not canonical JSON")
    return value, hashlib.sha256(raw).hexdigest()


def validate(record):
    if set(record) != {"schema_version", "side", "identity", "metrics"} or record.get("schema_version") != SCHEMA:
        raise MetricsError("invalid metrics record shape")
    if record["side"] not in {"baseline", "candidate"}:
        raise MetricsError("invalid metrics side")
    identity = record["identity"]
    if set(identity) != {"commit", "harness_identity", "harness_sha256", "environment", "artifact_sha256"}:
        raise MetricsError("invalid metrics identity shape")
    _commit(identity["commit"])
    _string(identity["harness_identity"], "harness identity", 128)
    _digest(identity["harness_sha256"], "harness sha256")
    _digest(identity["artifact_sha256"], "artifact sha256")
    environment = identity["environment"]
    if set(environment) != {"machine", "operating_system", "architecture", "power_state"}:
        raise MetricsError("invalid metrics environment shape")
    for key in ("machine", "operating_system", "architecture", "power_state"):
        _string(environment[key], "environment " + key, 256)
    metrics = record["metrics"]
    if not isinstance(metrics, list) or not metrics:
        raise MetricsError("metrics must be a non-empty list")
    seen = set()
    normalized = []
    for item in metrics:
        if set(item) != {"name", "unit", "method", "samples", "observation_window_seconds", "status", "reason"}:
            raise MetricsError("invalid metric shape")
        name = item["name"]
        if name not in METRICS or name in seen:
            raise MetricsError("unknown or duplicate metric")
        seen.add(name)
        unit, _direction, method = METRICS[name]
        if item["unit"] != unit or item["method"] != method:
            raise MetricsError("metric unit or method mismatch")
        if item["status"] not in {"measured", "pending", "not-applicable"}:
            raise MetricsError("invalid metric status")
        if item["status"] == "measured":
            if not isinstance(item["samples"], list) or not item["samples"]:
                raise MetricsError("measured metric needs samples")
            if item["reason"] is not None:
                raise MetricsError("measured metric cannot carry a reason")
            samples = [_number(value, "metric sample") for value in item["samples"]]
            if ((method == "filesystem-stat" and len(samples) != 1) or (method != "filesystem-stat" and not 5 <= len(samples) <= 1000) or _number(item["observation_window_seconds"], "observation window") <= 0):
                raise MetricsError("invalid measured metric observation")
        else:
            if item["samples"] != [] or item["observation_window_seconds"] is not None or not isinstance(item["reason"], str):
                raise MetricsError("unmeasured metric needs an explicit reason")
            _string(item["reason"], "metric reason", 512)
            samples = []
        normalized.append(dict(item, samples=samples))
    return {"identity": identity, "metrics": normalized, "missing_required": sorted(REQUIRED - seen)}


def template(side):
    if side not in {"baseline", "candidate"}:
        raise MetricsError("invalid metrics side")
    metric_rows = []
    for name, (unit, _direction, method) in METRICS.items():
        metric_rows.append({"name": name, "unit": unit, "method": method, "samples": [], "observation_window_seconds": None, "status": "pending", "reason": "measurement not yet collected"})
    return {"schema_version": SCHEMA, "side": side, "identity": {"commit": "0" * 40, "harness_identity": "lidswitch-benchmark-v3", "harness_sha256": "0" * 64, "environment": {"machine": "qualified-mac", "operating_system": "macOS", "architecture": "arm64", "power_state": "AC"}, "artifact_sha256": "0" * 64}, "metrics": metric_rows}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--template", choices=("baseline", "candidate"))
    group.add_argument("--validate")
    args = parser.parse_args(argv)
    try:
        if args.template:
            print(canonical(template(args.template)))
        else:
            record, digest = load_canonical(args.validate)
            checked = validate(record)
            print(canonical({"schema_version": "lidswitch-external-release-metrics-validation-v1", "sha256": digest, "missing_required": checked["missing_required"]}))
    except (MetricsError, OSError) as error:
        print("release metrics evidence denied: " + str(error), file=sys.stderr)
        return 65
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
