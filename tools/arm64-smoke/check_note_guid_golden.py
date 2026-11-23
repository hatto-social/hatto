# SPDX-FileCopyrightText: 2026 Hatto Social contributors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Check the shared note-guid golden file against Python's uuid module.

Rust and Dart read the same file. This script is the Python side. It does
not open a collection and does not need the host harness.

Import rows are checked with the same rules as hatto_card_contract:
normalize with IMPORT_NS, assign duplicate groups, strip the media-collision
suffix, and classify. The script recomputes; it does not trust the stored
expect until it matches that recomputation.
"""

import hashlib
import json
import re
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GOLDEN = ROOT / "packages" / "hatto_card_contract" / "fixtures" / "note_guid_golden.json"

IMPORT_NS = uuid.uuid5(uuid.NAMESPACE_URL, "urn:hatto:import-note:v1")
MEDIA_SUFFIX = re.compile(r"-[0-9a-f]{40}(\.[A-Za-z0-9]+)")

# The six f rows from the I1 contract. A lowercase version-4 guid is kept.
IMPORT_F_SPEC = (
    ("oxr*zK@INR", "c15b93d8-6483-5c3c-b94f-1061d53fda92"),
    ("b91/guid#2", "51aed07c-7668-5726-9830-b3eab77dcb92"),
    ("plainGuid3", "e67308dc-2365-5fc4-900e-4fc19f04c9ab"),
    (
        "3f2b8a64-1c0e-4d5a-9b7e-0a1b2c3d4e5f",
        "3f2b8a64-1c0e-4d5a-9b7e-0a1b2c3d4e5f",
    ),
    (
        "3F2B8A64-1C0E-4D5A-9B7E-0A1B2C3D4E5F",
        "4b08d171-4bd5-5f1f-8e85-1315a11b82e0",
    ),
    ("a  ", "490ca485-3c6e-5cd4-82ab-174a4023134b"),
)


def load_golden(path=GOLDEN):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def is_guid_format(text):
    try:
        parsed = uuid.UUID(text)
    except ValueError:
        return False
    if str(parsed) != text:
        return False
    return parsed.version in (4, 5)


def normalize_import_guid(raw):
    if raw == "":
        raise ValueError("empty source guid")
    if is_guid_format(raw):
        return raw
    return str(uuid.uuid5(IMPORT_NS, raw))


def assign_import_guids(notes):
    decorated = []
    for note in notes:
        raw = note["raw_guid"]
        key = None if raw == "" else normalize_import_guid(raw)
        decorated.append((note["source_note_id"], raw, key))
    groups = {}
    for index, (_nid, _raw, key) in enumerate(decorated):
        if key is None:
            continue
        groups.setdefault(key, []).append(index)
    out = [None] * len(decorated)
    for key, indexes in groups.items():
        indexes = sorted(indexes, key=lambda index: (decorated[index][0], decorated[index][1]))
        for k, index in enumerate(indexes):
            nid, raw, _key = decorated[index]
            if k == 0:
                guid = key
            else:
                guid = str(uuid.uuid5(IMPORT_NS, raw + "\x1f" + str(k)))
            out[index] = {"source_note_id": nid, "guid": guid, "dup_index": k}
    for index, (nid, _raw, key) in enumerate(decorated):
        if key is not None:
            continue
        guid = str(uuid.uuid5(IMPORT_NS, "\x1fnid:" + str(nid)))
        out[index] = {"source_note_id": nid, "guid": guid, "dup_index": 0}
    out.sort(key=lambda row: (row["source_note_id"], row["dup_index"], row["guid"]))
    return out


def note_content_hash(fields, tags):
    normalized = [MEDIA_SUFFIX.sub(r"\1", field) for field in fields]
    unique = sorted(set(tags))
    body = "\x1f".join(normalized) + "\x1e" + " ".join(unique)
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


def classify(file_facts, resident):
    if resident is None:
        return "NEW"
    if file_facts["notetype_id"] != resident["notetype_id"]:
        return "BLOCKED"
    if file_facts["content_hash"] == resident["content_hash"]:
        return "SAME"
    if file_facts["mod"] > resident["mod"]:
        return "CHANGED"
    return "LOCAL_NEWER"


def check(document):
    errors = []
    if IMPORT_NS != uuid.UUID("ec425e06-0eeb-5cbc-b4c8-3818366d46e9"):
        errors.append(f"IMPORT_NS recomputed as {IMPORT_NS}")
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
    jobs = document.get("smoke_jobs")
    if not isinstance(jobs, dict) or set(jobs) != {"job1", "job2", "job3"}:
        errors.append("smoke_jobs must map job1, job2, and job3 to fixed UUIDs")
    else:
        seen = set()
        for name, value in jobs.items():
            parsed = str(uuid.UUID(value))
            if parsed != value or value[14] not in "45":
                errors.append(f"smoke_jobs.{name} is not a lowercase UUID version 4 or 5")
            seen.add(parsed)
        if len(seen) != 3:
            errors.append("smoke_jobs must be three different ids")

    for key in (
        "import_f",
        "assign_import_guids",
        "note_content_hash",
        "classify",
        "plans",
    ):
        if key not in document:
            errors.append(f"missing {key}")

    rows = document.get("import_f")
    if not isinstance(rows, list) or len(rows) != len(IMPORT_F_SPEC):
        errors.append("import_f must hold the six spec rows")
    else:
        for spec_raw, spec_expect in IMPORT_F_SPEC:
            matches = [row for row in rows if row.get("raw") == spec_raw]
            if len(matches) != 1 or matches[0].get("expect") != spec_expect:
                errors.append(f"import_f missing spec row {spec_raw!r} -> {spec_expect}")
        for case in rows:
            try:
                derived = normalize_import_guid(case["raw"])
            except ValueError as exc:
                errors.append(f"{case.get('label')}: {exc}")
                continue
            if case["expect"] != derived:
                errors.append(
                    f"{case.get('label')}: file {case['expect']} python {derived}"
                )
            if not is_guid_format(derived) or normalize_import_guid(derived) != derived:
                errors.append(f"{case.get('label')}: f is not idempotent")

    for case in document.get("assign_import_guids", []):
        assigned = assign_import_guids(case["notes"])
        if assigned != case["expect"]:
            errors.append(f"{case['label']}: assign mismatch {assigned!r}")
        if len(assigned) != len(case["notes"]):
            errors.append(f"{case['label']}: note count changed")
        dup = sum(1 for row in assigned if row["dup_index"] >= 1)
        if dup != case["dup"]:
            errors.append(f"{case['label']}: dup {case['dup']} counted {dup}")

    for case in document.get("note_content_hash", []):
        digest = note_content_hash(case["fields"], case["tags"])
        if case["expect"] != digest:
            errors.append(f"{case['label']}: file {case['expect']} python {digest}")

    classes = document.get("classify", [])
    seen_classes = {case.get("expect") for case in classes}
    for name in ("NEW", "SAME", "CHANGED", "LOCAL_NEWER", "BLOCKED"):
        if name not in seen_classes:
            errors.append(f"classify is missing {name}")
    for case in classes:
        got = classify(case["file"], case["resident"])
        if got != case["expect"]:
            errors.append(f"{case['label']}: classify {got} file {case['expect']}")

    for case in document.get("plans", []):
        counts = {"new": 0, "same": 0, "changed": 0, "local_newer": 0, "blocked": 0}
        names = {
            "NEW": "new",
            "SAME": "same",
            "CHANGED": "changed",
            "LOCAL_NEWER": "local_newer",
            "BLOCKED": "blocked",
        }
        for name in case["classes"]:
            counts[names[name]] += 1
        expect = dict(case["expect"])
        dup = case["dup"]
        no_call = counts["new"] == 0 and counts["changed"] == 0
        got = {**counts, "dup": dup, "no_resident_call": no_call}
        if got != expect:
            errors.append(f"{case['label']}: plan {got} file {expect}")
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
