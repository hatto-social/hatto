# hatto-card

Developer CLI that only generates data. It checks a deck file, appends one
note, builds a temporary collection, and writes an apkg. It does not import
a package and it does not open a user collection.

Guid derivation and the guid format check come from `packages/hatto_card_contract`.
Export flags come from `rslib_bridge::export_contract` (legacy false, media
included, scheduling off, deck configs off, one deck).

## Provisional deck JSON

No contract document defines this file. The shape is the thinnest map onto
Anki and can change:

| Field | Meaning |
| --- | --- |
| `deck_name` | Deck created with `AddDeck` |
| `job_id` | Accepted and ignored. A note may still set its own. Neither is used to derive a guid. |
| `op_id` | UUID for local notes. A note may override it. |
| `notetype` | Stock notetype name or its Hatto name (table below). Default `Basic`. |
| `notetype_legacy` | Optional Anki legacy notetype object, sent to `add_notetype_legacy`. |
| `media_dir` | Files added with `add_media_file`. Relative to the deck file. |
| `notes[].source_guid` | Imported note. Guid is `normalize_import_guid(source_guid)`. |
| `notes[].k` | Local note. Guid is `local_note_guid(op_id, k)`. |
| `notes[].fields` | Field strings, one per notetype field. |
| `notes[].tags` | Tag list. |

A note sets `source_guid` or `k`, not both. `source_guid` is not trimmed,
case-folded, or Unicode-normalized. An empty `source_guid` is `GUID_FORMAT`.
The same derived guid twice in this file is `NOTE_GUID_DUPLICATE`.
Duplicates against a collection or `note_map` are not checked here.

CLI `source_guid` mode is an input generator that mimics an external apkg: `normalize_import_guid` is idempotent, so a guid written here is the same guid a later import would assign.

`hatto-card new` writes this shape with a new UUIDv4 `job_id` and `op_id`.
`--deck-name` sets `deck_name` (default `Example`). With `--output`, it also
writes `media/dot.png` beside the deck file when that file is missing, so
`validate` and `export` can run next. An existing `dot.png` is left unchanged.
`examples/with-media/` is the same shape with the fixed ids in that file, plus
the png `new` copies. Local note guids are uuid5 values from the fresh
`op_id`. The `source_guid` note uses `normalize_import_guid`, so the fresh
`job_id` is stored and does not change that guid. A deck with no notes is
still rejected.

## Commands

```sh
hatto-card --help
hatto-card new --help
hatto-card --json new --output deck.json --deck-name "My deck"
hatto-card --json validate --deck deck.json
hatto-card --json export --deck deck.json --output out.apkg
hatto-card --json add-note --deck deck.json --notetype Basic --field front --field back
hatto-card --json add-note --deck deck.json --notetype Basic --field front --field back --op-id UUID --k 0
hatto-card --json add-note --deck deck.json --notetype Basic --field front --field back --tag example --job-id UUID --source-guid TEXT
```

`-h` and `--help` print help on stdout and exit 0, for the top level and for
each command (`hatto-card new --help`, and the same for `validate`, `export`,
and `add-note`). A missing or unknown command still exits 2.

`export` validates, writes the notes into a temporary collection, and exports
that one deck. `validate` runs the same notetype gate first: it opens a
temporary collection, checks that the notetype exists, and checks that each
note has one field per notetype field. It does not write an apkg. `--json`
prints one JSON object. Exit status is non-zero when the deck JSON is invalid,
a guid check fails, a media file is missing, a note's field count does not
match the notetype, or `notetype_legacy.id` is present and is not 0.

`add-note` appends one note. There is no add-card command; Anki builds the
cards from the note and the notetype. `--notetype` must name the same notetype as the deck's
`notetype` string, or `Basic` when that field is absent (`Basic` and
`Hatto Basic` are the same notetype). The note does not
store a notetype. Each `--field` is one field string, in notetype order.
`--tag` may be repeated and is omitted from the note when absent. `--output`
writes that path instead of the input file.

