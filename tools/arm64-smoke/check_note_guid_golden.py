# SPDX-FileCopyrightText: 2026 Hatto Social contributors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Check the shared note-guid golden file against Python's uuid module.

Rust and Dart read the same file. This script is the Python side. It does
not open a collection and does not need the host harness.
"""

import json
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GOLDEN = ROOT / "packages" / "hatto_card_contract" / "fixtures" / "note_guid_golden.json"


def load_golden(path=GOLDEN):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def check(document):
    errors = []
    for case in document["imported"]:
        job = uuid.UUID(case["job_id"])
        source = case["source_guid"]
        if case.get("error") == "empty_source_guid":
            if source != "":
                errors.append(f"{case['label']}: empty case has source {source!r}")
            continue
        expect = str(uuid.uuid5(job, source))
        if case["expect"] != expect:
            errors.append(f"{case['label']}: file {case['expect']} python {expect}")
    for case in document["local"]:
        op_id = uuid.UUID(case["op_id"])
        name = "note:" + str(case["k"])
        expect = str(uuid.uuid5(op_id, name))
        if case["expect"] != expect:
            errors.append(f"{case['label']}: file {case['expect']} python {expect}")
    return errors


def main():
    document = load_golden()
    errors = check(document)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"note guid golden ok ({GOLDEN})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
