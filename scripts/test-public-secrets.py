#!/usr/bin/python3
"""Isolated fixtures for the authoritative descriptor-relative scanner."""

from __future__ import annotations

import importlib.util
import hashlib
import os
import pathlib
import subprocess
import sys
import tempfile
from typing import Union

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
SCANNER_PATH = SCRIPT_DIR / "scan-public-secrets.py"
VALIDATE_DMG_PATH = SCRIPT_DIR.parent / "script" / "validate_dmg.sh"
SPEC = importlib.util.spec_from_file_location("public_secret_scanner", SCANNER_PATH)
assert SPEC and SPEC.loader
scanner = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = scanner
SPEC.loader.exec_module(scanner)

TOKEN_BODY = "A" * 30


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def write(root: str, relative_path: str, data: Union[bytes, str]) -> str:
    path = os.path.join(root, relative_path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if isinstance(data, bytes):
        with open(path, "wb") as handle:
            handle.write(data)
    else:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(data)
    return path


def failure(callback, code: str, message: str):
    try:
        callback()
    except scanner.ScanFailure as error:
        require(error.code == code, f"{message}: expected {code}, got {error.code}")
        return error
    raise AssertionError(f"{message}: expected scanner failure")


def cli(root: str, *extra: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["/usr/bin/python3", "-I", "-S", str(SCANNER_PATH), *extra, "--path", root], text=True, capture_output=True, check=False)


def test_no_echo_and_private_forms() -> None:
    with tempfile.TemporaryDirectory(prefix="lidswitch-secret-scan-") as root:
        synthetic = "ghp_" + TOKEN_BODY
        write(root, "leak.txt", f"token={synthetic}\n")
        result = cli(root)
        require(result.returncode == 1 and "type=source-observation-finding" in result.stderr and "label=github-token" in result.stderr, "synthetic token should be reported")
        require(synthetic not in result.stdout and synthetic not in result.stderr, "scanner must not echo a matched value")
        for form in ("EC", "DSA", "ENCRYPTED"):
            write(root, f"{form}.pem", f"-----BEGIN {form} PRIVATE KEY-----\n")
        findings = scanner.scan_public_secrets([root])["findings"]
        require(sum(finding["label"] == "private-key" for finding in findings) == 3, "expanded private-key forms should be detected")


def test_streaming_binary_and_overlap() -> None:
    with tempfile.TemporaryDirectory(prefix="lidswitch-secret-scan-") as root:
        token = ("gho_" + TOKEN_BODY).encode()
        write(root, "boundary.bin", b"\0" * (scanner.CHUNK_BYTES - 2) + token)
        write(root, "large-tail.bin", b"\0" * 1_500_001 + token)
        write(root, "binary.bin", b"\0\x01" + token + b"\x00")
        findings = scanner.scan_public_secrets([root])["findings"]
        require(sum(finding["label"] == "github-token" for finding in findings) == 3, "streaming binary fixtures should all be detected")
        require(scanner.MAX_DETECTOR_MATCH_BYTES < scanner.OVERLAP_BYTES, "detector bound must remain below overlap")
        write(root, "binary-barrier.bin", b"token\x00=" + token)
        barrier = scanner.scan_public_secrets([root])["findings"]
        require(not any(finding["path"] == "binary-barrier.bin" and finding["label"] == "generic-secret-assignment" for finding in barrier), "binary controls must not bridge whitespace")


def test_source_release_and_special_inputs() -> None:
    with tempfile.TemporaryDirectory(prefix="lidswitch-secret-scan-") as root:
        token = "ghr_" + TOKEN_BODY
        write(root, "node_modules/hidden.txt", f"token={token}\n")
        write(root, ".git/hidden.txt", f"token={token}\n")
        write(root, "playwright-report/hidden.txt", f"token={token}\n")
        write(root, "dist", f"token={token}\n")
        source = scanner.scan_public_secrets([root])
        require(any(finding["path"] == "dist" for finding in source["findings"]), "regular files named like excluded directories must be scanned")
        require(not any(any(name in finding["path"] for name in ("node_modules", ".git", "playwright-report")) for finding in source["findings"]), "source mode should skip only actual generated directories")
        failure(lambda: scanner.scan_public_secrets(["/private/path-that-must-not-be-opened"], release_artifacts=True), "immutable-candidate-manifest-required", "release qualification must refuse before path consumption")
        failure(lambda: scanner.Scanner(True).scan(["/private/path-that-must-not-be-opened"]), "immutable-candidate-manifest-required", "direct scanner release mode must also refuse before path consumption")
        release = cli("/private/path-that-must-not-be-opened", "--release-artifacts")
        require(release.returncode == 2 and release.stdout == "" and release.stderr.count("record type=terminal-failure") == 1 and "code=immutable-candidate-manifest-required" in release.stderr, "release CLI must map refusal to one typed terminal record")
        os.symlink(os.path.join(root, "dist"), os.path.join(root, "linked"))
        failure(lambda: scanner.scan_public_secrets([root]), "symlink-input-rejected", "symlink fixture")

    with tempfile.TemporaryDirectory(prefix="lidswitch-secret-scan-") as root:
        fifo = os.path.join(root, "fixture.fifo")
        os.mkfifo(fifo)
        failure(lambda: scanner.scan_public_secrets([root]), "nonregular-input-rejected", "nonregular fixture")


def test_nonblocking_fifo_replacement() -> None:
    with tempfile.TemporaryDirectory(prefix="lidswitch-secret-scan-") as root:
        target = write(root, "replace-with-fifo", "safe\n")
        replaced = False

        def replace_before_open(parts):
            nonlocal replaced
            if parts == ("replace-with-fifo",) and not replaced:
                os.unlink(target)
                os.mkfifo(target)
                replaced = True

        failure(
            lambda: scanner.scan_public_secrets([root], hooks={"before_open": replace_before_open}),
            "file-identity-changed",
            "FIFO replacement must fail instead of blocking",
        )
        require(replaced, "FIFO fixture hook should run exactly in the lstat-to-open window")


def test_midread_change_caps_receipts_and_provenance() -> None:
    with tempfile.TemporaryDirectory(prefix="lidswitch-secret-scan-") as root:
        target = write(root, "replace.bin", b"A" * (scanner.CHUNK_BYTES * 2))
        def replace(parts, chunk, _offset):
            if parts == ("replace.bin",) and chunk == 1:
                replacement = write(root, "replacement.bin", b"B" * (scanner.CHUNK_BYTES * 2))
                os.replace(replacement, target)
        failure(lambda: scanner.scan_public_secrets([root], hooks={"after_read": replace}), "file-path-changed-during-read", "mid-read replacement")

    with tempfile.TemporaryDirectory(prefix="lidswitch-secret-scan-") as root:
        target = write(root, "truncate.bin", b"A" * (scanner.CHUNK_BYTES * 2))
        def truncate(parts, chunk, _offset):
            if parts == ("truncate.bin",) and chunk == 1:
                os.truncate(target, 0)
        failure(lambda: scanner.scan_public_secrets([root], hooks={"after_read": truncate}), "file-truncated-during-read", "mid-read truncation")

    with tempfile.TemporaryDirectory(prefix="lidswitch-secret-scan-") as root:
        target = write(root, "unlink.bin", b"A" * (scanner.CHUNK_BYTES * 2))
        def unlink(parts, chunk, _offset):
            if parts == ("unlink.bin",) and chunk == 1:
                os.unlink(target)
        failure(lambda: scanner.scan_public_secrets([root], hooks={"after_read": unlink}), "file-path-changed-during-read", "mid-read unlink")

    with tempfile.TemporaryDirectory(prefix="lidswitch-secret-scan-") as root:
        target = write(root, "modify.bin", b"A" * (scanner.CHUNK_BYTES * 2))
        def modify(parts, chunk, _offset):
            if parts == ("modify.bin",) and chunk == 1:
                with open(target, "r+b") as handle:
                    handle.write(b"B")
        failure(lambda: scanner.scan_public_secrets([root], hooks={"after_read": modify}), "file-changed-during-read", "mid-read same-size modification")

    with tempfile.TemporaryDirectory(prefix="lidswitch-secret-scan-") as root:
        write(root, "a.txt", "safe\n")
        write(root, "b.txt", "safe\n")
        error = failure(lambda: scanner.scan_public_secrets([root], limits={"max_paths": 2}), "path-count-cap-exceeded", "path cap")
        require(error.partial["summary"]["files"] == 0 and error.partial["summary"]["paths"] == 1, "directory entry cap must fail before collecting or scanning beyond the remaining budget")

    with tempfile.TemporaryDirectory(prefix="lidswitch-secret-scan-") as root:
        first = write(root, "same-a.txt", "safe\n")
        second = write(root, "same-b.txt", "safe\n")
        result = scanner.scan_public_secrets([second, first])
        roots = [receipt["root"] for receipt in result["receipts"]]
        require(roots[0].startswith("root-1-") and roots[1].startswith("root-2-") and roots[0] != roots[1], "multiple roots need stable opaque provenance")
        require(result == scanner.scan_public_secrets([second, first]), "receipts and findings should be deterministic")


def test_end_inventory_revalidation() -> None:
    def later_hook(root: str, mutation):
        def after_file(parts):
            if parts == ("z-later.txt",):
                mutation()
        return after_file

    with tempfile.TemporaryDirectory(prefix="lidswitch-secret-scan-") as root:
        early = write(root, "a-early.txt", "original\n")
        write(root, "z-later.txt", "safe\n")
        def modify_in_place():
            with open(early, "r+b") as handle:
                handle.write(b"changed!")
        failure(
            lambda: scanner.scan_public_secrets([root], hooks={"after_file": later_hook(root, modify_in_place)}),
            "inventory-content-changed-during-revalidation",
            "post-scan same-inode mutation",
        )

    with tempfile.TemporaryDirectory(prefix="lidswitch-secret-scan-") as root:
        early = write(root, "a-early.txt", "original\n")
        write(root, "z-later.txt", "safe\n")
        failure(
            lambda: scanner.scan_public_secrets([root], hooks={"before_revalidate": lambda: os.unlink(early)}),
            "inventory-root-changed-during-revalidation",
            "final-inventory unlink",
        )

    with tempfile.TemporaryDirectory(prefix="lidswitch-secret-scan-") as root:
        early = write(root, "a-early.txt", "original\n")
        os.link(early, os.path.join(root, "b-hardlink.txt"))
        write(root, "z-later.txt", "safe\n")
        def mutate_hardlink():
            with open(os.path.join(root, "b-hardlink.txt"), "r+b") as handle:
                handle.write(b"changed!")
        failure(
            lambda: scanner.scan_public_secrets([root], hooks={"after_file": later_hook(root, mutate_hardlink)}),
            "inventory-content-changed-during-revalidation",
            "post-scan hardlink mutation",
        )

    with tempfile.TemporaryDirectory(prefix="lidswitch-secret-scan-") as root:
        early = write(root, "a-early.txt", "original\n")
        write(root, "z-later.txt", "safe\n")
        failure(
            lambda: scanner.scan_public_secrets([root], hooks={"before_revalidate": lambda: os.rename(early, os.path.join(root, "renamed.txt"))}),
            "inventory-root-changed-during-revalidation",
            "final-inventory rename",
        )


def test_source_observation_late_mutation_boundary() -> None:
    with tempfile.TemporaryDirectory(prefix="lidswitch-secret-scan-") as root:
        early = write(root, "a-early.txt", "original\n")
        write(root, "z-later.txt", "safe\n")
        mutated = False

        def mutate_after_own_revalidation(parts):
            nonlocal mutated
            if parts == ("a-early.txt",) and not mutated:
                with open(early, "r+b") as handle:
                    handle.write(b"changed!")
                mutated = True

        result = scanner.scan_public_secrets([root], hooks={"after_revalidate_file": mutate_after_own_revalidation})
        receipt = next(item for item in result["receipts"] if item["path"] == "a-early.txt")
        with open(early, "rb") as handle:
            current_digest = hashlib.sha256(handle.read()).hexdigest()
        require(mutated and receipt["sha256"] != current_digest, "late mutation must demonstrate non-atomic source observation")
        require(result["scope"] == {"mode": "source-observation", "status": "source-observation-complete", "limitation": scanner.SOURCE_OBSERVATION_LIMITATION, "release_qualified": False}, "source results must never claim immutable release evidence")

    with tempfile.TemporaryDirectory(prefix="lidswitch-secret-scan-") as root:
        write(root, "nested/inside.txt", "safe\n")
        write(root, "z-later.txt", "safe\n")
        changed = False

        def mutate_nested_after_own_revalidation(parts):
            nonlocal changed
            if parts == ("nested",) and not changed:
                write(root, "nested/late.txt", "safe\n")
                changed = True

        result = scanner.scan_public_secrets([root], hooks={"after_revalidate_directory": mutate_nested_after_own_revalidation})
        require(changed and result["scope"]["mode"] == "source-observation" and not result["scope"]["release_qualified"], "nested late mutation must remain explicitly observational")


def test_finding_caps_whitespace_and_safe_paths() -> None:
    with tempfile.TemporaryDirectory(prefix="lidswitch-secret-scan-") as root:
        repeated = "\n".join(f"token=ghp_{TOKEN_BODY}" for _ in range(8))
        write(root, "many-findings.txt", repeated)
        error = failure(
            lambda: scanner.scan_public_secrets([root], limits={"max_findings_per_file": 2, "max_findings_total": 3}),
            "finding-limit-exceeded",
            "finding caps",
        )
        coverage = error.partial["coverage"]
        require(len(coverage) == 1 and coverage[0]["status"] == "finding-limit-exceeded", "finding cap must leave a typed coverage receipt")
        require(coverage[0]["file_findings"] == 2 and coverage[0]["aggregate_findings"] == 2, "coverage receipt must report bounded counts")

    with tempfile.TemporaryDirectory(prefix="lidswitch-secret-scan-") as root:
        value = "A" * 30
        write(root, "text-ff.txt", f"password\f=\f{value}\rpassword={value}\r")
        write(root, "binary-ff.bin", b"\0password\f=\f" + value.encode("ascii"))
        result = scanner.scan_public_secrets([root])
        text = [item for item in result["findings"] if item["path"] == "text-ff.txt" and item["label"] == "generic-secret-assignment"]
        require([item["line"] for item in text] == [1, 2], "FF and CR-only text whitespace must retain detector and line semantics")
        require(not any(item["path"] == "binary-ff.bin" and item["label"] == "generic-secret-assignment" for item in result["findings"]), "binary FF must remain a barrier")

    with tempfile.TemporaryDirectory(prefix="lidswitch-secret-scan-") as root:
        bidi_name = "bidi\u202e-control.txt"
        write(root, bidi_name, "safe\n")
        write(root, "space name:equals=.txt", "safe\n")
        result = scanner.scan_public_secrets([root])
        paths = [receipt["path"] for receipt in result["receipts"]]
        require(all(path.startswith("sha256:") for path in paths), "unsafe grammar paths must be hashed")
        surrogate = "surrogate-" + chr(0xDCFF)
        require(scanner.display_path((surrogate,)).startswith("sha256:"), "surrogateescaped paths must be hashed")
        require(bidi_name not in str(result) and surrogate not in str(result), "unsafe paths must not echo in output")


def test_dmg_source_binding_proof() -> None:
    source = VALIDATE_DMG_PATH.read_text(encoding="utf-8")
    mode = VALIDATE_DMG_PATH.stat().st_mode & 0o777
    require(mode == 0o755, "DMG refusal must remain directly executable at mode 0755")
    require(source.startswith("#!/bin/bash -p\n"), "DMG refusal must use privileged bash startup")
    require("PATH=/usr/bin:/bin:/usr/sbin:/sbin" in source and "export PATH" in source, "DMG refusal must set a fixed PATH")
    require("immutable-candidate-required code=legacy-dmg-validator-retired phase=unqualified" in source and source.rstrip().endswith("exit 65") and source.count("exit ") == 1, "DMG refusal must be typed and all paths nonzero")
    forbidden = ("source ", "release.env", "$(", "`", "build", "cp ", "rm ", "xattr", "codesign", "shasum", "mount", "scan-public-secrets", "hdiutil")
    require(not any(token in source for token in forbidden), "DMG refusal must have no executable or mutation route")


def test_distribution_release_truth() -> None:
    source = (SCRIPT_DIR.parent / "docs" / "DISTRIBUTION.md").read_text(encoding="utf-8")
    require("current public manual release" in source and "v0.2.11" in source, "distribution docs must state the current release")
    require("c2ab38170b2ae42fd46b234ba83cbe974a983d85" in source, "distribution docs must bind the release tag to its exact source")
    require("ecfb76230b92636018375997af6e14a61a1a3b28cf4fe5d272ddf75e6fcfa7ce" in source, "distribution docs must bind the release asset digest")
    require("peer-process-invalid" in source and "SleepDisabled=0" in source and "no automatic rearm" in source, "distribution docs must state native canary acceptance")
    require("ad-hoc signing" in source and "no Developer ID" in source and "no notarization" in source, "distribution docs must retain the manual trust boundary")
    forbidden = ("blocked release candidate", "not a built, distributed", "intended future tier", "full-release", "checks are green", "Publish `dist/", "Packaging commands:", "./script/build_dmg.sh", "./script/validate_dmg.sh")
    require(not any(token in source for token in forbidden), "distribution docs must not retain blocked, green, or legacy packaging claims")


def test_path_redaction() -> None:
    with tempfile.TemporaryDirectory(prefix="lidswitch-secret-scan-") as root:
        unsafe_name = "ghp_" + TOKEN_BODY
        write(root, unsafe_name, "safe\n")
        result = scanner.scan_public_secrets([root])
        receipt = result["receipts"][0]
        require(receipt["path"].startswith("sha256:"), "detector-shaped path must be redacted")
        require(unsafe_name not in str(result), "unsafe path must not appear in receipts or findings")


def main() -> int:
    if not scanner.qualified_interpreter():
        print("public secret scanner regression failed: isolated-python-required", file=sys.stderr)
        return 2
    test_no_echo_and_private_forms()
    test_streaming_binary_and_overlap()
    test_source_release_and_special_inputs()
    test_nonblocking_fifo_replacement()
    test_midread_change_caps_receipts_and_provenance()
    test_end_inventory_revalidation()
    test_source_observation_late_mutation_boundary()
    test_finding_caps_whitespace_and_safe_paths()
    test_path_redaction()
    test_dmg_source_binding_proof()
    test_distribution_release_truth()
    print("public secret scanner regression ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
