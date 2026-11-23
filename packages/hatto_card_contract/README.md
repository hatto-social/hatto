# hatto_card_contract

Pure note-guid derivation, import classification, and guid format checks.

`rslib_bridge` re-exports `imported_note_guid`, `local_note_guid`, and
`is_guid_format` over flutter_rust_bridge. `imported_note_guid` takes two
`String`s and returns `Result<String, String>`. `local_note_guid` takes a
`String` and a `u32` and returns `Result<String, String>`. `is_guid_format`
takes a `String` and returns `bool`. `validate_deck_file` is not re-exported.

`assign_import_guids`, `note_content_hash`, `classify`, and `summarize_plan`
have thin wrappers in `rslib_bridge`'s Rust API, with the same `frb(sync)`
marker the three functions above use. The generated Dart and Rust bindings
were not regenerated with them, so those four are not in the Dart API yet.
Regenerating would rewrite the large generated bridge and change the wire
content hash the app loads. The wrappers do no I/O and do not call rslib.

`apps/desktop` and `packages/hatto_store` do not call the three re-exported
functions, and neither does `apps/mobile/lib`. The device smoke
`apps/mobile/integration_test/smoke_flow.dart` calls `importedNoteGuid`.
The hatto-card CLI calls this crate directly. No other package calls
`validate_deck_file`.

## Status

Not wired yet: `hatto_store` does not mint a note `op_id`; `AddNote` is
still `Pending` and `validators.rs` does not call `is_guid_format`;
`validate_deck_file` has no bridge export. The I1 import helpers are in this
crate. Nothing in the apps calls them yet.

## Boundary

This crate does pure computation and format checks only. It has no I/O, no
global state, and no rslib or protobuf.

By contract, Dart `hatto_store` issues an `op_id`, a CSPRNG UUIDv4, for each
write. It owns intent, `note_map` duplicate checks, and mapping storage.
That issuance is not implemented. `NotesService.add_note` is `Pending`
(`policy/mod.rs`). The hatto-card CLI mints a UUIDv4 when a local note omits
`op_id` (`new_op_id`). Intent rows, `note_map`, and the mapping write are
already in `hatto_store`. This crate does not issue `op_id` and does not
know `note_map`. The AddNote validator does not call `is_guid_format`.

Deck guids are not derived here. Something else issues a UUIDv4 after rslib
creates the deck.

Invariant I1 covers only notes that have at least one card. An empty search
becomes `deck:*`, which joins through cards, so cardless notes are not
enumerated in v0. v1 import and sync will enumerate with `note:*` and handle
`skippedNotes` (`packages/hatto_store/lib/src/reconcile.dart`). This crate
does not see cards. `NOTE_GUID_DUPLICATE` is only a duplicate inside the one
deck file passed to `validate_deck_file`.

## Guid derivation

`imported_note_guid(job_id: Uuid, source_guid: &str) -> Result<Uuid, EmptySourceGuid>`

`uuid5` with namespace `job_id` and name the raw UTF-8 bytes of
`source_guid`. There is no trim, no case fold, and no Unicode normalization.
An empty `source_guid` is rejected as `EmptySourceGuid`. That error has no
string code. Whitespace is not empty.

Import calls `imported_note_guid` only with `job_id = IMPORT_NS`. A per-job
namespace is not used for import. The function itself still accepts the
`job_id` the caller passes. `derive` stays private. There is no second hash
of a derived guid.

`local_note_guid(op_id: Uuid, k: u32) -> Uuid`

`uuid5` with namespace `op_id` and name `"note:"` plus `k` in decimal, with
no padding. `k` counts from 0 inside one write. `0` is the name `"note:0"`.

## Import namespace

`IMPORT_NS` is the constant `ec425e06-0eeb-5cbc-b4c8-3818366d46e9`.

That is `uuid5(NAMESPACE_URL, "urn:hatto:import-note:v1")`. The value is
permanent. Tests assert both the literal and the derivation.

`normalize_import_guid(raw) -> Result<String, EmptySourceGuid>` is `f`.

When `is_guid_format(raw)` is true, the result is `raw`. Otherwise it is
`imported_note_guid(IMPORT_NS, raw)` in canonical text. An empty `raw` is
`EmptySourceGuid`. A uuid5 result passes `is_guid_format`, so `f(f(x))` is
`f(x)` whenever `f(x)` is `Ok`. There is no trim.

The six `f` rows in the golden file are:

| raw | result |
| --- | --- |
| `oxr*zK@INR` | `c15b93d8-6483-5c3c-b94f-1061d53fda92` |
| `b91/guid#2` | `51aed07c-7668-5726-9830-b3eab77dcb92` |
| `plainGuid3` | `e67308dc-2365-5fc4-900e-4fc19f04c9ab` |
| `3f2b8a64-1c0e-4d5a-9b7e-0a1b2c3d4e5f` | the same text (lowercase UUIDv4, kept) |
| `3F2B8A64-1C0E-4D5A-9B7E-0A1B2C3D4E5F` | `4b08d171-4bd5-5f1f-8e85-1315a11b82e0` (uppercase is not a guid) |
| `a` followed by two spaces | `490ca485-3c6e-5cd4-82ab-174a4023134b` (not trimmed) |

The first row is an Anki default base91 guid.

## File guid assignment

`assign_import_guids(notes: &[ImportSourceNote]) -> Vec<AssignedImportGuid>`

`ImportSourceNote` is `{ source_note_id: i64, raw_guid: String }`.
`AssignedImportGuid` is `{ source_note_id, guid, dup_index, reassigned }`.
`source_note_id` is the original note id. Its decimal form is Rust's
default integer format.

