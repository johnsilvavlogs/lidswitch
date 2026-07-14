#!/usr/bin/python3
"""Focused tests for the fail-closed native startup metrics adapter."""
from __future__ import annotations

import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import adapt_native_startup_metrics as adapter
import release_metrics_evidence as release_metrics


def record(side):
    return {"schema_version": adapter.NATIVE_SCHEMA, "side": side, "app": {"path": "/private/tmp/LidSwitch.app", "version": "0.2.9", "build": "29", "executable_sha256": ("a" if side == "baseline" else "b") * 64, "executable_bytes": 100, "tree_bytes": 200, "tree_sha256": ("c" if side == "baseline" else "d") * 64}, "identity": {"artifact_commit": ("e" if side == "baseline" else "f") * 40, "harness_sha256": "1" * 64, "machine": "Mac16,7"}, "environment": {"architecture": "arm64", "operating_system": "26.5.2 (25G80)", "power_state": "AC"}, "observation_window_seconds": 2.5, "samples": [{"launch_to_process_ms": 20 + n, "launch_to_idle_ms": 40 + n, "peak_rss_bytes": 1000 + n, "idle_cpu_percent": .1} for n in range(5)]}


class NativeStartupAdapterTests(unittest.TestCase):
    def test_adapts_resource_metrics_and_latency_deltas(self):
        baseline, candidate = adapter.validate(record("baseline"), "baseline"), adapter.validate(record("candidate"), "candidate")
        result = adapter.adapt(baseline, candidate, "a" * 64, "b" * 64)
        baseline_external = result["baseline"]["external_metrics"]
        self.assertEqual(baseline_external["schema_version"], release_metrics.SCHEMA)
        self.assertEqual([item["name"] for item in baseline_external["metrics"]], [item[0] for item in adapter.RESOURCE_METRICS])
        self.assertEqual(release_metrics.validate(baseline_external)["missing_required"], sorted(release_metrics.REQUIRED - {item[0] for item in adapter.RESOURCE_METRICS}))
        self.assertEqual([item["metric"] for item in result["ux_latency_deltas"]], list(adapter.LATENCIES))

    def test_rejects_mismatched_harness_machine_environment_and_ac(self):
        baseline = adapter.validate(record("baseline"), "baseline")
        for field, value in (("harness_sha256", "2" * 64), ("machine", "OtherMac")):
            source = record("candidate")
            source["identity"][field] = value
            with self.assertRaises(adapter.AdapterError):
                adapter.adapt(baseline, adapter.validate(source, "candidate"), "a" * 64, "b" * 64)
        source = record("candidate")
        source["environment"]["operating_system"] = "different"
        with self.assertRaises(adapter.AdapterError):
            adapter.adapt(baseline, adapter.validate(source, "candidate"), "a" * 64, "b" * 64)
        source = record("candidate")
        source["environment"]["power_state"] = "Battery"
        with self.assertRaises(adapter.AdapterError):
            adapter.validate(source, "candidate")

    def test_rejects_schema_drift_and_noncanonical_input(self):
        source = record("baseline")
        del source["app"]["build"]
        with self.assertRaises(adapter.AdapterError):
            adapter.validate(source, "baseline")
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
            path = pathlib.Path(temporary) / "benchmark.json"
            path.write_text('{"side":"baseline","schema_version":"lidswitch-native-startup-benchmark-v1"}\n', encoding="utf-8")
            with self.assertRaises(adapter.AdapterError):
                adapter.load_canonical(path)

    def test_even_count_uses_r7_median_and_counts_must_match(self):
        baseline, candidate = record("baseline"), record("candidate")
        for source in (baseline, candidate):
            source["samples"] = source["samples"] + [{"launch_to_process_ms": 100, "launch_to_idle_ms": 200, "peak_rss_bytes": 2000, "idle_cpu_percent": .1}]
        result = adapter.adapt(adapter.validate(baseline, "baseline"), adapter.validate(candidate, "candidate"), "a" * 64, "b" * 64)
        self.assertEqual(result["ux_latency_deltas"][0]["baseline_median"], 22.5)
        candidate["samples"].pop()
        with self.assertRaises(adapter.AdapterError):
            adapter.adapt(adapter.validate(baseline, "baseline"), adapter.validate(candidate, "candidate"), "a" * 64, "b" * 64)

    def test_rejects_nonpositive_or_noninteger_byte_observations(self):
        for location, key, value in (("app", "executable_bytes", 0), ("app", "tree_bytes", 1.0), ("sample", "peak_rss_bytes", 0), ("sample", "peak_rss_bytes", 1.0)):
            source = record("baseline")
            (source["app"] if location == "app" else source["samples"][0])[key] = value
            with self.assertRaises(adapter.AdapterError):
                adapter.validate(source, "baseline")

    def test_cli_emits_release_metrics_compatible_sidecars(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
            directory = pathlib.Path(temporary)
            baseline, candidate = directory / "baseline.json", directory / "candidate.json"
            baseline.write_text(adapter.canonical(record("baseline")) + "\n", encoding="utf-8")
            candidate.write_text(adapter.canonical(record("candidate")) + "\n", encoding="utf-8")
            report, baseline_external, candidate_external = directory / "report.json", directory / "baseline-external.json", directory / "candidate-external.json"
            self.assertEqual(adapter.main(["--baseline", str(baseline), "--candidate", str(candidate), "--output", str(report), "--baseline-external-output", str(baseline_external), "--candidate-external-output", str(candidate_external)]), 0)
            checked, _digest = release_metrics.load_canonical(baseline_external)
            self.assertEqual(checked["side"], "baseline")
            self.assertEqual(release_metrics.load_canonical(candidate_external)[0]["side"], "candidate")
            self.assertEqual(adapter.main(["--baseline", str(baseline), "--candidate", str(candidate), "--output", str(report)]), 65)
            self.assertEqual(adapter.main(["--baseline", str(baseline), "--candidate", str(candidate), "--baseline-external-output", str(directory / "only-one.json")]), 65)


if __name__ == "__main__":
    unittest.main()
