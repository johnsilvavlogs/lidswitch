#!/usr/bin/python3
"""Create one local, manual-ad-hoc LidSwitch candidate from already-built bytes.

This is deliberately a release-only coordinator, not an ordinary build command.
The caller supplies the two outputs from the held `release-candidate` build and
the envelope receipt produced for that build.  It then creates a fresh private
candidate root, signs exactly those copied bytes with the local ad-hoc identity,
packages once with ``hdiutil``, extracts the image, and publishes the existing
immutable v3 app/package manifests.  Nothing here requires an Apple account,
Developer ID, Team ID, notarization, Xcode, or a network service.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
import immutable_candidate_core as core
import capture_immutable_build_envelope as release_capture
import build_immutable_candidate as build_manifest
import package_immutable_candidate as package_manifest
import validate_immutable_candidate as validate_candidate
import validate_immutable_dmg as validate_dmg

TOOLS = {
    "codesign": "/usr/bin/codesign",
    "hdiutil": "/usr/bin/hdiutil",
    "ditto": "/usr/bin/ditto",
    "shasum": "/usr/bin/shasum",
}
CDHASH = re.compile(r"^CDHash=([0-9a-f]{40})$", re.MULTILINE)
SIGNATURE_FIELD = re.compile(r"^([A-Za-z][A-Za-z ]+)=([^\n]*)$", re.MULTILINE)


class AssemblyError(RuntimeError):
    pass


def deny(message: str) -> None:
    raise AssemblyError(message)


def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb", buffering=0) as handle:
        while True:
            chunk = handle.read(131072)
            if not chunk:
                return digest.hexdigest()
            digest.update(chunk)


def run(argv: list[str], *, capture: bool = False, capture_stderr: bool = False) -> str:
    if capture and capture_stderr:
        deny("local-tool-capture-stream-ambiguous")
    try:
        completed = subprocess.run(
            argv, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            check=False, close_fds=True,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"},
            text=True,
        )
    except OSError as error:
        deny("local-tool-unavailable: " + argv[0] + ": " + str(error))
    if completed.returncode != 0:
        deny("local-tool-failed: " + Path(argv[0]).name)
    if capture_stderr:
        return completed.stderr
    return completed.stdout if capture else ""


def require_free_tools() -> dict[str, str]:
    observed: dict[str, str] = {}
    for name, value in TOOLS.items():
        info = os.stat(value, follow_symlinks=False)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            deny("local-tool-identity-invalid: " + name)
        observed[name] = value
    return observed


def regular_input(value: str, label: str) -> Path:
    supplied = Path(value).expanduser()
    if supplied.is_symlink():
        deny("unsafe-" + label)
    path = supplied.resolve(strict=True)
    info = os.lstat(path)
    if path.is_symlink() or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_mode & 0o022 or info.st_size <= 0:
        deny("unsafe-" + label)
    return path


def bound_release_binary(root: Path, name: str, expected: dict[str, object], label: str) -> Path:
    path = regular_input(str(root / name), label)
    info = os.lstat(path)
    if info.st_size != expected.get("size") or sha256_path(path) != expected.get("sha256"):
        deny("bound-release-" + label + "-mismatch")
    return path


def require_release_identity_binding(origin: dict[str, object], identity_bytes: bytes) -> None:
    if origin.get("release_identity_sha256") != hashlib.sha256(identity_bytes).hexdigest():
        deny("bound-release-identity-digest-mismatch")


def envelope_reference(envelope_sha: str, envelope: dict[str, object]) -> dict[str, object]:
    return {"receipt_sha256": envelope_sha, "wrapper_sha256": envelope["wrapper_sha256"],
            "source_tree_sha256": envelope["source_tree_sha256"], "toolchain_sha256": envelope["toolchain_sha256"],
            "release_output": envelope["release_output"]}


def fresh_private_root(value: str) -> Path:
    path = Path(value).expanduser().resolve()
    if path.exists():
        deny("output-root-must-not-exist")
    path.mkdir(mode=0o700, parents=False)
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    fd = os.open(path, flags)
    try:
        created = os.fstat(fd)
        if not stat.S_ISDIR(created.st_mode) or created.st_uid != os.getuid():
            deny("output-root-identity-invalid")
        # Darwin's sticky /private/tmp may assign wheel even though the caller
        # owns the new directory. Normalize the held directory descriptor to
        # the caller's primary group before it becomes candidate authority.
        if created.st_gid != os.getgid():
            os.fchown(fd, -1, os.getgid())
        os.fchmod(fd, 0o700)
        held = os.fstat(fd)
        visible = os.lstat(path)
        identity = lambda info: (info.st_dev, info.st_ino, info.st_uid, info.st_gid,
                                 stat.S_IFMT(info.st_mode), stat.S_IMODE(info.st_mode), info.st_nlink)
        if (identity(held) != identity(visible)
                or not stat.S_ISDIR(held.st_mode)
                or held.st_uid != os.getuid()
                or held.st_gid != os.getgid()
                or stat.S_IMODE(held.st_mode) != 0o700
                or held.st_nlink < 2):
            deny("output-root-identity-invalid")
    finally:
        os.close(fd)
    return path


def read_identity(path: Path) -> tuple[dict[str, object], bytes]:
    raw = path.read_bytes()
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AssemblyError("release-identity-invalid") from error
    if not isinstance(value, dict) or value.get("channel") != "manual-ad-hoc":
        deny("release-identity-invalid")
    return value, raw


def write_private(path: Path, payload: bytes, mode: int = 0o600) -> None:
    with path.open("xb") as handle:
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(path, mode)


def cdhash(path: Path) -> str:
    # `codesign -d` writes its inspection record to stderr even on success.
    output = run([TOOLS["codesign"], "-d", "--verbose=4", str(path)], capture_stderr=True)
    match = CDHASH.search(output)
    if match is None:
        deny("manual-adhoc-cdhash-missing")
    return match.group(1)


def signature_identity(path: Path, expected_identifier: str) -> dict[str, str]:
    """Inspect one ad-hoc code object without mutating it."""
    run([TOOLS["codesign"], "--verify", "--strict", "--verbose=2", str(path)])
    output = run([TOOLS["codesign"], "-d", "--verbose=4", str(path)], capture_stderr=True)
    fields: dict[str, str] = {}
    for key, value in SIGNATURE_FIELD.findall(output):
        if key in fields:
            deny("manual-adhoc-signature-field-duplicate: " + key)
        fields[key] = value
    if fields.get("Identifier") != expected_identifier:
        deny("manual-adhoc-identifier-mismatch")
    if fields.get("Signature") != "adhoc":
        deny("manual-adhoc-signature-not-adhoc")
    if fields.get("TeamIdentifier") != "not set":
        deny("manual-adhoc-team-identifier-present")
    notarization = fields.get("Notarization Ticket")
    if notarization not in (None, "none"):
        deny("manual-adhoc-notarization-present")
    match = CDHASH.search(output)
    if match is None:
        deny("manual-adhoc-cdhash-missing")
    return {"identifier": fields["Identifier"], "cdhash": match.group(1)}


def signature_metadata(path: Path, expected_identifier: str) -> dict[str, object]:
    """Measure one already-signed regular helper without mutating it."""
    identity = signature_identity(path, expected_identifier)
    info = os.lstat(path)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size <= 0:
        deny("manual-adhoc-helper-not-regular")
    return {"sha256": sha256_path(path), "size": info.st_size,
            "identifier": identity["identifier"], "cdhash": identity["cdhash"]}


def require_unchanged_helper(before: dict[str, object], after: dict[str, object]) -> None:
    for field in ("sha256", "size", "identifier", "cdhash"):
        if before.get(field) != after.get(field):
            deny("manual-adhoc-helper-drift-after-app-sign: " + field)


def publish_candidate_helper(candidate: Path, bundled_helper: Path,
                             expected_identifier: str,
                             expected: dict[str, object]) -> Path:
    """Publish the manifest's descriptor-addressable helper leaf."""
    target = candidate / "LidSwitchHelper"
    shutil.copyfile(bundled_helper, target)
    os.chmod(target, 0o755)
    require_unchanged_helper(expected, signature_metadata(target, expected_identifier))
    return target


