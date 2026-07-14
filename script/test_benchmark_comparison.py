#!/usr/bin/python3
"""Private-temp fixtures for source-independent benchmark evidence tooling."""
from __future__ import annotations

import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import benchmark_comparison as comparison
import release_metrics_evidence as metrics


def write(path, value):
    path.write_text(comparison.canonical(value) + "\n", encoding="utf-8")
    return path


def identity(side):
    return {
        "commit": ("a" if side == "baseline" else "b") * 40,
        "harness": {"identity": "lidswitch-benchmark-v3", "sha256": "c" * 64, "methodology_id": "benchmark-comparison@1"},
        "environment": {"machine": "qualified-mac", "operating_system": "macOS 26.5.2", "architecture": "arm64", "power_state": "AC"},
        "artifact_sha256": ("d" if side == "baseline" else "e") * 64,
    }


def normalized(side, force_fresh, cold_force_fresh=None):
    def samples(values, counter):
        return [{"index": index, "elapsed_nanoseconds": value, "counters": counter} for index, value in enumerate(values, 1)]
    scenarios = []
    for name, kind in comparison.RELEASE_SCENARIOS.items():
        counter = {"comparison_counter": 1}
        values = force_fresh if name == "fixture.installation.force-fresh" else [1000 + 2 * index for index in range(len(force_fresh))]
        cold_value = cold_force_fresh if name == "fixture.installation.force-fresh" and cold_force_fresh is not None else values[0]
        row = {"name": name, "kind": kind, "cold": {"elapsed_nanoseconds": cold_value, "counters": counter}, "warm": samples(values, counter)}
        if name == "artifact.app-bundle.validation":
            row["artifact_truth"] = {"app_bundle": "/private/tmp/LidSwitch.app", "bundle_integrity_valid": True, "bundle_version_valid": True, "codesign_exit_code": 0}
        elif name == "artifact.helper-byte-comparison":
            row["artifact_truth"] = {"app_bundle": "/private/tmp/LidSwitch.app", "bundled_helper_path": "/private/tmp/LidSwitch.app/Contents/Library/LaunchServices/LidSwitchHelper", "installed_helper_path": "/private/tmp/LidSwitchHelper", "helper_bytes_match": True}
        scenarios.append(row)
    return {
        "schema_version": comparison.NORMALIZED,
        "side": side,
        "identity": identity(side),
        "methodology": {"warm_samples": len(force_fresh), "percentile": "R-7 linear interpolation", "cold_samples": 1, "exclusions": [], "artifact_scenarios_included": True},
        "scenarios": scenarios,
    }


def external(side, idle):
    bound = identity(side)
    rows = []
    for name, (unit, _direction, method) in metrics.METRICS.items():
        value = idle if name in {"app_idle_cpu_percent", "helper_idle_cpu_percent"} else 100.0
        samples = [value] if method == "filesystem-stat" else [value] * 5
        rows.append({"name": name, "unit": unit, "method": method, "samples": samples, "observation_window_seconds": 60.0, "status": "measured", "reason": None})
    return {"schema_version": metrics.SCHEMA, "side": side, "identity": {"commit": bound["commit"], "harness_identity": bound["harness"]["identity"], "harness_sha256": bound["harness"]["sha256"], "environment": bound["environment"], "artifact_sha256": bound["artifact_sha256"]}, "metrics": rows}


def attestation(side):
    bound = identity(side)
    return {"schema_version": comparison.ATTESTATION, "side": side, "commit": bound["commit"], "harness": bound["harness"], "environment": bound["environment"], "artifact_sha256": bound["artifact_sha256"], "exclusions": []}


