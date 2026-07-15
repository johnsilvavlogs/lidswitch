#!/usr/bin/python3
"""Fail-closed public/release secret scanner with descriptor-relative traversal."""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import stat
import sys
import unicodedata
from dataclasses import dataclass
from typing import Callable, Iterable, Optional

MINIMUM_PYTHON = (3, 8)
SOURCE_OBSERVATION_LIMITATION = "bounded-two-pass-drift-detection-not-an-immutable-snapshot"

if sys.version_info < MINIMUM_PYTHON:
    print("public secret scan failed: python-3.8-or-newer-required", file=sys.stderr)
    raise SystemExit(2)

CHUNK_BYTES = 64 * 1024
OVERLAP_BYTES = 1024
# The longest expression is `authorization: bearer <token>` at
# 13 + 32 + 1 + 32 + 6 + 32 + 512 = 628 bytes. Every detector deliberately
# has bounded whitespace and credential material, so 1024 retained bytes are
# sufficient to recognize every match spanning a 64 KiB read boundary.
MAX_DETECTOR_MATCH_BYTES = 628
DEFAULT_LIMITS = {
    "max_paths": 50_000,
    "max_total_bytes": 512 * 1024 * 1024,
    "max_file_bytes": 256 * 1024 * 1024,
    "max_path_bytes": 4096,
    "max_findings_per_file": 1_000,
    "max_findings_total": 10_000,
}
SOURCE_EXCLUDED_DIRECTORIES = frozenset({
    ".agents", ".build", ".direnv", ".git", ".jtbd-done-gate",
    ".playwright-artifacts", ".tmp", "coverage", "DerivedData", "dist",
    "node_modules", "pkg", "playwright-report", "test-results", "tmp", "work",
})

DETECTORS = (
    ("private-key", re.compile(r"BEGIN (?:RSA |OPENSSH |EC |DSA |ENCRYPTED )?PRIVATE KEY", re.ASCII)),
    ("openai-key", re.compile(r"\bsk-[A-Za-z0-9_-]{20,512}(?![A-Za-z0-9_-])", re.ASCII)),
    ("github-token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{20,512}|github_pat_[A-Za-z0-9_]{20,512})(?![A-Za-z0-9_])", re.ASCII)),
    ("slack-token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,512}(?![A-Za-z0-9-])", re.ASCII)),
    ("aws-access-key", re.compile(r"\bAKIA[0-9A-Z]{16}\b", re.ASCII)),
    ("aws-secret-assignment", re.compile(r"\bAWS_(?:ACCESS_KEY_ID|SECRET_ACCESS_KEY)\b\s{0,32}[:=]\s{0,32}[\"']?[A-Za-z0-9/+=]{16,512}(?![A-Za-z0-9/+=])", re.ASCII)),
    ("google-credentials-assignment", re.compile(r"\bGOOGLE_APPLICATION_CREDENTIALS\b\s{0,32}[:=]\s{0,32}[\"']?[^\"'\s]{8,512}(?![^\"'\s])", re.ASCII)),
    ("bearer-token", re.compile(r"(?:\bauthorization\s{0,32}:\s{0,32}bearer\s{1,32}[A-Za-z0-9._-]{20,512}(?![A-Za-z0-9._-])|\bbearer\s{1,32}[A-Za-z0-9._-]{32,512}(?![A-Za-z0-9._-]))", re.ASCII | re.IGNORECASE)),
    ("generic-secret-assignment", re.compile(r"\b(?:api[_-]?key|client_secret|secret|token|password|passwd)\b\s{0,32}[:=]\s{0,32}[\"']?[A-Za-z0-9_./+=-]{16,512}(?![A-Za-z0-9_./+=-])", re.ASCII | re.IGNORECASE)),
)

if MAX_DETECTOR_MATCH_BYTES >= OVERLAP_BYTES:
    raise RuntimeError("detector bound must remain below overlap")


class ScanFailure(Exception):
    def __init__(self, code: str, partial: Optional[dict] = None, root: str = "root-none", phase: str = "source-observation"):
        super().__init__(code)
        self.code = code
        self.partial = partial
        self.root = root
        self.phase = phase