def sign_outer_app(path: Path, expected_identifier: str) -> str:
    """The app is the sole artifact this coordinator is permitted to sign."""
    run([TOOLS["codesign"], "--force", "--sign", "-", "--timestamp=none", str(path)])
    run([TOOLS["codesign"], "--verify", "--deep", "--strict", "--verbose=2", str(path)])
    return signature_identity(path, expected_identifier)["cdhash"]


def artifact(role: str, name: str, path: Path, receipt: str, *, tree: str | None = None,
             size_override: int | None = None, identifier: str | None = None,
             cd_hash: str | None = None) -> dict[str, object]:
    info = os.lstat(path)
    digest = tree or sha256_path(path)
    value: dict[str, object] = {
        "role": role, "name": name, "sha256": digest,
        "size": info.st_size if size_override is None else size_override,
        "mode": stat.S_IMODE(info.st_mode), "uid": info.st_uid, "gid": info.st_gid,
        "tree_sha256": digest, "signature_receipt": receipt,
    }
    if role in ("helper", "app"):
        if identifier is None or cd_hash is None:
            deny("signed-artifact-metadata-missing")
        value.update({"identifier": identifier, "cdhash": cd_hash,
                      "signing_profile": "manual-adhoc", "team_id": None,
                      "notarized": False})
    return value


