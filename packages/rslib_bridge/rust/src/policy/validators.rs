// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Request checks for the desktop calls this PR implements.
//!
//! A failure is returned to `command` and is not sent to rslib. Checks that
//! need another collection read use [crate::api::dispatch_message], which
//! does not pass the desktop gate.

use std::time::{SystemTime, UNIX_EPOCH};

use prost::Message;

use super::desktop::{require_inside_data_dir, PresentedStates};
use super::{
    ANSWER_TAKEN_MAX_MILLIS, CARDS, COLLECTION, CONFIG, DECKS, FETCH_LIMIT_MAX, GRAPHS_DAYS_MAX,
    IMPORT_EXPORT, NOTETYPES, SCHEDULER, SEARCH, STATS,
};
use crate::api::{dispatch_message, AnkiBackend};

pub(crate) fn prepare(
    backend: &AnkiBackend,
    service: &str,
    method: &str,
    input: &[u8],
) -> Result<Vec<u8>, String> {
    match (service, method) {
        (COLLECTION, "open_collection") => validate_open(backend, input),
        (COLLECTION, "close_collection") => validate_close(input),
        (COLLECTION, "undo" | "redo") => validate_undo(input),
        (CONFIG, "get_config_bool") => validate_get_config_bool(input),
        (SCHEDULER, "get_queued_cards") => validate_queued(input),
        (SCHEDULER, "answer_card") => validate_answer(backend, input),
        (DECKS, "set_current_deck") => validate_current_deck(backend, input),
        (STATS, "graphs") => validate_graphs(backend, input),
        (SCHEDULER, "bury_or_suspend_cards") => validate_bury(backend, input),
        (SCHEDULER, "restore_buried_and_suspended_cards") => validate_restore(backend, input),
        (NOTETYPES, "get_cloze_field_ords") => validate_cloze_field_ords(backend, input),
        (DECKS, "rename_deck") => validate_rename_deck(backend, input),
        (SEARCH, "search_notes" | "search_cards") => validate_search(backend, input),
        (IMPORT_EXPORT, "import_anki_package") => validate_resident_import(backend, input),
        _ => Ok(input.to_vec()),
    }
}

fn validate_open(backend: &AnkiBackend, input: &[u8]) -> Result<Vec<u8>, String> {
    let mut request = decode::<anki_proto::collection::OpenCollectionRequest>(input)?;
    let data_dir = data_dir(backend)?;
    let collection = require_inside_data_dir(&request.collection_path, &data_dir)
        .map_err(|err| format!("collection_path: {err}"))?;
    let media = require_inside_data_dir(&request.media_folder_path, &data_dir)
        .map_err(|err| format!("media_folder_path: {err}"))?;
    let media_db = require_inside_data_dir(&request.media_db_path, &data_dir)
        .map_err(|err| format!("media_db_path: {err}"))?;
    request.collection_path = collection.to_string_lossy().into_owned();
    request.media_folder_path = media.to_string_lossy().into_owned();
    request.media_db_path = media_db.to_string_lossy().into_owned();
    Ok(request.encode_to_vec())
}

fn validate_undo(input: &[u8]) -> Result<Vec<u8>, String> {
    if !input.is_empty() {
        return Err("undo request must be empty".into());
    }
    Ok(input.to_vec())
}

fn validate_close(input: &[u8]) -> Result<Vec<u8>, String> {
    let request = decode::<anki_proto::collection::CloseCollectionRequest>(input)?;
    if request.downgrade_to_schema11 {
        return Err("downgrade_to_schema11 must be false".into());
    }
    Ok(input.to_vec())
}

fn validate_get_config_bool(input: &[u8]) -> Result<Vec<u8>, String> {
    let request = decode::<anki_proto::config::GetConfigBoolRequest>(input)?;
    let allowed = anki_proto::config::config_key::Bool::NormalizeNoteText as i32;
    if request.key != allowed {
        return Err("only NormalizeNoteText is allowed".into());
    }
    Ok(input.to_vec())
}

