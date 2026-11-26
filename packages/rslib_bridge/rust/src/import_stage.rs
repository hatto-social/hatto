// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Host side of the two-step import. E stays inside `hatto_import`.
//! The resident handle is used only by [`resident_lookup`], through `command`.

use std::collections::BTreeSet;
use std::path::Path;

use anki_proto::backend::backend_error::Kind;
use prost::Message;

use crate::api::{
    call, command, service_method_index, AnkiBackend, ImportFolderScan, NoteFacts, PendingImport,
    Plan, PreparedImport, ResidentMatch,
};

pub(crate) fn import_stage_e(
    data_dir: String,
    source_path: String,
    max_bytes: u64,
) -> Result<PendingImport, String> {
    let staged = hatto_import::stage_import(
        Path::new(&data_dir),
        Path::new(&source_path),
        hatto_import::ImportLimits { max_bytes },
    )
    .map_err(|err| err.to_string())?;
    let notes = staged.notes.iter().map(bridge_note).collect();
    Ok(PendingImport::new(staged.pending, notes, staged.deck_names))
}

pub(crate) fn resident_lookup(
    backend: &AnkiBackend,
    note_ids: Vec<i64>,
    deck_names: Vec<String>,
) -> Result<ResidentMatch, String> {
    let mut notes = Vec::new();
    let mut seen_ids = BTreeSet::new();
    for id in note_ids {
        if !seen_ids.insert(id) {
            continue;
        }
        let bytes = call(
            backend,
            "BackendNotesService",
            "get_note",
            &anki_proto::notes::NoteId { nid: id },
        )?;
        let note = anki_proto::notes::Note::decode(bytes.as_slice())
            .map_err(|err| format!("decode note: {err}"))?;
        let flds = note.fields.join("\u{1f}");
        let tags = note.tags.join(" ");
        let facts = hatto_import::facts_from_stored_note(
            &note.guid,
            note.notetype_id,
            i64::from(note.mtime_secs),
            &flds,
            &tags,
        );
        notes.push(bridge_note(&facts));
    }
    let mut found_deck_names = Vec::new();
    let mut seen_names = BTreeSet::new();
    for name in deck_names {
        if !seen_names.insert(name.clone()) {
            continue;
        }
        if deck_id_by_name(backend, &name)?.is_some() {
            found_deck_names.push(name);
        }
    }
    Ok(ResidentMatch {
        notes,
        found_deck_names,
    })
}

pub(crate) fn import_stage_finish(
    pending: PendingImport,
    resident_facts: Vec<NoteFacts>,
    found_deck_names: Vec<String>,
) -> Result<PreparedImport, String> {
    let inner = pending.take()?;
    let mut notes = Vec::new();
    for facts in resident_facts {
        notes.push(contract_facts(facts)?);
    }
    let mut lookup = hatto_import::PrefetchedLookup::new(notes, found_deck_names)
        .map_err(|err| err.to_string())?;
    let prepared =
        hatto_import::finish_import(inner, &mut lookup).map_err(|err| err.to_string())?;
    bridge_prepared(prepared)
}

pub(crate) fn scan_import_folders(
    data_dir: String,
    prepared_batch_ids: Vec<String>,
) -> Result<ImportFolderScan, String> {
    let scan = hatto_import::scan_prepared_batches(Path::new(&data_dir), &prepared_batch_ids)
        .map_err(|err| err.to_string())?;
    Ok(ImportFolderScan {
        removed: scan.removed.iter().map(ToString::to_string).collect(),
        kept_prepared: scan.kept_prepared.iter().map(ToString::to_string).collect(),
        ignored: scan.ignored,
    })
}

fn deck_id_by_name(backend: &AnkiBackend, name: &str) -> Result<Option<i64>, String> {
    let Some(index) = service_method_index(
        "BackendDecksService".to_string(),
        "get_deck_id_by_name".to_string(),
    ) else {
        return Err("no index for BackendDecksService.get_deck_id_by_name".into());
    };
    let input = anki_proto::generic::String {
        val: name.to_string(),
    }
    .encode_to_vec();
    let response = command(backend, index.service, index.method, input);
    if response.success {
        let id = anki_proto::decks::DeckId::decode(response.payload.as_slice())
            .map_err(|err| format!("deck id: {err}"))?;
        return Ok((id.did != 0).then_some(id.did));
    }
    let err = anki_proto::backend::BackendError::decode(response.payload.as_slice())
        .map_err(|_| "undecodable backend error".to_string())?;
    if err.kind == Kind::NotFoundError as i32 {
        return Ok(None);
    }
    Err(format!("{} (kind={})", err.message, err.kind))
}

