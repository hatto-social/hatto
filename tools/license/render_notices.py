# SPDX-FileCopyrightText: 2026 Hatto Social contributors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Turn cargo-about JSON and a Gradle license report into committed notices.

Anki path crates stay out of the ordinary third-party list. Their entry
points at NOTICE.md. rslib_bridge is this repository's own crate and is
omitted. License texts are the ones cargo-about and the Gradle plugin
resolved, including clarifications for crates whose packaged license files
are not machine-readable on their own.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ANKI_RUNTIME = ("anki", "anki_i18n", "anki_io", "anki_proto")
OWN_CRATE = "rslib_bridge"
ANKI_COMMIT = "29bb700b951e3f0c0cb69b77c0180fc1fe33e6ba"

ANKI_TEXT = f"""\
Anki rslib is included unmodified from the third_party/anki submodule, commit {ANKI_COMMIT} (tag 26.09.3). Copyright Ankitects Pty Ltd and contributors. License: AGPL-3.0-or-later, the same license as Hatto.

The path crates named with this entry are linked into the Android build. They are not ordinary third-party components. The notice is NOTICE.md.

anki_proto_gen is the same pin and the same license. The bridge build script uses it, and it is not linked into the APK.
"""

# POM / plugin license keys that are the same grants cargo-deny allows.
LICENSE_KEY_TO_SPDX = {
    "apache-2.0": "Apache-2.0",
    "apache_2_0": "Apache-2.0",
    "mit": "MIT",
    "bsd-2-clause": "BSD-2-Clause",
    "bsd-3-clause": "BSD-3-Clause",
    "isc": "ISC",
    "mpl-2.0": "MPL-2.0",
    "cc0-1.0": "CC0-1.0",
    "0bsd": "0BSD",
    "unlicense": "Unlicense",
    "zlib": "Zlib",
    "bsl-1.0": "BSL-1.0",
    "unicode-3.0": "Unicode-3.0",
    "cdla-permissive-2.0": "CDLA-Permissive-2.0",
}