fn validate_cloze_field_ords(backend: &AnkiBackend, input: &[u8]) -> Result<Vec<u8>, String> {
    let notetype = decode::<anki_proto::notetypes::NotetypeId>(input)?;
    dispatch_message(backend, NOTETYPES, "get_notetype", &notetype)
        .map_err(|_| format!("notetype {} does not exist", notetype.ntid))?;
    Ok(input.to_vec())
}

fn validate_queued(input: &[u8]) -> Result<Vec<u8>, String> {
    let request = decode::<anki_proto::scheduler::GetQueuedCardsRequest>(input)?;
    if request.fetch_limit > FETCH_LIMIT_MAX {
        return Err(format!(
            "fetch_limit {} is above {FETCH_LIMIT_MAX}",
            request.fetch_limit
        ));
    }
    Ok(input.to_vec())
}

fn validate_answer(backend: &AnkiBackend, input: &[u8]) -> Result<Vec<u8>, String> {
    let mut answer = decode::<anki_proto::scheduler::CardAnswer>(input)?;
    let Some(new_state) = answer.new_state.as_ref() else {
        return Err("new_state is missing".into());
    };
    if !custom_data_is_empty(new_state) {
        return Err("custom_data must be empty".into());
    }
    if answer.milliseconds_taken > ANSWER_TAKEN_MAX_MILLIS {
        return Err(format!(
            "milliseconds_taken {} is above {ANSWER_TAKEN_MAX_MILLIS}",
            answer.milliseconds_taken
        ));
    }
    let offered = {
        let session = backend.lock_session();
        session
            .presented
            .get(&answer.card_id)
            .cloned()
            .ok_or_else(|| format!("card {} was not offered", answer.card_id))?
    };
    let expected = state_for_rating(&offered, answer.rating)?;
    if expected.is_empty() {
        return Err("the offered state for that rating is missing".into());
    }
    if new_state.encode_to_vec() != expected {
        return Err("new_state does not match the offered state".into());
    }
    fill_answered_at_millis(&mut answer, now_millis());
    Ok(answer.encode_to_vec())
}

/// The desktop profile writes the bridge clock into `answered_at_millis`
/// before rslib sees the answer. A client-supplied value is replaced.
pub(crate) fn fill_answered_at_millis(
    answer: &mut anki_proto::scheduler::CardAnswer,
    now_millis: i64,
) {
    answer.answered_at_millis = now_millis;
}

fn custom_data_is_empty(state: &anki_proto::scheduler::SchedulingState) -> bool {
    match &state.custom_data {
        Some(value) => value.is_empty(),
        None => true,
    }
}

fn state_for_rating(offered: &PresentedStates, rating: i32) -> Result<Vec<u8>, String> {
    let again = anki_proto::scheduler::card_answer::Rating::Again as i32;
    let hard = anki_proto::scheduler::card_answer::Rating::Hard as i32;
    let good = anki_proto::scheduler::card_answer::Rating::Good as i32;
    let easy = anki_proto::scheduler::card_answer::Rating::Easy as i32;
    if rating == again {
        Ok(offered.again.clone())
    } else if rating == hard {
        Ok(offered.hard.clone())
    } else if rating == good {
        Ok(offered.good.clone())
    } else if rating == easy {
        Ok(offered.easy.clone())
    } else {
        Err(format!("rating {rating} is not again, hard, good, or easy"))
    }
}

fn validate_current_deck(backend: &AnkiBackend, input: &[u8]) -> Result<Vec<u8>, String> {
    let request = decode::<anki_proto::decks::DeckId>(input)?;
    let bytes = dispatch_message(
        backend,
        DECKS,
        "get_deck",
        &anki_proto::decks::DeckId { did: request.did },
    )
    .map_err(|_| format!("deck {} does not exist", request.did))?;
    let deck = decode::<anki_proto::decks::Deck>(&bytes)?;
    let normal = matches!(deck.kind, Some(anki_proto::decks::deck::Kind::Normal(_)));
    if !normal {
        return Err(format!("deck {} is not a normal deck", request.did));
    }
    Ok(input.to_vec())
}

