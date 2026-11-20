# hatto_card_contract

Pure note-guid derivation and guid format checks. Desktop and mobile call
this crate through `rslib_bridge`. The `hatto-card` CLI calls it directly.

## Boundary

This crate does pure computation and format checks only. It has no I/O, no
global state, and no rslib or protobuf.

Dart `hatto_store` issues `op_id`, a CSPRNG UUIDv4, once per write. It owns
intent, `note_map` duplicate checks, and mapping storage. This crate does
not issue `op_id` and does not know `note_map`.

Deck guids are not derived here. Something else issues a UUIDv4 after rslib
creates the deck.

Appendix C of the desktop v0 mapping contract limits invariant I1 to notes
with at least one card. This crate does not see cards. `NOTE_GUID_DUPLICATE`
is only a duplicate inside the one deck file passed to `validate_deck_file`.

## Guid derivation

`imported_note_guid(job_id: Uuid, source_guid: &str) -> Result<Uuid, EmptySourceGuid>`

`uuid5` with namespace `job_id` and name the raw UTF-8 bytes of
`source_guid`. There is no trim, no case fold, and no Unicode normalization.
An empty `source_guid` is rejected as `EmptySourceGuid`. That error has no
string code. Whitespace is not empty.

`local_note_guid(op_id: Uuid, k: u32) -> Uuid`

`uuid5` with namespace `op_id` and name `"note:"` plus `k` in decimal, with
no padding. `0` is `"note:0"`.

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
string appears more than once. Output is sorted by `(code string, location)`.
Equal keys keep input order.

## Error codes

`CardErrorCode` is `#[non_exhaustive]`. The string ids are `GUID_FORMAT` and
`NOTE_GUID_DUPLICATE`. New codes may be added. Existing ids are never changed
or removed.

## Golden fixture

`fixtures/note_guid_golden.json` is the shared note-guid file. The Rust tests
in this crate, the Dart tests through the flutter_rust_bridge re-export, and
the mobile smoke all read it. A mismatch fails CI.