def fail(code: str) -> None:
    raise ScanFailure(code)


def qualified_interpreter() -> bool:
    """Only an explicit `/usr/bin/python3 -I -S` entry route is qualified."""
    return sys.flags.isolated == 1 and sys.flags.no_site == 1


def stat_identity(value: os.stat_result) -> tuple:
    """Exact nanosecond identity used before, during, and after reads."""
    return (
        value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_gid,
        value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns,
    )


def same_identity(left: os.stat_result, right: os.stat_result) -> bool:
    return stat_identity(left) == stat_identity(right)


def name_key(name: str) -> bytes:
    return name.encode("utf-8", "surrogateescape")


def contains_unsafe_path_content(raw_path: str) -> bool:
    for character in raw_path:
        codepoint = ord(character)
        if (codepoint < 32 or 0x7F <= codepoint <= 0x9F
                or codepoint in (0x2028, 0x2029) or 0xD800 <= codepoint <= 0xDFFF):
            return True
        # Format characters include bidi overrides/isolation controls. Hash
        # rather than escaping them so output cannot be visually reordered.
        if unicodedata.category(character) == "Cf":
            return True
        if character.isspace() or character in ":=":
            return True
    return any(pattern.search(raw_path) for _, pattern in DETECTORS)


def display_path(parts: tuple[str, ...]) -> str:
    raw_path = "/".join(parts) if parts else "."
    if contains_unsafe_path_content(raw_path):
        digest = hashlib.sha256(raw_path.encode("utf-8", "surrogateescape")).hexdigest()
        return f"sha256:{digest}"
    return raw_path


def root_key(root: str) -> int:
    return int(root.split("-", 2)[1])


def root_label(index: int, path: str) -> str:
    """Stable ordinal plus a non-reversible exact encoded-root provenance ID."""
    digest = hashlib.sha256(os.fsencode(path)).hexdigest()
    return f"root-{index}-{digest}"


def is_binary(sample: bytes) -> bool:
    if not sample:
        return False
    if b"\x00" in sample:
        return True
    controls = sum(byte < 7 or (14 < byte < 32) for byte in sample[:4096])
    return controls / min(len(sample), 4096) >= 0.05


def project_chunk(chunk: bytes, binary: bool) -> str:
    """Produce detector input without allowing binary controls to bridge it."""
    projected = bytearray()
    for byte in chunk:
        if 32 <= byte <= 126:
            projected.append(byte)
        elif not binary and byte in (9, 10, 11, 12, 13):
            # re.ASCII's \s includes tab, LF, VT, FF and CR. Text projection
            # must preserve that exact supported whitespace language.
            projected.append(byte)
        else:
            # U+001F is a non-whitespace, non-word barrier. In binary data it
            # prevents every control byte, including VT/FF, from satisfying \s.
            projected.append(31)
    return projected.decode("ascii")


def line_starts(value: str, start_line: int, previous_was_cr: bool) -> list[tuple[int, int]]:
    """Bounded linear CR/LF/CRLF line index for one chunk plus overlap."""
    starts = [(0, start_line)]
    line = start_line
    was_cr = previous_was_cr
    for offset, character in enumerate(value):
        if character == "\r":
            line += 1
            starts.append((offset + 1, line))
            was_cr = True
        elif character == "\n":
            if not was_cr:
                line += 1
                starts.append((offset + 1, line))
            was_cr = False
        else:
            was_cr = False
    return starts


def line_at(starts: list[tuple[int, int]], offset: int) -> int:
    # Avoid allocating a prefix or positions array for each finding. This is a
    # bounded binary lookup over one linear chunk index.
    low = 0
    high = len(starts)
    while low < high:
        middle = (low + high) // 2
        if starts[middle][0] <= offset:
            low = middle + 1
        else:
            high = middle
    return starts[low - 1][1]


@dataclass(frozen=True)
class Finding:
    root: str
    parts: tuple[str, ...]
    line: int
    label: str


@dataclass(frozen=True)
class FileInventory:
    root: str
    parts: tuple[str, ...]
    identity: tuple
    digest: str


