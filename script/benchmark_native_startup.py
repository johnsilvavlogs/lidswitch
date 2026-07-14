#!/usr/bin/python3
"""Measure LidSwitch launch-to-process, launch-to-idle, RSS, and idle CPU.

The harness uses only system tools, never starts a protected session, and
refuses to run unless ``SleepDisabled`` is zero before and after every sample.
It terminates only the exact app process it launched and publishes one
canonical create-once JSON record.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import stat
import subprocess
import sys
import time
from pathlib import Path


class BenchmarkError(RuntimeError):
    pass


def deny(message: str) -> None:
    raise BenchmarkError(message)


def run(argv: list[str], *, timeout: float = 10.0) -> str:
    try:
        completed = subprocess.run(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
            check=False,
            close_fds=True,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"},
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        deny("system-tool-failed: " + argv[0] + ": " + str(error))
    if completed.returncode != 0:
        deny("system-tool-failed: " + argv[0])
    return completed.stdout


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb", buffering=0) as handle:
        while True:
            chunk = handle.read(131072)
            if not chunk:
                return digest.hexdigest()
            digest.update(chunk)


def safe_app(value: str) -> tuple[Path, Path, dict[str, object]]:
    supplied = Path(value).expanduser()
    if not supplied.is_absolute() or supplied.is_symlink():
        deny("app-path-unsafe")
    app = supplied.resolve(strict=True)
    if app != supplied:
        deny("app-path-not-canonical")
    if app != Path("/Applications/LidSwitch.app"):
        pieces = app.parts
        if len(pieces) != 5 or tuple(pieces[:3]) != ("/", "private", "tmp"):
            deny("app-path-outside-allowed-roots")
        parent = app.parent
        parent_info = os.lstat(parent)
        if (
            not stat.S_ISDIR(parent_info.st_mode)
            or parent_info.st_uid != os.getuid()
            or parent_info.st_gid != os.getgid()
            or stat.S_IMODE(parent_info.st_mode) != 0o700
        ):
            deny("app-parent-not-private")
    app_info = os.lstat(app)
    if not stat.S_ISDIR(app_info.st_mode) or app_info.st_mode & 0o022:
        deny("app-bundle-unsafe")
    info_path = app / "Contents" / "Info.plist"
    try:
        info = plistlib.loads(info_path.read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise BenchmarkError("app-info-invalid") from error
    if not isinstance(info, dict) or info.get("CFBundleIdentifier") != "com.johnsilva.LidSwitch":
        deny("app-identity-invalid")
    name = info.get("CFBundleExecutable")
    if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", name):
        deny("app-executable-invalid")
    executable = app / "Contents" / "MacOS" / name
    executable_info = os.lstat(executable)
    if (
        executable.is_symlink()
        or not stat.S_ISREG(executable_info.st_mode)
        or executable_info.st_nlink != 1
        or executable_info.st_mode & 0o022
        or executable_info.st_size <= 0
    ):
        deny("app-executable-unsafe")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)])
    return app, executable, info


def power_observation() -> tuple[int, str]:
    output = run(["/usr/bin/pmset", "-g", "live"])
    matches = re.findall(r"(?m)^\s*SleepDisabled\s+([01])\s*$", output)
    if len(matches) != 1:
        deny("sleep-disabled-observation-invalid")
    battery = run(["/usr/bin/pmset", "-g", "batt"])
    sources = re.findall(r"(?m)^Now drawing from '([^']+)'\s*$", battery)
    if sources != ["AC Power"]:
        deny("external-power-observation-invalid")
    return int(matches[0]), sources[0]


def exact_pids(executable: Path) -> list[int]:
    output = run(["/bin/ps", "-axo", "pid=,command="])
    pids: list[int] = []
    expected = str(executable)
    for line in output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2 or not fields[0].isdigit():
            continue
        command = fields[1]
        if command == expected or command.startswith(expected + " "):
            pids.append(int(fields[0]))
    return pids


def process_sample(pid: int) -> tuple[int, float]:
    output = run(["/bin/ps", "-o", "rss=,%cpu=", "-p", str(pid)])
    fields = output.split()
    if len(fields) != 2:
        deny("process-observation-invalid")
    try:
        rss = int(fields[0]) * 1024
        cpu = float(fields[1])
    except ValueError as error:
        raise BenchmarkError("process-observation-invalid") from error
    if rss <= 0 or cpu < 0:
        deny("process-observation-invalid")
    return rss, cpu


def stop_child(child: subprocess.Popen) -> None:
    """A live child cannot have its PID reused until this parent reaps it."""
    if child.poll() is not None:
        return
    child.terminate()
    try:
        child.wait(timeout=5.0)
        return
    except subprocess.TimeoutExpired:
        child.kill()
    try:
        child.wait(timeout=5.0)
    except subprocess.TimeoutExpired:
        deny("app-process-did-not-stop")


def measure_once(app: Path, executable: Path) -> dict[str, float | int]:
    before_power = power_observation()
    if before_power != (0, "AC Power") or exact_pids(executable):
        deny("unsafe-preexisting-runtime-state")
    started = time.monotonic_ns()
    environment = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LC_ALL": "C",
        "HOME": str(Path.home()),
        "TMPDIR": os.environ.get("TMPDIR", "/private/tmp"),
    }
    try:
        child = subprocess.Popen(
            [str(executable)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            close_fds=True,
            start_new_session=True,
            env=environment,
        )
    except OSError as error:
        raise BenchmarkError("app-process-did-not-start") from error
    deadline = time.monotonic() + 10.0
    pid = child.pid
    while time.monotonic() < deadline:
        if child.poll() is not None:
            deny("app-process-exited-during-startup")
        if pid in exact_pids(executable):
            break
        time.sleep(0.02)
    else:
        deny("app-process-did-not-start")
    process_seen = time.monotonic_ns()
    peak_rss = 0
    idle_cpu = 100.0
    stable_idle = 0
    idle_seen = process_seen
    try:
        while time.monotonic() < deadline:
            rss, cpu = process_sample(pid)
            peak_rss = max(peak_rss, rss)
            idle_cpu = cpu
            if cpu <= 2.0:
                stable_idle += 1
                if stable_idle >= 3:
                    idle_seen = time.monotonic_ns()
                    break
            else:
                stable_idle = 0
            time.sleep(0.05)
        if stable_idle < 3:
            deny("app-did-not-reach-bounded-idle")
    finally:
        stop_child(child)
    if power_observation() != before_power:
        deny("app-launch-changed-power-state")
    return {
        "launch_to_process_ms": (process_seen - started) / 1_000_000.0,
        "launch_to_idle_ms": (idle_seen - started) / 1_000_000.0,
        "peak_rss_bytes": peak_rss,
        "idle_cpu_percent": idle_cpu,
    }


def tree_measure(root: Path) -> tuple[int, str]:
    total = 0
    digest = hashlib.sha256()
    for directory, names, files in os.walk(root, followlinks=False):
        names.sort()
        files.sort()
        directory_path = Path(directory)
        if directory_path.is_symlink():
            deny("app-tree-symlink")
        for name in names + files:
            path = directory_path / name
            info = os.lstat(path)
            relative = str(path.relative_to(root))
            if stat.S_ISLNK(info.st_mode):
                deny("app-tree-symlink")
            if stat.S_ISREG(info.st_mode):
                total += info.st_size
                digest.update(("F\0%s\0%d\0%d\0" % (relative, stat.S_IMODE(info.st_mode), info.st_size)).encode())
                digest.update(bytes.fromhex(sha256(path)))
            elif not stat.S_ISDIR(info.st_mode):
                deny("app-tree-special-file")
            else:
                digest.update(("D\0%s\0%d\0" % (relative, stat.S_IMODE(info.st_mode))).encode())
    return total, digest.hexdigest()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--label", choices=("baseline", "candidate"), required=True)
    parser.add_argument("--artifact-commit", required=True)
    parser.add_argument("--samples", type=int, default=5)
    args = parser.parse_args(argv)
    try:
        if not 5 <= args.samples <= 20:
            deny("sample-count-out-of-range")
        if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", args.artifact_commit):
            deny("artifact-commit-invalid")
        app, executable, info = safe_app(args.app)
        output = Path(args.output).expanduser()
        if not output.is_absolute() or output.exists() or output.is_symlink():
            deny("output-must-be-new-absolute-path")
        parent = output.parent.resolve(strict=True)
        parent_info = os.lstat(parent)
        if (
            not str(parent).startswith("/private/tmp/")
            or parent.parent != Path("/private/tmp")
            or parent_info.st_uid != os.getuid()
            or parent_info.st_gid != os.getgid()
            or stat.S_IMODE(parent_info.st_mode) != 0o700
        ):
            deny("output-parent-not-private")
        measured_started = time.monotonic()
        samples = [measure_once(app, executable) for _ in range(args.samples)]
        observation_window = time.monotonic() - measured_started
        app_tree_bytes, app_tree_sha256 = tree_measure(app)
        record = {
            "schema_version": "lidswitch-native-startup-benchmark-v1",
            "side": args.label,
            "app": {
                "path": str(app),
                "version": str(info.get("CFBundleShortVersionString")),
                "build": str(info.get("CFBundleVersion")),
                "executable_sha256": sha256(executable),
                "executable_bytes": os.lstat(executable).st_size,
                "tree_bytes": app_tree_bytes,
                "tree_sha256": app_tree_sha256,
            },
            "identity": {
                "artifact_commit": args.artifact_commit,
                "harness_sha256": sha256(Path(__file__).resolve()),
                "machine": run(["/usr/sbin/sysctl", "-n", "hw.model"]).strip(),
            },
            "environment": {
                "architecture": run(["/usr/bin/uname", "-m"]).strip(),
                "operating_system": run(["/usr/bin/sw_vers", "-productVersion"]).strip()
                    + " (" + run(["/usr/bin/sw_vers", "-buildVersion"]).strip() + ")",
                "power_state": "AC",
            },
            "observation_window_seconds": observation_window,
            "samples": samples,
        }
        payload = (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
        fd = os.open(str(output), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            view = memoryview(payload)
            while view:
                written = os.write(fd, view)
                if written <= 0:
                    deny("output-write-failed")
                view = view[written:]
            os.fsync(fd)
        finally:
            os.close(fd)
        print(json.dumps({"output": str(output), "sha256": hashlib.sha256(payload).hexdigest()}, sort_keys=True, separators=(",", ":")))
        return 0
    except (BenchmarkError, OSError) as error:
        print("native-startup-benchmark-denied: " + str(error), file=sys.stderr)
        return 65


if __name__ == "__main__":
    raise SystemExit(main())
