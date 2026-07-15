#!/usr/bin/python3
"""Fail-closed before/after comparison for LidSwitch benchmark evidence.

Inputs are either canonical ``lidswitch-benchmark-v3`` JSONL or a documented
normalized input.  Both forms require supplemental identity metadata; v3 raw
rows alone deliberately cannot prove a commit, harness digest, or machine.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import release_metrics_evidence as release_metrics

V3 = "lidswitch-benchmark-v3"
NORMALIZED = "lidswitch-benchmark-normalized-v1"
ATTESTATION = "lidswitch-benchmark-attestation-v1"
REPORT = "lidswitch-benchmark-comparison-report-v1"
HEX = re.compile(r"[0-9a-f]{64}\Z")
COMMIT = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
FIXTURE_SCENARIOS = {
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
}
ARTIFACT_SCENARIOS = {
    "artifact.app-bundle.validation": "external-app-artifact",
    "artifact.helper-byte-comparison": "external-app-artifact",
}
RELEASE_SCENARIOS = dict(FIXTURE_SCENARIOS, **ARTIFACT_SCENARIOS)


class ComparisonError(ValueError):
    pass


def _pairs(pairs):
    output = {}
    for key, value in pairs:
        if key in output:
            raise ComparisonError("duplicate JSON key")
        output[key] = value
    return output


def _constant(_):
    raise ComparisonError("non-finite JSON number")


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)


def _read(path, jsonl=False):
    raw = pathlib.Path(path).read_bytes()
    if not raw or not raw.endswith(b"\n") or b"\r" in raw or b"\x00" in raw:
        raise ComparisonError("input must be canonical newline-terminated UTF-8")
    digest = hashlib.sha256(raw).hexdigest()
    try:
        if jsonl:
            values = [json.loads(line.decode("utf-8", "strict"), object_pairs_hook=_pairs, parse_constant=_constant) for line in raw[:-1].split(b"\n")]
            if not values or any(not isinstance(value, dict) for value in values):
                raise ComparisonError("JSONL requires object records")
            if any(canonical(value).encode("utf-8") != line for value, line in zip(values, raw[:-1].split(b"\n"))):
                raise ComparisonError("JSONL is not canonical sorted JSON")
            return values, digest
        value = json.loads(raw[:-1].decode("utf-8", "strict"), object_pairs_hook=_pairs, parse_constant=_constant)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ComparisonError("invalid JSON input") from error
    if not isinstance(value, dict) or canonical(value).encode("utf-8") + b"\n" != raw:
        raise ComparisonError("JSON input is not canonical")
    return value, digest


def _string(value, label, maximum=1024):
    if not isinstance(value, str) or not value or "\x00" in value or len(value.encode("utf-8")) > maximum:
        raise ComparisonError("invalid " + label)
    return value


def _digest(value, label):
    value = _string(value, label, 64)
    if not HEX.fullmatch(value):
        raise ComparisonError("invalid " + label)
    return value


def _commit(value):
    value = _string(value, "commit", 64)
    if not COMMIT.fullmatch(value):
        raise ComparisonError("invalid commit")
    return value


def _absolute_path(value, label, suffix=None):
    value = _string(value, label, 4096)
    if not value.startswith("/") or (suffix is not None and not value.endswith(suffix)):
        raise ComparisonError("invalid " + label)
    return value


def _artifact_truth(name, record, run=None):
    """Reject an artifact row that records a probe failure as benchmark truth."""
    expected = {"app_bundle", "bundle_integrity_valid", "bundle_version_valid", "codesign_exit_code"} if name == "artifact.app-bundle.validation" else {"app_bundle", "bundled_helper_path", "installed_helper_path", "helper_bytes_match"}
    if set(record) != expected:
        raise ComparisonError("invalid artifact truth shape")
    app_bundle = _absolute_path(record["app_bundle"], "app bundle", ".app")
    if run is not None and app_bundle != run["app_bundle"]:
        raise ComparisonError("artifact app bundle drift")
    if name == "artifact.app-bundle.validation":
        if record["bundle_integrity_valid"] is not True or record["bundle_version_valid"] is not True:
            raise ComparisonError("artifact bundle validation failed")
        if isinstance(record["codesign_exit_code"], bool) or not isinstance(record["codesign_exit_code"], int) or record["codesign_exit_code"] != 0:
            raise ComparisonError("artifact codesign validation failed")
    else:
        bundled = _absolute_path(record["bundled_helper_path"], "bundled helper path", "/Contents/Library/LaunchServices/LidSwitchHelper")
        installed = _absolute_path(record["installed_helper_path"], "installed helper path")
        if bundled != app_bundle + "/Contents/Library/LaunchServices/LidSwitchHelper" or (run is not None and installed != run["installed_helper_path"]):
            raise ComparisonError("artifact helper path drift")
        if record["helper_bytes_match"] is not True:
            raise ComparisonError("artifact helper comparison failed")


def _integer(value, label):
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ComparisonError("invalid " + label)
    return value


def _number(value, label):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value)) or float(value) < 0:
        raise ComparisonError("invalid " + label)
    return float(value)


def percentile(values, quantile):
    ordered = sorted(float(value) for value in values)
    position = (len(ordered) - 1) * quantile
    lower, upper = math.floor(position), math.ceil(position)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def standard_deviation(values):
    ordered = sorted(float(value) for value in values)
    mean = sum(ordered) / len(ordered)
    return math.sqrt(sum((value - mean) ** 2 for value in ordered) / (len(ordered) - 1))


def _stats(samples):
    if len(samples) < 5:
        raise ComparisonError("at least five warm samples are required")
    return {"sample_count": len(samples), "median": percentile(samples, .5), "p95": percentile(samples, .95), "sample_standard_deviation": standard_deviation(samples)}


def _metric_stats(samples):
    """External observations may be a single bounded filesystem measurement."""
    if not samples:
        raise ComparisonError("external metric has no samples")
    if len(samples) == 1:
        value = float(samples[0])
        return {"sample_count": 1, "median": value, "p95": value, "sample_standard_deviation": 0.0}
    return _stats(samples)


def _identity(attestation, side):
    if set(attestation) != {"schema_version", "side", "commit", "harness", "environment", "artifact_sha256", "exclusions"} or attestation.get("schema_version") != ATTESTATION or attestation.get("side") != side:
        raise ComparisonError("invalid comparison attestation")
    _commit(attestation["commit"])
    harness = attestation["harness"]
    if set(harness) != {"identity", "sha256", "methodology_id"}:
        raise ComparisonError("invalid harness identity")
    _string(harness["identity"], "harness identity", 128)
    _digest(harness["sha256"], "harness sha256")
    _string(harness["methodology_id"], "methodology id", 128)
    environment = attestation["environment"]
    if set(environment) != {"machine", "operating_system", "architecture", "power_state"}:
        raise ComparisonError("invalid benchmark environment identity")
    for key in environment:
        _string(environment[key], "environment " + key, 256)
    _digest(attestation["artifact_sha256"], "artifact sha256")
    if not isinstance(attestation["exclusions"], list) or attestation["exclusions"]:
        raise ComparisonError("excluded samples are not accepted")
    return {"commit": attestation["commit"], "harness": harness, "environment": environment, "artifact_sha256": attestation["artifact_sha256"]}


def _normalized(value, side):
    required = {"schema_version", "side", "identity", "methodology", "scenarios"}
    if set(value) != required or value.get("schema_version") != NORMALIZED or value.get("side") != side:
        raise ComparisonError("invalid normalized input shape")
    identity = _identity({"schema_version": ATTESTATION, "side": side, "commit": value["identity"].get("commit"), "harness": value["identity"].get("harness"), "environment": value["identity"].get("environment"), "artifact_sha256": value["identity"].get("artifact_sha256"), "exclusions": value["methodology"].get("exclusions")}, side)
    methodology = value["methodology"]
    if set(methodology) != {"warm_samples", "percentile", "cold_samples", "exclusions", "artifact_scenarios_included"} or methodology["percentile"] != "R-7 linear interpolation" or methodology["cold_samples"] != 1 or methodology["artifact_scenarios_included"] is not True:
        raise ComparisonError("normalized methodology is not canonical")
    warm_count = _integer(methodology["warm_samples"], "warm samples")
    if warm_count < 5 or warm_count > 100:
        raise ComparisonError("invalid normalized warm sample count")
    scenarios = _scenarios(value["scenarios"], warm_count, normalized=True)
    return {"identity": identity, "methodology": methodology, "scenarios": scenarios}


def _scenarios(rows, warm_count, normalized=False):
    if not isinstance(rows, list):
        raise ComparisonError("benchmark scenarios are missing")
    output = {}
    for row in rows:
        if normalized:
            if not isinstance(row, dict) or not {"name", "kind", "cold", "warm"}.issubset(row):
                raise ComparisonError("invalid normalized scenario")
            name, kind, cold, warm = row["name"], row["kind"], row["cold"], row["warm"]
            expected = {"name", "kind", "cold", "warm"}
            if name in ARTIFACT_SCENARIOS:
                expected.add("artifact_truth")
            if set(row) != expected:
                raise ComparisonError("invalid normalized scenario shape")
            if not isinstance(cold, dict) or not isinstance(warm, list):
                raise ComparisonError("invalid normalized samples")
            samples = []
            for item in warm:
                if set(item) != {"index", "elapsed_nanoseconds", "counters"}:
                    raise ComparisonError("invalid normalized warm sample")
                samples.append((item["index"], _integer(item["elapsed_nanoseconds"], "elapsed nanoseconds"), item["counters"]))
            if set(cold) != {"elapsed_nanoseconds", "counters"}:
                raise ComparisonError("invalid normalized cold sample")
            _integer(cold["elapsed_nanoseconds"], "cold elapsed nanoseconds")
            if name in ARTIFACT_SCENARIOS:
                if not isinstance(row["artifact_truth"], dict):
                    raise ComparisonError("invalid normalized artifact truth")
                artifact = row["artifact_truth"]
                _artifact_truth(name, artifact)
            cold = (cold["elapsed_nanoseconds"], cold["counters"])
        else:
            name, kind, cold, samples = row
        _string(name, "scenario", 256); _string(kind, "scenario kind", 128)
        if name not in RELEASE_SCENARIOS or kind != RELEASE_SCENARIOS[name] or name in output:
            raise ComparisonError("duplicate benchmark scenario")
        if len(samples) != warm_count or sorted(index for index, _elapsed, _counters in samples) != list(range(1, warm_count + 1)):
            raise ComparisonError("warm samples are missing, duplicated, or best-of-N")
        cold_elapsed, cold_counters = cold
        cold_elapsed = _integer(cold_elapsed, "cold elapsed nanoseconds")
        if not isinstance(cold_counters, dict) or any(not isinstance(key, str) or _integer(value, "cold counter") < 0 for key, value in cold_counters.items()):
            raise ComparisonError("invalid cold scenario counters")
        values, counters = [], {}
        for _index, elapsed, sample_counters in samples:
            values.append(_integer(elapsed, "elapsed nanoseconds"))
            if not isinstance(sample_counters, dict) or any(not isinstance(key, str) or _integer(value, "counter") < 0 for key, value in sample_counters.items()):
                raise ComparisonError("invalid scenario counters")
            for key, value in sample_counters.items():
                counters[key] = counters.get(key, 0) + value
        if set(cold_counters) != set(counters):
            raise ComparisonError("cold/warm counter contract mismatch")
        output[name] = {"kind": kind, "cold": {"elapsed_nanoseconds": cold_elapsed, "counters": dict(sorted(cold_counters.items()))}, "stats": _stats(values), "counter_totals": dict(sorted(counters.items()))}
    if set(output) != set(RELEASE_SCENARIOS):
        raise ComparisonError("benchmark corpus is not the exact release inventory")
    return output


def _v3(records, side, attestation):
    identity = _identity(attestation, side)
    if len(records) < 4 or [record.get("record_type") for record in records[:3]] != ["run", "methodology", "environment"]:
        raise ComparisonError("v3 records must begin run, methodology, environment")
    if any(record.get("schema_version") != V3 for record in records):
        raise ComparisonError("benchmark schema is not v3")
    run, methodology, environment = records[:3]
    run_required = {"record_type", "schema_version", "warm_samples", "fixture_root", "artifact_scenarios_included", "snapshot_core_context", "snapshot_core_limitations"}
    run_optional = {"app_bundle", "installed_helper_path"}
    if not run_required.issubset(run) or set(run) != run_required | run_optional or run["artifact_scenarios_included"] is not True:
        raise ComparisonError("invalid v3 run shape")
    _absolute_path(run["app_bundle"], "run app bundle", ".app")
    _absolute_path(run["installed_helper_path"], "run installed helper path")
    methodology_required = {"record_type", "schema_version", "snapshot_core_context", "snapshot_core_limitations", "artifact_validation", "helper_comparison"}
    if set(methodology) != methodology_required or set(environment) != {"record_type", "schema_version", "operating_system", "architecture"}:
        raise ComparisonError("invalid v3 methodology or environment shape")
    if not isinstance(run.get("warm_samples"), int) or isinstance(run["warm_samples"], bool) or not 5 <= run["warm_samples"] <= 100:
        raise ComparisonError("invalid v3 warm sample count")
    if methodology.get("snapshot_core_context") != run.get("snapshot_core_context") or methodology.get("snapshot_core_limitations") != run.get("snapshot_core_limitations"):
        raise ComparisonError("v3 methodology/run disagreement")
    if environment.get("operating_system") != identity["environment"]["operating_system"] or environment.get("architecture") != identity["environment"]["architecture"]:
        raise ComparisonError("v3 environment does not match attestation")
    warm_count, sampled = run["warm_samples"], {}
    summaries = {}
    for record in records[3:]:
        kind = record.get("record_type")
        if kind == "sample":
            required = {"record_type", "schema_version", "scenario", "scenario_kind", "classification", "sample_index", "elapsed_nanoseconds", "main_thread_elapsed_nanoseconds", "counters", "fixture_root"}
            artifact = {"app_bundle", "bundle_integrity_valid", "bundle_version_valid", "codesign_exit_code", "bundled_helper_path", "installed_helper_path", "helper_bytes_match"}
            if not required.issubset(record) or not set(record).issubset(required | artifact) or record["classification"] not in {"cold", "warm"}:
                raise ComparisonError("invalid v3 sample shape")
            name = _string(record["scenario"], "scenario", 256)
            scenario_kind = _string(record["scenario_kind"], "scenario kind", 128)
            index = _integer(record["sample_index"], "sample index")
            elapsed = _integer(record["elapsed_nanoseconds"], "elapsed nanoseconds")
            _integer(record["main_thread_elapsed_nanoseconds"], "main thread elapsed nanoseconds")
            _string(record["fixture_root"], "fixture root", 4096)
            if not isinstance(record["counters"], dict) or any(not isinstance(key, str) or _integer(value, "counter") < 0 for key, value in record["counters"].items()):
                raise ComparisonError("invalid v3 counters")
            if name == "artifact.app-bundle.validation":
                if set(record) != required | {"app_bundle", "bundle_integrity_valid", "bundle_version_valid", "codesign_exit_code"}:
                    raise ComparisonError("invalid v3 bundle artifact sample")
                _artifact_truth(name, {key: record[key] for key in ("app_bundle", "bundle_integrity_valid", "bundle_version_valid", "codesign_exit_code")}, run)
            elif name == "artifact.helper-byte-comparison":
                if set(record) != required | {"app_bundle", "bundled_helper_path", "installed_helper_path", "helper_bytes_match"}:
                    raise ComparisonError("invalid v3 helper artifact sample")
                _artifact_truth(name, {key: record[key] for key in ("app_bundle", "bundled_helper_path", "installed_helper_path", "helper_bytes_match")}, run)
            elif set(record) != required:
                raise ComparisonError("fixture scenario contains artifact fields")
            if record["classification"] == "cold":
                if index != 0 or name in sampled and "cold" in sampled[name]:
                    raise ComparisonError("duplicate or invalid cold sample")
                sampled.setdefault(name, {"kind": scenario_kind, "warm": []})["cold"] = (elapsed, record["counters"])
            else:
                sampled.setdefault(name, {"kind": scenario_kind, "warm": []})["warm"].append((index, elapsed, record["counters"]))
            if sampled[name]["kind"] != scenario_kind:
                raise ComparisonError("scenario kind drift inside v3 input")
        elif kind == "summary":
            required = {"record_type", "schema_version", "scenario", "sample_count", "median_nanoseconds", "p95_nanoseconds", "sample_standard_deviation_nanoseconds", "quantile"}
            if set(record) != required or record.get("quantile") != "R-7 linear interpolation" or record["scenario"] in summaries:
                raise ComparisonError("invalid or duplicate v3 summary")
            summaries[record["scenario"]] = record
        else:
            raise ComparisonError("unknown v3 record type")
    rows = []
    for name, sample in sampled.items():
        if "cold" not in sample:
            raise ComparisonError("v3 scenario is missing a cold sample")
        rows.append((name, sample["kind"], sample["cold"], sample["warm"]))
    scenarios = _scenarios(rows, warm_count)
    if set(summaries) != set(scenarios):
        raise ComparisonError("v3 summaries do not match scenarios")
    for name, scenario in scenarios.items():
        summary = summaries[name]
        if summary["sample_count"] != warm_count:
            raise ComparisonError("v3 summary sample count disagrees")
        for key, expected in (("median_nanoseconds", scenario["stats"]["median"]), ("p95_nanoseconds", scenario["stats"]["p95"]), ("sample_standard_deviation_nanoseconds", scenario["stats"]["sample_standard_deviation"])):
            if not isinstance(summary[key], (int, float)) or isinstance(summary[key], bool) or not math.isclose(float(summary[key]), expected, rel_tol=1e-15, abs_tol=1e-6):
                raise ComparisonError("v3 summary statistics disagree with samples")
    return {"identity": identity, "methodology": {"warm_samples": warm_count, "percentile": "R-7 linear interpolation", "cold_samples": 1, "exclusions": [], "artifact_scenarios_included": True}, "scenarios": scenarios}


def load_input(path, side, attestation_path=None):
    raw, digest = _read(path, jsonl=True)
    if raw[0].get("schema_version") == V3:
        if not attestation_path:
            raise ComparisonError("v3 raw input requires an attestation")
        attestation, _attestation_hash = _read(attestation_path)
        return _v3(raw, side, attestation), digest
    value, digest = _read(path)
    return _normalized(value, side), digest


def _percent(before, after):
    if before == 0:
        return None
    return ((after - before) / before) * 100.0


def _external(path, side, identity):
    if path is None:
        return None
    record, digest = release_metrics.load_canonical(path)
    checked = release_metrics.validate(record)
    if record["side"] != side or checked["identity"] != {"commit": identity["commit"], "harness_identity": identity["harness"]["identity"], "harness_sha256": identity["harness"]["sha256"], "environment": identity["environment"], "artifact_sha256": identity["artifact_sha256"]}:
        raise ComparisonError("external metrics identity does not bind benchmark evidence")
    return checked, digest


def compare(baseline, candidate, baseline_hash, candidate_hash, baseline_external=None, candidate_external=None):
    if baseline["identity"]["harness"] != candidate["identity"]["harness"] or baseline["identity"]["environment"] != candidate["identity"]["environment"] or baseline["methodology"] != candidate["methodology"]:
        raise ComparisonError("baseline/candidate harness, environment, or methodology mismatch")
    if set(baseline["scenarios"]) != set(candidate["scenarios"]):
        raise ComparisonError("baseline/candidate scenario set mismatch")
    deltas, regressions = [], []
    for name in sorted(baseline["scenarios"]):
        before, after = baseline["scenarios"][name], candidate["scenarios"][name]
        if before["kind"] != after["kind"] or set(before["counter_totals"]) != set(after["counter_totals"]) or set(before["cold"]["counters"]) != set(after["cold"]["counters"]):
            raise ComparisonError("scenario kind or counter contract mismatch: " + name)
        stats = {key: {"baseline": before["stats"][key], "candidate": after["stats"][key], "percent_delta": _percent(before["stats"][key], after["stats"][key])} for key in ("median", "p95", "sample_standard_deviation")}
        p95_delta = stats["p95"]["percent_delta"]
        cold_delta = _percent(before["cold"]["elapsed_nanoseconds"], after["cold"]["elapsed_nanoseconds"])
        cold_regression = cold_delta is not None and cold_delta > 5.0
        regression = (p95_delta is not None and p95_delta > 5.0) or cold_regression
        if regression:
            regressions.append(name)
        deltas.append({"scenario": name, "kind": before["kind"], "cold": {"baseline_elapsed_nanoseconds": before["cold"]["elapsed_nanoseconds"], "candidate_elapsed_nanoseconds": after["cold"]["elapsed_nanoseconds"], "percent_delta": cold_delta, "counter_totals": {key: {"baseline": before["cold"]["counters"][key], "candidate": after["cold"]["counters"][key], "percent_delta": _percent(before["cold"]["counters"][key], after["cold"]["counters"][key])} for key in sorted(before["cold"]["counters"])}, "unexplained_regression": cold_regression}, "statistics": stats, "counter_totals": {key: {"baseline": before["counter_totals"][key], "candidate": after["counter_totals"][key], "percent_delta": _percent(before["counter_totals"][key], after["counter_totals"][key])} for key in sorted(before["counter_totals"])}, "unexplained_regression": regression})
    external_deltas, external_missing = [], sorted(release_metrics.REQUIRED)
    if baseline_external and candidate_external:
        base = {item["name"]: item for item in baseline_external["metrics"]}
        cand = {item["name"]: item for item in candidate_external["metrics"]}
        external_missing = sorted(name for name in release_metrics.REQUIRED if name not in base or name not in cand or base[name]["status"] != "measured" or cand[name]["status"] != "measured")
        for name in sorted(set(base) & set(cand)):
            one, two = base[name], cand[name]
            if one["status"] != "measured" or two["status"] != "measured":
                continue
            first, second = _metric_stats(one["samples"]), _metric_stats(two["samples"])
            delta = _percent(first["p95"], second["p95"])
            regression = delta is not None and delta > 5.0
            if regression:
                regressions.append(name)
            external_deltas.append({"metric": name, "unit": one["unit"], "statistics": {"baseline": first, "candidate": second, "p95_percent_delta": delta}, "unexplained_regression": regression})
    force_fresh = candidate["scenarios"].get("fixture.installation.force-fresh")
    force_fresh_ok = force_fresh is not None and force_fresh["stats"]["p95"] <= 250000000.0
    idle = {item["metric"]: item for item in external_deltas}
    idle_ok = idle.get("app_idle_cpu_percent", {}).get("statistics", {}).get("candidate", {}).get("p95", math.inf) < .5
    critical = next((item for item in deltas if item["scenario"] == "fixture.installation.force-fresh"), None)
    critical_improvement = critical is not None and critical["statistics"]["p95"]["percent_delta"] is not None and critical["statistics"]["p95"]["percent_delta"] <= -25.0
    recurring_improvement = any(item["metric"] in {"app_idle_cpu_percent", "helper_idle_cpu_percent"} and item["statistics"]["p95_percent_delta"] is not None and item["statistics"]["p95_percent_delta"] <= -30.0 for item in external_deltas)
    budgets = {"no_unexplained_over_5_percent_regression": not regressions, "force_fresh_p95_at_most_250ms": force_fresh_ok, "idle_cpu_below_0_5_percent": idle_ok, "user_critical_latency_improved_at_least_25_percent": critical_improvement, "recurring_resource_work_improved_at_least_30_percent": recurring_improvement, "external_required_metrics_missing": external_missing}
    verdict = "regression" if regressions else "pass" if all((force_fresh_ok, idle_ok, critical_improvement, recurring_improvement, not external_missing)) else "needs-measurement"
    return {"schema_version": REPORT, "baseline": {"commit": baseline["identity"]["commit"], "raw_sha256": baseline_hash}, "candidate": {"commit": candidate["identity"]["commit"], "raw_sha256": candidate_hash}, "harness": baseline["identity"]["harness"], "environment": baseline["identity"]["environment"], "scenario_deltas": deltas, "external_metric_deltas": external_deltas, "budgets": budgets, "verdict": verdict}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--baseline-attestation")
    parser.add_argument("--candidate-attestation")
    parser.add_argument("--baseline-external-metrics")
    parser.add_argument("--candidate-external-metrics")
    parser.add_argument("--output")
    args = parser.parse_args(argv)
    try:
        baseline, baseline_hash = load_input(args.baseline, "baseline", args.baseline_attestation)
        candidate, candidate_hash = load_input(args.candidate, "candidate", args.candidate_attestation)
        base_external = _external(args.baseline_external_metrics, "baseline", baseline["identity"]) if args.baseline_external_metrics else None
        candidate_external = _external(args.candidate_external_metrics, "candidate", candidate["identity"]) if args.candidate_external_metrics else None
        report = compare(baseline, candidate, baseline_hash, candidate_hash, base_external[0] if base_external else None, candidate_external[0] if candidate_external else None)
        payload = canonical(report) + "\n"
        if args.output:
            pathlib.Path(args.output).write_text(payload, encoding="utf-8")
        else:
            sys.stdout.write(payload)
        return 0 if report["verdict"] == "pass" else 2
    except (ComparisonError, release_metrics.MetricsError, OSError) as error:
        print("benchmark comparison denied: " + str(error), file=sys.stderr)
        return 65


if __name__ == "__main__":
    raise SystemExit(main())