fn bridge_prepared(prepared: hatto_import::PreparedImport) -> Result<PreparedImport, String> {
    let staged_path = prepared
        .staged_path
        .to_str()
        .ok_or_else(|| format!("{} is not utf-8", prepared.staged_path.display()))?
        .to_string();
    Ok(PreparedImport {
        import_batch_id: prepared.import_batch_id.to_string(),
        plan: bridge_plan(prepared.plan),
        staged_path,
        staged_sha256: prepared.staged_sha256,
        first_import: prepared.first_import,
        cardless_notes: prepared.cardless_notes,
        new_guids: prepared.new_guids,
        changed: prepared
            .changed
            .into_iter()
            .map(|(guid, content_hash)| crate::api::ChangedNote { guid, content_hash })
            .collect(),
        deck_names: prepared.deck_names,
        pre_note_count: prepared.pre_note_count,
    })
}

fn bridge_plan(plan: hatto_card_contract::Plan) -> Plan {
    Plan {
        new: plan.new,
        same: plan.same,
        changed: plan.changed,
        local_newer: plan.local_newer,
        blocked: plan.blocked,
        dup: plan.dup,
        no_resident_call: plan.no_resident_call,
    }
}

fn bridge_note(facts: &hatto_card_contract::NoteFacts) -> NoteFacts {
    NoteFacts {
        guid: facts.guid.clone(),
        notetype_id: facts.notetype_id,
        r#mod: facts.r#mod,
        content_hash: facts.content_hash.to_vec(),
    }
}

