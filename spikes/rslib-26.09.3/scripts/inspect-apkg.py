#!/usr/bin/env python3
"""Read notes/cards/revlog out of an .apkg without linking rslib.

Latest packages store collection.anki21b as zstd. The query avoids WHERE
clauses on unicase columns so stock sqlite3 can open the file.
"""

from __future__ import annotations

import json
import sqlite3
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


def collection_bytes(archive: zipfile.ZipFile) -> tuple[str, bytes]:
    names = archive.namelist()
    for name in ("collection.anki21b", "collection.anki21", "collection.anki2"):
        if name in names:
            raw = archive.read(name)
            if name.endswith("anki21b"):
                raw = subprocess.check_output(["zstd", "-dc"], input=raw)
            return name, raw
    raise SystemExit(f"no collection entry in {names}")


def main() -> None:
    path = Path(sys.argv[1])
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        entry, raw = collection_bytes(archive)
    with tempfile.TemporaryDirectory() as tmp:
        db_path = Path(tmp) / "collection.anki2"
        db_path.write_bytes(raw)
        conn = sqlite3.connect(db_path)
        conn.row_factory = sqlite3.Row
        notes = [
            {"guid": row["guid"], "flds": row["flds"].split("\x1f")}
            for row in conn.execute("select guid, flds from notes order by id")
        ]
        cards = [
            {
                "type": row["type"],
                "queue": row["queue"],
                "due": row["due"],
                "ivl": row["ivl"],
                "factor": row["factor"],
                "reps": row["reps"],
                "lapses": row["lapses"],
                "left": row["left"],
                "data": row["data"],
            }
            for row in conn.execute(
                "select type, queue, due, ivl, factor, reps, lapses, left, data from cards order by id"
            )
        ]
        revlog = conn.execute("select count(*) from revlog").fetchone()[0]
        try:
            deck_config = conn.execute("select count(*) from deck_config").fetchone()[0]
        except sqlite3.OperationalError:
            deck_config = None
        schema = conn.execute("select ver from col").fetchone()[0]
        conn.close()
    json.dump(
        {
            "entries": names,
            "collection": entry,
            "schema": schema,
            "notes": notes,
            "cards": cards,
            "revlog_count": revlog,
            "deck_config_count": deck_config,
        },
        sys.stdout,
    )
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
