# hatto_card_contract

Pure note-guid derivation and guid format checks.

`rslib_bridge` re-exports three functions over flutter_rust_bridge.
`imported_note_guid` (`api.rs` line 240) takes two `String`s and returns
`Result<String, String>`. `local_note_guid` (line 252) takes a `String` and
a `u32` and returns `Result<String, String>`. `is_guid_format` (line 262)
takes a `String` and returns `bool`. `validate_deck_file` is not
re-exported.

`apps/desktop` and `packages/hatto_store` do not call those three
functions, and neither does `apps/mobile/lib`. The device smoke
`apps/mobile/integration_test/smoke_flow.dart` calls `importedNoteGuid`.
The hatto-card CLI calls this crate directly. No other package calls
`validate_deck_file`.

## Status

Not wired yet: `hatto_store` does not mint a note `op_id`; `AddNote` is
still `Pending` and `validators.rs` does not call `is_guid_format`;
`validate_deck_file` has no bridge export.

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

`local_note_guid(op_id: Uuid, k: u32) -> Uuid`

`uuid5` with namespace `op_id` and name `"note:"` plus `k` in decimal, with
no padding. `k` counts from 0 inside one write. `0` is the name `"note:0"`.

`derive` stays private. There is no second hash and no constant namespace.

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

`fixtures/note_guid_golden.json` is the shared note-guid file. It is read by
the Rust tests in this crate, the Dart tests in
`packages/rslib_bridge/test/note_guid_golden_test.dart` (through the bridge
re-export), `tools/arm64-smoke/check_note_guid_golden.py`, and
`apps/mobile/test/arm64_smoke_codec_test.dart`. That mobile test checks the
file with the Dart `uuid5` in `smoke_support.dart` and does not call the
bridge. A mismatch fails CI.
