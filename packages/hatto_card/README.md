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
| `job_id` | UUID for imported notes. A note may override it. |
| `op_id` | UUID for local notes. A note may override it. |
| `notetype` | Stock notetype name. Default `Basic`. |
| `notetype_legacy` | Optional Anki legacy notetype object, sent to `add_notetype_legacy`. |
| `media_dir` | Files added with `add_media_file`. Relative to the deck file. |
| `notes[].source_guid` | Imported note. Guid is `imported_note_guid(job_id, source_guid)`. |
| `notes[].k` | Local note. Guid is `local_note_guid(op_id, k)`. |
| `notes[].fields` | Field strings, one per notetype field. |
| `notes[].tags` | Tag list. |

A note sets `source_guid` or `k`, not both. `source_guid` is not trimmed or
normalized. An empty `source_guid` is `GUID_FORMAT`. The same derived guid
twice in this file is `NOTE_GUID_DUPLICATE`. Duplicates against a collection
or `note_map` are not checked here.

`hatto-card new` writes an example. `examples/with-media/` is that example
plus `media/dot.png`.

## Commands

```sh
hatto-card --json new --output deck.json
hatto-card --json validate --deck deck.json
hatto-card --json export --deck deck.json --output out.apkg
hatto-card --json add-note --deck deck.json --notetype Basic --field front --field back
hatto-card --json add-note --deck deck.json --notetype Basic --field front --field back --op-id UUID --k 0
hatto-card --json add-note --deck deck.json --notetype Basic --field front --field back --tag example --job-id UUID --source-guid TEXT
```

`export` validates, writes the notes into a temporary collection, and exports
that one deck. `--json` prints one JSON object. Exit status is non-zero when
the deck JSON is invalid, a guid check fails, or a media file is missing.

`add-note` appends one note. There is no add-card command; Anki builds the
cards from the note and the notetype. `--notetype` must match the deck's
`notetype` string, or `Basic` when that field is absent. The note does not
store a notetype. Each `--field` is one field string, in notetype order.
`--tag` may be repeated and is omitted from the note when absent. `--output`
writes that path instead of the input file.

With no guid flags, `add-note` makes a UUIDv4 `op_id` and sets `k` to 0.
`k` is the index of the note inside this write, not the index in the file.
The guid is `local_note_guid(op_id, k)`. `--op-id` and `--k` set those
values. `--job-id` and `--source-guid` together use `imported_note_guid`
and cannot be combined with `--op-id` or `--k`. The id is stored on the
new note, so the deck-level `op_id` or `job_id` of the other notes stays
as it was.

The file is written only after the same checks as `validate`. A failure
leaves every deck file unchanged.

Checks kept here are the deck JSON shape, `GUID_FORMAT`, `NOTE_GUID_DUPLICATE`
inside this file, and a missing media path. Media bytes are copied as-is.