fn contract_facts(facts: NoteFacts) -> Result<hatto_card_contract::NoteFacts, String> {
    let len = facts.content_hash.len();
    let content_hash: [u8; 32] = facts
        .content_hash
        .try_into()
        .map_err(|_bytes: Vec<u8>| format!("content_hash must be 32 bytes, got {len}"))?;
    Ok(hatto_card_contract::NoteFacts {
        guid: facts.guid,
        notetype_id: facts.notetype_id,
        r#mod: facts.r#mod,
        content_hash,
    })
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use anki_proto::generic;
    use prost::Message;

    use super::{import_stage_e, import_stage_finish, resident_lookup, scan_import_folders};
    use crate::api::{
        call, open_backend, open_desktop_backend, prepare_runtime, AnkiBackend, ResidentMatch,
    };

    const GUID_1: &str = "00000000-0000-4000-8000-000000000001";
    const MOD: i64 = 1_700_000_000;
    const MAX_BYTES: u64 = 32 * 1024 * 1024;

    fn guid(n: u32) -> String {
        format!("00000000-0000-4000-8000-{n:012x}")
    }

    fn init_bytes() -> Vec<u8> {
        anki_proto::backend::BackendInit {
            preferred_langs: vec!["en".into()],
            locale_folder_path: String::new(),
            server: false,
        }
        .encode_to_vec()
    }

    fn open_unrestricted(root: &Path) -> AnkiBackend {
        std::fs::create_dir_all(root.join("collection.media")).unwrap();
        let backend = open_backend(init_bytes()).unwrap();
        open_at(&backend, root);
        backend
    }

    fn open_desktop(data_dir: &Path) -> AnkiBackend {
        std::fs::create_dir_all(data_dir.join("collection.media")).unwrap();
        std::fs::create_dir_all(data_dir.join("tmp")).unwrap();
        let backend =
            open_desktop_backend(init_bytes(), data_dir.to_string_lossy().into_owned()).unwrap();
        open_at(&backend, data_dir);
        backend
    }

    fn open_at(backend: &AnkiBackend, root: &Path) {
        let open = anki_proto::collection::OpenCollectionRequest {
            collection_path: root.join("collection.anki2").to_string_lossy().into_owned(),
            media_folder_path: root.join("collection.media").to_string_lossy().into_owned(),
            media_db_path: root
                .join("collection.media.db")
                .to_string_lossy()
                .into_owned(),
        };
        call(
            backend,
            "BackendCollectionService",
            "open_collection",
            &open,
        )
        .unwrap();
    }

    fn close(backend: &AnkiBackend) {
        let close = anki_proto::collection::CloseCollectionRequest {
            downgrade_to_schema11: false,
        };
        call(
            backend,
            "BackendCollectionService",
            "close_collection",
            &close,
        )
        .unwrap();
    }

    fn add_deck(backend: &AnkiBackend, name: &str) -> i64 {
        let mut deck: anki_proto::decks::Deck = decode(call(
            backend,
            "BackendDecksService",
            "new_deck",
            &generic::Empty {},
        ));
        deck.name = name.into();
        let added: anki_proto::collection::OpChangesWithId =
            decode(call(backend, "BackendDecksService", "add_deck", &deck));
        added.id
    }

    fn notetype_id(backend: &AnkiBackend) -> i64 {
        let notetype: anki_proto::notetypes::NotetypeId = decode(call(
            backend,
            "BackendNotetypesService",
            "get_notetype_id_by_name",
            &generic::String {
                val: "Basic".into(),
            },
        ));
        notetype.ntid
    }

    fn add_note(
        backend: &AnkiBackend,
        deck: i64,
        fields: &[&str],
        guid: &str,
        mod_secs: i64,
    ) -> i64 {
        let mut note: anki_proto::notes::Note = decode(call(
            backend,
            "BackendNotesService",
            "new_note",
            &anki_proto::notetypes::NotetypeId {
                ntid: notetype_id(backend),
            },
        ));
        note.guid = guid.into();
        note.fields = fields.iter().map(|field| (*field).to_string()).collect();
        let added: anki_proto::notes::AddNoteResponse = decode(call(
            backend,
            "BackendNotesService",
            "add_note",
            &anki_proto::notes::AddNoteRequest {
                note: Some(note),
                deck_id: deck,
            },
        ));
        set_mod(backend, added.note_id, mod_secs);
        added.note_id
    }

    fn set_fields(backend: &AnkiBackend, note_id: i64, fields: &[&str], mod_secs: i64) {
        let mut note: anki_proto::notes::Note = decode(call(
            backend,
            "BackendNotesService",
            "get_note",
            &anki_proto::notes::NoteId { nid: note_id },
        ));
        note.fields = fields.iter().map(|field| (*field).to_string()).collect();
        let _changes: anki_proto::collection::OpChanges = decode(call(
            backend,
            "BackendNotesService",
            "update_notes",
            &anki_proto::notes::UpdateNotesRequest {
                notes: vec![note],
                skip_undo_entry: true,
            },
        ));
        set_mod(backend, note_id, mod_secs);
    }

    fn set_mod(backend: &AnkiBackend, note_id: i64, mod_secs: i64) {
        exec(
            backend,
            "UPDATE notes SET \"mod\" = ? WHERE id = ?",
            vec![serde_json::json!(mod_secs), serde_json::json!(note_id)],
        );
    }

    fn note_id_by_guid(backend: &AnkiBackend, guid: &str) -> i64 {
        let body = serde_json::json!({
            "kind": "query",
            "sql": "SELECT id FROM notes WHERE guid = ? ORDER BY id",
            "args": [guid],
            "first_row_only": false,
        });
        let response: generic::Json = decode(call(
            backend,
            "BackendAnkidroidService",
            "run_db_command",
            &generic::Json {
                json: serde_json::to_vec(&body).unwrap(),
            },
        ));
        let value: serde_json::Value = serde_json::from_slice(&response.json).unwrap();
        value[0][0].as_i64().unwrap()
    }

    fn exec(backend: &AnkiBackend, sql: &str, args: Vec<serde_json::Value>) {
        let body = serde_json::json!({
            "kind": "executemany",
            "sql": sql,
            "args": [args],
        });
        let _empty: generic::Json = decode(call(
            backend,
            "BackendAnkidroidService",
            "run_db_command",
            &generic::Json {
                json: serde_json::to_vec(&body).unwrap(),
            },
        ));
    }

    fn export_apkg(backend: &AnkiBackend, path: &Path) {
        let request = anki_proto::import_export::ExportAnkiPackageRequest {
            out_path: path.to_string_lossy().into_owned(),
            options: Some(anki_proto::import_export::ExportAnkiPackageOptions {
                with_scheduling: true,
                with_deck_configs: true,
                with_media: true,
                legacy: false,
            }),
            limit: Some(anki_proto::import_export::ExportLimit {
                limit: Some(
                    anki_proto::import_export::export_limit::Limit::WholeCollection(
                        generic::Empty {},
                    ),
                ),
            }),
        };
        let _count: generic::UInt32 = decode(call(
            backend,
            "BackendImportExportService",
            "export_anki_package",
            &request,
        ));
    }

    fn import_staged(backend: &AnkiBackend, path: &str, with_deck_configs: bool) {
        let request = anki_proto::import_export::ImportAnkiPackageRequest {
            package_path: path.to_string(),
            options: Some(anki_proto::import_export::ImportAnkiPackageOptions {
                merge_notetypes: false,
                update_notes: anki_proto::import_export::ImportAnkiPackageUpdateCondition::IfNewer
                    as i32,
                update_notetypes: anki_proto::import_export::ImportAnkiPackageUpdateCondition::Never
                    as i32,
                with_scheduling: true,
                with_deck_configs,
            }),
        };
        let _response: anki_proto::import_export::ImportResponse = decode(call(
            backend,
            "BackendImportExportService",
            "import_anki_package",
            &request,
        ));
    }

    fn decode<T: Message + Default>(bytes: Result<Vec<u8>, String>) -> T {
        let bytes = bytes.unwrap();
        T::decode(bytes.as_slice()).unwrap()
    }

    fn hash_of(fields: &[&str]) -> Vec<u8> {
        crate::api::note_content_hash(
            fields.iter().map(|field| (*field).to_string()).collect(),
            Vec::new(),
        )
    }

    fn fresh() -> (tempfile::TempDir, std::path::PathBuf) {
        let tmp = tempfile::TempDir::new_in("/tmp").unwrap();
        let root = tmp.path().canonicalize().unwrap();
        let data = root.join("data");
        std::fs::create_dir_all(data.join("tmp")).unwrap();
        prepare_runtime(data.join("tmp").to_string_lossy().into_owned());
        (tmp, data)
    }

    fn deck_id(backend: &AnkiBackend, name: &str) -> i64 {
        let id: anki_proto::decks::DeckId = decode(call(
            backend,
            "BackendDecksService",
            "get_deck_id_by_name",
            &generic::String { val: name.into() },
        ));
        id.did
    }

    #[test]
    fn resident_lookup_uses_get_note_and_deck_name_on_the_desktop_profile() {
        let _lock = crate::lock_bridge_runtime();
        let (_tmp, data) = fresh();
        let backend = open_desktop(&data);
        let found = resident_lookup(
            &backend,
            Vec::new(),
            vec!["Default".into(), "Missing".into(), "Default".into()],
        )
        .unwrap();
        assert!(found.notes.is_empty());
        assert_eq!(found.found_deck_names, vec!["Default".to_string()]);
        let missing = resident_lookup(&backend, vec![999], Vec::new());
        assert!(missing.is_err(), "{missing:?}");
        close(&backend);
    }

    #[test]
    fn t1_second_stage_is_same_and_does_not_need_a_resident_write() {
        let _lock = crate::lock_bridge_runtime();
        let (tmp, data) = fresh();
        let root = data.parent().unwrap();
        let source_dir = root.join("source");
        std::fs::create_dir_all(&source_dir).unwrap();
        let file = root.join("deck.apkg");
        {
            let source = open_unrestricted(&source_dir);
            let deck = add_deck(&source, "Spanish");
            add_note(&source, deck, &["hola", "hello"], GUID_1, MOD);
            export_apkg(&source, &file);
            close(&source);
        }
        let resident = open_unrestricted(&data);
        let data_dir = data.to_string_lossy().into_owned();
        let file_text = file.to_string_lossy().into_owned();

        let pending = import_stage_e(data_dir.clone(), file_text.clone(), MAX_BYTES).unwrap();
        assert_eq!(pending.file_notes().len(), 1);
        assert_eq!(pending.file_notes()[0].guid, GUID_1);
        assert!(pending.deck_names().iter().any(|name| name == "Spanish"));
        let looked = resident_lookup(&resident, Vec::new(), pending.deck_names()).unwrap();
        assert!(looked.notes.is_empty());
        assert!(looked.found_deck_names.is_empty());
        let first = import_stage_finish(pending, looked.notes.clone(), looked.found_deck_names)
        .unwrap();
        assert_eq!(first.new_guids, vec![GUID_1.to_string()]);
        assert!(first.changed.is_empty());
        assert_eq!(first.pre_note_count, 1);
        assert!(first.first_import);
        assert!(!first.plan.no_resident_call);
        assert!(Path::new(&first.staged_path).is_file());
        let still = resident_lookup(&resident, Vec::new(), vec!["Spanish".into()]).unwrap();
        assert!(still.notes.is_empty());

        import_staged(&resident, &first.staged_path, first.first_import);
        let id = note_id_by_guid(&resident, GUID_1);
        let again = import_stage_e(data_dir, file_text, MAX_BYTES).unwrap();
        let looked = resident_lookup(&resident, vec![id], again.deck_names()).unwrap();
        assert_eq!(looked.notes.len(), 1);
        assert_eq!(looked.notes[0].r#mod, MOD);
        assert!(looked.found_deck_names.iter().any(|name| name == "Spanish"));
        let second =
            import_stage_finish(again, looked.notes, looked.found_deck_names).unwrap();
        assert!(second.plan.no_resident_call, "{second:?}");
        assert!(second.new_guids.is_empty());
        assert!(second.changed.is_empty());
        assert_eq!(second.pre_note_count, 0);
        assert_eq!(second.plan.same, 1);
        assert!(!Path::new(&second.staged_path).is_file());
        close(&resident);
        let _ = tmp;
    }

    #[test]
    fn t3_mixed_plan_lists_only_new_guids_and_changed_hashes() {
        let _lock = crate::lock_bridge_runtime();
        let (tmp, data) = fresh();
        let root = data.parent().unwrap();
        let source_dir = root.join("source");
        std::fs::create_dir_all(&source_dir).unwrap();
        let v1 = root.join("v1.apkg");
        let v2 = root.join("v2.apkg");
        {
            let source = open_unrestricted(&source_dir);
            let deck = add_deck(&source, "Box");
            for (n, front) in [(1u32, "same"), (2, "changed"), (3, "local"), (4, "missing")] {
                add_note(&source, deck, &[front, "back"], &guid(n), MOD);
            }
            export_apkg(&source, &v1);
            close(&source);
        }
        let resident = open_unrestricted(&data);
        import_staged(&resident, v1.to_str().unwrap(), true);
        {
            let source = open_unrestricted(&source_dir);
            let changed = note_id_by_guid(&source, &guid(2));
            set_fields(&source, changed, &["changed-now", "back"], MOD + 100);
            let local = note_id_by_guid(&source, &guid(3));
            set_fields(&source, local, &["local-file", "back"], MOD - 1);
            let missing = note_id_by_guid(&source, &guid(4));
            let _removed: anki_proto::collection::OpChangesWithCount = decode(call(
                &source,
                "BackendNotesService",
                "remove_notes",
                &anki_proto::notes::RemoveNotesRequest {
                    note_ids: vec![missing],
                    card_ids: Vec::new(),
                },
            ));
            let deck = deck_id(&source, "Box");
            add_note(&source, deck, &["brand-new", "back"], &guid(5), MOD);
            export_apkg(&source, &v2);
            close(&source);
        }
        let ids: Vec<i64> = (1..=4)
            .map(|n| note_id_by_guid(&resident, &guid(n)))
            .collect();
        let before = resident_lookup(&resident, ids.clone(), vec!["Box".into()]).unwrap();
        let pending = import_stage_e(
            data.to_string_lossy().into_owned(),
            v2.to_string_lossy().into_owned(),
            MAX_BYTES,
        )
        .unwrap();
        let looked = resident_lookup(&resident, ids, pending.deck_names()).unwrap();
        let finished = import_stage_finish(pending, looked.notes, looked.found_deck_names).unwrap();
        assert_eq!(finished.plan.new, 1, "{finished:?}");
        assert_eq!(finished.plan.changed, 1);
        assert_eq!(finished.plan.same, 1);
        assert_eq!(finished.plan.local_newer, 1);
        assert!(!finished.plan.no_resident_call);
        assert_eq!(finished.new_guids, vec![guid(5)]);
        assert_eq!(finished.changed.len(), 1);
        assert_eq!(finished.changed[0].guid, guid(2));
        assert_eq!(
            finished.changed[0].content_hash,
            hash_of(&["changed-now", "back"])
        );
        assert_eq!(finished.pre_note_count, 2);
        let after = resident_lookup(
            &resident,
            (1..=4)
                .map(|n| note_id_by_guid(&resident, &guid(n)))
                .collect(),
            vec!["Box".into()],
        )
        .unwrap();
        assert_eq!(note_snapshot(&after), note_snapshot(&before));
        close(&resident);
        let _ = tmp;
    }

    fn note_snapshot(found: &ResidentMatch) -> Vec<(String, i64, Vec<u8>)> {
        found
            .notes
            .iter()
            .map(|note| (note.guid.clone(), note.r#mod, note.content_hash.clone()))
            .collect()
    }

    #[test]
    fn t21_first_import_uses_only_the_names_lookup_found() {
        let _lock = crate::lock_bridge_runtime();
        let (tmp, data) = fresh();
        let root = data.parent().unwrap();
        let source_dir = root.join("source");
        std::fs::create_dir_all(&source_dir).unwrap();
        let file = root.join("deck.apkg");
        {
            let source = open_unrestricted(&source_dir);
            let deck = add_deck(&source, "D1");
            add_note(&source, deck, &["dee", "back"], GUID_1, MOD);
            export_apkg(&source, &file);
            close(&source);
        }
        let resident = open_unrestricted(&data);
        add_deck(&resident, "d1");
        let data_dir = data.to_string_lossy().into_owned();
        let file_text = file.to_string_lossy().into_owned();
        let pending = import_stage_e(data_dir.clone(), file_text.clone(), MAX_BYTES).unwrap();
        let looked = resident_lookup(&resident, Vec::new(), pending.deck_names()).unwrap();
        assert!(
            looked
                .found_deck_names
                .iter()
                .any(|name| name.eq_ignore_ascii_case("d1")),
            "{:?}",
            looked.found_deck_names
        );
        let finished =
            import_stage_finish(pending, looked.notes, looked.found_deck_names).unwrap();
        assert!(!finished.first_import, "{finished:?}");

        let gone = deck_id(&resident, "d1");
        let _removed: anki_proto::collection::OpChangesWithCount = decode(call(
            &resident,
            "BackendDecksService",
            "remove_decks",
            &anki_proto::decks::DeckIds { dids: vec![gone] },
        ));
        let pending = import_stage_e(data_dir, file_text, MAX_BYTES).unwrap();
        let looked = resident_lookup(&resident, Vec::new(), pending.deck_names()).unwrap();
        assert!(looked.found_deck_names.is_empty(), "{looked:?}");
        let again =
            import_stage_finish(pending, looked.notes, looked.found_deck_names).unwrap();
        assert!(again.first_import, "{again:?}");
        assert_eq!(again.plan.new, 1);
        close(&resident);
        let _ = tmp;
    }

    #[test]
    fn scan_keeps_only_the_prepared_batch_ids() {
        let root = tempfile::TempDir::new_in("/tmp").unwrap();
        let data = root.path().canonicalize().unwrap();
        let keep = "11111111-1111-4111-8111-111111111111";
        let drop_id = "22222222-2222-4222-8222-222222222222";
        let raw = data.join("import").join("raw");
        std::fs::create_dir_all(&raw).unwrap();
        std::fs::write(raw.join(format!("{keep}.apkg")), b"keep").unwrap();
        std::fs::write(raw.join(format!("{drop_id}.apkg")), b"drop").unwrap();
        let scan =
            scan_import_folders(data.to_string_lossy().into_owned(), vec![keep.into()]).unwrap();
        assert_eq!(scan.kept_prepared, vec![keep.to_string()]);
        assert_eq!(scan.removed, vec![drop_id.to_string()]);
        assert!(raw.join(format!("{keep}.apkg")).is_file());
        assert!(!raw.join(format!("{drop_id}.apkg")).is_file());
        let bad = scan_import_folders(data.to_string_lossy().into_owned(), vec!["nope".into()]);
        assert!(bad.is_err(), "{bad:?}");
    }
}