def receipt(root: Path, role: str, index: int, binding: str, previous: str,
            source_commit: str, subject_name: str, subject_sha: str, subject_size: int) -> dict[str, object]:
    name = "receipt-%02d.json" % index
    value = {"role": role, "name": name, "sha256": "0" * 64,
             "tool_sha256": sha256_path(Path(__file__)), "subject_role": "release-identity",
             "subject_name": subject_name, "subject_sha256": subject_sha,
             "subject_size": subject_size, "source_commit": source_commit,
             "candidate_binding": binding, "previous_receipt": previous,
             "strict": True, "exit": 0}
    payload = core.canonical_receipt_payload(value)
    value["sha256"] = hashlib.sha256(payload).hexdigest()
    write_private(root / name, payload)
    return value


def open_fd(path: Path, directory: bool = False) -> int:
    return os.open(str(path), os.O_RDONLY | os.O_CLOEXEC | (os.O_DIRECTORY if directory else 0))


def private_subdirectory(parent: Path, name: str) -> Path:
    path = parent / name
    path.mkdir(mode=0o700)
    os.chmod(path, 0o700)
    info = os.lstat(path)
    if (path.is_symlink()
            or not stat.S_ISDIR(info.st_mode)
            or info.st_uid != os.getuid()
            or info.st_gid != os.getgid()
            or stat.S_IMODE(info.st_mode) != 0o700
            or info.st_nlink < 2):
        deny("private-subdirectory-identity-invalid: " + name)
    return path


def require_bundle_at_root(root: Path, app_name: str) -> Path:
    if app_name != "LidSwitch.app":
        deny("dmg-layout-app-name-invalid")
    try:
        os.lstat(root / "Contents")
    except FileNotFoundError:
        pass
    else:
        deny("dmg-layout-bare-contents")
    target = root / app_name
    try:
        info = os.lstat(target)
    except FileNotFoundError:
        deny("dmg-layout-app-missing")
    if target.is_symlink() or not stat.S_ISDIR(info.st_mode):
        deny("dmg-layout-app-invalid")
    return target


def verified_bundle_copy(root: Path, app_name: str, expected_tree: str,
                         expected_identifier: str, expected_cdhash: str,
                         label: str) -> Path:
    app = require_bundle_at_root(root, app_name)
    root_fd = open_fd(root, True)
    try:
        _, observed_tree = core.capture_tree(root_fd, app_name)
    finally:
        os.close(root_fd)
    if observed_tree != expected_tree:
        deny(label + "-tree-mismatch")
    if signature_identity(app, expected_identifier)["cdhash"] != expected_cdhash:
        deny(label + "-signature-mismatch")
    return app


def stage_dmg_source(output: Path, app: Path, app_tree: str,
                     expected_identifier: str, expected_cdhash: str) -> Path:
    source = private_subdirectory(output, "dmg-source")
    staged_app = source / "LidSwitch.app"
    run([TOOLS["ditto"], str(app), str(staged_app)])
    verified_bundle_copy(source, "LidSwitch.app", app_tree,
                         expected_identifier, expected_cdhash, "dmg-staging")
    return source


def create_dmg(dmg_source: Path, dmg: Path, app_tree: str,
               expected_identifier: str, expected_cdhash: str) -> None:
    verified_bundle_copy(dmg_source, "LidSwitch.app", app_tree,
                         expected_identifier, expected_cdhash, "dmg-staging")
    run([TOOLS["hdiutil"], "create", "-volname", "LidSwitch", "-srcfolder",
         str(dmg_source), "-format", "UDZO", "-ov", str(dmg)])
    verified_bundle_copy(dmg_source, "LidSwitch.app", app_tree,
                         expected_identifier, expected_cdhash, "dmg-staging-post-create")


