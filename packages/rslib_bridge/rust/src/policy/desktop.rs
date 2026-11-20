// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Desktop profile: name gate, session memory, and path checks.
//!
//! The profile is fixed when the backend opens. Internal bridge calls use
//! `dispatch` and do not pass through this gate. App calls do.

use std::collections::{HashMap, HashSet};
use std::path::{Component, Path, PathBuf};

use prost::Message;

use super::validators;
use super::{entry, is_forwarded, Status};
use crate::api::ProtoResponse;
use crate::api::{backend_error, dispatch, AnkiBackend};
use crate::fsrs_init;
use crate::index;

/// States offered for one card by the latest `GetQueuedCards` or
/// `GetSchedulingStates` in this session. The bytes are prost's encoding of
/// each `SchedulingState`.
#[derive(Clone, Debug, Default)]
pub(crate) struct PresentedStates {
    pub again: Vec<u8>,
    pub hard: Vec<u8>,
    pub good: Vec<u8>,
    pub easy: Vec<u8>,
}

#[derive(Debug, Default)]
pub(crate) struct DesktopSession {
    pub data_dir: Option<PathBuf>,
    pub presented: HashMap<i64, PresentedStates>,
    pub search_strings: HashSet<String>,
}

impl DesktopSession {
    pub(crate) fn new(data_dir: Option<PathBuf>) -> Self {
        Self {
            data_dir,
            presented: HashMap::new(),
            search_strings: HashSet::new(),
        }
    }
}

pub(crate) fn enforce(
    backend: &AnkiBackend,
    service_index: u32,
    method_index: u32,
    input: Vec<u8>,
) -> ProtoResponse {
    let Some((service, method)) = index::reverse(service_index, method_index) else {
        return backend_error(format!(
            "denied: index {service_index}/{method_index} (not on allowlist)"
        ));
    };
    let full = format!("{service}.{method}");
    if !is_forwarded(service, method) {
        let why = match entry(service, method).map(|row| row.status) {
            Some(Status::Pending) => "validator not implemented",
            _ => "not on allowlist",
        };
        return backend_error(format!("denied: {full} ({why})"));
    }

    let bytes = match validators::prepare(backend, service, method, &input) {
        Ok(bytes) => bytes,
        Err(reason) => return backend_error(format!("denied: {full} ({reason})")),
    };
    let response = dispatch(backend, service_index, method_index, &bytes);
    if !response.success {
        return response;
    }
    observe(backend, service, method, &bytes, &response.payload);
    if service == super::COLLECTION && method == "open_collection" {
        match anki_proto::collection::OpenCollectionRequest::decode(bytes.as_slice()) {
            Ok(open) => {
                if let Err(err) = fsrs_init::maybe_initialize(backend, &open) {
                    let _ = fsrs_init::close_collection(backend);
                    return backend_error(format!("fsrs init failed: {err}"));
                }
            }
            Err(err) => {
                return backend_error(format!("fsrs init failed: open request: {err}"));
            }
        }
    }
    response
}

fn observe(backend: &AnkiBackend, service: &str, method: &str, input: &[u8], output: &[u8]) {
    let mut session = backend.lock_session();
    match (service, method) {
        (super::SCHEDULER, "get_queued_cards") => record_queued(&mut session, output),
        (super::SCHEDULER, "get_scheduling_states") => {
            record_scheduling(&mut session, input, output)
        }
        (super::SEARCH, "build_search_string" | "join_search_nodes" | "replace_search_node") => {
            record_search(&mut session, output);
        }
        (super::SCHEDULER, "answer_card") => {
            if let Ok(answer) = anki_proto::scheduler::CardAnswer::decode(input) {
                session.presented.remove(&answer.card_id);
            }
        }
        (super::COLLECTION, "close_collection") => {
            session.presented.clear();
            session.search_strings.clear();
        }
        _ => {}
    }
}