def v3_records():
    run = {"record_type": "run", "schema_version": comparison.V3, "warm_samples": 5, "fixture_root": "/private/tmp/fixture", "artifact_scenarios_included": True, "snapshot_core_context": "test-host", "snapshot_core_limitations": "fixture", "app_bundle": "/private/tmp/LidSwitch.app", "installed_helper_path": "/private/tmp/LidSwitchHelper"}
    records = [run, {"record_type": "methodology", "schema_version": comparison.V3, "snapshot_core_context": "test-host", "snapshot_core_limitations": "fixture", "artifact_validation": "explicit", "helper_comparison": "exact"}, {"record_type": "environment", "schema_version": comparison.V3, "operating_system": "macOS 26.5.2", "architecture": "arm64"}]
    for name, kind in comparison.RELEASE_SCENARIOS.items():
        values = [1000, 1002, 1004, 1006, 1008]
        for classification, index, elapsed in [("cold", 0, 1000)] + [("warm", number + 1, value) for number, value in enumerate(values)]:
            row = {"record_type": "sample", "schema_version": comparison.V3, "scenario": name, "scenario_kind": kind, "classification": classification, "sample_index": index, "elapsed_nanoseconds": elapsed, "main_thread_elapsed_nanoseconds": 0, "counters": {"comparison_counter": 1}, "fixture_root": "/private/tmp/fixture"}
            if name == "artifact.app-bundle.validation":
                row.update({"app_bundle": "/private/tmp/LidSwitch.app", "bundle_integrity_valid": True, "bundle_version_valid": True, "codesign_exit_code": 0})
            elif name == "artifact.helper-byte-comparison":
                row.update({"app_bundle": "/private/tmp/LidSwitch.app", "bundled_helper_path": "/private/tmp/LidSwitch.app/Contents/Library/LaunchServices/LidSwitchHelper", "installed_helper_path": "/private/tmp/LidSwitchHelper", "helper_bytes_match": True})
            records.append(row)
        stats = comparison._stats(values)
        records.append({"record_type": "summary", "schema_version": comparison.V3, "scenario": name, "sample_count": 5, "median_nanoseconds": stats["median"], "p95_nanoseconds": stats["p95"], "sample_standard_deviation_nanoseconds": stats["sample_standard_deviation"], "quantile": "R-7 linear interpolation"})
    return records