fn validate_graphs(backend: &AnkiBackend, input: &[u8]) -> Result<Vec<u8>, String> {
    let request = decode::<anki_proto::stats::GraphsRequest>(input)?;
    if request.days > GRAPHS_DAYS_MAX {
        return Err(format!("days {} is above {GRAPHS_DAYS_MAX}", request.days));
    }
    require_built_search(backend, &request.search)?;
    Ok(input.to_vec())
}

/// Browser columns rslib maps to SQL itself. `SortOrder.custom` is appended
/// after `ORDER BY` verbatim, so it stays rejected.
const SEARCH_SORT_COLUMNS: &[&str] = &[
    "answer",
    "cardMod",
    "template",
    "deck",
    "cardDue",
    "cardEase",
    "cardLapses",
    "cardIvl",
    "noteCrt",
    "noteMod",
    "note",
    "originalPosition",
    "question",
    "cardReps",
    "noteFld",
    "noteTags",
    "stability",
    "difficulty",
    "retrievability",
];

fn validate_search(backend: &AnkiBackend, input: &[u8]) -> Result<Vec<u8>, String> {
    let request = decode::<anki_proto::search::SearchRequest>(input)?;
    require_built_search(backend, &request.search)?;
    check_search_order(request.order.as_ref())?;
    Ok(input.to_vec())
}

pub(crate) fn check_search_order(
    order: Option<&anki_proto::search::SortOrder>,
) -> Result<(), String> {
    let Some(order) = order else {
        return Ok(());
    };
    match order.value.as_ref() {
        None | Some(anki_proto::search::sort_order::Value::None(_)) => Ok(()),
        Some(anki_proto::search::sort_order::Value::Custom(_)) => {
            Err("custom sort order is not allowed".into())
        }
        Some(anki_proto::search::sort_order::Value::Builtin(builtin)) => {
            if SEARCH_SORT_COLUMNS.contains(&builtin.column.as_str()) {
                Ok(())
            } else {
                Err(format!(
                    "sort column '{}' is not allowlisted",
                    builtin.column
                ))
            }
        }
    }
}

fn require_built_search(backend: &AnkiBackend, search: &str) -> Result<(), String> {
    let known = backend.lock_session().search_strings.contains(search);
    if !known {
        return Err("search was not returned by a search builder in this session".into());
    }
    Ok(())
}

fn validate_rename_deck(backend: &AnkiBackend, input: &[u8]) -> Result<Vec<u8>, String> {
    let request = decode::<anki_proto::decks::RenameDeckRequest>(input)?;
    if request.deck_id == 0 {
        return Err("deck does not exist".into());
    }
    dispatch_message(
        backend,
        DECKS,
        "get_deck",
        &anki_proto::decks::DeckId {
            did: request.deck_id,
        },
    )
    .map_err(|_| format!("deck {} does not exist", request.deck_id))?;
    check_deck_name(&request.new_name)?;
    Ok(input.to_vec())
}

fn check_deck_name(name: &str) -> Result<(), String> {
    if name.trim().is_empty() || name.split("::").any(|part| part.is_empty()) {
        return Err("deck name is empty or has an empty segment".into());
    }
    if name.len() > 255 {
        return Err("deck name is longer than 255 bytes".into());
    }
    if name.chars().any(|c| {
        matches!(
            c as u32,
            0x00..=0x08 | 0x0B | 0x0C | 0x0E..=0x1F | 0x7F
        )
    }) {
        return Err("deck name contains a control character".into());
    }
    Ok(())
}

