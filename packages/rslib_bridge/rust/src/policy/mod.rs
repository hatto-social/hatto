// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Desktop call policy for one open backend.
//!
//! Names are `(Backend*Service, snake_case method)`. Numeric indexes are not
//! an ABI. A call is forwarded only when this table says it is allowed and,
//! for each checked call, [validators] accepts the request. Calls whose
//! validator is still not implemented stay on the table and are denied.
//! `SetActiveBrowserColumns` stays deferred and is not part of the profile.

mod desktop;
mod validators;

pub(crate) use desktop::enforce;
pub(crate) use desktop::{prepare_data_dir, DesktopSession};

use std::collections::HashSet;

pub const COLLECTION: &str = "BackendCollectionService";
pub const CONFIG: &str = "BackendConfigService";
pub const DECKS: &str = "BackendDecksService";
pub const NOTES: &str = "BackendNotesService";
pub const NOTETYPES: &str = "BackendNotetypesService";
pub const CARDS: &str = "BackendCardsService";
pub const RENDERING: &str = "BackendCardRenderingService";
pub const SEARCH: &str = "BackendSearchService";
pub const TAGS: &str = "BackendTagsService";
pub const MEDIA: &str = "BackendMediaService";
pub const OCCLUSION: &str = "BackendImageOcclusionService";
pub const IMPORT_EXPORT: &str = "BackendImportExportService";
pub const SCHEDULER: &str = "BackendSchedulerService";
pub const STATS: &str = "BackendStatsService";

/// `GetQueuedCards.fetch_limit` must be at most this. The brief proposes 50.
pub const FETCH_LIMIT_MAX: u32 = 50;

/// `AnswerCard.milliseconds_taken` must be at most 60 seconds.
pub const ANSWER_TAKEN_MAX_MILLIS: u32 = 60_000;

/// `Graphs.days` must be at most this.
///
/// The brief requires a cap and does not give the number. rslib treats 0 as
/// the whole revlog, so 0 stays allowed. 3650 is ten years, above Anki's
/// one-year preset.
pub const GRAPHS_DAYS_MAX: u32 = 3_650;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Access {
    Read,
    Write,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    /// Allowed, and [validators] checks the request.
    Validated,
    /// Allowed with no argument check (read, pure, or no arguments).
    NameOnly,
    /// On the contract list. Denied until the port PR implements the validator.
    Pending,
    /// Not in the 87. Carried to the port PR. The profile does not allow it.
    Deferred,
}

#[derive(Clone, Copy, Debug)]
pub struct AllowEntry {
    pub service: &'static str,
    pub method: &'static str,
    pub access: Access,
    pub status: Status,
    pub validation: &'static str,
    pub test_name: &'static str,
}

const NAME_ONLY_TEST: &str = "name_only_calls_are_not_denied_by_the_desktop_profile";
const PENDING_TEST: &str = "pending_validators_are_denied";
const NONE: &str = "없음";
const UNIMPLEMENTED: &str = "미구현";

macro_rules! row {
    ($service:expr, $method:literal, $access:ident, $status:ident, $validation:expr, $test:expr) => {
        AllowEntry {
            service: $service,
            method: $method,
            access: Access::$access,
            status: Status::$status,
            validation: $validation,
            test_name: $test,
        }
    };
}

