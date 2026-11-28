# hatto-card

Developer CLI that checks a deck file, appends one note, builds a temporary
collection, and writes an apkg. `inspect` reads an existing apkg through
Stage E in a temporary data directory. It does not open a user collection.

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
| `media_dir` | Files added with `add_media_file`. Relative to the deck file. |
| `notes[].source_guid` | Imported note. Guid is `normalize_import_guid(source_guid)`. |
| `notes[].k` | Local note. Guid is `local_note_guid(op_id, k)`. |
| `notes[].fields` | Field strings, one per notetype field. |
| `notes[].tags` | Tag list. |
| `notes[].notetype` | Optional. Overrides the deck `notetype` for this note. Same stock or Hatto names. |
| `notes[].deck_name` | Optional. The deck `deck_name`, or `{deck_name}::...` with no empty segment. |

A note sets `source_guid` or `k`, not both. `source_guid` is not trimmed,
case-folded, or Unicode-normalized. An empty `source_guid` is `GUID_FORMAT`.
The same derived guid twice in this file is `NOTE_GUID_DUPLICATE`.
Duplicates against a collection or `note_map` are not checked here.

CLI `source_guid` mode is an input generator that mimics an external apkg: `normalize_import_guid` is idempotent, so a guid written here is the same guid a later import would assign.

`hatto-card new` writes this shape with a new UUIDv4 `job_id` and `op_id`.
`--deck-name` sets `deck_name` (default `Example`). `--notetype` sets a seed
notetype (stock or Hatto spelling). Without it, the 3-note deck keeps
`Basic`. `--empty` writes `notes: []` and, when `--notetype` is omitted,
`Hatto Basic`. With `--output`, it also writes `media/dot.png` beside the
deck file when that file is missing, so `validate` and `export` can run next.
An existing `dot.png` is left unchanged. `examples/with-media/` is the same
shape with the fixed ids in that file, plus the png `new` copies. Local note
guids are uuid5 values from the fresh `op_id`. The `source_guid` note uses
`normalize_import_guid`, so the fresh `job_id` is stored and does not change
that guid. A deck with no notes is still rejected by `validate` and `export`.

## Commands

```sh
hatto-card --help
hatto-card new --help
hatto-card --json new --output deck.json --deck-name "My deck"
hatto-card --json new --empty --output deck.json --notetype "Hatto Basic"
hatto-card --json validate --deck deck.json
hatto-card --json validate --deck -
hatto-card --json export --deck deck.json --output out.apkg
hatto-card --json export --deck - --output out.apkg
hatto-card --json add-note --deck deck.json --notetype Basic --field front --field back
hatto-card --json add-note --deck deck.json --notetype Basic --field "--foo" --field=--bar --tag "-v"
hatto-card --json add-note --deck deck.json --notetype Basic --field front --field back --deck-name "My deck::Sub"
hatto-card --json add-note --deck deck.json --notetype Basic --field front --field back --op-id UUID --k 0
hatto-card --json add-note --deck deck.json --notetype Basic --field front --field back --tag example --job-id UUID --source-guid TEXT
hatto-card --json add-notes --deck deck.json --input notes.jsonl --op-id UUID --start-k 0
hatto-card inspect deck.apkg
hatto-card --json inspect deck.apkg
```

`-h` and `--help` print help on stdout and exit 0, for the top level and for
each command (`hatto-card new --help`, and the same for `validate`, `export`,
`add-note`, `add-notes`, and `inspect`). A missing or unknown command still
exits 2. `--flag=value` is the same as `--flag value`. A value may start with
`-` or `--`, including the tokens `help`, `-h`, `--help`, and `--json`. A
token is help or the json flag only when it is not the value of a flag.

`export` validates, writes the notes into a temporary collection, and exports
the root deck. rslib's deck-id limit includes child decks (`DeckIdWithChildren`),
so a note on `{deck_name}::Sub` is in the package with the root. `validate`
runs the same gate first: seed notetype, one field per notetype field, cloze
syntax, and media references. It does not write an apkg. `--deck -` reads the
deck JSON from stdin and resolves a relative `media_dir` from the current
directory. `--json` prints one JSON object. Exit status is non-zero when the
deck JSON is invalid, a guid check fails, a media file is missing, a note's
field count does not match the notetype, a Cloze note's first field has no
`{{c1::...}}` deletion, a note deck is outside the root, or the deck sets
`notetype_legacy`.

`add-note` appends one note. There is no add-card command; Anki builds the
cards from the note and the notetype. `--notetype` must name the same notetype as the deck's
`notetype` string, or `Basic` when that field is absent (`Basic` and
`Hatto Basic` are the same notetype). The note does not
store a notetype. `--deck-name` stores that deck on the note when set. It
must be the deck's `deck_name` or `{deck_name}::...` with no empty segment.
Each `--field` is one field string, in notetype order.
`--tag` may be repeated and is omitted from the note when absent. `--output`
writes that path instead of the input file.

