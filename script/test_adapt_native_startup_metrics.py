#!/usr/bin/python3
"""Focused tests for the fail-closed native startup metrics adapter."""
from __future__ import annotations

import copy
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import adapt_native_startup_metrics as adapter
import benchmark_native_startup as benchmark
import release_metrics_evidence as release_metrics


def record(side):
    def sample(n):
        return {"launch_to_process_ms": 20 + n, "launch_to_ready_ms": 30 + n, "launch_to_idle_ms": 1040 + n, "peak_rss_bytes": 1000 + n, "idle_cpu_percent": .1}
    state = {"power": {"sleep_disabled": 0, "source": "AC Power"}, "activation_lease": {"path": "/Users/test/Library/Application Support/LidSwitch/activation-lease", "state": "absent"}, "desired_state": {"path": "/Users/test/Library/Application Support/LidSwitch/desired-state", "state": "absent"}, "applied_state": {"path": "/Library/Application Support/LidSwitch/applied-state", "state": "absent"}}
    return {"schema_version": adapter.NATIVE_SCHEMA, "side": side, "app": {"path": "/private/tmp/LidSwitch.app", "version": "0.2.9", "build": "29", "executable_sha256": ("a" if side == "baseline" else "b") * 64, "executable_bytes": 100, "tree_bytes": 200, "tree_sha256": ("c" if side == "baseline" else "d") * 64}, "identity": {"artifact_commit": ("e" if side == "baseline" else "f") * 40, "harness_sha256": "1" * 64, "machine": "Mac16,7"}, "environment": {"architecture": "arm64", "operating_system": "26.5.2 (25F84)", "power_state": "AC"}, "methodology": {"cold_samples": 1, "discarded_warmup_samples": 1, "warm_samples": 5, "readiness_observer": "unique-enabled-axmenuextra-for-exact-pid", "idle_cpu_threshold_percent": 2.0, "idle_window_seconds": 1.0, "minimum_idle_samples": 5, "poll_interval_seconds": 0.1}, "host_state": {"before": state, "after": copy.deepcopy(state)}, "observation_window_seconds": 2.5, "cold_sample": sample(10), "discarded_warmup_sample": sample(20), "warm_samples": [sample(n) for n in range(5)]}


class NativeStartupAdapterTests(unittest.TestCase):
    def test_adapts_resource_metrics_and_latency_deltas(self):
        baseline, candidate = adapter.validate(record("baseline"), "baseline"), adapter.validate(record("candidate"), "candidate")
        result = adapter.adapt(baseline, candidate, "a" * 64, "b" * 64)
        baseline_external = result["baseline"]["external_metrics"]
        self.assertEqual(baseline_external["schema_version"], release_metrics.SCHEMA)
        self.assertEqual([item["name"] for item in baseline_external["metrics"]], [item[0] for item in adapter.RESOURCE_METRICS])
        self.assertEqual(release_metrics.validate(baseline_external)["missing_required"], sorted(release_metrics.REQUIRED - {item[0] for item in adapter.RESOURCE_METRICS}))
        self.assertEqual([item["metric"] for item in result["ux_latency_deltas"]], list(adapter.LATENCIES))
        self.assertIn("p95", result["ux_latency_deltas"][0]["warm"]["baseline"])
        self.assertEqual(result["ux_latency_deltas"][0]["cold"]["baseline"], 30.0)

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
            source["warm_samples"] = source["warm_samples"] + [{"launch_to_process_ms": 100, "launch_to_ready_ms": 150, "launch_to_idle_ms": 1200, "peak_rss_bytes": 2000, "idle_cpu_percent": .1}]
            source["methodology"]["warm_samples"] = 6
        result = adapter.adapt(adapter.validate(baseline, "baseline"), adapter.validate(candidate, "candidate"), "a" * 64, "b" * 64)
        self.assertEqual(result["ux_latency_deltas"][0]["warm"]["baseline"]["median"], 22.5)
        candidate["warm_samples"].pop()
        candidate["methodology"]["warm_samples"] = 5
        with self.assertRaises(adapter.AdapterError):
            adapter.adapt(adapter.validate(baseline, "baseline"), adapter.validate(candidate, "candidate"), "a" * 64, "b" * 64)

    def test_rejects_nonpositive_or_noninteger_byte_observations(self):
        for location, key, value in (("app", "executable_bytes", 0), ("app", "tree_bytes", 1.0), ("sample", "peak_rss_bytes", 0), ("sample", "peak_rss_bytes", 1.0)):
            source = record("baseline")
            (source["app"] if location == "app" else source["warm_samples"][0])[key] = value
            with self.assertRaises(adapter.AdapterError):
                adapter.validate(source, "baseline")

    def test_rejects_lifecycle_and_methodology_drift(self):
        source = record("baseline")
        source["warm_samples"][0]["launch_to_ready_ms"] = 10
        with self.assertRaises(adapter.AdapterError):
            adapter.validate(source, "baseline")
        source = record("baseline")
        source["methodology"]["readiness_observer"] = "cpu-only"
        with self.assertRaises(adapter.AdapterError):
            adapter.validate(source, "baseline")
        source = record("baseline")
        source["methodology"]["warm_samples"] = 5.0
        with self.assertRaises(adapter.AdapterError):
            adapter.validate(source, "baseline")

    def test_rejects_host_state_drift_or_active_authority(self):
        source = record("baseline")
        source["host_state"]["after"] = dict(source["host_state"]["after"])
        source["host_state"]["after"]["power"] = {"sleep_disabled": 1, "source": "AC Power"}
        with self.assertRaises(adapter.AdapterError):
            adapter.validate(source, "baseline")
        source = record("baseline")
        source["host_state"]["before"]["activation_lease"] = {"path": "/tmp/lease", "state": "present"}
        source["host_state"]["after"]["activation_lease"] = {"path": "/tmp/lease", "state": "present"}
        with self.assertRaises(adapter.AdapterError):
            adapter.validate(source, "baseline")

    def test_rejects_cross_side_host_state_mismatch(self):
        baseline, candidate = record("baseline"), record("candidate")
        desired = {"path": "/Users/test/Library/Application Support/LidSwitch/desired-state", "state": "present", "device": 1, "inode": 2, "uid": 501, "gid": 20, "mode": 0o600, "size": 12, "sha256": "a" * 64}
        candidate["host_state"]["before"]["desired_state"] = desired
        candidate["host_state"]["after"]["desired_state"] = copy.deepcopy(desired)
        checked_baseline = adapter.validate(baseline, "baseline")
        checked_candidate = adapter.validate(candidate, "candidate")
        with self.assertRaisesRegex(adapter.AdapterError, "host states differ"):
            adapter.adapt(checked_baseline, checked_candidate, "a" * 64, "b" * 64)

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


