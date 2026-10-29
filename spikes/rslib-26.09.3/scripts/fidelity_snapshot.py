#!/usr/bin/env python3
"""Snapshot an .apkg or collection.anki2 for roundtrip comparison.

Schema 18 columns are read with SELECT only (no WHERE on unicase), so the
stdlib sqlite3 works. Media hashes are of the decompressed bytes.
"""

from __future__ import annotations

import hashlib
import json
import sqlite3
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


def zstd(data: bytes) -> bytes:
    if data.startswith(b"\x28\xb5\x2f\xfd"):
        return subprocess.check_output(["zstd", "-dc"], input=data)
    return data


def open_db(path: Path) -> tuple[sqlite3.Connection, dict]:
    media: dict[str, dict] = {}
    if path.suffix == ".apkg" or zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            entry = next(
                n
                for n in ("collection.anki21b", "collection.anki21", "collection.anki2")
                if n in names
            )
            raw = archive.read(entry)
            if entry.endswith("anki21b"):
                raw = zstd(raw)
            media = media_from_zip(archive)
        tmp = tempfile.NamedTemporaryFile(suffix=".anki2", delete=False)
        tmp.write(raw)
        tmp.close()
        conn = sqlite3.connect(tmp.name)
        conn.row_factory = sqlite3.Row
        return conn, {"collection_entry": entry, "zip_entries": names, "media": media}
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    folder = path.with_suffix(".media")
    if not folder.is_dir():
        # OpenCollection uses "<col dir>/media" in this spike.
        folder = path.parent / "media"
    if folder.is_dir():
        for child in sorted(folder.iterdir()):
            if child.is_file():
                blob = child.read_bytes()
                media[child.name] = {
                    "sha1": hashlib.sha1(blob).hexdigest(),
                    "size": len(blob),
                }
    return conn, {"collection_entry": str(path), "media": media}


def media_from_zip(archive: zipfile.ZipFile) -> dict[str, dict]:
    """Map filename → sha1 of decompressed bytes.

    Latest packages store a zstd+protobuf media map whose entry order matches
    zip members 0..n. If protobuf parsing is unavailable, names fall back to
    the zip index and the test still compares hashes.
    """
    names = {}
    if "media" in archive.namelist():
        raw = zstd(archive.read("media"))
        stripped = raw.lstrip()
        if stripped.startswith(b"{") or stripped.startswith(b"["):
            legacy = json.loads(stripped.decode("utf-8"))
            # Legacy map is {"0": "filename"}.
            names = {int(key): value for key, value in legacy.items() if str(key).isdigit()}
        else:
            names = parse_media_names(raw)
    out = {}
    numeric = sorted(
        (n for n in archive.namelist() if n.isdigit()),
        key=lambda n: int(n),
    )
    for index, member in enumerate(numeric):
        blob = zstd(archive.read(member))
        filename = names.get(index, f"#{member}")
        out[filename] = {"sha1": hashlib.sha1(blob).hexdigest(), "size": len(blob), "zip": member}
    return out


def parse_media_names(raw: bytes) -> dict[int, str]:
    """Decode MediaEntries without a protobuf library.

    Field 1 of MediaEntries is a repeated MediaEntry. Each entry's field 1 is
    the filename. Entry order is the zip index.
    """
    names: dict[int, str] = {}
    index = 0
    pos = 0
    while pos < len(raw):
        key, pos = read_varint(raw, pos)
        field, wire = key >> 3, key & 7
        if wire == 2:
            length, pos = read_varint(raw, pos)
            chunk = raw[pos : pos + length]
            pos += length
            if field == 1:
                filename = entry_name(chunk)
                if filename is not None:
                    names[index] = filename
                index += 1
        elif wire == 0:
            _, pos = read_varint(raw, pos)
        elif wire == 5:
            pos += 4
        elif wire == 1:
            pos += 8
        else:
            break
    return names


def entry_name(chunk: bytes) -> str | None:
    pos = 0
    while pos < len(chunk):
        key, pos = read_varint(chunk, pos)
        field, wire = key >> 3, key & 7
        if wire == 2:
            length, pos = read_varint(chunk, pos)
            data = chunk[pos : pos + length]
            pos += length
            if field == 1:
                return data.decode("utf-8", "replace")
        elif wire == 0:
            _, pos = read_varint(chunk, pos)
        elif wire == 5:
            pos += 4
        elif wire == 1:
            pos += 8
        else:
            break
    return None


def read_varint(data: bytes, pos: int) -> tuple[int, int]:
    value = 0
    shift = 0
    while pos < len(data):
        byte = data[pos]
        pos += 1
        value |= (byte & 0x7F) << shift
        if byte < 128:
            return value, pos
        shift += 7
    raise ValueError("truncated varint")


def rows(conn: sqlite3.Connection, sql: str) -> list[dict]:
    try:
        return [dict(row) for row in conn.execute(sql)]
    except sqlite3.OperationalError as err:
        return [{"_error": str(err), "_sql": sql}]


def snapshot(path: Path) -> dict:
    conn, extra = open_db(path)
    try:
        schema = conn.execute("select ver from col").fetchone()[0]
        notes = rows(
            conn,
            "select id, guid, mid, mod, usn, tags, flds, sfld, csum, flags from notes order by id",
        )
        for note in notes:
            if "flds" in note and isinstance(note["flds"], str):
                note["fields"] = note["flds"].split("\x1f")
            if isinstance(note.get("tags"), str):
                note["tag_list"] = [t for t in note["tags"].split(" ") if t]
        cards = rows(
            conn,
            "select id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data from cards order by nid, ord",
        )
        notetypes = rows(conn, "select id, name, mtime_secs, usn from notetypes order by id")
        fields = rows(conn, "select ntid, ord, name from fields order by ntid, ord")
        templates = rows(
            conn,
            "select ntid, ord, name, mtime_secs, usn from templates order by ntid, ord",
        )
        decks = rows(conn, "select id, name, mtime_secs, usn from decks order by id")
        revlog = conn.execute("select count(*) from revlog").fetchone()[0]
        try:
            deck_config = conn.execute("select count(*) from deck_config").fetchone()[0]
        except sqlite3.OperationalError:
            deck_config = None
    finally:
        conn.close()
    by_nt = {}
    for field in fields:
        if "ntid" not in field:
            continue
        by_nt.setdefault(field["ntid"], {"fields": [], "templates": []})
        by_nt[field["ntid"]]["fields"].append({"ord": field["ord"], "name": field["name"]})
    for template in templates:
        if "ntid" not in template:
            continue
        by_nt.setdefault(template["ntid"], {"fields": [], "templates": []})
        by_nt[template["ntid"]]["templates"].append(
            {"ord": template["ord"], "name": template["name"]}
        )
    for notetype in notetypes:
        if "id" in notetype:
            extra_nt = by_nt.get(notetype["id"], {"fields": [], "templates": []})
            notetype["fields"] = extra_nt["fields"]
            notetype["templates"] = extra_nt["templates"]
    return {
        "schema": schema,
        "revlog_count": revlog,
        "deck_config_count": deck_config,
        "notes": notes,
        "cards": cards,
        "notetypes": notetypes,
        "decks": decks,
        **extra,
    }


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit("usage: fidelity_snapshot.py <file.apkg|file.anki2>")
    json.dump(snapshot(Path(sys.argv[1])), sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