/// Contract 87, in the brief's order, plus the one deferred row.
pub static ALLOWLIST: &[AllowEntry] = &[
    // Collection (7)
    row!(COLLECTION, "open_collection", Write, Validated, "three paths are absolute, normalized, and inside data_dir; '..' is rejected", "validates_open_collection"),
    row!(COLLECTION, "close_collection", Write, Validated, "downgrade_to_schema11 is false", "validates_close_collection"),
    row!(COLLECTION, "latest_progress", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(COLLECTION, "set_wants_abort", Write, NameOnly, NONE, NAME_ONLY_TEST),
    row!(COLLECTION, "get_undo_status", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(COLLECTION, "undo", Write, Validated, "request is empty; the FSRS bootstrap is not left on the undo stack", "validates_undo_and_redo"),
    row!(COLLECTION, "redo", Write, Validated, "request is empty", "validates_undo_and_redo"),
    // Config (1)
    row!(CONFIG, "get_config_bool", Read, Validated, "Bool key is NormalizeNoteText", "validates_get_config_bool"),
    // Decks (10) plus SetCurrentDeck from the study list
    row!(DECKS, "new_deck", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(DECKS, "get_deck", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(DECKS, "get_deck_id_by_name", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(DECKS, "get_deck_names", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(DECKS, "get_deck_and_child_names", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(DECKS, "deck_tree", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(DECKS, "add_deck", Write, Validated, "name is non-empty, has no empty :: segment, and kind is normal. rslib may create missing parents", "validates_add_deck"),
    row!(DECKS, "rename_deck", Write, Pending, UNIMPLEMENTED, PENDING_TEST),
    row!(DECKS, "reparent_decks", Write, Pending, UNIMPLEMENTED, PENDING_TEST),
    row!(DECKS, "remove_decks", Write, Pending, UNIMPLEMENTED, PENDING_TEST),
    row!(DECKS, "set_current_deck", Write, Validated, "the deck exists and is a normal deck", "validates_set_current_deck"),
    // Notes (13)
    row!(NOTES, "new_note", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(NOTES, "get_note", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(NOTES, "defaults_for_adding", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(NOTES, "default_deck_for_notetype", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(NOTES, "field_names_for_notes", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(NOTES, "cloze_numbers_in_note", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(NOTES, "note_fields_check", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(NOTES, "cards_of_note", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(NOTES, "get_single_notetype_of_notes", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(NOTES, "add_note", Write, Pending, UNIMPLEMENTED, PENDING_TEST),
    row!(NOTES, "add_notes", Write, Pending, UNIMPLEMENTED, PENDING_TEST),
    row!(NOTES, "update_notes", Write, Pending, UNIMPLEMENTED, PENDING_TEST),
    row!(NOTES, "remove_notes", Write, Validated, "note_ids is a non-empty list of notes that exist; card_ids is empty", "validates_remove_notes"),
    // Notetypes (11)
    row!(NOTETYPES, "get_notetype", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(NOTETYPES, "get_notetype_names", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(NOTETYPES, "get_notetype_names_and_counts", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(NOTETYPES, "get_notetype_id_by_name", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(NOTETYPES, "get_field_names", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(NOTETYPES, "get_cloze_field_ords", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(NOTETYPES, "get_change_notetype_info", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(NOTETYPES, "add_notetype", Write, Pending, UNIMPLEMENTED, PENDING_TEST),
    row!(NOTETYPES, "update_notetype", Write, Pending, UNIMPLEMENTED, PENDING_TEST),
    row!(NOTETYPES, "remove_notetype", Write, Pending, "노트타입 관리 UI가 생길 때 연다", PENDING_TEST),
    row!(NOTETYPES, "change_notetype", Write, Pending, UNIMPLEMENTED, PENDING_TEST),
    // Cards (1)
    row!(CARDS, "get_card", Read, NameOnly, NONE, NAME_ONLY_TEST),
    // Card rendering (10)
    row!(RENDERING, "render_existing_card", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(RENDERING, "render_uncommitted_card", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(RENDERING, "extract_latex", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(RENDERING, "extract_av_tags", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(RENDERING, "strip_av_tags", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(RENDERING, "strip_html", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(RENDERING, "html_to_text_line", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(RENDERING, "get_empty_cards", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(RENDERING, "encode_iri_paths", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(RENDERING, "decode_iri_paths", Read, NameOnly, NONE, NAME_ONLY_TEST),
    // Search (7) and the deferred column call
    row!(SEARCH, "search_notes", Read, Validated, "search was returned by BuildSearchString, JoinSearchNodes, or ReplaceSearchNode this session", "validates_search"),
    row!(SEARCH, "search_cards", Read, Validated, "search was returned by BuildSearchString, JoinSearchNodes, or ReplaceSearchNode this session", "validates_search"),
    row!(SEARCH, "browser_row_for_id", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(SEARCH, "all_browser_columns", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(SEARCH, "build_search_string", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(SEARCH, "join_search_nodes", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(SEARCH, "replace_search_node", Read, NameOnly, NONE, NAME_ONLY_TEST),
    // Tags (3)
    row!(TAGS, "all_tags", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(TAGS, "tag_tree", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(TAGS, "complete_tag", Read, NameOnly, NONE, NAME_ONLY_TEST),
    // Media (3)
    row!(MEDIA, "add_media_file", Write, Pending, UNIMPLEMENTED, PENDING_TEST),
    row!(MEDIA, "extract_media_files", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(MEDIA, "extract_static_media_files", Read, NameOnly, NONE, NAME_ONLY_TEST),
    // Image occlusion (4)
    row!(OCCLUSION, "get_image_occlusion_fields", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(OCCLUSION, "add_image_occlusion_notetype", Write, NameOnly, NONE, NAME_ONLY_TEST),
    row!(OCCLUSION, "update_image_occlusion_note", Write, Pending, UNIMPLEMENTED, PENDING_TEST),
    row!(OCCLUSION, "get_image_occlusion_note", Read, Pending, "N1 초크포인트가 없다. 이미지 필드 경로 가드가 생기기 전에는 거부", PENDING_TEST),
    // Import / export (1)
    row!(IMPORT_EXPORT, "export_anki_package", Write, Validated, "with_scheduling=false, with_deck_configs=false, with_media=true, legacy=false; limit is one deck or a note id list", "validates_export_anki_package"),
    // Study scheduler (9) plus bury and restore
    row!(SCHEDULER, "get_queued_cards", Read, Validated, "fetch_limit <= 50", "validates_get_queued_cards"),
    row!(SCHEDULER, "answer_card", Write, Validated, "new_state bytes match the offered rating; custom_data empty; milliseconds_taken <= 60000; wrapper sets answered_at_millis", "validates_answer_card"),
    row!(SCHEDULER, "counts_for_deck_today", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(SCHEDULER, "congrats_info", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(SCHEDULER, "sched_timing_today", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(SCHEDULER, "studied_today", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(SCHEDULER, "get_scheduling_states", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(SCHEDULER, "describe_next_states", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(SCHEDULER, "state_is_leech", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(SCHEDULER, "bury_or_suspend_cards", Write, Validated, "mode is SUSPEND, card_ids is non-empty, note_ids is empty, every card exists", "validates_bury_or_suspend_cards"),
    row!(SCHEDULER, "restore_buried_and_suspended_cards", Write, Validated, "every listed card exists and has queue -1", "validates_restore_buried_and_suspended_cards"),
    // Stats (4)
    row!(STATS, "graphs", Read, Validated, "search was returned by BuildSearchString, JoinSearchNodes, or ReplaceSearchNode this session; days <= 3650. days=0 reads the whole revlog, so 3650 is not a cost cap", "validates_graphs"),
    row!(STATS, "get_graph_preferences", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(STATS, "card_stats", Read, NameOnly, NONE, NAME_ONLY_TEST),
    row!(STATS, "get_review_logs", Read, NameOnly, NONE, NAME_ONLY_TEST),
    // Deferred. Not one of the 87, and not allowed.
    row!(SEARCH, "set_active_browser_columns", Write, Deferred, "이식 PR", "set_active_browser_columns_is_outside_the_profile"),
];

pub fn entry(service: &str, method: &str) -> Option<&'static AllowEntry> {
    ALLOWLIST
        .iter()
        .find(|row| row.service == service && row.method == method)
}

pub fn is_forwarded(service: &str, method: &str) -> bool {
    matches!(
        entry(service, method).map(|row| row.status),
        Some(Status::Validated | Status::NameOnly)
    )
}

pub fn forwarded_names() -> HashSet<(&'static str, &'static str)> {
    ALLOWLIST
        .iter()
        .filter(|row| matches!(row.status, Status::Validated | Status::NameOnly))
        .map(|row| (row.service, row.method))
        .collect()
}

pub fn status_label(status: Status) -> &'static str {
    match status {
        Status::Validated => "허용(검증 있음)",
        Status::NameOnly => "허용(이름만)",
        Status::Pending => "검증 미구현, 이 PR에서는 거부",
        Status::Deferred => "이월",
    }
}

pub fn access_label(access: Access) -> &'static str {
    match access {
        Access::Read => "읽기",
        Access::Write => "쓰기",
    }
}

pub fn camel_method(snake: &str) -> String {
    snake
        .split('_')
        .map(|part| {
            let mut chars = part.chars();
            match chars.next() {
                None => String::new(),
                Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
            }
        })
        .collect()
}

pub fn service_short_name(service: &str) -> &str {
    service
        .strip_prefix("Backend")
        .unwrap_or(service)
        .strip_suffix("Service")
        .unwrap_or(service)
}

/// Markdown table generated from [ALLOWLIST]. The PR body copies this.
pub fn allowlist_markdown() -> String {
    let mut out = String::from(
        "| # | Service | method | 구분(읽기/쓰기) | 상태 | 검증 | 테스트 |\n|---|---|---|---|---|---|---|\n",
    );
    for (index, row) in ALLOWLIST.iter().enumerate() {
        out.push_str(&format!(
            "| {} | {} | {} | {} | {} | {} | {} |\n",
            index + 1,
            service_short_name(row.service),
            camel_method(row.method),
            access_label(row.access),
            status_label(row.status),
            row.validation.replace('|', "/"),
            row.test_name,
        ));
    }
    out
}

#[cfg(test)]
mod tests;