fn validate_bury(backend: &AnkiBackend, input: &[u8]) -> Result<Vec<u8>, String> {
    let request = decode::<anki_proto::scheduler::BuryOrSuspendCardsRequest>(input)?;
    let suspend = anki_proto::scheduler::bury_or_suspend_cards_request::Mode::Suspend as i32;
    if request.mode != suspend {
        return Err("mode must be SUSPEND".into());
    }
    if request.card_ids.is_empty() {
        return Err("card_ids is empty".into());
    }
    if !request.note_ids.is_empty() {
        return Err("note_ids must be empty".into());
    }
    for card_id in &request.card_ids {
        card_exists(backend, *card_id)?;
    }
    Ok(input.to_vec())
}

fn validate_restore(backend: &AnkiBackend, input: &[u8]) -> Result<Vec<u8>, String> {
    let request = decode::<anki_proto::cards::CardIds>(input)?;
    if request.cids.is_empty() {
        return Err("card ids are empty".into());
    }
    for card_id in &request.cids {
        let card = load_card(backend, *card_id)?;
        if card.queue != -1 {
            return Err(format!("card {card_id} queue is {}, not -1", card.queue));
        }
    }
    Ok(input.to_vec())
}

fn card_exists(backend: &AnkiBackend, card_id: i64) -> Result<(), String> {
    load_card(backend, card_id).map(|_| ())
}

fn load_card(backend: &AnkiBackend, card_id: i64) -> Result<anki_proto::cards::Card, String> {
    let bytes = dispatch_message(
        backend,
        CARDS,
        "get_card",
        &anki_proto::cards::CardId { cid: card_id },
    )
    .map_err(|_| format!("card {card_id} does not exist"))?;
    decode(&bytes)
}

pub(crate) fn data_dir(backend: &AnkiBackend) -> Result<std::path::PathBuf, String> {
    backend
        .lock_session()
        .data_dir
        .clone()
        .ok_or_else(|| "desktop profile has no data_dir".to_string())
}

pub(crate) fn decode<T: Message + Default>(bytes: &[u8]) -> Result<T, String> {
    T::decode(bytes).map_err(|err| format!("invalid protobuf: {err}"))
}

/// Resident `ImportAnkiPackage`. `options` must be present. `with_deck_configs`
/// is the caller's choice. The path is checked after symlink resolution.
fn validate_resident_import(backend: &AnkiBackend, input: &[u8]) -> Result<Vec<u8>, String> {
    let mut request = decode::<anki_proto::import_export::ImportAnkiPackageRequest>(input)?;
    let Some(options) = request.options.as_ref() else {
        return Err("options must be set".into());
    };
    check_import_options(options, &RESIDENT_IMPORT_OPTIONS)?;
    let data_dir = data_dir(backend)?;
    let resolved = resolve_under_data_dir(&request.package_path, &data_dir)
        .map_err(|err| format!("package_path: {err}"))?;
    uuid_v4_apkg_id(&resolved, &data_dir, "staged")?;
    request.package_path = resolved.to_string_lossy().into_owned();
    Ok(request.encode_to_vec())
}

/// Fixed import options shared by the resident row and the import-E row.
///
/// `with_deck_configs` is `None` when either boolean is accepted.
pub(crate) struct ImportOptionRule {
    pub update_notes: i32,
    pub with_deck_configs: Option<bool>,
}

pub(crate) const RESIDENT_IMPORT_OPTIONS: ImportOptionRule = ImportOptionRule {
    update_notes: anki_proto::import_export::ImportAnkiPackageUpdateCondition::IfNewer as i32,
    with_deck_configs: None,
};

pub(crate) fn check_import_options(
    options: &anki_proto::import_export::ImportAnkiPackageOptions,
    rule: &ImportOptionRule,
) -> Result<(), String> {
    if options.merge_notetypes {
        return Err("merge_notetypes must be false".into());
    }
    if options.update_notes != rule.update_notes {
        return Err(update_notes_reason(rule.update_notes));
    }
    let never = anki_proto::import_export::ImportAnkiPackageUpdateCondition::Never as i32;
    if options.update_notetypes != never {
        return Err("update_notetypes must be NEVER".into());
    }
    if !options.with_scheduling {
        return Err("with_scheduling must be true".into());
    }
    if let Some(expected) = rule.with_deck_configs {
        if options.with_deck_configs != expected {
            return Err(format!("with_deck_configs must be {expected}"));
        }
    }
    Ok(())
}