fn record_queued(session: &mut DesktopSession, output: &[u8]) {
    let Ok(queued) = anki_proto::scheduler::QueuedCards::decode(output) else {
        return;
    };
    for card in queued.cards {
        let Some(id) = card.card.as_ref().map(|card| card.id) else {
            continue;
        };
        if let Some(states) = card.states {
            session.presented.insert(id, presented_from_states(&states));
        }
    }
}

fn record_scheduling(session: &mut DesktopSession, input: &[u8], output: &[u8]) {
    let Ok(card_id) = anki_proto::cards::CardId::decode(input) else {
        return;
    };
    let Ok(states) = anki_proto::scheduler::SchedulingStates::decode(output) else {
        return;
    };
    session
        .presented
        .insert(card_id.cid, presented_from_states(&states));
}

fn presented_from_states(states: &anki_proto::scheduler::SchedulingStates) -> PresentedStates {
    PresentedStates {
        again: encode_state(states.again.as_ref()),
        hard: encode_state(states.hard.as_ref()),
        good: encode_state(states.good.as_ref()),
        easy: encode_state(states.easy.as_ref()),
    }
}

fn encode_state(state: Option<&anki_proto::scheduler::SchedulingState>) -> Vec<u8> {
    state.map(|state| state.encode_to_vec()).unwrap_or_default()
}

fn record_search(session: &mut DesktopSession, output: &[u8]) {
    if let Ok(value) = anki_proto::generic::String::decode(output) {
        session.search_strings.insert(value.val);
    }
}

/// Canonical absolute `data_dir` for a desktop profile.
///
/// The directory must already exist so the check can resolve symlinks.
pub fn prepare_data_dir(raw: &str) -> Result<PathBuf, String> {
    let path = Path::new(raw);
    if !path.is_absolute() {
        return Err("data_dir must be an absolute path".into());
    }
    if has_parent_dir(path) {
        return Err("data_dir must not contain '..'".into());
    }
    if !path.is_dir() {
        return Err("data_dir must be an existing directory".into());
    }
    path.canonicalize()
        .map_err(|err| format!("data_dir: {err}"))
}

/// The collection, media folder, and media database must each be a normalized
/// absolute path inside `data_dir`. `..` is rejected before normalization.
pub fn require_inside_data_dir(path: &str, data_dir: &Path) -> Result<(), String> {
    let raw = Path::new(path);
    if !raw.is_absolute() {
        return Err(format!("path is not absolute: {path}"));
    }
    if has_parent_dir(raw) {
        return Err(format!("path contains '..': {path}"));
    }
    let normalized = lexical_normalize(raw);
    let base = lexical_normalize(data_dir);
    if !is_strict_child(&normalized, &base) {
        return Err(format!("path is outside data_dir: {path}"));
    }
    let resolved = resolve_existing_prefix(&normalized)?;
    let base_canon = data_dir
        .canonicalize()
        .map_err(|err| format!("data_dir: {err}"))?;
    if !is_strict_child(&resolved, &base_canon) {
        return Err(format!("path escapes data_dir: {path}"));
    }
    Ok(())
}

fn has_parent_dir(path: &Path) -> bool {
    path.components()
        .any(|component| matches!(component, Component::ParentDir))
}

fn lexical_normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out
}

fn is_strict_child(path: &Path, root: &Path) -> bool {
    path.starts_with(root) && path != root
}

fn resolve_existing_prefix(path: &Path) -> Result<PathBuf, String> {
    let mut cursor = path.to_path_buf();
    let mut missing = PathBuf::new();
    while !cursor.exists() {
        let Some(name) = cursor.file_name() else {
            return Err(format!("path has no existing ancestor: {}", path.display()));
        };
        let name = name.to_os_string();
        cursor.pop();
        missing = PathBuf::from(name).join(missing);
        if cursor.as_os_str().is_empty() {
            return Err(format!("path has no existing ancestor: {}", path.display()));
        }
    }
    let canonical = cursor
        .canonicalize()
        .map_err(|err| format!("{}: {err}", cursor.display()))?;
    Ok(canonical.join(missing))
}