class FakeChild:
    pid = 42

    def __init__(self):
        self.terminated = False

    def poll(self):
        return None

    def terminate(self):
        self.terminated = True

    def wait(self, timeout):
        return 0

    def kill(self):
        raise AssertionError("kill should not be needed")


class FakeClock:
    def __init__(self):
        self.nanoseconds = 0

    def now(self):
        return self.nanoseconds

    def sleep(self, seconds):
        self.nanoseconds += int(seconds * 1_000_000_000)


class NativeStartupReadinessTests(unittest.TestCase):
    def test_pid_discovery_failure_still_stops_launched_child(self):
        child = FakeChild()
        state = {"power": {"sleep_disabled": 0, "source": "AC Power"}}
        with (
            mock.patch.object(benchmark, "safe_host_state", return_value=state),
            mock.patch.object(benchmark, "exact_pids", side_effect=[[], benchmark.BenchmarkError("injected")]),
            mock.patch.object(benchmark.subprocess, "Popen", return_value=child),
        ):
            with self.assertRaisesRegex(benchmark.BenchmarkError, "injected"):
                benchmark.measure_once(pathlib.Path("/private/tmp/LidSwitch.app"), pathlib.Path("/private/tmp/LidSwitch.app/Contents/MacOS/LidSwitch"))
        self.assertTrue(child.terminated)

    def test_low_cpu_before_status_item_cannot_false_green(self):
        clock = FakeClock()
        samples = iter([
            (32 * 1024, 0.1),
            (11 * 1024 * 1024, 1.9),
            (70 * 1024 * 1024, 8.0),
            *[(78 * 1024 * 1024, 0.5)] * 20,
        ])

        ready, idle, peak, idle_cpu = benchmark.observe_ready_idle(
            FakeChild(),
            42,
            3_000_000_000,
            readiness_observer=lambda _pid: clock.now() >= 200_000_000,
            sample_observer=lambda _pid: next(samples),
            clock=clock.now,
            sleeper=clock.sleep,
        )

        self.assertEqual(ready, 200_000_000)
        self.assertGreaterEqual(idle - ready, 1_100_000_000)
        self.assertEqual(peak, 78 * 1024 * 1024)
        self.assertEqual(idle_cpu, 0.5)

    def test_busy_sample_restarts_the_entire_idle_window(self):
        clock = FakeClock()
        values = [(80 * 1024 * 1024, 0.2)] * 5 + [(80 * 1024 * 1024, 3.0)] + [(80 * 1024 * 1024, 0.4)] * 20
        samples = iter(values)

        ready, idle, _peak, _idle_cpu = benchmark.observe_ready_idle(
            FakeChild(),
            42,
            4_000_000_000,
            readiness_observer=lambda _pid: True,
            sample_observer=lambda _pid: next(samples),
            clock=clock.now,
            sleeper=clock.sleep,
        )

        self.assertEqual(ready, 0)
        self.assertGreaterEqual(idle, 1_600_000_000)

    def test_missing_status_item_fails_closed(self):
        clock = FakeClock()
        with self.assertRaisesRegex(benchmark.BenchmarkError, "app-status-item-did-not-become-ready"):
            benchmark.observe_ready_idle(
                FakeChild(),
                42,
                500_000_000,
                readiness_observer=lambda _pid: False,
                sample_observer=lambda _pid: (80 * 1024 * 1024, 0.0),
                clock=clock.now,
                sleeper=clock.sleep,
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