class BenchmarkComparisonFixtures(unittest.TestCase):
    def compare(self, directory, candidate_values=(140, 142, 144, 146, 148), cold_force_fresh=None):
        baseline_path = write(directory / "baseline.json", normalized("baseline", [200, 202, 204, 206, 208]))
        candidate_path = write(directory / "candidate.json", normalized("candidate", list(candidate_values), cold_force_fresh))
        baseline_metrics = write(directory / "baseline-metrics.json", external("baseline", .4))
        candidate_metrics = write(directory / "candidate-metrics.json", external("candidate", .2))
        baseline, baseline_hash = comparison.load_input(baseline_path, "baseline")
        candidate, candidate_hash = comparison.load_input(candidate_path, "candidate")
        one = comparison._external(baseline_metrics, "baseline", baseline["identity"])
        two = comparison._external(candidate_metrics, "candidate", candidate["identity"])
        return comparison.compare(baseline, candidate, baseline_hash, candidate_hash, one[0], two[0])

    def test_pass_fixture_reports_absolute_and_percentage_deltas(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
            report = self.compare(pathlib.Path(temporary))
        self.assertEqual(report["verdict"], "pass")
        force_fresh = next(row for row in report["scenario_deltas"] if row["scenario"] == "fixture.installation.force-fresh")
        self.assertLessEqual(force_fresh["statistics"]["p95"]["percent_delta"], -25.0)
        self.assertTrue(report["budgets"]["force_fresh_p95_at_most_250ms"])

    def test_over_five_percent_regression_is_not_hidden(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
            report = self.compare(pathlib.Path(temporary), (213, 215, 217, 219, 221))
        self.assertEqual(report["verdict"], "regression")
        self.assertFalse(report["budgets"]["no_unexplained_over_5_percent_regression"])

    def test_drop_one_release_scenario_fails_closed(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
            directory = pathlib.Path(temporary)
            source = normalized("baseline", [200, 202, 204, 206, 208])
            source["scenarios"].pop()
            with self.assertRaises(comparison.ComparisonError):
                comparison.load_input(write(directory / "partial.json", source), "baseline")

    def test_artifact_failure_and_cold_regression_are_not_hidden(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
            directory = pathlib.Path(temporary)
            source = normalized("baseline", [200, 202, 204, 206, 208])
            artifact = next(row for row in source["scenarios"] if row["name"] == "artifact.app-bundle.validation")
            artifact["artifact_truth"]["codesign_exit_code"] = 0.0
            with self.assertRaises(comparison.ComparisonError):
                comparison.load_input(write(directory / "bad-artifact.json", source), "baseline")
            report = self.compare(directory, (140, 142, 144, 146, 148), cold_force_fresh=220)
        self.assertEqual(report["verdict"], "regression")
        force_fresh = next(row for row in report["scenario_deltas"] if row["scenario"] == "fixture.installation.force-fresh")
        self.assertTrue(force_fresh["cold"]["unexplained_regression"])

    def test_v3_artifact_probe_failure_fails_closed(self):
        records = v3_records()
        artifact = next(row for row in records if row.get("scenario") == "artifact.helper-byte-comparison" and row.get("classification") == "warm")
        artifact["helper_bytes_match"] = False
        with self.assertRaises(comparison.ComparisonError):
            comparison._v3(records, "baseline", attestation("baseline"))

    def test_metrics_reject_one_sample_cpu_and_bad_commit(self):
        record = external("baseline", .4)
        rss = next(row for row in record["metrics"] if row["name"] == "app_peak_rss_bytes")
        rss["samples"] = [100.0]
        with self.assertRaises(metrics.MetricsError):
            metrics.validate(record)
        record = external("baseline", .4)
        record["identity"]["commit"] = "A" * 40
        with self.assertRaises(metrics.MetricsError):
            metrics.validate(record)
        source = normalized("baseline", [200, 202, 204, 206, 208])
        source["identity"]["commit"] = "z" * 40
        with self.assertRaises(comparison.ComparisonError):
            comparison._normalized(source, "baseline")

    def test_noncanonical_and_missing_attestation_inputs_fail_closed(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
            directory = pathlib.Path(temporary)
            malformed = directory / "malformed.jsonl"
            malformed.write_text('{"schema_version": "lidswitch-benchmark-v3"}\n', encoding="utf-8")
            with self.assertRaises(comparison.ComparisonError):
                comparison.load_input(malformed, "baseline")
            canonical_v3 = directory / "v3.jsonl"
            canonical_v3.write_text(comparison.canonical({"schema_version": comparison.V3, "record_type": "run"}) + "\n", encoding="utf-8")
            with self.assertRaises(comparison.ComparisonError):
                comparison.load_input(canonical_v3, "baseline")

    def test_methodology_mismatch_fails_closed(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
            directory = pathlib.Path(temporary)
            baseline_path = write(directory / "baseline.json", normalized("baseline", [200, 202, 204, 206, 208]))
            candidate_path = write(directory / "candidate.json", normalized("candidate", [140, 142, 144, 146, 148, 150]))
            baseline, baseline_hash = comparison.load_input(baseline_path, "baseline")
            candidate, candidate_hash = comparison.load_input(candidate_path, "candidate")
            with self.assertRaises(comparison.ComparisonError):
                comparison.compare(baseline, candidate, baseline_hash, candidate_hash)

    def test_tools_cannot_launch_project_or_build_commands(self):
        root = pathlib.Path(__file__).resolve().parent
        banned = ("subprocess", "xcodebuild", "swift build", "run_swift", "hdiutil", "os.system")
        for name in ("benchmark_comparison.py", "release_metrics_evidence.py"):
            source = (root / name).read_text(encoding="utf-8").lower()
            for token in banned:
                self.assertNotIn(token, source)


if __name__ == "__main__":
    unittest.main()