def make_app_bundle(root: Path, app_binary: Path, helper_binary: Path, icon: Path, identity: dict[str, object], identity_bytes: bytes) -> tuple[Path, Path]:
    app = root / "LidSwitch.app"
    macos = app / "Contents" / "MacOS"
    services = app / "Contents" / "Library" / "LaunchServices"
    resources = app / "Contents" / "Resources"
    for directory in (app, app / "Contents", macos, app / "Contents" / "Library", services, resources):
        directory.mkdir(mode=0o755)
        os.chmod(directory, 0o755)
    plist = {"CFBundleIdentifier": identity["appBundleIdentifier"],
             "CFBundleDisplayName": "LidSwitch", "CFBundleName": "LidSwitch",
             "CFBundleShortVersionString": identity["appVersion"],
             "CFBundleVersion": str(identity["appBuild"]),
             "CFBundleExecutable": "LidSwitch", "CFBundlePackageType": "APPL", "CFBundleIconFile": "LidSwitch",
             "LSMinimumSystemVersion": "14.0", "LSUIElement": True,
             "NSHighResolutionCapable": True, "NSPrincipalClass": "NSApplication"}
    with (app / "Contents" / "Info.plist").open("wb") as handle:
        plistlib.dump(plist, handle, sort_keys=True)
    shutil.copyfile(app_binary, macos / "LidSwitch")
    shutil.copyfile(helper_binary, services / "LidSwitchHelper")
    with (resources / "LidSwitchReleaseIdentity.json").open("xb") as handle:
        handle.write(identity_bytes); handle.flush(); os.fsync(handle.fileno())
    shutil.copyfile(icon, resources / "LidSwitch.icns")
    for binary in (macos / "LidSwitch", services / "LidSwitchHelper"):
        os.chmod(binary, 0o755)
    os.chmod(app / "Contents" / "Info.plist", 0o644)
    os.chmod(resources / "LidSwitchReleaseIdentity.json", 0o644)
    return app, services / "LidSwitchHelper"


def attach_extract(dmg: Path, extraction: Path, app_name: str) -> None:
    output = run([TOOLS["hdiutil"], "attach", "-readonly", "-nobrowse", "-plist", str(dmg)], capture=True)
    try:
        attached = plistlib.loads(output.encode("utf-8"))
        entries = attached.get("system-entities", [])
        mount = next(Path(item["mount-point"]) for item in entries if isinstance(item, dict) and "mount-point" in item)
    except (ValueError, StopIteration, TypeError, KeyError) as error:
        raise AssemblyError("dmg-attach-output-invalid") from error
    try:
        mounted_app = require_bundle_at_root(mount, app_name)
        run([TOOLS["ditto"], str(mounted_app), str(extraction / app_name)])
    finally:
        run([TOOLS["hdiutil"], "detach", str(mount)])


