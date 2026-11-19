#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 Hatto Social contributors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Stage a source tree whose archive does not depend on the clock or the uid.

Reads the index (including submodules) and writes a directory with git file
modes, symlink targets, and a BUILD_INFO.txt. The caller passes that directory
to tar. Crates and Dart packages are not copied in; the lockfiles are.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

# Prebuilt libraries the sqlite3 3.8.0 hook downloads for this repo.
# Android ABIs match apps/mobile/android/app/build.gradle.kts.
# Linux x64 is the host hook used by packages/hatto_store.
SQLITE3_TARGETS = (
    "libsqlite3.arm.android.so",
    "libsqlite3.arm64.android.so",
    "libsqlite3.x64.android.so",
    "libsqlite3.x64.linux.so",
)

FLUTTER_KEYS = (
    "channel",
    "dartSdkVersion",
    "devToolsVersion",
    "engineBuildDate",
    "engineCommitDate",
    "engineContentHash",
    "engineRevision",
    "flutterVersion",
    "frameworkCommitDate",
    "frameworkRevision",
    "frameworkVersion",
    "repositoryUrl",
)


def run(cmd: list[str], cwd: Path | None = None) -> str | None:
    try:
        done = subprocess.run(
            cmd,
            cwd=cwd,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    return done.stdout.strip()


def first_line(cmd: list[str]) -> str:
    out = run(cmd)
    if not out:
        return "absent"
    return out.splitlines()[0]


def flutter_lines() -> list[str]:
    out = run(["flutter", "--version", "--machine"])
    if not out:
        return ["flutter: absent"]
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return ["flutter: absent"]
    lines = []
    for key in FLUTTER_KEYS:
        if key in data:
            lines.append(f"flutter.{key}: {data[key]}")
    return lines


def ndk_revision() -> str:
    home = os.environ.get("ANDROID_NDK_HOME") or os.environ.get("ANDROID_NDK_ROOT")
    if not home:
        return "absent"
    props = Path(home) / "source.properties"
    if not props.is_file():
        return "absent"
    for line in props.read_text(encoding="utf-8").splitlines():
        if line.startswith("Pkg.Revision="):
            return line.split("=", 1)[1].strip() or "absent"
    return "absent"


def gradle_wrapper(root: Path) -> str:
    path = root / "apps/mobile/android/gradle/wrapper/gradle-wrapper.properties"
    text = path.read_text(encoding="utf-8")
    match = re.search(r"gradle-([0-9.]+)-", text)
    if not match:
        raise SystemExit(f"no gradle version in {path}")
    return match.group(1)


def submodule_lines(root: Path) -> list[str]:
    out = run(["git", "-C", str(root), "submodule", "status", "--recursive"])
    if out is None:
        raise SystemExit("git submodule status failed")
    rows: list[tuple[str, str]] = []
    for line in out.splitlines():
        if not line:
            continue
        # status char, 40-hex sha, path, optional " (describe)"
        body = line[1:] if line[0] in " +-U" else line
        sha, rest = body.split(" ", 1)
        path = rest.split(" (", 1)[0]
        if len(sha) != 40 or any(ch not in "0123456789abcdef" for ch in sha):
            raise SystemExit(f"unexpected submodule status line: {line}")
        rows.append((path, sha))
    rows.sort()
    if not any(path == "third_party/anki" for path, _sha in rows):
        raise SystemExit("third_party/anki is not checked out")
    return [f"submodule {path} {sha}" for path, sha in rows]


def sqlite3_lock(root: Path) -> tuple[str, str]:
    lines = (root / "pubspec.lock").read_text(encoding="utf-8").splitlines()
    for index, line in enumerate(lines):
        if line != "  sqlite3:":
            continue
        block: list[str] = []
        for next_line in lines[index + 1 :]:
            if next_line.startswith("  ") and not next_line.startswith("    "):
                break
            block.append(next_line)
        body = "\n".join(block)
        version = re.search(r'version: "([^"]+)"', body)
        digest = re.search(r'sha256: "([0-9a-f]{64})"', body)
        if not version or not digest:
            raise SystemExit("pubspec.lock sqlite3 entry is missing version or sha256")
        return version.group(1), digest.group(1)
    raise SystemExit("pubspec.lock has no sqlite3 package")


def sqlite3_hook(version: str, package_sha256: str) -> list[str]:
    url = f"https://pub.dev/api/archives/sqlite3-{version}.tar.gz"
    with urllib.request.urlopen(url, timeout=120) as response:
        blob = response.read()
    got = hashlib.sha256(blob).hexdigest()
    if got != package_sha256:
        raise SystemExit(
            f"sqlite3 {version} archive sha256 is {got}, lockfile says {package_sha256}"
        )
    with tempfile.TemporaryDirectory() as tmp:
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
            tar.extractall(tmp, filter="data")
        root = Path(tmp)
        hashes = (root / "lib/src/hook/asset_hashes.dart").read_text(encoding="utf-8")
        description = (root / "lib/src/hook/compile/description.dart").read_text(
            encoding="utf-8"
        )
    release = re.search(r"const String\? releaseTag = '([^']+)';", hashes)
    pattern = re.search(r"defaultUrlPattern =\s*r'([^']+)'", description)
    if not release or not pattern:
        raise SystemExit("sqlite3 hook sources have no release tag or url pattern")
    found = dict(re.findall(r"'([^']+)': '([0-9a-f]{64})'", hashes))
    lines = [
        f"native.sqlite3.package: {version}",
        f"native.sqlite3.package_sha256: {package_sha256}",
        f"native.sqlite3.release_tag: {release.group(1)}",
        f"native.sqlite3.url_pattern: {pattern.group(1)}",
    ]
    for name in SQLITE3_TARGETS:
        digest = found.get(name)
        if not digest:
            raise SystemExit(f"sqlite3 {version} has no hash for {name}")
        file_url = (
            pattern.group(1)
            .replace("$RELEASE_TAG", release.group(1))
            .replace("$FILENAME", name)
        )
        lines.append(f"native.sqlite3.file.{name}.sha256: {digest}")
        lines.append(f"native.sqlite3.file.{name}.url: {file_url}")
    return lines


def build_info(root: Path, tag: str, version: str, sha: str) -> str:
    package_version, package_sha = sqlite3_lock(root)
    lines = [
        "# Toolchain, submodule commits, and native downloads for this source archive.",
        "# Crates and Dart packages are not in the archive. Cargo.lock and",
        "# pubspec.lock pin the registry versions and hashes. There is no mirror.",
        "# native.sqlite3 lines are the prebuilt libraries the Dart sqlite3 hook",
        "# downloads for the Android ABIs and for the Linux host hook. The hook",
        "# checks the sha256. rslib's SQLite is the bundled copy inside the",
        "# rusqlite crate from crates.io, not a separate download.",
        f"hatto_release_tag: {tag}",
        f"hatto_git_sha: {sha}",
        f"hatto_version: {version}",
        f"rustc: {first_line(['rustc', '--version'])}",
        f"cargo: {first_line(['cargo', '--version'])}",
        f"protoc: {first_line(['protoc', '--version'])}",
        f"ndk: {ndk_revision()}",
        f"gradle.wrapper: {gradle_wrapper(root)}",
        *flutter_lines(),
        *submodule_lines(root),
        *sqlite3_hook(package_version, package_sha),
        "",
    ]
    return "\n".join(lines)


def stage_files(root: Path, dest: Path) -> None:
    listed = subprocess.run(
        [
            "git",
            "-C",
            str(root),
            "ls-files",
            "-z",
            "--stage",
            "--recurse-submodules",
        ],
        check=True,
        stdout=subprocess.PIPE,
    )
    count = 0
    for record in listed.stdout.split(b"\0"):
        if not record:
            continue
        meta, path_b = record.split(b"\t", 1)
        mode = meta.split()[0].decode("ascii")
        rel = path_b.decode("utf-8")
        src = root / rel
        target = dest / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        if mode == "120000":
            link = os.readlink(src)
            if target.exists() or target.is_symlink():
                target.unlink()
            os.symlink(link, target)
        elif mode in ("100644", "100755"):
            if target.exists() or target.is_symlink():
                target.unlink()
            shutil.copyfile(src, target)
            os.chmod(target, 0o755 if mode == "100755" else 0o644)
        elif mode == "160000":
            continue
        else:
            raise SystemExit(f"unsupported git mode {mode} for {rel}")
        count += 1
    if count < 1000:
        raise SystemExit(f"only {count} files staged; submodule contents are missing")
    for dirpath, _dirnames, _filenames in os.walk(dest, followlinks=False):
        os.chmod(dirpath, 0o755)


def require_present(dest: Path) -> None:
    required = (
        "third_party/anki/rslib/Cargo.toml",
        "third_party/anki/ftl/core-repo",
        "third_party/anki/ftl/qt-repo",
        "Cargo.lock",
        "pubspec.lock",
        "SOURCE.md",
        "LICENSE",
    )
    for rel in required:
        if not (dest / rel).exists():
            raise SystemExit(f"staged tree is missing {rel}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--dest", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--sha", required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    dest = args.dest
    if dest.exists():
        raise SystemExit(f"{dest} already exists")
    dest.mkdir(parents=True)
    stage_files(root, dest)
    require_present(dest)
    info = build_info(root, args.tag, args.version, args.sha)
    info_path = dest / "BUILD_INFO.txt"
    info_path.write_text(info, encoding="utf-8", newline="\n")
    os.chmod(info_path, 0o644)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as err:
        sys.exit(err.returncode)