Non-empty raws are grouped by `f(raw)`, not by the raw string. Two raws
that normalize to the same guid are one group, including a raw string and
the canonical text of its own `f` result. Inside a group, notes are ordered
by `(source_note_id, raw_guid)` as UTF-8 bytes.

Pass 1 gives the 0th note of each group `f(raw)` and `dup_index` 0.
`reassigned` is false. Those guids are not moved later.

Pass 2 visits empty raws and the notes with group index `k >= 1`, in
`(source_note_id, raw_guid, k)` order. An empty raw has candidate name
`"\x1fnid:"` plus the decimal note id and `dup_index` 0. A later note has
candidate name `that note's own raw + "\x1f" + decimal k` and `dup_index` k.
The candidate guid is `uuid5(IMPORT_NS, candidate_name)`. If that guid was
already taken by pass 1 or by an earlier pass-2 note, the note uses the
first free `uuid5(IMPORT_NS, candidate_name + "\x1f#" + decimal j)` for
`j = 1, 2, …`, and `reassigned` is true. Otherwise `reassigned` is false and
the candidate guid is kept.

Every input note is returned, and the guids in one result are distinct.
`import_dup_count` counts a row when `dup_index >= 1` or `reassigned` is
true. A row that is both is counted once. The vec is sorted by
`(source_note_id, dup_index, guid)`, so shuffling the input does not change
it. Calling the function twice on the same slice returns the same vec. A
file whose candidates do not collide gets the same guids and `dup_index`
values as pass 1 plus the unbumped candidates.

## Content hash

`note_content_hash(fields, tags) -> [u8; 32]`

Each field loses a media-collision suffix only when `-[0-9a-f]{40}` is
immediately followed by `\.[A-Za-z0-9]+`. Rust's `regex` crate has no
lookahead, so the pattern is `-[0-9a-f]{40}(\.[A-Za-z0-9]+)` replaced by
`$1`. A run that is not 40 lowercase hex digits, uppercase hex, and a hash
with no extension are left in the field.

The hashed bytes are the normalized fields joined by `0x1f`, then `0x1e`,
then the tags joined by one space. Tags are deduplicated and sorted by
UTF-8 bytes. There is no case fold, no trim, and no Unicode normalization.
Media bytes are not an input.

## Classification

`classify(file: &NoteFacts, resident: Option<&NoteFacts>) -> Class`

`NoteFacts` is `{ guid, notetype_id, mod, content_hash }`. `guid` is the
normalized guid. `mod` is stored as `r#mod` because `mod` is a Rust keyword.
`notetype_id` and `mod` are `i64`. `content_hash` is `[u8; 32]`. `classify`
does not read `guid`. The caller pairs a file note with its resident note.

The order is fixed:

1. No resident note: `New`.
2. Different `notetype_id`: `Blocked`, even when the content hashes match.
3. Equal content hashes: `Same`.
4. `file.mod > resident.mod`: `Changed`.
5. Anything else: `LocalNewer`. Equal `mod` with a different content hash is
   `LocalNewer`.

`Class::as_str` is `NEW`, `SAME`, `CHANGED`, `LOCAL_NEWER`, or `BLOCKED`.

`summarize_plan(classes: &[Class], dup: u32) -> Plan`

`Plan` is `{ new, same, changed, local_newer, blocked, dup, no_resident_call }`.
`dup` is the caller's duplicate count, usually `import_dup_count`.
`no_resident_call` is true when `new == 0` and `changed == 0`.

## `NoteGuid` and format

`NoteGuid` is a `String` wrapper. `from_uuid` stores `Uuid::as_hyphenated`,
which is lowercase, hyphenated, and 36 characters.

`is_guid_format` accepts that canonical text when the version nibble is 4 or
5 and the variant is RFC 4122. Uppercase hex and strings without hyphens are
rejected.

## Deck file check

`validate_deck_file(notes: &[DeckNote]) -> Vec<CardError>`

`DeckNote` is `{ guid, location }`. `location` is the caller's string, for
example `notes[1].guid`. `CardError` is `{ code, location }`.

The check looks at that slice only. It reports `GUID_FORMAT` when
`is_guid_format` rejects a guid, and `NOTE_GUID_DUPLICATE` when the same guid
string appears more than once. A repeated guid is reported at every location
where it appears. The same note can carry both `GUID_FORMAT` and
`NOTE_GUID_DUPLICATE`.

Output is sorted by the code's string, then by `location` as a string, so
`notes[10]` comes before `notes[2]`. Equal keys keep input order.

## Error codes

`CardErrorCode` is `#[non_exhaustive]`. The string ids are `GUID_FORMAT` and
`NOTE_GUID_DUPLICATE`. New codes may be added. Existing ids are never changed
or removed.

## Golden fixture

`fixtures/note_guid_golden.json` is the shared file. Rust tests in this
crate, the Dart test
`packages/rslib_bridge/test/note_guid_golden_test.dart`,
`tools/arm64-smoke/check_note_guid_golden.py`, and
`apps/mobile/test/arm64_smoke_codec_test.dart` read it. A mismatch fails CI.

`imported` and `local` are checked by all four readers. `import_f` is the
six rows in the table above. Rust, the Python script, and the bridge Dart
test check it. The Dart test uses the already exported `isGuidFormat` and
`importedNoteGuid` with `IMPORT_NS`. The mobile test does not read `import_f`.

`assign_import_guids`, `note_content_hash`, `classify`, and `plans` are
checked by the Rust tests and the Python script. The Python script
recomputes with `uuid`, `hashlib`, and `re`. The generated Dart API does not
export those functions yet, so the Dart test does not call them.