@dataclass(frozen=True)
class DirectoryInventory:
    root: str
    parts: tuple[str, ...]
    identity: tuple
    names: tuple[str, ...]


@dataclass
class RootInventory:
    root: str
    path: str
    identity: tuple
    descriptor: Optional[int]


def immutable_candidate_refusal() -> ScanFailure:
    return ScanFailure(
        "immutable-candidate-manifest-required",
        {
            "receipts": [], "findings": [], "coverage": [],
            "scope": {
                "mode": "release-qualification", "status": "unavailable",
                "limitation": "immutable-candidate-manifest-required",
                "release_qualified": False,
            },
            "summary": {"files": 0, "paths": 0, "bytes": 0, "chunks": 0, "findings": 0, "coverage": 0},
        },
        "root-none",
        "release-qualification",
    )


class Scanner:
    def __init__(self, release_artifacts: bool, limits: Optional[dict] = None, hooks: Optional[dict] = None):
        self.release_artifacts = release_artifacts
        self.limits = {**DEFAULT_LIMITS, **(limits or {})}
        self.hooks = hooks or {}
        self.findings: list[Finding] = []
        self.receipts: list[dict] = []
        self.coverage: list[dict] = []
        self.files: list[FileInventory] = []
        self.directories: list[DirectoryInventory] = []
        self.roots: dict[str, RootInventory] = {}
        self.finding_counts: dict[tuple[str, tuple[str, ...]], int] = {}
        self.path_count = 0
        self.total_bytes = 0
        self.total_chunks = 0
        self.current_root = "root-none"
        self.current_phase = "source-observation"
        if not all(hasattr(os, flag) for flag in ("O_NOFOLLOW", "O_DIRECTORY", "O_NONBLOCK")):
            fail("descriptor-safety-unavailable")
        base_flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
        # Nonblocking open is mandatory: a lstat-to-open replacement with a
        # FIFO cannot turn a release gate into an unbounded wait.
        self.file_open_flags = base_flags | os.O_NONBLOCK
        self.directory_flags = base_flags | os.O_DIRECTORY

    def summary(self) -> dict:
        return {
            "files": len(self.receipts), "paths": self.path_count,
            "bytes": self.total_bytes, "chunks": self.total_chunks,
            "findings": len(self.findings), "coverage": len(self.coverage),
        }

    def result(self, status: str = "source-observation-complete") -> dict:
        receipts = sorted(self.receipts, key=lambda item: (root_key(item["root"]), item["path"]))
        findings = sorted(self.findings, key=lambda item: (root_key(item.root), display_path(item.parts), item.line, item.label))
        coverage = sorted(self.coverage, key=lambda item: (root_key(item["root"]), item["path"], item["status"]))
        return {
            "findings": [{"root": item.root, "path": display_path(item.parts), "line": item.line, "label": item.label} for item in findings],
            "receipts": receipts,
            "coverage": coverage,
            "scope": {
                "mode": "source-observation",
                "status": status,
                "limitation": SOURCE_OBSERVATION_LIMITATION,
                "release_qualified": False,
            },
            "summary": self.summary(),
        }

    def check_path(self, path_bytes: bytes) -> None:
        if len(path_bytes) > self.limits["max_path_bytes"]:
            fail("path-length-cap-exceeded")
        self.path_count += 1
        if self.path_count > self.limits["max_paths"]:
            fail("path-count-cap-exceeded")

    def read_directory_names(self, descriptor: int) -> list[str]:
        """Read at most remaining budget plus one entry before sorting/failing."""
        remaining = self.limits["max_paths"] - self.path_count
        names: list[str] = []
        try:
            with os.scandir(descriptor) as entries:
                for entry in entries:
                    names.append(entry.name)
                    if len(names) > remaining:
                        fail("path-count-cap-exceeded")
        except OSError:
            fail("directory-read-failed")
        return sorted(names, key=name_key)

    def read_expected_directory_names(self, descriptor: int, expected_count: int) -> tuple[str, ...]:
        """Bound revalidation allocation to the original exact inventory + 1."""
        names: list[str] = []
        try:
            with os.scandir(descriptor) as entries:
                for entry in entries:
                    names.append(entry.name)
                    if len(names) > expected_count:
                        fail("inventory-tree-changed-during-revalidation")
        except OSError:
            fail("inventory-directory-unreadable-during-revalidation")
        return tuple(sorted(names, key=name_key))

    def add_findings(self, root: str, parts: tuple[str, ...], value: str, tail_length: int, starts: list[tuple[int, int]]) -> None:
        key = (root, parts)
        for label, pattern in DETECTORS:
            for match in pattern.finditer(value):
                if match.end() <= tail_length:
                    continue
                file_count = self.finding_counts.get(key, 0)
                if file_count >= self.limits["max_findings_per_file"] or len(self.findings) >= self.limits["max_findings_total"]:
                    self.coverage.append({
                        "root": root, "path": display_path(parts), "status": "finding-limit-exceeded",
                        "file_findings": file_count, "aggregate_findings": len(self.findings),
                    })
                    fail("finding-limit-exceeded")
                self.findings.append(Finding(root, parts, line_at(starts, match.start()), label))
                self.finding_counts[key] = file_count + 1

    def scan_open_file(self, descriptor: int, expected: os.stat_result, final_stat: Callable[[], os.stat_result], root: str, parts: tuple[str, ...]) -> None:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode) or not same_identity(expected, opened):
            fail("file-identity-changed")
        if opened.st_size > self.limits["max_file_bytes"]:
            fail("file-bytes-cap-exceeded")
        if self.total_bytes + opened.st_size > self.limits["max_total_bytes"]:
            fail("total-bytes-cap-exceeded")

        digest = hashlib.sha256()
        offset = chunks = 0
        tail = ""
        tail_line = 1
        tail_preceded_by_cr = False
        binary: Optional[bool] = None
        while offset < opened.st_size:
            chunk = os.read(descriptor, min(CHUNK_BYTES, opened.st_size - offset))
            if not chunk:
                fail("file-truncated-during-read")
            digest.update(chunk)
            if binary is None:
                binary = is_binary(chunk)
            projected = project_chunk(chunk, binary)
            combined = tail + projected
            starts = line_starts(combined, tail_line, tail_preceded_by_cr)
            self.add_findings(root, parts, combined, len(tail), starts)
            cut = max(0, len(combined) - OVERLAP_BYTES)
            tail_line = line_at(starts, cut)
            tail_preceded_by_cr = combined[cut - 1] == "\r" if cut else tail_preceded_by_cr
            tail = combined[cut:]
            offset += len(chunk)
            chunks += 1
            after_read = self.hooks.get("after_read")
            if after_read:
                after_read(parts, chunks, offset)

        try:
            final_entry = final_stat()
        except OSError:
            fail("file-path-changed-during-read")
        if not stat.S_ISREG(final_entry.st_mode) or (final_entry.st_dev, final_entry.st_ino) != (expected.st_dev, expected.st_ino):
            fail("file-path-changed-during-read")
        final_open = os.fstat(descriptor)
        if not same_identity(expected, final_open) or not same_identity(expected, final_entry):
            fail("file-changed-during-read")

        self.total_bytes += opened.st_size
        self.total_chunks += chunks
        digest_hex = digest.hexdigest()
        self.files.append(FileInventory(root, parts, stat_identity(expected), digest_hex))
        self.receipts.append({
            "root": root, "path": display_path(parts), "bytes": opened.st_size, "chunks": chunks,
            "encoding": "binary-printable-ascii" if binary else "text-ascii", "sha256": digest_hex,
            "identity": stat_identity(expected),
        })
        after_file = self.hooks.get("after_file")
        if after_file:
            after_file(parts)

    def scan_file_entry(self, parent_fd: int, name: str, expected: os.stat_result, root: str, parts: tuple[str, ...]) -> None:
        before_open = self.hooks.get("before_open")
        if before_open:
            before_open(parts)
        try:
            descriptor = os.open(name, self.file_open_flags, dir_fd=parent_fd)
        except OSError:
            fail("file-open-failed")
        try:
            self.scan_open_file(descriptor, expected, lambda: os.stat(name, dir_fd=parent_fd, follow_symlinks=False), root, parts)
        finally:
            os.close(descriptor)

    def scan_root_file(self, path: str, expected: os.stat_result, root: str) -> None:
        try:
            descriptor = os.open(path, self.file_open_flags)
        except OSError:
            fail("file-open-failed")
        try:
            self.scan_open_file(descriptor, expected, lambda: os.stat(path, follow_symlinks=False), root, ())
        finally:
            os.close(descriptor)

    def scan_directory(self, descriptor: int, root: str, parts: tuple[str, ...]) -> None:
        before = os.fstat(descriptor)
        if not stat.S_ISDIR(before.st_mode):
            fail("directory-identity-changed")
        names = self.read_directory_names(descriptor)
        self.directories.append(DirectoryInventory(root, parts, stat_identity(before), tuple(names)))
        for name in names:
            entry_parts = parts + (name,)
            self.check_path("/".join(entry_parts).encode("utf-8", "surrogateescape"))
            try:
                entry = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            except OSError:
                fail("path-stat-failed")
            if not self.release_artifacts and stat.S_ISDIR(entry.st_mode) and name in SOURCE_EXCLUDED_DIRECTORIES:
                continue
            if stat.S_ISLNK(entry.st_mode):
                fail("symlink-input-rejected")
            if stat.S_ISREG(entry.st_mode):
                self.scan_file_entry(descriptor, name, entry, root, entry_parts)
                continue
            if not stat.S_ISDIR(entry.st_mode):
                fail("nonregular-input-rejected")
            try:
                child = os.open(name, self.directory_flags, dir_fd=descriptor)
            except OSError:
                fail("directory-open-failed")
            try:
                opened = os.fstat(child)
                if not stat.S_ISDIR(opened.st_mode) or not same_identity(entry, opened):
                    fail("directory-identity-changed")
                self.scan_directory(child, root, entry_parts)
                final_entry = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
                if not stat.S_ISDIR(final_entry.st_mode) or not same_identity(entry, final_entry):
                    fail("directory-path-changed-during-read")
            finally:
                os.close(child)
        if not same_identity(before, os.fstat(descriptor)):
            fail("directory-changed-during-read")

    def open_inventory_directory(self, root_fd: int, parts: tuple[str, ...]) -> int:
        descriptor = os.dup(root_fd)
        try:
            for name in parts:
                entry = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
                if not stat.S_ISDIR(entry.st_mode):
                    fail("inventory-tree-changed-during-revalidation")
                child = os.open(name, self.directory_flags, dir_fd=descriptor)
                os.close(descriptor)
                descriptor = child
                if not same_identity(entry, os.fstat(descriptor)):
                    fail("inventory-tree-changed-during-revalidation")
            return descriptor
        except ScanFailure:
            os.close(descriptor)
            raise
        except OSError:
            os.close(descriptor)
            fail("inventory-tree-changed-during-revalidation")

    def revalidate_directory(self, record: DirectoryInventory) -> None:
        root = self.roots[record.root]
        assert root.descriptor is not None
        descriptor = self.open_inventory_directory(root.descriptor, record.parts)
        try:
            if not same_identity_tuple(record.identity, os.fstat(descriptor)):
                fail("inventory-tree-changed-during-revalidation")
            if self.read_expected_directory_names(descriptor, len(record.names)) != record.names:
                fail("inventory-tree-changed-during-revalidation")
        finally:
            os.close(descriptor)

    def revalidate_file(self, record: FileInventory) -> None:
        root = self.roots[record.root]
        if root.descriptor is None:
            try:
                entry = os.stat(root.path, follow_symlinks=False)
                descriptor = os.open(root.path, self.file_open_flags)
            except OSError:
                fail("inventory-path-changed-during-revalidation")
            parent_fd = None
            name = None
        else:
            parent_fd = self.open_inventory_directory(root.descriptor, record.parts[:-1])
            name = record.parts[-1]
            try:
                entry = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
                descriptor = os.open(name, self.file_open_flags, dir_fd=parent_fd)
            except OSError:
                os.close(parent_fd)
                fail("inventory-path-changed-during-revalidation")
        try:
            if not stat.S_ISREG(entry.st_mode) or (entry.st_dev, entry.st_ino) != record.identity[:2]:
                fail("inventory-path-changed-during-revalidation")
            opened = os.fstat(descriptor)
            if not stat.S_ISREG(opened.st_mode) or not same_identity_tuple(record.identity, opened):
                fail("inventory-content-changed-during-revalidation")
            digest = hashlib.sha256()
            remaining = opened.st_size
            while remaining:
                chunk = os.read(descriptor, min(CHUNK_BYTES, remaining))
                if not chunk:
                    fail("inventory-content-changed-during-revalidation")
                digest.update(chunk)
                remaining -= len(chunk)
            final_open = os.fstat(descriptor)
            if not same_identity_tuple(record.identity, final_open) or digest.hexdigest() != record.digest:
                fail("inventory-content-changed-during-revalidation")
            if parent_fd is not None:
                final_entry = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            else:
                final_entry = os.stat(root.path, follow_symlinks=False)
            if not stat.S_ISREG(final_entry.st_mode) or not same_identity_tuple(record.identity, final_entry):
                fail("inventory-path-changed-during-revalidation")
        except OSError:
            fail("inventory-path-changed-during-revalidation")
        finally:
            os.close(descriptor)
            if parent_fd is not None:
                os.close(parent_fd)

    def revalidate_inventory(self) -> None:
        # This is a bounded two-pass consistency check, not a global snapshot:
        # it rejects every observed final-tree drift but cannot serialize a
        # hostile concurrent same-UID writer between individual system calls.
        for root in self.roots.values():
            try:
                current = os.stat(root.path, follow_symlinks=False)
            except OSError:
                fail("inventory-root-changed-during-revalidation")
            if not same_identity_tuple(root.identity, current):
                fail("inventory-root-changed-during-revalidation")
            if root.descriptor is not None and not same_identity_tuple(root.identity, os.fstat(root.descriptor)):
                fail("inventory-root-changed-during-revalidation")
        for record in self.directories:
            self.revalidate_directory(record)
            after_directory = self.hooks.get("after_revalidate_directory")
            if after_directory:
                after_directory(record.parts)
        for record in self.files:
            self.revalidate_file(record)
            after_file = self.hooks.get("after_revalidate_file")
            if after_file:
                after_file(record.parts)
        # Recheck roots after the complete second pass. This still is not a
        # filesystem-wide atomic snapshot, but no observed final root switch
        # can be approved after its contents were re-read.
        for root in self.roots.values():
            try:
                current = os.stat(root.path, follow_symlinks=False)
            except OSError:
                fail("inventory-root-changed-during-revalidation")
            if not same_identity_tuple(root.identity, current):
                fail("inventory-root-changed-during-revalidation")

    def close_roots(self) -> None:
        for root in self.roots.values():
            if root.descriptor is not None:
                os.close(root.descriptor)
                root.descriptor = None

    def scan(self, paths: Iterable[str]) -> dict:
        if self.release_artifacts:
            raise immutable_candidate_refusal()
        try:
            for index, path in enumerate(paths, start=1):
                root = root_label(index, path)
                self.current_root = root
                self.check_path(os.fsencode(path))
                try:
                    expected = os.stat(path, follow_symlinks=False)
                except OSError:
                    fail("scan-path-missing")
                if stat.S_ISLNK(expected.st_mode):
                    fail("symlink-input-rejected")
                if stat.S_ISREG(expected.st_mode):
                    self.roots[root] = RootInventory(root, path, stat_identity(expected), None)
                    self.scan_root_file(path, expected, root)
                elif stat.S_ISDIR(expected.st_mode):
                    try:
                        descriptor = os.open(path, self.directory_flags)
                    except OSError:
                        fail("directory-open-failed")
                    if not stat.S_ISDIR(os.fstat(descriptor).st_mode) or not same_identity(expected, os.fstat(descriptor)):
                        os.close(descriptor)
                        fail("directory-identity-changed")
                    self.roots[root] = RootInventory(root, path, stat_identity(expected), descriptor)
                    self.scan_directory(descriptor, root, ())
                else:
                    fail("nonregular-input-rejected")
            before_revalidate = self.hooks.get("before_revalidate")
            if before_revalidate:
                before_revalidate()
            self.revalidate_inventory()
            return self.result()
        except ScanFailure as error:
            if error.root == "root-none":
                error.root = self.current_root
            if error.phase == "source-observation":
                error.phase = self.current_phase
            if error.partial is None:
                error.partial = self.result("source-observation-partial")
            raise
        except OSError:
            raise ScanFailure("io-error", self.result("source-observation-partial"), self.current_root, self.current_phase) from None
        finally:
            self.close_roots()