fn update_notes_reason(expected: i32) -> String {
    let if_newer = anki_proto::import_export::ImportAnkiPackageUpdateCondition::IfNewer as i32;
    let never = anki_proto::import_export::ImportAnkiPackageUpdateCondition::Never as i32;
    if expected == if_newer {
        "update_notes must be IF_NEWER".into()
    } else if expected == never {
        "update_notes must be NEVER".into()
    } else {
        format!("update_notes must be {expected}")
    }
}

/// Resolve `path` the way [super::desktop::require_inside_data_dir] does,
/// then the caller matches the resolved path against one import shape.
pub(crate) fn resolve_under_data_dir(
    path: &str,
    data_dir: &std::path::Path,
) -> Result<std::path::PathBuf, String> {
    super::desktop::require_inside_data_dir(path, data_dir)
}

/// `<data_dir>/import/<folder>/<uuid v4>.apkg` after symlink resolution.
pub(crate) fn uuid_v4_apkg_id(
    resolved: &std::path::Path,
    data_dir: &std::path::Path,
    folder: &str,
) -> Result<String, String> {
    let parent = data_dir.join("import").join(folder);
    if resolved.parent() != Some(parent.as_path()) {
        return Err(format!("path is not import/{folder}/<uuid v4>.apkg"));
    }
    let Some(name) = resolved.file_name().and_then(|name| name.to_str()) else {
        return Err("path has no utf-8 file name".into());
    };
    let Some(id) = name.strip_suffix(".apkg") else {
        return Err("path is not an .apkg file".into());
    };
    if !is_import_batch_id(id) {
        return Err("import_batch_id is not a lowercase uuid v4".into());
    }
    Ok(id.to_string())
}

/// `<data_dir>/import/e/<uuid v4>/collection.anki2` after symlink resolution.
pub(crate) fn e_collection_batch_id(
    resolved: &std::path::Path,
    data_dir: &std::path::Path,
) -> Result<String, String> {
    let Some(name) = resolved.file_name().and_then(|name| name.to_str()) else {
        return Err("collection path has no utf-8 file name".into());
    };
    if name != "collection.anki2" {
        return Err("collection file must be collection.anki2".into());
    }
    let Some(batch_dir) = resolved.parent() else {
        return Err("collection path has no directory".into());
    };
    let e_dir = data_dir.join("import").join("e");
    if batch_dir.parent() != Some(e_dir.as_path()) {
        return Err("collection path is not import/e/<uuid v4>/collection.anki2".into());
    }
    let Some(id) = batch_dir.file_name().and_then(|name| name.to_str()) else {
        return Err("import batch directory is not utf-8".into());
    };
    if !is_import_batch_id(id) {
        return Err("import_batch_id is not a lowercase uuid v4".into());
    }
    Ok(id.to_string())
}

/// `import/e/<id>/<name>` after symlink resolution. `name` is one path segment.
pub(crate) fn expect_e_sibling(
    resolved: &std::path::Path,
    data_dir: &std::path::Path,
    id: &str,
    name: &str,
) -> Result<(), String> {
    let expected = data_dir.join("import").join("e").join(id).join(name);
    if resolved != expected {
        return Err(format!("path must be import/e/<id>/{name}"));
    }
    Ok(())
}

/// Lowercase hyphenated UUID with version nibble 4 and the RFC 4122 variant.
pub(crate) fn is_import_batch_id(text: &str) -> bool {
    hatto_card_contract::is_guid_format(text) && text.as_bytes().get(14) == Some(&b'4')
}

pub(crate) fn now_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| i64::try_from(duration.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}
