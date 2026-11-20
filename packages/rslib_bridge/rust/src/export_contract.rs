// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Desktop apkg export arguments.
//!
//! One builder so the developer CLI does not copy the four flags. The
//! desktop profile's `validate_export` in `policy/validators.rs` checks the
//! same values. This file does not change that validator: PR #20 deletes
//! `validate_export`, and the allowlist row stays as it is on main.

use anki_proto::generic;
use anki_proto::import_export;

/// `with_scheduling` for a desktop v0 package. Scheduling stays out.
pub const WITH_SCHEDULING: bool = false;

/// `with_deck_configs` for a desktop v0 package. Deck configs stay out.
pub const WITH_DECK_CONFIGS: bool = false;

/// `with_media` for a desktop v0 package. Media is included.
pub const WITH_MEDIA: bool = true;

/// `legacy` for a desktop v0 package. Packages are not legacy.
pub const LEGACY: bool = false;

/// The four export options from the desktop contract.
pub fn anki_package_export_options() -> import_export::ExportAnkiPackageOptions {
    import_export::ExportAnkiPackageOptions {
        with_scheduling: WITH_SCHEDULING,
        with_deck_configs: WITH_DECK_CONFIGS,
        with_media: WITH_MEDIA,
        legacy: LEGACY,
    }
}

/// Export request for one deck. The limit is that deck id, not the whole
/// collection and not a card-id list.
pub fn anki_package_export_request(
    out_path: String,
    deck_id: i64,
) -> import_export::ExportAnkiPackageRequest {
    import_export::ExportAnkiPackageRequest {
        out_path,
        options: Some(anki_package_export_options()),
        limit: Some(import_export::ExportLimit {
            limit: Some(import_export::export_limit::Limit::DeckId(deck_id)),
        }),
    }
}

/// Import options that match [anki_package_export_options]: no scheduling
/// and no deck configs. Used when a package built by this builder is read
/// back. Not a desktop-profile request.
pub fn anki_package_import_options() -> import_export::ImportAnkiPackageOptions {
    import_export::ImportAnkiPackageOptions {
        merge_notetypes: false,
        update_notes: import_export::ImportAnkiPackageUpdateCondition::Never as i32,
        update_notetypes: import_export::ImportAnkiPackageUpdateCondition::Never as i32,
        with_scheduling: WITH_SCHEDULING,
        with_deck_configs: WITH_DECK_CONFIGS,
    }
}

/// Empty protobuf used by `new_deck` and similar calls. Exposed so the CLI
/// does not depend on a second copy of the "no arguments" message.
pub fn empty_message() -> generic::Empty {
    generic::Empty {}
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn export_request_is_the_desktop_contract() {
        let request = anki_package_export_request("/tmp/out.apkg".into(), 7);
        let options = request.options.unwrap();
        assert!(!options.with_scheduling);
        assert!(!options.with_deck_configs);
        assert!(options.with_media);
        assert!(!options.legacy);
        match request.limit.unwrap().limit.unwrap() {
            import_export::export_limit::Limit::DeckId(id) => assert_eq!(id, 7),
            other => panic!("limit is not one deck: {other:?}"),
        }
    }
}
