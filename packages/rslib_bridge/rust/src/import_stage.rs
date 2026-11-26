// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Two-step `.apkg` import.
//!
//! [`import_stage_e`] writes only the E collection and fills the intent lists.
//! [`resident_lookup`] reads the open resident collection. [`import_stage_finish`]
//! is the resident write. Classifying notes is [`hatto_import::partition_intents`],
//! which does not touch a backend.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use anki_proto::backend::backend_error::Kind;
use hatto_import::ResidentLookup;
use prost::Message;

use crate::api::{
    command, from_contract_class, service_method_index, AnkiBackend, ImportFinish, NoteFacts,
    NoteIntent, Plan, PreparedImport, ResidentDeck, ResidentObjects,
};

pub(crate) fn import_stage_e(
    data_dir: String,
    source_path: String,
    max_bytes: u64,
    resident: &AnkiBackend,
) -> Result<PreparedImport, String> {
    let mut lookup = BackendLookup { backend: resident };
    let prepared = hatto_import::prepare_import(
        Path::new(&data_dir),
        Path::new(&source_path),
        hatto_import::ImportLimits { max_bytes },
        &mut lookup,
    )
    .map_err(|err| err.to_string())?;
    bridge_prepared(prepared)
}

pub(crate) fn resident_lookup(
    resident: &AnkiBackend,
    guids: Vec<String>,
    deck_names: Vec<String>,
) -> Result<ResidentObjects, String> {
    let notes_by_guid = resident_note_map(resident, &guids)?;
    let mut notes = Vec::new();
    let mut seen_guids = BTreeSet::new();
    for guid in &guids {
        if !seen_guids.insert(guid.as_str()) {
            continue;
        }
        if let Some(facts) = notes_by_guid.get(guid) {
            notes.push(bridge_note(facts));
        }
    }
    let mut decks = Vec::new();
    let mut seen_names = BTreeSet::new();
    for name in &deck_names {
        if !seen_names.insert(name.as_str()) {
            continue;
        }
        if let Some(id) = deck_id_by_name(resident, name)? {
            decks.push(ResidentDeck {
                name: name.clone(),
                id,
            });
        }
    }
    Ok(ResidentObjects { notes, decks })
}

pub(crate) fn import_stage_finish(
    resident: &AnkiBackend,
    prepared: PreparedImport,
) -> Result<ImportFinish, String> {
    if prepared.plan.no_resident_call {
        return Ok(ImportFinish {
            resident_called: false,
        });
    }
    let request = anki_proto::import_export::ImportAnkiPackageRequest {
        package_path: prepared.staged_path,
        options: Some(anki_proto::import_export::ImportAnkiPackageOptions {
            merge_notetypes: false,
            update_notes: anki_proto::import_export::ImportAnkiPackageUpdateCondition::IfNewer
                as i32,
            update_notetypes: anki_proto::import_export::ImportAnkiPackageUpdateCondition::Never
                as i32,
            with_scheduling: true,
            with_deck_configs: prepared.first_import,
        }),
    };
    let bytes = crate::api::call(
        resident,
        "BackendImportExportService",
        "import_anki_package",
        &request,
    )?;
    let response = anki_proto::import_export::ImportResponse::decode(bytes.as_slice())
        .map_err(|err| format!("import response: {err}"))?;
    let conflicting = response.log.map(|log| log.conflicting.len()).unwrap_or(0);
    if conflicting != 0 {
        return Err(format!("resident import conflicting {conflicting}"));
    }
    Ok(ImportFinish {
        resident_called: true,
    })
}

struct BackendLookup<'a> {
    backend: &'a AnkiBackend,
}

impl ResidentLookup for BackendLookup<'_> {
    fn note_facts(
        &mut self,
        guids: &[String],
    ) -> Result<BTreeMap<String, hatto_card_contract::NoteFacts>, hatto_import::ImportError> {
        resident_note_map(self.backend, guids).map_err(hatto_import::ImportError::new)
    }

    fn deck_id_by_name(&mut self, name: &str) -> Result<Option<i64>, hatto_import::ImportError> {
        deck_id_by_name(self.backend, name).map_err(hatto_import::ImportError::new)
    }
}