def assemble(args: argparse.Namespace) -> dict[str, object]:
    require_free_tools()
    receipt_path = regular_input(args.envelope_receipt, "envelope-receipt")
    release_output = Path(args.release_output).expanduser().resolve(strict=True)
    if release_output.is_symlink() or not release_output.is_dir():
        deny("unsafe-release-output")
    identity_path = regular_input(args.release_identity, "release-identity")
    identity, identity_bytes = read_identity(identity_path)
    icon = regular_input(str(ROOT.parent / "Resources" / "LidSwitch.icns"), "app-icon")
    output = fresh_private_root(args.output_root)
    candidate = output / "candidate"; candidate.mkdir(mode=0o700)
    extraction = output / "extracted"; extraction.mkdir(mode=0o700)
    expected_helper_identifier = str(identity["helperLabel"])
    expected_app_identifier = str(identity["appBundleIdentifier"])
    envelope_fd = open_fd(receipt_path)
    envelope_sha = sha256_path(receipt_path)
    try:
        envelope = core.read_inherited_receipt(envelope_fd, envelope_sha)
    finally:
        os.close(envelope_fd)
    origin = envelope["release_output"]
    if release_capture.read_release_output(str(release_output)) != origin:
        deny("bound-release-output-stale-or-substituted")
    require_release_identity_binding(origin, identity_bytes)
    if origin["app"]["identifier"] != expected_app_identifier or origin["helper"]["identifier"] != expected_helper_identifier:
        deny("bound-release-identity-mismatch")
    app_binary = bound_release_binary(release_output, "LidSwitch", origin["app"], "app")
    helper_binary = bound_release_binary(release_output, "LidSwitchHelper", origin["helper"], "helper")
    source_helper = signature_metadata(helper_binary, expected_helper_identifier)
    if source_helper != {key: origin["helper"][key] for key in ("sha256", "size", "identifier", "cdhash")}:
        deny("bound-release-helper-signature-mismatch")
    app, helper = make_app_bundle(candidate, app_binary, helper_binary, icon, identity, identity_bytes)
    copied_helper = signature_metadata(helper, expected_helper_identifier)
    require_unchanged_helper(source_helper, copied_helper)
    app_cdhash = sign_outer_app(app, expected_app_identifier)
    final_helper = signature_metadata(helper, expected_helper_identifier)
    require_unchanged_helper(copied_helper, final_helper)
    helper_cdhash = str(final_helper["cdhash"])
    published_helper = publish_candidate_helper(candidate, helper, expected_helper_identifier, final_helper)
    candidate_fd = open_fd(candidate, True)
    try:
        app_size, app_tree = core.capture_tree(candidate_fd, "LidSwitch.app")
    finally:
        os.close(candidate_fd)
    identity_name = "release-identity.json"
    write_private(candidate / identity_name, identity_bytes)
    preliminary = {"envelope": envelope_reference(envelope_sha, envelope),
                   "release_identity": {"name": identity_name, "sha256": sha256_path(candidate / identity_name), "signing_profile": "manual-adhoc", "team_id": None, "notarized": False},
                   "source": {"commit": envelope["source_commit"], "tree_sha256": envelope["source_tree_sha256"]},
                   "helper": artifact("helper", "LidSwitchHelper", published_helper, "0" * 64, identifier=str(identity["helperLabel"]), cd_hash=helper_cdhash),
                   "app": artifact("app", "LidSwitch.app", app, "0" * 64, tree=app_tree, size_override=app_size, identifier=str(identity["appBundleIdentifier"]), cd_hash=app_cdhash)}
    binding = core.candidate_binding(preliminary)
    receipts: list[dict[str, object]] = []; previous = "0" * 64
    for index, role in enumerate(core.PHASES["app-captured"]):
        entry = receipt(candidate, role, index, binding, previous, str(envelope["source_commit"]), identity_name, preliminary["release_identity"]["sha256"], len(identity_bytes))
        receipts.append(entry); previous = str(entry["sha256"])
    build_descriptor = {"schema_version": core.BUILD_DESCRIPTOR_SCHEMA, "phase": "app-captured",
                        "release_identity": preliminary["release_identity"], "source": preliminary["source"],
                        "helper": artifact("helper", "LidSwitchHelper", published_helper, str(receipts[0]["sha256"]), identifier=str(identity["helperLabel"]), cd_hash=helper_cdhash),
                        "app": artifact("app", "LidSwitch.app", app, str(receipts[3]["sha256"]), tree=app_tree, size_override=app_size, identifier=str(identity["appBundleIdentifier"]), cd_hash=app_cdhash),
                        "package": {"dmg": None, "checksum": None, "extraction_receipt": None, "extracted_tree_sha256": None}, "receipts": receipts}
    build_payload = core.canonical(build_descriptor); write_private(candidate / "build-descriptor.json", build_payload)
    fds = [open_fd(candidate, True), open_fd(receipt_path), open_fd(candidate / "build-descriptor.json")]
    try:
        app_manifest = build_manifest.run(argparse.Namespace(candidate_root_fd=fds[0], envelope_receipt_fd=fds[1], envelope_receipt_sha256=envelope_sha, build_descriptor_fd=fds[2], build_descriptor_sha256=hashlib.sha256(build_payload).hexdigest(), manifest="candidate-manifest.json"))
    finally:
        for fd in fds: os.close(fd)
    fds = [open_fd(candidate, True), open_fd(receipt_path)]
    try:
        validate_candidate.run(argparse.Namespace(candidate_root_fd=fds[0], envelope_receipt_fd=fds[1], envelope_receipt_sha256=envelope_sha, manifest="candidate-manifest.json"))
    finally:
        for fd in fds: os.close(fd)
    dmg_source = stage_dmg_source(output, app, app_tree, expected_app_identifier, app_cdhash)
    dmg = candidate / "LidSwitch.dmg"
    create_dmg(dmg_source, dmg, app_tree, expected_app_identifier, app_cdhash)
    dmg_sha = sha256_path(dmg)
    checksum = candidate / "LidSwitch.dmg.sha256"; write_private(checksum, (dmg_sha + "  LidSwitch.dmg\n").encode("ascii"))
    attach_extract(dmg, extraction, "LidSwitch.app")
    extraction_fd = open_fd(extraction, True)
    try:
        _, extracted_tree = core.capture_tree(extraction_fd, "LidSwitch.app")
    finally:
        os.close(extraction_fd)
    if extracted_tree != app_tree:
        deny("dmg-extraction-tree-mismatch")
    package_receipts = list(receipts); previous = str(receipts[-1]["sha256"])
    for index, role in enumerate(core.PHASES["package-captured"][6:], 6):
        entry = receipt(candidate, role, index, binding, previous, str(envelope["source_commit"]), identity_name, preliminary["release_identity"]["sha256"], len(identity_bytes))
        package_receipts.append(entry); previous = str(entry["sha256"])
    package_descriptor = {"schema_version": core.PACKAGE_DESCRIPTOR_SCHEMA, "base_candidate_id": app_manifest["candidate_id"],
                          "package": {"dmg": artifact("package", "LidSwitch.dmg", dmg, str(package_receipts[6]["sha256"])),
                                      "checksum": artifact("checksum", "LidSwitch.dmg.sha256", checksum, str(package_receipts[7]["sha256"])),
                                      "extraction_receipt": str(package_receipts[8]["sha256"]), "extracted_tree_sha256": extracted_tree},
                          "receipts": package_receipts}
    package_payload = core.canonical(package_descriptor); write_private(candidate / "package-descriptor.json", package_payload)
    fds = [open_fd(candidate, True), open_fd(extraction, True), open_fd(receipt_path), open_fd(candidate / "candidate-manifest.json"), open_fd(candidate / "package-descriptor.json")]
    try:
        packaged = package_manifest.run(argparse.Namespace(candidate_root_fd=fds[0], extracted_app_root_fd=fds[1], extracted_app_name="LidSwitch.app", envelope_receipt_fd=fds[2], envelope_receipt_sha256=envelope_sha, app_manifest_fd=fds[3], app_manifest_sha256=sha256_path(candidate / "candidate-manifest.json"), package_descriptor_fd=fds[4], package_descriptor_sha256=hashlib.sha256(package_payload).hexdigest(), manifest="package-manifest.json"))
    finally:
        for fd in fds: os.close(fd)
    fds = [open_fd(candidate, True), open_fd(extraction, True), open_fd(receipt_path)]
    try:
        validate_dmg.run(argparse.Namespace(candidate_root_fd=fds[0], extracted_app_root_fd=fds[1], extracted_app_name="LidSwitch.app", envelope_receipt_fd=fds[2], envelope_receipt_sha256=envelope_sha, manifest="package-manifest.json"))
    finally:
        for fd in fds: os.close(fd)
    return {"candidate_root": str(candidate), "extracted_root": str(extraction), "manifest": str(candidate / "package-manifest.json"), "candidate_id": packaged["candidate_id"], "dmg": str(dmg), "dmg_sha256": dmg_sha, "signing_profile": "manual-adhoc", "notarized": False, "team_id": None}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-binary", required=False)
    parser.add_argument("--helper-binary", required=False)
    parser.add_argument("--envelope-receipt", required=False)
    parser.add_argument("--release-output", required=False)
    parser.add_argument("--output-root", required=False)
    parser.add_argument("--release-identity", default=str(ROOT.parent / "Resources" / "LidSwitchReleaseIdentity.json"))
    parser.add_argument("--check-tools", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.check_tools:
            if any((args.app_binary, args.helper_binary, args.envelope_receipt, args.release_output, args.output_root)):
                deny("check-tools-does-not-assemble")
            print(json.dumps({"schema_version": "lidswitch-free-packaging-tools-v1", "tools": require_free_tools(), "paid_services": False}, sort_keys=True, separators=(",", ":")))
            return 0
        if args.app_binary or args.helper_binary:
            deny("explicit-app-or-helper-paths-are-not-accepted")
        if not all((args.envelope_receipt, args.release_output, args.output_root)):
            deny("release-output-envelope-receipt-and-output-root-are-required")
        print(json.dumps(assemble(args), sort_keys=True, separators=(",", ":")))
        return 0
    except (AssemblyError, core.CandidateError, OSError, ValueError) as error:
        print("manual-adhoc-candidate-denied: " + str(error), file=sys.stderr)
        return 65


if __name__ == "__main__":
    raise SystemExit(main())