def _die(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def _package_label(name: str, version: str) -> str:
    return f"{name} {version}"


def _rust_entries(
    about: dict,
) -> tuple[dict, list[dict], list[str], int]:
    crates = about.get("crates")
    licenses = about.get("licenses")
    if not isinstance(crates, list) or not isinstance(licenses, list):
        _die("cargo-about JSON is missing crates or licenses")

    by_name: dict[str, dict] = {}
    for crate in crates:
        package = crate.get("package") or {}
        name = package.get("name")
        if not name:
            _die("cargo-about crate is missing a package name")
        by_name[name] = crate
        if crate.get("license") == "Unknown":
            _die(f"{name} has an unknown license; add a clarification")

    missing = [name for name in ANKI_RUNTIME if name not in by_name]
    if missing:
        _die(
            "Anki runtime crates missing from cargo-about output: "
            + ", ".join(missing)
        )
    if OWN_CRATE not in by_name:
        _die("rslib_bridge missing from cargo-about output")

    anki_packages = [
        _package_label(name, by_name[name]["package"]["version"])
        for name in ANKI_RUNTIME
    ]
    skip = set(ANKI_RUNTIME) | {OWN_CRATE}

    entries: list[dict] = []
    satisfied: dict[str, list[str]] = {}
    for lic in licenses:
        spdx = lic.get("id") or ""
        text = (lic.get("text") or "").strip()
        source = lic.get("source_path") or ""
        suffix = source.rsplit("/", 1)[-1]
        if suffix.endswith((".rs", ".h", ".c", ".cc", ".cpp", ".py")):
            used = ", ".join(
                item["crate"]["name"] for item in lic.get("used_by") or []
            )
            _die(
                f"license text for {spdx} came from source file {suffix} ({used})"
            )
        if not text:
            _die(f"empty license text for {spdx}")
        packages: list[str] = []
        for item in lic.get("used_by") or []:
            crate = item.get("crate") or {}
            name = crate.get("name")
            if name in skip:
                continue
            label = _package_label(name, crate.get("version") or "")
            packages.append(label)
            satisfied.setdefault(name, [])
            if spdx not in satisfied[name]:
                satisfied[name].append(spdx)
        if not packages:
            continue
        packages = sorted(set(packages))
        entries.append(
            {"license": spdx, "packages": packages, "text": text + "\n"}
        )

    entries.sort(key=lambda entry: (entry["license"], entry["packages"][0], entry["text"]))

    flagged: list[str] = []
    for name, crate in sorted(by_name.items()):
        if name in skip:
            continue
        expression = crate.get("license") or ""
        # List AND and any GPL-family expression so the notice shows the choice.
        if " AND " in expression or "GPL" in expression or "LGPL" in expression:
            chosen = " AND ".join(satisfied.get(name, [])) or "(none)"
            version = crate["package"]["version"]
            flagged.append(f"{name} {version}: `{expression}` satisfied by {chosen}")

    anki = {
        "license": "AGPL-3.0-or-later",
        "notice": "NOTICE.md",
        "packages": anki_packages,
        "text": ANKI_TEXT,
    }
    third_party_count = len({pkg for entry in entries for pkg in entry["packages"]})
    return anki, entries, flagged, third_party_count


def _spdx_for_key(key: str, pom_name: str) -> str:
    mapped = LICENSE_KEY_TO_SPDX.get(key.lower())
    if mapped:
        return mapped
    return pom_name or key


def _android_entries(report: dict, flutter_license: str) -> list[dict]:
    if not isinstance(report, dict):
        _die("Gradle license report is not a JSON object")
    texts = report.get("license_texts")
    deps = report.get("dependencies")
    if not isinstance(texts, dict) or not isinstance(deps, list):
        _die(
            "Gradle license report has no license_texts/dependencies. "
            "Expected com.jaredsburrows.license generateJsonFullReport."
        )
    groups: dict[tuple[str, str], list[str]] = {}
    for dep in deps:
        coordinate = dep.get("dependency") or ""
        if not coordinate:
            project = dep.get("project") or "unknown"
            version = dep.get("version") or ""
            coordinate = f"{project}:{version}" if version else project
        licenses = dep.get("licenses") or []
        if not licenses:
            # The Flutter engine Maven POMs ship no <licenses> block. The
            # SDK LICENSE is BSD-3-Clause. Engine third parties are in the
            # app NOTICES file, not in this POM.
            if coordinate.startswith("io.flutter:"):
                body = flutter_license.strip() + "\n"
                groups.setdefault(("BSD-3-Clause", body), []).append(coordinate)
                continue
            _die(f"no license for Gradle dependency {coordinate}")
        for lic in licenses:
            key = lic.get("license_key")
            pom_name = lic.get("license") or ""
            if not key or key not in texts or not (texts.get(key) or "").strip():
                _die(
                    f"no full license text for {coordinate} "
                    f"({pom_name}, key={key}, url={lic.get('license_url')})"
                )
            spdx = _spdx_for_key(str(key), pom_name)
            body = str(texts[key]).strip() + "\n"
            groups.setdefault((spdx, body), []).append(coordinate)

    entries = []
    for (spdx, body), packages in groups.items():
        entries.append(
            {
                "license": spdx,
                "packages": sorted(set(packages)),
                "text": body,
            }
        )
    entries.sort(key=lambda entry: (entry["license"], entry["packages"][0]))
    return entries


def _markdown(
    anki: dict,
    rust_entries: list[dict],
    android_entries: list[dict],
    material_entry: dict,
    flagged: list[str],
    rust_count: int,
    android_count: int,
    desktop_count: int,
    ofl_text: str,
) -> str:
    lines: list[str] = []
    lines.append("# Third-party notices")
    lines.append("")
    lines.append(
        "Generated by `tools/license/gen-notices.sh`. Do not edit by hand."
    )
    lines.append("")
    lines.append(
        "Rust crates in the Android section are the Android runtime graph of "
        "`packages/rslib_bridge/rust` "
        "(`aarch64-linux-android`, `armv7-linux-androideabi`, `x86_64-linux-android`). "
        "Build-only and dev-only crates are omitted. Gradle dependencies are the "
        "Android `releaseRuntimeClasspath`. "
        "The desktop graph (`x86_64-unknown-linux-gnu`, `aarch64-apple-darwin`) "
        f"is {desktop_count} third-party crates in "
        "`apps/desktop/assets/licenses/rust-crates.json`."
    )
    lines.append("")
    lines.append(
        f"Rust third-party crates: {rust_count}. "
        f"Gradle dependencies: {android_count}."
    )
    lines.append("")
    lines.append("## Anki")
    lines.append("")
    lines.append(anki["text"].rstrip())
    lines.append("")
    lines.append("Runtime path crates:")
    lines.append("")
    for package in anki["packages"]:
        lines.append(f"- {package}")
    lines.append("")
    if flagged:
        lines.append("## License choices")
        lines.append("")
        lines.append(
            "These runtime crates needed a choice or an `AND` of more than one "
            "grant. `OR` expressions are satisfied by the earliest license in "
            "`tools/license/about.toml`. GPL-2.0-only and LGPL-only are not "
            "accepted."
        )
        lines.append("")
        for line in flagged:
            lines.append(f"- {line}")
        lines.append("")
    lines.append("## Rust crates")
    lines.append("")
    for entry in rust_entries:
        lines.append(f"### {entry['license']}")
        lines.append("")
        for package in entry["packages"]:
            lines.append(f"- {package}")
        lines.append("")
        lines.append("```")
        lines.append(entry["text"].rstrip())
        lines.append("```")
        lines.append("")
    lines.append("## Android Gradle dependencies")
    lines.append("")
    lines.append(
        "Collected from `releaseRuntimeClasspath` with "
        "`com.jaredsburrows.license` 0.9.91 (`generateJsonFullReport`). "
        "That plugin is Apache-2.0. Google's oss-licenses plugin is not used. "
        "The report is not copied into the APK by the build; the app loads "
        "`apps/mobile/assets/licenses/android-deps.json`."
    )
    lines.append("")
    lines.append(
        "`io.flutter` engine artifacts publish no license in their POM. "
        "Their text is the Flutter SDK `LICENSE` (BSD-3-Clause, Copyright 2014 "
        "The Flutter Authors). Third-party code linked into the engine "
        "(FreeType, HarfBuzz, ICU, and the rest) is in the Flutter `NOTICES` "
        "bundle, which the app reads through `LicenseRegistry`, and is not "
        "copied again here."
    )
    lines.append("")
    for entry in android_entries:
        lines.append(f"### {entry['license']}")
        lines.append("")
        for package in entry["packages"]:
            lines.append(f"- {package}")
        lines.append("")
        lines.append("```")
        lines.append(entry["text"].rstrip())
        lines.append("```")
        lines.append("")
    lines.append("## Material Icons")
    lines.append("")
    lines.append(
        "`apps/mobile/pubspec.yaml` sets `uses-material-design: true`, so the "
        "release asset bundle contains `fonts/MaterialIcons-Regular.otf` from "
        "the Flutter SDK (`bin/cache/artifacts/material_fonts/`). The font's "
        "license file in that directory is CC BY 4.0, not Apache-2.0. Flutter's "
        "license collector reads package `LICENSE` / `NOTICES` files and does "
        "not read `MaterialIcons_LICENSE.txt`, so this text is registered with "
        "the app's `LicenseRegistry` from `material-icons.json`."
    )
    lines.append("")
    lines.append(f"### {material_entry['license']}")
    lines.append("")
    for package in material_entry["packages"]:
        lines.append(f"- {package}")
    lines.append("")
    lines.append("```")
    lines.append(material_entry["text"].rstrip())
    lines.append("```")
    lines.append("")
    lines.append("## Desktop fonts")
    lines.append("")
    lines.append(
        "Golden tests for `apps/desktop` load Noto Sans Regular and "
        "Noto Sans KR Regular from `apps/desktop/test/fonts/` through "
        "`FontLoader`. Both are SIL Open Font License 1.1. The text below "
        "is `apps/desktop/test/fonts/OFL.txt`. The desktop app also loads "
        "`apps/desktop/assets/licenses/material-icons.json` and "
        "`apps/desktop/assets/licenses/flutter-sdk.json` (the Flutter SDK "
        "`LICENSE`, BSD-3-Clause). Engine third parties stay in Flutter's "
        "own `NOTICES` bundle via `LicenseRegistry`."
    )
    lines.append("")
    lines.append("### OFL-1.1")
    lines.append("")
    lines.append("- Noto Sans Regular")
    lines.append("- Noto Sans KR Regular")
    lines.append("")
    lines.append("```")
    lines.append(ofl_text.rstrip())
    lines.append("```")
    lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def _material_icons_entry(license_text: str) -> dict:
    # Flutter 3.47 ships this file next to MaterialIcons-Regular.otf. The
    # asset bundler copies the font when uses-material-design is true and
    # does not copy this license into NOTICES.
    if "Creative Commons Attribution 4.0 International Public License" not in license_text:
        _die("MaterialIcons_LICENSE.txt is not the CC BY 4.0 text this script expects")
    return {
        "license": "CC-BY-4.0",
        "packages": ["MaterialIcons-Regular.otf"],
        "text": license_text.strip() + "\n",
    }


def _desktop_anki_text(text: str) -> str:
    return text.replace(
        "The path crates named with this entry are linked into the Android build.",
        "The path crates named with this entry are linked into the desktop build.",
    ).replace(
        "it is not linked into the APK.",
        "it is not linked into the desktop app.",
    )


def main() -> None:
    if len(sys.argv) != 8:
        _die(
            "usage: render_notices.py ROOT ABOUT_JSON ANDROID_JSON "
            "FLUTTER_LICENSE MATERIAL_ICONS_LICENSE DESKTOP_ABOUT_JSON OFL_TEXT"
        )
    root = Path(sys.argv[1])
    about = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
    android_raw = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
    flutter_license = Path(sys.argv[4]).read_text(encoding="utf-8")
    material_license = Path(sys.argv[5]).read_text(encoding="utf-8")
    desktop_about = json.loads(Path(sys.argv[6]).read_text(encoding="utf-8"))
    ofl_text = Path(sys.argv[7]).read_text(encoding="utf-8")
    if "Copyright 2014 The Flutter Authors" not in flutter_license:
        _die(f"{sys.argv[4]} is not the Flutter SDK LICENSE")
    anki, rust_entries, flagged, rust_count = _rust_entries(about)
    desktop_anki, desktop_entries, _desktop_flagged, desktop_count = _rust_entries(
        desktop_about
    )
    desktop_anki = dict(desktop_anki)
    desktop_anki["text"] = _desktop_anki_text(desktop_anki["text"])
    android_entries = _android_entries(android_raw, flutter_license)
    material_entry = _material_icons_entry(material_license)
    android_count = sum(len(entry["packages"]) for entry in android_entries)

    rust_doc = {
        "generator": "cargo-about 0.9.3",
        "targets": [
            "aarch64-linux-android",
            "armv7-linux-androideabi",
            "x86_64-linux-android",
        ],
        "anki": anki,
        "entries": rust_entries,
    }
    android_doc = {
        "generator": "com.jaredsburrows.license 0.9.91",
        "configuration": "releaseRuntimeClasspath",
        "entries": android_entries,
    }
    material_doc = {
        "generator": "flutter-sdk material_fonts/MaterialIcons_LICENSE.txt",
        "entries": [material_entry],
    }
    license_dir = root / "apps" / "mobile" / "assets" / "licenses"
    license_dir.mkdir(parents=True, exist_ok=True)
    (license_dir / "rust-crates.json").write_text(
        json.dumps(rust_doc, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    (license_dir / "android-deps.json").write_text(
        json.dumps(android_doc, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    (license_dir / "material-icons.json").write_text(
        json.dumps(material_doc, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    desktop_dir = root / "apps" / "desktop" / "assets" / "licenses"
    desktop_dir.mkdir(parents=True, exist_ok=True)
    desktop_doc = {
        "generator": "cargo-about 0.9.3",
        "targets": [
            "x86_64-unknown-linux-gnu",
            "aarch64-apple-darwin",
        ],
        "anki": desktop_anki,
        "entries": desktop_entries,
    }
    flutter_doc = {
        "generator": "flutter-sdk LICENSE",
        "entries": [
            {
                "license": "BSD-3-Clause",
                "packages": ["Flutter SDK"],
                "text": flutter_license.strip() + "\n",
            }
        ],
    }
    (desktop_dir / "rust-crates.json").write_text(
        json.dumps(desktop_doc, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    (desktop_dir / "material-icons.json").write_text(
        json.dumps(material_doc, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    (desktop_dir / "flutter-sdk.json").write_text(
        json.dumps(flutter_doc, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    (root / "THIRD_PARTY_NOTICES.md").write_text(
        _markdown(
            anki,
            rust_entries,
            android_entries,
            material_entry,
            flagged,
            rust_count,
            android_count,
            desktop_count,
            ofl_text,
        ),
        encoding="utf-8",
    )
    print(
        f"rust third-party crates: {rust_count}; "
        f"rust license texts: {len(rust_entries)}; "
        f"gradle dependencies: {android_count}; "
        f"gradle license texts: {len(android_entries)}"
    )
    if flagged:
        print("license choices:")
        for line in flagged:
            print(f"  {line}")


if __name__ == "__main__":
    main()