def same_identity_tuple(expected: tuple, actual: os.stat_result) -> bool:
    return expected == stat_identity(actual)


def scan_public_secrets(paths: Iterable[str], release_artifacts: bool = False, limits: Optional[dict] = None, hooks: Optional[dict] = None) -> dict:
    # Do not enumerate, stat, open, or otherwise consume a purported release
    # candidate until a future immutable manifest protocol exists.
    if release_artifacts:
        raise immutable_candidate_refusal()
    return Scanner(False, limits, hooks).scan(paths)


def print_receipts(result: dict) -> None:
    for receipt in result["receipts"]:
        identity = receipt["identity"]
        print(
            f"record type=source-observation-receipt root={receipt['root']} path={receipt['path']} "
            f"bytes={receipt['bytes']} chunks={receipt['chunks']} encoding={receipt['encoding']} "
            f"sha256={receipt['sha256']} dev={identity[0]} ino={identity[1]} mode={identity[2]} "
            f"uid={identity[3]} gid={identity[4]} nlink={identity[5]} size={identity[6]} "
            f"mtime_ns={identity[7]} ctime_ns={identity[8]}"
        )
    for coverage in result["coverage"]:
        print(f"record type=source-observation-coverage root={coverage['root']} path={coverage['path']} status={coverage['status']} file_findings={coverage['file_findings']} aggregate_findings={coverage['aggregate_findings']}")
    summary = result["summary"]
    scope = result["scope"]
    print(f"record type=source-observation-summary status={scope['status']} limitation={scope['limitation']} release_qualified=false files={summary['files']} paths={summary['paths']} bytes={summary['bytes']} chunks={summary['chunks']} findings={summary['findings']} coverage={summary['coverage']}")


