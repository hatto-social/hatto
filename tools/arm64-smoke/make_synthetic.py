#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 Hatto Social contributors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Regenerate the three synthetic colpkg fixtures and their expected counts.

The decks are built by `make_synthetic_decks`, which talks to unmodified
rslib 26.09.3 only through Backend::run_service_method. Run this from a
checkout that already has third_party/anki at the pinned commit. protoc must
be on PATH (the repo documents 31.1). faketime freezes the clock so a second
run writes the same colpkg bytes.

    TZ is set here. Do not call the Rust binary on its own.

host_seconds in expected.json are a timing sample from this process. judge.py
does not read them, and a later run can change the third decimal place.
"""

import hashlib
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
FILES = os.path.join(HERE, "files")
EXPECTED = os.path.join(HERE, "expected.json")
MEASURE = os.path.join(HERE, "synthetic", "measure.json")
BINARY_REL = os.path.join("target", "release", "make_synthetic_decks")
FROZEN = "2026-01-15 12:00:00"
COLPKG = (
    "palace.colpkg",
    "collection.colpkg",
    "collection_nomedia_new.colpkg",
)


def require(tool):
    if shutil.which(tool) is None:
        sys.exit(f"{tool} is not on PATH")


def main():
    require("faketime")
    require("protoc")
    require("cargo")
    os.chdir(ROOT)
    subprocess.run(
        ["cargo", "build", "--release", "-p", "rslib_bridge", "--bin", "make_synthetic_decks"],
        check=True,
    )
    env = os.environ.copy()
    env["TZ"] = "Asia/Seoul"
    env["FAKETIME_DONT_FAKE_MONOTONIC"] = "1"
    os.makedirs(os.path.dirname(MEASURE), exist_ok=True)
    subprocess.run(
        [
            "faketime",
            "-f",
            FROZEN,
            os.path.join(ROOT, BINARY_REL),
            "--out",
            FILES,
            "--measure",
            MEASURE,
        ],
        check=True,
        env=env,
        stdout=subprocess.DEVNULL,
    )
    measured = json.load(open(MEASURE, encoding="utf-8"))
    expected = json.load(open(EXPECTED, encoding="utf-8"))
    expected["host"] = (
        "x86_64 linux, rslib 26.09.3; synthetic colpkg measured by "
        "tools/arm64-smoke/make_synthetic.py at 2026-01-15 12:00:00 Asia/Seoul"
    )
    expected["colpkg_capture"] = (
        "Host round trip through rslib's protobuf import and export. "
        "The arm64 device was not run for this capture. Judged fields are "
        "notes, cards, and revlog_with_card; those counts do not depend on "
        "the device clock. fsrs_synthetic and notetype were not regenerated."
    )
    def counts(row):
        return {
            "notes": row["notes"],
            "cards": row["cards"],
            "revlog_total": row["revlog_total"],
            "revlog_with_card": row["revlog_with_card"],
            "filtered_cards": row["filtered_cards"],
        }

    def fsrs(row):
        return {
            "fsrs_items": row["fsrs_items"],
            "n_params": row["n_params"],
            "params": row["params"],
            "all_finite": row["all_finite"],
            "seconds": row["seconds"],
        }

    colpkg = {}
    for name in COLPKG:
        path = os.path.join(FILES, name)
        blob = open(path, "rb").read()
        row = measured[name]
        seconds = row["host_seconds"]
        colpkg[name] = {
            "bytes": len(blob),
            "sha256": hashlib.sha256(blob).hexdigest(),
            "E_after_colpkg_import": counts(row["E_after_colpkg_import"]),
            "R_after_apkg_import": counts(row["R_after_apkg_import"]),
            "import_new_notes": row["import_new_notes"],
            "host_seconds": {
                "colpkg": seconds["colpkg"],
                "export": seconds["export"],
                "apkg_import": seconds["apkg_import"],
            },
            "fsrs": fsrs(row["fsrs"]),
            "fsrs_deterministic_on_host": row["fsrs_deterministic_on_host"],
            "pass_rule": {
                "notes": row["pass_rule"]["notes"],
                "cards": row["pass_rule"]["cards"],
                "revlog_with_card": row["pass_rule"]["revlog_with_card"],
            },
            "media_files_after_colpkg_import": row["media_files_after_colpkg_import"],
        }
    expected["colpkg"] = colpkg
    with open(EXPECTED, "w", encoding="utf-8") as handle:
        json.dump(expected, handle, indent=1, ensure_ascii=False)
        handle.write("\n")
    sums = []
    for name in sorted(os.listdir(FILES)):
        path = os.path.join(FILES, name)
        if not name.endswith((".colpkg", ".apkg")) or not os.path.isfile(path):
            continue
        digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
        sums.append((name, digest))
    with open(os.path.join(FILES, "SHA256SUMS"), "w", encoding="utf-8") as handle:
        handle.write("".join(f"{digest}  {name}\n" for name, digest in sums))
    good = subprocess.check_output([sys.executable, os.path.join(HERE, "selftest_make_log.py")])
    with open(os.path.join(HERE, "selftest.log"), "wb") as handle:
        handle.write(good)
    bad = good.decode("utf-8").replace(
        "R_notes=6 R_cards=8 R_revlog_total=1 R_revlog_with_card=1",
        "R_notes=6 R_cards=8 R_revlog_total=1 R_revlog_with_card=0",
        1,
    )
    with open(os.path.join(HERE, "selftest_bad.log"), "w", encoding="utf-8") as handle:
        handle.write(bad)
    os.remove(MEASURE)
    print("wrote synthetic colpkg fixtures and expected.json")


if __name__ == "__main__":
    main()