fn resident_note_map(
    backend: &AnkiBackend,
    guids: &[String],
) -> Result<BTreeMap<String, hatto_card_contract::NoteFacts>, String> {
    let rows = rslib_core::read_resident_notes(backend, guids)?;
    let mut found = BTreeMap::new();
    for row in rows {
        if found.contains_key(&row.guid) {
            return Err(format!("guid {} has more than one resident note", row.guid));
        }
        let facts = hatto_import::facts_from_stored_note(
            &row.guid,
            row.notetype_id,
            row.mod_secs,
            &row.flds,
            &row.tags,
        );
        found.insert(row.guid, facts);
    }
    Ok(found)
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
        added: prepared.added.into_iter().map(bridge_intent).collect(),
        updated: prepared.updated.into_iter().map(bridge_intent).collect(),
        skipped: prepared.skipped.into_iter().map(bridge_intent).collect(),
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

fn bridge_intent(row: hatto_import::NoteIntent) -> NoteIntent {
    NoteIntent {
        guid: row.guid,
        class: from_contract_class(row.class),
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

#[cfg(test)]
mod tests {
    use std::path::Path;

    use anki_proto::generic;
    use prost::Message;

    use super::{import_stage_e, import_stage_finish, resident_lookup};
    use crate::api::Class;
    use crate::api::{
        call, open_backend, open_desktop_backend, prepare_runtime, AnkiBackend, NoteFacts,
    };

    const GUID: &str = "00000000-0000-4000-8000-000000000001";
    const MOD: i64 = 1_700_000_000;
    const MAX_BYTES: u64 = 32 * 1024 * 1024;

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

    fn add_spanish_note(backend: &AnkiBackend, fields: &[&str], mod_secs: i64) -> i64 {
        let mut deck: anki_proto::decks::Deck = decode(call(
            backend,
            "BackendDecksService",
            "new_deck",
            &generic::Empty {},
        ));
        deck.name = "Spanish".into();
        let added_deck: anki_proto::collection::OpChangesWithId =
            decode(call(backend, "BackendDecksService", "add_deck", &deck));
        let notetype: anki_proto::notetypes::NotetypeId = decode(call(
            backend,
            "BackendNotetypesService",
            "get_notetype_id_by_name",
            &generic::String {
                val: "Basic".into(),
            },
        ));
        let mut note: anki_proto::notes::Note = decode(call(
            backend,
            "BackendNotesService",
            "new_note",
            &anki_proto::notetypes::NotetypeId {
                ntid: notetype.ntid,
            },
        ));
        note.guid = GUID.into();
        note.fields = fields.iter().map(|field| (*field).to_string()).collect();
        let added: anki_proto::notes::AddNoteResponse = decode(call(
            backend,
            "BackendNotesService",
            "add_note",
            &anki_proto::notes::AddNoteRequest {
                note: Some(note),
                deck_id: added_deck.id,
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
        let body = serde_json::json!({
            "kind": "executemany",
            "sql": "UPDATE notes SET \"mod\" = ? WHERE id = ?",
            "args": [[mod_secs, note_id]],
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

    #[test]
    fn stage_lookup_and_finish_keep_the_plan_off_the_resident_write() {
        let _lock = crate::lock_bridge_runtime();
        let tmp = tempfile::TempDir::new_in("/tmp").unwrap();
        let root = tmp.path().canonicalize().unwrap();
        let data = root.join("data");
        let source_dir = root.join("source");
        std::fs::create_dir_all(data.join("tmp")).unwrap();
        std::fs::create_dir_all(&source_dir).unwrap();
        prepare_runtime(data.join("tmp").to_string_lossy().into_owned());

        let file = root.join("deck.apkg");
        let changed = root.join("changed.apkg");
        let note_id = {
            let source = open_unrestricted(&source_dir);
            let note_id = add_spanish_note(&source, &["hola", "hello"], MOD);
            export_apkg(&source, &file);
            close(&source);
            note_id
        };

        let resident = open_desktop(&data);
        let data_dir = data.to_string_lossy().into_owned();
        let before = resident_lookup(&resident, vec![GUID.into()], vec!["Spanish".into()]).unwrap();
        assert!(before.notes.is_empty(), "{before:?}");
        assert!(before.decks.is_empty(), "{before:?}");

        let staged =
            import_stage_e(data_dir.clone(), path_text(&file), MAX_BYTES, &resident).unwrap();
        assert_eq!(staged.added.len(), 1, "{staged:?}");
        assert_eq!(staged.added[0].guid, GUID);
        assert_eq!(staged.added[0].class, Class::New);
        assert!(staged.updated.is_empty());
        assert!(staged.skipped.is_empty());
        assert!(staged.first_import);
        assert!(!staged.plan.no_resident_call);
        assert!(Path::new(&staged.staged_path).is_file());
        let still_absent =
            resident_lookup(&resident, vec![GUID.into()], vec!["Spanish".into()]).unwrap();
        assert!(still_absent.notes.is_empty());
        assert!(still_absent.decks.is_empty());

        let finished = import_stage_finish(&resident, staged).unwrap();
        assert!(finished.resident_called);
        let imported =
            resident_lookup(&resident, vec![GUID.into()], vec!["Spanish".into()]).unwrap();
        assert_eq!(imported.notes.len(), 1);
        assert_note(&imported.notes[0], &["hola", "hello"], MOD);
        let notetype_id = imported.notes[0].notetype_id;
        assert_eq!(imported.decks.len(), 1);
        assert_eq!(imported.decks[0].name, "Spanish");
        assert_ne!(imported.decks[0].id, 0);

        let again =
            import_stage_e(data_dir.clone(), path_text(&file), MAX_BYTES, &resident).unwrap();
        assert!(again.plan.no_resident_call, "{again:?}");
        assert!(again.added.is_empty());
        assert!(again.updated.is_empty());
        assert_eq!(again.skipped.len(), 1);
        assert_eq!(again.skipped[0].guid, GUID);
        assert_eq!(again.skipped[0].class, Class::Same);
        assert!(!Path::new(&again.staged_path).is_file());
        let skipped = import_stage_finish(&resident, again).unwrap();
        assert!(!skipped.resident_called);
        let unchanged = resident_lookup(&resident, vec![GUID.into()], Vec::new()).unwrap();
        assert_note(&unchanged.notes[0], &["hola", "hello"], MOD);
        assert_eq!(unchanged.notes[0].notetype_id, notetype_id);

        {
            let source = open_unrestricted(&source_dir);
            set_fields(&source, note_id, &["hola-2", "hello"], MOD + 100);
            export_apkg(&source, &changed);
            close(&source);
        }
        let restaged = import_stage_e(data_dir, path_text(&changed), MAX_BYTES, &resident).unwrap();
        assert_eq!(restaged.updated.len(), 1, "{restaged:?}");
        assert_eq!(restaged.updated[0].guid, GUID);
        assert_eq!(restaged.updated[0].class, Class::Changed);
        assert!(restaged.added.is_empty());
        assert_eq!(restaged.skipped.len(), 0);
        assert!(!restaged.plan.no_resident_call);
        let applied = import_stage_finish(&resident, restaged).unwrap();
        assert!(applied.resident_called);
        let after = resident_lookup(&resident, vec![GUID.into()], Vec::new()).unwrap();
        assert_note(&after.notes[0], &["hola-2", "hello"], MOD + 100);
        assert_eq!(after.notes[0].notetype_id, notetype_id);
        close(&resident);
    }

    fn assert_note(note: &NoteFacts, fields: &[&str], mod_secs: i64) {
        assert_eq!(note.guid, GUID);
        assert_ne!(note.notetype_id, 0);
        assert_eq!(note.r#mod, mod_secs);
        assert_eq!(note.content_hash, hash_of(fields));
    }

    fn path_text(path: &Path) -> String {
        path.to_string_lossy().into_owned()
    }
}