def print_terminal_failure(error: ScanFailure) -> None:
    partial = error.partial or {}
    summary = partial.get("summary", {})
    scope = partial.get("scope", {})
    print(f"record type=terminal-failure code={error.code} root={error.root} phase={error.phase} partial_scope={scope.get('status', 'none')} partial_receipts={summary.get('files', 0)}", file=sys.stderr)


def main(argv: list[str]) -> int:
    if not qualified_interpreter():
        print("record type=terminal-failure code=isolated-python-required root=root-none phase=startup partial_scope=none partial_receipts=0", file=sys.stderr)
        return 2
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--release-artifacts", action="store_true")
    parser.add_argument("--path", action="append", default=[])
    try:
        options, unknown = parser.parse_known_args(argv)
    except SystemExit:
        print("record type=terminal-failure code=unknown-argument root=root-none phase=argument-parse partial_scope=none partial_receipts=0", file=sys.stderr)
        return 2
    if unknown:
        print("record type=terminal-failure code=unknown-argument root=root-none phase=argument-parse partial_scope=none partial_receipts=0", file=sys.stderr)
        return 2
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    paths = options.path or [os.path.join(root, "dist") if options.release_artifacts else root]
    try:
        result = scan_public_secrets(paths, options.release_artifacts)
    except ScanFailure as error:
        print_terminal_failure(error)
        return 2
    print_receipts(result)
    if result["findings"]:
        for finding in result["findings"]:
            print(f"record type=source-observation-finding root={finding['root']} path={finding['path']} line={finding['line']} label={finding['label']}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