With no guid flags, `add-note` makes a UUIDv4 `op_id` and sets `k` to 0.
`k` is the index of the note inside this write, not the index in the file.
The guid is `local_note_guid(op_id, k)`. `--op-id` and `--k` set those
values. `--source-guid` (with `--job-id`) uses `normalize_import_guid`.
`--job-id` is stored on the new note and ignored for that guid. Those
flags cannot be combined with `--op-id` or `--k`. The id is stored on the
new note, so the deck-level `op_id` or `job_id` of the other notes stays
as it was.

The file is written only after the guid checks and the media-directory check.
A failure leaves every deck file unchanged. `add-note` does not open a
collection, so it does not apply the notetype field-count or
`notetype_legacy.id` checks; `validate` and `export` do.

Checks kept here are the deck JSON shape, `GUID_FORMAT`, `NOTE_GUID_DUPLICATE`
inside this file, a missing media path, the notetype's field count, and a
`notetype_legacy.id` other than 0. Media bytes are copied as-is.

## Notetypes and the seed

`export` imports `seed/hatto-seed.apkg` into its temporary collection before it
builds the deck, deletes the seed's notes, and puts the deck's notes on the
seed's notetype. rslib keeps notetype ids on import, so every export carries
the same notetype id. Before the seed, each export made a new `Basic` with a new
random id, and importing two exports of one deck into one collection skipped
every note of the second as `conflicting` and added `Basic+` (F3).

| `deck.json` `notetype` (either spelling) | Name in the apkg | Id in the apkg |
| --- | --- | --- |
| `Basic` or `Hatto Basic` | `Hatto Basic` | 1767225600001 |
| `Basic (and reversed card)` or `Hatto Basic (and reversed card)` | `Hatto Basic (and reversed card)` | 1767225600002 |
| `Basic (optional reversed card)` or `Hatto Basic (optional reversed card)` | `Hatto Basic (optional reversed card)` | 1767225600003 |
| `Basic (type in the answer)` or `Hatto Basic (type in the answer)` | `Hatto Basic (type in the answer)` | 1767225600004 |
| `Cloze` or `Hatto Cloze` | `Hatto Cloze` | 1767225600005 |

Existing `deck.json` files do not change. The names are Hatto's, so a
collection's own stock `Basic` is not touched and the first import does not add
`Basic+` (contract section 16). The ids are 2026-01-01T00:00:00Z in
milliseconds. `src/seed.rs` holds the table.

What stays the same for an existing deck: note guids, fields, tags, the cards
Anki builds (count and template order), the deck name and the media. What
changes on purpose: the notetype's name, id and mtime, and the ids inside it.
`tests/roundtrip.rs` pins this for the example deck.

**Never regenerate the seed.** `seed/make_seed.py` records how it was made and
refuses to run without an override variable. A rebuilt seed keeps the notetype
ids but draws new field and template ids, and rslib compares those too: the
rebuilt seed is a different notetype, and importing exports from both skips every
note as `conflicting` and adds a `Hatto Basic+` copy. `cargo test -p hatto_card`
compares the file's size and SHA-256 with constants in `src/seed.rs`.

Limits:

- **`notetype_legacy` is not fixed.** A notetype the deck defines itself is
  created by `add_notetype_legacy`, which assigns a new id on every export.
  The legacy object's `id`, when present, must be 0. `validate` and `export`
  reject any other value before calling rslib, because `add_notetype` asserts
  the id is 0. A missing `id` still fails in rslib's decoder. Exporting the
  same deck twice and importing both gives `conflicting` for the second
  (contract section 4.4-3 reports that case as BLOCKED). A deck with
  `notetype_legacy` does not load the seed and behaves as before. `Image Occlusion`
  and any other name the table does
  not list are looked up in the temporary collection and are not fixed either.
- **Apkg files from before the seed are not migrated.** They carry a `Basic`
  with a random id. A collection that already imported one and then imports the
  same deck from this version skips its notes as `conflicting` (BLOCKED in the
  contract's report) and gets a `Hatto Basic` notetype. There is no migration
  tool (contract section 16, item 4).
- **The seed does not make a re-import write nothing.** Every export gives the
  notes a new mtime, so an import with `IF_NEWER` rewrites unchanged notes as
  `updated`. "Nothing changes for the same file" comes from the SAME
  classification in contract section 7, not from this tool.
