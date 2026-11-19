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
import gzip
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


def tool_env() -> dict[str, str]:
    # rust-toolchain.toml makes rustup install 1.97.1 on the first rustc
    # call when that toolchain is missing. The install's chatter is not the
    # same text the second call prints, so the two archives differed on CI.
    env = os.environ.copy()
    env["RUSTUP_AUTO_INSTALL"] = "0"
    env["LC_ALL"] = "C"
    return env


def tool_output(cmd: list[str], cwd: Path) -> str | None:
    try:
        done = subprocess.run(
            cmd,
            cwd=cwd,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            env=tool_env(),
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    return done.stdout


def first_line(cmd: list[str], cwd: Path) -> str:
    out = tool_output(cmd, cwd)
    if not out:
        return "absent"
    for line in out.splitlines():
        line = line.strip()
        if not line or line.startswith("info:") or line.startswith("warn:"):
            continue
        return line
    return "absent"


def flutter_lines(cwd: Path) -> list[str]:
    out = tool_output(["flutter", "--version", "--machine"], cwd)
    if not out:
        return ["flutter: absent"]
    start = out.find("{")
    end = out.rfind("}")
    if start < 0 or end < start:
        return ["flutter: absent"]
    try:
        data = json.loads(out[start : end + 1])
    except json.JSONDecodeError:
        return ["flutter: absent"]
    lines = []
    for key in FLUTTER_KEYS:
        if key in data:
            lines.append(f"flutter.{key}: {data[key]}")
    return lines


def pkg_revision(home: Path) -> str:
    props = home / "source.properties"
    if not props.is_file():
        return ""
    for line in props.read_text(encoding="utf-8").splitlines():
        if line.startswith("Pkg.Revision="):
            return line.split("=", 1)[1].strip()
    return ""


def ndk_revision() -> str:
    for var in ("ANDROID_NDK_HOME", "ANDROID_NDK_ROOT"):
        raw = os.environ.get(var)
        if not raw:
            continue
        revision = pkg_revision(Path(raw))
        if revision:
            return revision
        return "absent"
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if not sdk:
        return "absent"
    ndk_root = Path(sdk) / "ndk"
    if not ndk_root.is_dir():
        return "absent"
    installs = sorted(
        path for path in ndk_root.iterdir() if (path / "source.properties").is_file()
    )
    if len(installs) != 1:
        # More than one NDK is installed. ANDROID_NDK_HOME says which one
        # the release build used. Guessing would record the wrong toolchain.
        return "absent"
    return pkg_revision(installs[0]) or "absent"


def gradle_wrapper(root: Path) -> str:
    path = root / "apps/mobile/android/gradle/wrapper/gradle-wrapper.properties"
    text = path.read_text(encoding="utf-8")
    match = re.search(r"gradle-([0-9.]+)-", text)
    if not match:
        raise SystemExit(f"no gradle version in {path}")
    return match.group(1)


def submodule_lines(root: Path) -> list[str]:
    out = tool_output(
        ["git", "-c", "color.ui=never", "submodule", "status", "--recursive"],
        root,
    )
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


# A determinism archive is built without the release toolchain. The word
# "placeholder" is the label: this value is not the toolchain of a binary.
PLACEHOLDER = (
    "placeholder: not a release toolchain value; "
    "this determinism archive did not run the tool"
)


def toolchain_field(name: str, raw: str, mode: str) -> str:
    missing = raw in ("", "absent") or raw.startswith("placeholder:")
    if not missing:
        return f"{name}: {raw}"
    if mode == "release":
        raise SystemExit(
            f"release BUILD_INFO requires {name}. "
            f"The probe returned {raw!r}. Install it and re-run the release build."
        )
    return f"{name}: {PLACEHOLDER}"


def flutter_block(root: Path, mode: str) -> list[str]:
    lines = flutter_lines(root)
    engine = ""
    content_hash = ""
    framework = ""
    for line in lines:
        if line.startswith("flutter.engineRevision: "):
            engine = line.split(": ", 1)[1]
        elif line.startswith("flutter.engineContentHash: "):
            content_hash = line.split(": ", 1)[1]
        elif line.startswith("flutter.frameworkVersion: "):
            framework = line.split(": ", 1)[1]
    complete = bool(engine and content_hash and framework)
    if complete and lines != ["flutter: absent"]:
        return lines
    if mode == "release":
        raise SystemExit(
            "release BUILD_INFO requires flutter --version --machine, "
            "including frameworkVersion, engineRevision, and engineContentHash."
        )
    return [f"flutter: {PLACEHOLDER}"]


def release_fields(text: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in text.splitlines():
        if line.startswith("#") or ": " not in line:
            continue
        key, value = line.split(": ", 1)
        fields[key] = value
    return fields


def assert_release_record(text: str, tag: str, sha: str) -> None:
    """A release BUILD_INFO is the toolchain of a binary, not a placeholder."""
    fields = release_fields(text)
    if fields.get("build_info_mode") != "release":
        raise SystemExit("BUILD_INFO.txt is not a release record (build_info_mode).")
    if "placeholder:" in text:
        raise SystemExit("BUILD_INFO.txt still contains a placeholder toolchain line.")
    if fields.get("hatto_release_tag") != tag:
        raise SystemExit(
            f"BUILD_INFO tag is {fields.get('hatto_release_tag')!r}; expected {tag!r}."
        )
    if fields.get("hatto_git_sha") != sha:
        raise SystemExit(
            f"BUILD_INFO sha is {fields.get('hatto_git_sha')!r}; expected {sha!r}."
        )
    rustc = fields.get("rustc", "")
    cargo = fields.get("cargo", "")
    protoc = fields.get("protoc", "")
    ndk = fields.get("ndk", "")
    if not rustc.startswith("rustc "):
        raise SystemExit(f"BUILD_INFO rustc line is not a rustc version: {rustc!r}")
    if not cargo.startswith("cargo "):
        raise SystemExit(f"BUILD_INFO cargo line is not a cargo version: {cargo!r}")
    if "libprotoc" not in protoc:
        raise SystemExit(f"BUILD_INFO protoc line is not a protoc version: {protoc!r}")
    if not ndk or ndk == "absent":
        raise SystemExit(
            "BUILD_INFO has no NDK revision. Set ANDROID_NDK_HOME to the NDK "
            "this build used."
        )
    for key in (
        "flutter.frameworkVersion",
        "flutter.engineRevision",
        "flutter.engineContentHash",
    ):
        if not fields.get(key):
            raise SystemExit(f"BUILD_INFO is missing {key}.")
    submodule_lines_text = [
        line for line in text.splitlines() if line.startswith("submodule ")
    ]
    for needle in (
        "submodule third_party/anki ",
        "submodule third_party/anki/ftl/core-repo ",
        "submodule third_party/anki/ftl/qt-repo ",
    ):
        if not any(line.startswith(needle) for line in submodule_lines_text):
            raise SystemExit(f"BUILD_INFO is missing {needle.strip()}.")
    for name in SQLITE3_TARGETS:
        sha_key = f"native.sqlite3.file.{name}.sha256"
        url_key = f"native.sqlite3.file.{name}.url"
        digest = fields.get(sha_key, "")
        url = fields.get(url_key, "")
        if len(digest) != 64 or any(ch not in "0123456789abcdef" for ch in digest):
            raise SystemExit(f"BUILD_INFO {sha_key} is not a sha256.")
        if not url.startswith("https://"):
            raise SystemExit(f"BUILD_INFO {url_key} is not an https URL.")


def inherited_prefix(path: Path, prefix: str) -> list[str]:
    lines = [
        line
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.startswith(prefix)
    ]
    if any("placeholder:" in line for line in lines):
        raise SystemExit(f"{path} has a placeholder {prefix.strip()} line.")
    if not lines:
        raise SystemExit(f"{path} has no {prefix.strip()} lines to inherit.")
    return lines


def build_info(
    root: Path,
    tag: str,
    version: str,
    sha: str,
    mode: str,
    inherit_submodules_from: Path | None = None,
) -> str:
    if mode not in ("release", "determinism"):
        raise SystemExit(f"unknown BUILD_INFO mode {mode}")
    if mode == "determinism":
        header = [
            "# Determinism archive record. This is not the release toolchain.",
            "# build_info_mode: determinism means a line marked placeholder was",
            "# not used to build a binary. The release record is dist/BUILD_INFO.txt",
            "# from tools/release/build-android.sh.",
        ]
    else:
        header = [
            "# Release record of the toolchain that built the binaries for this tag.",
            "# tools/release/build-android.sh writes this from the environment that",
            "# produced the APK. tools/release/make-source-archive.sh copies it into",
            "# the source archive.",
        ]
    if inherit_submodules_from is None:
        modules = submodule_lines(root)
    else:
        modules = inherited_prefix(inherit_submodules_from, "submodule ")
    package_version, package_sha = sqlite3_lock(root)
    lines = [
        *header,
        "# Crates and Dart packages are not vendored. Cargo.lock and pubspec.lock",
        "# pin the registry versions and hashes. There is no mirror.",
        "# native.sqlite3 lines are the prebuilt libraries the Dart sqlite3 hook",
        "# downloads for the Android ABIs and the Linux host hook. The hook checks",
        "# the sha256. rslib's SQLite is the bundled copy inside the rusqlite crate.",
        f"build_info_mode: {mode}",
        f"hatto_release_tag: {tag}",
        f"hatto_git_sha: {sha}",
        f"hatto_version: {version}",
        toolchain_field("rustc", first_line(["rustc", "--version"], root), mode),
        toolchain_field("cargo", first_line(["cargo", "--version"], root), mode),
        toolchain_field("protoc", first_line(["protoc", "--version"], root), mode),
        toolchain_field("ndk", ndk_revision(), mode),
        f"gradle.wrapper: {gradle_wrapper(root)}",
        *flutter_block(root, mode),
        *modules,
        *sqlite3_hook(package_version, package_sha),
        "",
    ]
    text = "\n".join(lines)
    if mode == "release":
        assert_release_record(text, tag, sha)
    return text


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


def write_deterministic_archive(stage_dir: Path, archive: Path, mtime: int) -> None:
    """Write a gzipped tar whose bytes do not depend on the clock or the uid.

    The runner's tar stores atime or ctime. Those change between two builds
    of the same tree, so the sha256 check failed on CI. This writer sets
    every member's mtime to the commit time and leaves atime and ctime out.
    """
    parent = stage_dir.parent
    paths: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(stage_dir, followlinks=False):
        dirnames.sort()
        filenames.sort()
        current = Path(dirpath)
        paths.append(current)
        for name in filenames:
            paths.append(current / name)
    paths.sort(key=lambda path: path.relative_to(parent).as_posix())

    archive.parent.mkdir(parents=True, exist_ok=True)
    tmp = archive.with_suffix(archive.suffix + ".tmp")
    with open(tmp, "wb") as raw:
        with gzip.GzipFile(
            filename="",
            mode="wb",
            fileobj=raw,
            mtime=0,
            compresslevel=6,
        ) as gz:
            with tarfile.open(fileobj=gz, mode="w|", format=tarfile.GNU_FORMAT) as tar:
                for path in paths:
                    rel = path.relative_to(parent).as_posix()
                    info = tarfile.TarInfo(rel)
                    info.mtime = mtime
                    info.uid = 0
                    info.gid = 0
                    info.uname = ""
                    info.gname = ""
                    info.pax_headers = {}
                    if path.is_symlink():
                        info.type = tarfile.SYMTYPE
                        info.linkname = os.readlink(path)
                        info.mode = 0o777
                        tar.addfile(info)
                    elif path.is_dir():
                        info.type = tarfile.DIRTYPE
                        info.mode = 0o755
                        tar.addfile(info)
                    elif path.is_file():
                        info.type = tarfile.REGTYPE
                        info.size = path.lstat().st_size
                        info.mode = 0o755 if path.lstat().st_mode & 0o111 else 0o644
                        with open(path, "rb") as handle:
                            tar.addfile(info, handle)
                    else:
                        raise SystemExit(f"unsupported file type: {path}")
    os.replace(tmp, archive)


def resolve_build_info(
    root: Path,
    tag: str,
    version: str,
    sha: str,
    mode: str,
    build_info_in: Path | None,
    inherit_submodules_from: Path | None,
) -> str:
    if build_info_in is not None:
        if mode != "release":
            raise SystemExit("--build-info-in is only for a release archive.")
        text = build_info_in.read_text(encoding="utf-8")
        if not text.endswith("\n"):
            text += "\n"
        assert_release_record(text, tag, sha)
        return text
    return build_info(
        root,
        tag,
        version,
        sha,
        mode,
        inherit_submodules_from=inherit_submodules_from,
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--dest", type=Path)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--source-date", type=int)
    parser.add_argument("--mode", choices=("release", "determinism"), default="release")
    parser.add_argument("--write-only", action="store_true")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--build-info-in", type=Path)
    parser.add_argument("--inherit-submodules-from", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    info = resolve_build_info(
        root,
        args.tag,
        args.version,
        args.sha,
        args.mode,
        args.build_info_in,
        args.inherit_submodules_from,
    )
    if args.write_only:
        if args.output is None:
            raise SystemExit("--write-only requires --output")
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(info, encoding="utf-8", newline="\n")
        os.chmod(args.output, 0o644)
        return
    if args.dest is None:
        raise SystemExit("staging requires --dest")
    if (args.archive is None) != (args.source_date is None):
        raise SystemExit("pass --archive and --source-date together")
    dest = args.dest
    if dest.exists():
        raise SystemExit(f"{dest} already exists")
    dest.mkdir(parents=True)
    stage_files(root, dest)
    require_present(dest)
    info_path = dest / "BUILD_INFO.txt"
    info_path.write_text(info, encoding="utf-8", newline="\n")
    os.chmod(info_path, 0o644)
    if args.archive is not None:
        write_deterministic_archive(dest, args.archive, args.source_date)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as err:
        sys.exit(err.returncode)
