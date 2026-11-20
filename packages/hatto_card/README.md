# hatto-card

Developer CLI that only generates data. It checks a deck file, builds a
temporary collection, and writes an apkg. It does not import a package and
it does not open a user collection.

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
```

`export` validates, writes the notes into a temporary collection, and exports
that one deck. `--json` prints one JSON object. Exit status is non-zero when
the deck JSON is invalid, a guid check fails, or a media file is missing.

Checks kept here are the deck JSON shape, `GUID_FORMAT`, `NOTE_GUID_DUPLICATE`
inside this file, and a missing media path. Media bytes are copied as-is.
