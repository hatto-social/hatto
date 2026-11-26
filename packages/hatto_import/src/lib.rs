// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! E pipeline for one desktop `.apkg` import.
//!
//! This crate copies the file into `import/raw`, imports it into an E
//! collection under `import/e/<id>/`, normalizes guids with the I1 functions,
//! and writes `import/staged/<id>.apkg`. It does not accept a resident
//! collection handle, and the only package import it performs is into E.
//! Guid derivation uses [`hatto_card_contract::IMPORT_NS`], never the batch id.

mod channel;
mod cleanup;
mod error;
mod paths;
mod pipeline;
mod preset;

pub use cleanup::{
    remove_import_batch, scan_import_folders, scan_prepared_batches, BatchIntent, ImportScan,
};
pub use error::ImportError;
pub use hatto_card_contract::{Class, NoteFacts, Plan};
pub use paths::{
    e_collection_path, e_directory_path, e_media_db_path, e_media_directory_path,
    is_import_batch_id, raw_apkg_path, staged_apkg_path,
};
pub use pipeline::{
    facts_from_stored_note, finish_import, prepare_import, stage_import, ImportLimits,
    PendingImport, PrefetchedLookup, PreparedImport, ResidentLookup, StageOutput,
};

#[cfg(test)]
mod harness;
#[cfg(test)]
mod tests_import;
#[cfg(test)]
mod tests_lint;
#[cfg(test)]
mod tests_paths;
