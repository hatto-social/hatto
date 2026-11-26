// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Anki rslib protobuf channel and the desktop and import-E call policy.
//!
//! This is the only crate that links `anki` (rslib). `rslib_bridge` is the
//! flutter_rust_bridge cdylib and calls into this crate. `hatto_import` calls
//! this crate as well, so a process that loads the cdylib does not link a
//! second rslib.

pub mod api;
mod fsrs_init;
mod index;
mod policy;
mod resident;

pub use api::{
    anki_version, command, install_anki_logger, open_backend, open_backend_with_profile,
    open_desktop_backend, open_import_e_backend, prepare_runtime, service_method_index,
    smoke_open_collection, AnkiBackend, BridgeProfile, ProtoResponse, ServiceMethodIndex,
};
pub use resident::{read_resident_notes, ResidentNoteRow};