`add-notes` appends every object from `--input`. The file is a JSON array or
JSONL (one object per line, blank lines skipped). `--input -` reads stdin.
Each object has `fields` and may set `tags`, `notetype`, `deck_name`, `op_id`
and `k`, or `job_id` and `source_guid`. Any other key is rejected. An object
that sets none of `op_id`, `k`, and `source_guid` uses the command's `--op-id`
(one new UUIDv4 when the flag is omitted) and `k` starting at `--start-k`
(default 0), increasing by 1 for each such object. An object with `k` and no
`op_id` uses `--op-id` and is rejected when that flag is omitted. The response
includes the `op_id` that those notes used. `--notetype` is the default for
objects that omit it, and it must be a seed notetype. A notetype that differs
from the deck is stored on that note. Failures for notes added by this call
are located at `input[N]`, not at the index in the whole deck.

With no guid flags, `add-note` makes a UUIDv4 `op_id` and sets `k` to 0.
`k` is the index of the note inside this write, not the index in the file.
The guid is `local_note_guid(op_id, k)`. `--op-id` and `--k` set those
values. `--source-guid` (with `--job-id`) uses `normalize_import_guid`.
`--job-id` is stored on the new note and ignored for that guid. Those
flags cannot be combined with `--op-id` or `--k`. The id is stored on the
new note, so the deck-level `op_id` or `job_id` of the other notes stays
as it was.

The file is written only after the same checks as `validate` and `export`.
A failure leaves every deck file unchanged. All of these commands reject a
deck that sets `notetype_legacy` before those checks. The error code is
`NOTETYPE_LEGACY`. Any value is rejected, including `null` and an object
whose `id` is 0.

Checks kept here are the deck JSON shape, the codes below, and a missing
media directory. Local `<img src>` and `[sound:...]` names must be files in
`media_dir` (`http://`, `https://`, and `data:` are skipped). A Cloze first
field needs `{{cN::...}}` with `N` ≥ 1. A note `deck_name` must be the root
or `{root}::...` with no empty segment. The deck `notetype` and every note
`notetype` must be a seed name from the table below. Media bytes are copied
as-is.

| Code | When |
| --- | --- |
| `GUID_FORMAT` | A guid string is not a lowercase hyphenated UUID version 4 or 5, or `source_guid` is empty. |
| `NOTE_GUID_DUPLICATE` | The same derived guid appears twice in this file. |
| `NOTETYPE_LEGACY` | The deck sets `notetype_legacy`. |
| `NOTETYPE_UNKNOWN` | A deck or note notetype is not a seed name. The message lists the allowed names. |
| `FIELD_COUNT` | A note's field count is not the notetype's field count. |
| `CLOZE_MISSING` | A Cloze note's first field has no `{{cN::...}}` deletion. |
| `MEDIA_MISSING` | A local media reference is not a file in `media_dir`. |
| `DECK_NAME_INVALID` | A note deck name is empty, has an empty segment, or is outside the root. |

## Inspect

`hatto-card inspect FILE` prints the notes Stage E read from one `.apkg`.
The file is only read. inspect creates a temporary data directory, copies
the package to `<temp_data_dir>/import/raw/...`, and calls
`rslib_bridge::api::import_stage_e`. It does not call `resident_lookup` or
`import_stage_finish`, and it does not open a user collection.

`inspect` outputs the same Stage E facts used by import.

Notes come from `PendingImport::file_notes()` and stay in that note-id
order. Each note includes normalized `guid`, `content_hash`, and
`notetype_id`. `content_hash` is the lowercase hex of the 32-byte hash.
`mod` is Anki's note mod. The default output is pretty-printed JSON.
`--json` prints the same object on one line.

Size limits are the v0 desktop product ceilings, the same numbers the
desktop importer uses:

| Limit | Value |
| --- | --- |
| Compressed package (`max_bytes`) | 512 MiB (`512 * 1024 * 1024` bytes) |
| Uncompressed zip entry sum (`max_uncompressed_bytes`) | 2 GiB (`2 * 1024 * 1024 * 1024` bytes) |

A missing path, a file that is not an apkg, or a package over a limit
exits non-zero. The temporary data directory is removed on success and
on failure. `PendingImport` is dropped before that directory is removed.

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

- **`notetype_legacy` is rejected.** The CLI only exports the seed notetypes
  in the table above. A deck JSON key `notetype_legacy` is `NOTETYPE_LEGACY`
  from `validate`, `export`, and `add-note`. It is not sent to rslib.
  `Image Occlusion` and any other name the table does not list are
  `NOTETYPE_UNKNOWN` on the deck `notetype` and on a note `notetype`. They
  are not looked up in the temporary collection.
- **Apkg files from before the seed are not migrated.** They carry a `Basic`
  with a random id. A collection that already imported one and then imports the
  same deck from this version skips its notes as `conflicting` (BLOCKED in the
  contract's report) and gets a `Hatto Basic` notetype. There is no migration
  tool (contract section 16, item 4).
- **The seed does not make a re-import write nothing.** Every export gives the
  notes a new mtime, so an import with `IF_NEWER` rewrites unchanged notes as
  `updated`. "Nothing changes for the same file" comes from the SAME
  classification in contract section 7, not from this tool.
