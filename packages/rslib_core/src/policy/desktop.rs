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
    /// Set after `OpenCollection` and its FSRS init both succeed. Cleared
    /// after a successful `CloseCollection`.
    pub collection_open: bool,
    /// Set when rslib panics. Later calls are rejected until the process
    /// builds a new backend. The collection mutex may already be poisoned.
    pub poisoned: bool,
    pub presented: HashMap<i64, PresentedStates>,
    pub search_strings: HashSet<String>,
    /// UUID v4 of the collection the import-E profile has open.
    /// The desktop profile leaves this empty.
    pub import_batch_id: Option<String>,
}

impl DesktopSession {
    pub(crate) fn new(data_dir: Option<PathBuf>) -> Self {
        Self {
            data_dir,
            collection_open: false,
            poisoned: false,
            presented: HashMap::new(),
            search_strings: HashSet::new(),
            import_batch_id: None,
        }
    }
}

/// Requests larger than this are rejected before they reach rslib.
pub(crate) const MAX_REQUEST_BYTES: usize = 4 * 1024 * 1024;

pub(crate) fn enforce(
    backend: &AnkiBackend,
    service_index: u32,
    method_index: u32,
    input: Vec<u8>,
) -> ProtoResponse {
    if input.len() > MAX_REQUEST_BYTES {
        return backend_error(format!(
            "denied: request is {} bytes (exceeds 4 MiB)",
            input.len()
        ));
    }
    if backend.lock_session().poisoned {
        return backend_error("denied: backend poisoned, restart");
    }
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
    let opens_or_closes = service == super::COLLECTION
        && (method == "open_collection" || method == "close_collection");
    if !opens_or_closes && !backend.lock_session().collection_open {
        return backend_error(format!("denied: {full} (collection is not open)"));
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
                    backend.lock_session().collection_open = false;
                    return backend_error(format!("fsrs init failed: {err}"));
                }
                backend.lock_session().collection_open = true;
            }
            Err(err) => {
                backend.lock_session().collection_open = false;
                return backend_error(format!("fsrs init failed: open request: {err}"));
            }
        }
    }
    if service == super::COLLECTION && method == "close_collection" {
        backend.lock_session().collection_open = false;
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
        (super::COLLECTION, "undo" | "redo") => {
            session.presented.clear();
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
///
/// `data_dir` is stored canonicalized. A path may still use a symlink that is
/// a strict ancestor of that directory (`/var` → `/private/var` on macOS).
/// A symlink that is not on the way to `data_dir` stays outside.
pub fn require_inside_data_dir(path: &str, data_dir: &Path) -> Result<PathBuf, String> {
    let raw = Path::new(path);
    if !raw.is_absolute() {
        return Err(format!("path is not absolute: {path}"));
    }
    if has_parent_dir(raw) {
        return Err(format!("path contains '..': {path}"));
    }
    let normalized = lexical_normalize(raw);
    // `data_dir` is the canonical path stored when the backend opened.
    // It is not canonicalized again, so a later rename of that directory
    // does not move the check.
    let base = lexical_normalize(data_dir);
    let lexical_ok =
        is_strict_child(&normalized, &base) || rewritten_ancestor_is_child(&normalized, &base);
    if !lexical_ok {
        return Err(format!("path is outside data_dir: {path}"));
    }
    let resolved = resolve_existing_prefix(&normalized)?;
    if !is_strict_child(&resolved, &base) {
        return Err(format!("path escapes data_dir: {path}"));
    }
    Ok(resolved)
}

/// True when `path` is a child of `data_dir` after following symlinks that
/// are strict ancestors of `data_dir`. A symlink whose target is `data_dir`
/// itself is not followed.
fn rewritten_ancestor_is_child(path: &Path, data_dir: &Path) -> bool {
    let Some(rewritten) = rewrite_ancestor_symlinks(path, data_dir) else {
        return false;
    };
    is_strict_child(&rewritten, data_dir)
}

fn rewrite_ancestor_symlinks(path: &Path, data_dir: &Path) -> Option<PathBuf> {
    let mut resolved = PathBuf::new();
    let mut inside = false;
    for component in path.components() {
        match component {
            Component::RootDir => resolved.push(component),
            Component::Normal(name) => {
                if inside {
                    resolved.push(name);
                    continue;
                }
                let next = resolved.join(name);
                if metadata_exists(&next).is_none() {
                    return None;
                }
                let canon = next.canonicalize().ok()?;
                if data_dir.starts_with(&canon) && canon != data_dir {
                    resolved = canon;
                    continue;
                }
                if canon == data_dir && !is_symlink(&next) {
                    resolved = canon;
                    inside = true;
                    continue;
                }
                return None;
            }
            Component::Prefix(_) | Component::CurDir | Component::ParentDir => return None,
        }
    }
    Some(resolved)
}

/// `Path::exists` follows symlinks, so a dangling link looks missing.
/// `symlink_metadata` reports the link itself.
fn metadata_exists(path: &Path) -> Option<std::fs::Metadata> {
    std::fs::symlink_metadata(path).ok()
}

fn is_symlink(path: &Path) -> bool {
    std::fs::symlink_metadata(path)
        .map(|meta| meta.file_type().is_symlink())
        .unwrap_or(false)
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
    while metadata_exists(&cursor).is_none() {
        let Some(name) = cursor.file_name() else {
            return Err(format!("path has no existing ancestor: {}", path.display()));
        };
        let name = PathBuf::from(name);
        cursor.pop();
        missing = if missing.as_os_str().is_empty() {
            name
        } else {
            name.join(missing)
        };
        if cursor.as_os_str().is_empty() {
            return Err(format!("path has no existing ancestor: {}", path.display()));
        }
    }
    let canonical = cursor
        .canonicalize()
        .map_err(|err| format!("{}: {err}", cursor.display()))?;
    if missing.as_os_str().is_empty() {
        Ok(canonical)
    } else {
        Ok(canonical.join(missing))
    }
}
