# SPDX-FileCopyrightText: 2026 Hatto Social contributors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Record of how hatto-seed.apkg was made. DO NOT RUN THIS TO REPLACE THE SEED.

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  NEVER REGENERATE hatto-seed.apkg.

  Every run draws new random ids for the fields and templates inside each
  notetype. rslib's import (`equal_schema`, notetype/merge.rs) compares those
  ids, not just the notetype id. A seed rebuilt with the same notetype ids
  but new field/template ids is a different notetype to every collection that
  already imported the old one: the second import skips every note as
  `conflicting` and adds a `Hatto Basic+` copy. That is the bug (F3) this file
  exists to prevent.

  The committed bytes are pinned by SEED_SHA256 in src/seed.rs and checked by
  `cargo test -p hatto_card`. Change the seed only on purpose, with a new
  decision in the contract, and treat every collection that imported the old
  seed as incompatible.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

What it did (run once on 2026-11-20 with Python `anki` 26.9.3, build
29bb700b, the same rslib commit the CLI pins):

1. Make a new collection. It holds Anki's stock notetypes.
2. Add one note per notetype below to the Default deck.
3. Close it. In SQLite, set each notetype's id to 1767225600001..05, its
   mtime to 1767225600 (2026-01-01T00:00:00Z) and usn to -1, and fix the
   ids and mod times of the notes and cards. Rename the notetypes to the
   Hatto names. Ids stay below "now": a future id makes Anki ask for a
   Check Database.
4. Open it again and export the whole collection as a package with
   legacy=false, no scheduling, no deck configs.

The CLI imports the seed into every temporary collection, deletes the seed
notes, and builds the deck on the notetype it just imported.

Usage (documentation only): python make_seed.py OUT.apkg
"""

import os
import shutil
import sqlite3
import sys
import tempfile

if os.environ.get("HATTO_SEED_I_KNOW_THIS_BREAKS_F3") != "yes":
    sys.exit(
        "refusing to run: regenerating the seed reintroduces F3 (see the top of this file)"
    )

from anki.collection import Collection  # noqa: E402
from anki.generic_pb2 import Empty  # noqa: E402
from anki.import_export_pb2 import ExportAnkiPackageOptions, ExportLimit  # noqa: E402

# (stock name, Hatto name). Same order as ALIASES in src/seed.rs.
NOTETYPES = [
    ("Basic", "Hatto Basic"),
    ("Basic (and reversed card)", "Hatto Basic (and reversed card)"),
    ("Basic (optional reversed card)", "Hatto Basic (optional reversed card)"),
    ("Basic (type in the answer)", "Hatto Basic (type in the answer)"),
    ("Cloze", "Hatto Cloze"),
]
FIXED_MTIME = 1767225600  # 2026-01-01T00:00:00Z
BASE = 1767225600000  # the same instant in ms; ids are 1767225600001..05

out = os.path.abspath(sys.argv[1])
work = tempfile.mkdtemp()
path = f"{work}/collection.anki2"

col = Collection(path)
for stock, _ in NOTETYPES:
    note = col.new_note(col.models.by_name(stock))
    note.fields[0] = "seed {{c1::x}}" if stock == "Cloze" else "seed"
    if stock != "Cloze":
        for i in range(1, len(note.fields)):
            note.fields[i] = "seed"
    col.add_note(note, 1)  # deck 1 is Default
col.close()

con = sqlite3.connect(path)
con.create_collation("unicase", lambda a, b: (a.lower() > b.lower()) - (a.lower() < b.lower()))
ids = dict(con.execute("select name, id from notetypes").fetchall())
for i, (stock, hatto) in enumerate(NOTETYPES, start=1):
    old, new = ids[stock], BASE + i
    con.execute(
        "update notetypes set id=?, name=?, mtime_secs=?, usn=-1 where id=?",
        (new, hatto, FIXED_MTIME, old),
    )
    con.execute("update fields set ntid=? where ntid=?", (new, old))
    con.execute(
        "update templates set ntid=?, mtime_secs=?, usn=-1 where ntid=?",
        (new, FIXED_MTIME, old),
    )
    con.execute("update notes set mid=? where mid=?", (new, old))
for i, (nid,) in enumerate(con.execute("select id from notes order by id").fetchall()):
    con.execute("update cards set nid=? where nid=?", (BASE + 1000 + i, nid))
    con.execute(
        "update notes set id=?, guid=?, mod=?, usn=-1 where id=?",
        (BASE + 1000 + i, f"hatto-seed-{i}", FIXED_MTIME, nid),
    )
for i, (cid,) in enumerate(con.execute("select id from cards order by id").fetchall()):
    con.execute("update cards set id=?, mod=?, usn=-1 where id=?", (BASE + 2000 + i, FIXED_MTIME, cid))
con.commit()
con.close()

col = Collection(path)
col._backend.export_anki_package(
    out_path=out,
    options=ExportAnkiPackageOptions(
        with_scheduling=False, with_deck_configs=False, with_media=True, legacy=False
    ),
    limit=ExportLimit(whole_collection=Empty()),
)
col.close()
shutil.rmtree(work)
print("wrote", out)
