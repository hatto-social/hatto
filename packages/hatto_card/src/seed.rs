// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! The seed package and the notetype alias table.
//!
//! A fresh rslib collection gives its stock notetypes random ids, so two
//! exports of one deck carried two different `Basic` ids and the second import
//! skipped every note as `conflicting` (F3). `export` now imports
//! `seed/hatto-seed.apkg` first. Import keeps notetype ids, so every export
//! uses the same ids. See `seed/make_seed.py` for why the file must never be
//! regenerated, and contract §16 for the names.

/// The committed seed. Never regenerate it: a rebuilt seed has the same
/// notetype ids but new field and template ids, and rslib treats it as a
/// different notetype.
pub(crate) const SEED: &[u8] = include_bytes!("../seed/hatto-seed.apkg");

/// Size of the committed seed in bytes.
#[cfg(test)]
pub(crate) const SEED_LEN: usize = 57_328;

/// SHA-256 of the committed seed. A different seed fails `cargo test`.
#[cfg(test)]
pub(crate) const SEED_SHA256: &str =
    "8e79098baaa42c4f429cc906d2508ffda24536b857addcd443a6b27bb1accdae";

/// (name accepted in deck.json, seed notetype name, seed notetype id).
///
/// Ids are 1767225600000 + n, 2026-01-01T00:00:00Z in milliseconds. The
/// seed's notetype names are the second column. The stock names stay valid
/// input so an existing deck.json does not change.
pub(crate) const ALIASES: [(&str, &str, i64); 5] = [
    ("Basic", "Hatto Basic", 1_767_225_600_001),
    (
        "Basic (and reversed card)",
        "Hatto Basic (and reversed card)",
        1_767_225_600_002,
    ),
    (
        "Basic (optional reversed card)",
        "Hatto Basic (optional reversed card)",
        1_767_225_600_003,
    ),
    (
        "Basic (type in the answer)",
        "Hatto Basic (type in the answer)",
        1_767_225_600_004,
    ),
    ("Cloze", "Hatto Cloze", 1_767_225_600_005),
];

/// The notetype name `export` looks up. A stock name maps to its seed name,
/// a seed name maps to itself, anything else is returned as written (for
/// example `Image Occlusion`, which the seed does not carry and whose id is
/// not fixed).
pub(crate) fn canonical_notetype(name: &str) -> &str {
    for (stock, hatto, _) in ALIASES {
        if name == stock || name == hatto {
            return hatto;
        }
    }
    name
}

/// True when `name` is a stock or Hatto spelling in [`ALIASES`].
pub(crate) fn is_seed_notetype(name: &str) -> bool {
    ALIASES
        .iter()
        .any(|(stock, hatto, _)| name == *stock || name == *hatto)
}

/// Cloze is the only seed notetype whose first field must contain a deletion.
pub(crate) fn is_cloze_notetype(name: &str) -> bool {
    canonical_notetype(name) == "Hatto Cloze"
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use sha2::{Digest, Sha256};

    use super::*;

    #[test]
    fn seed_is_the_committed_file() {
        let digest = Sha256::digest(SEED);
        let hex: String = digest.iter().map(|byte| format!("{byte:02x}")).collect();
        assert_eq!(
            hex, SEED_SHA256,
            "seed/hatto-seed.apkg changed. Never regenerate it (see seed/make_seed.py)."
        );
        assert_eq!(SEED.len(), SEED_LEN);
    }

    #[test]
    fn stock_and_hatto_names_map_to_the_hatto_name() {
        assert_eq!(canonical_notetype("Basic"), "Hatto Basic");
        assert_eq!(canonical_notetype("Hatto Basic"), "Hatto Basic");
        assert_eq!(canonical_notetype("Cloze"), "Hatto Cloze");
        assert_eq!(canonical_notetype("Hatto Cloze"), "Hatto Cloze");
        assert_eq!(
            canonical_notetype("Basic (type in the answer)"),
            "Hatto Basic (type in the answer)"
        );
        // Not in the seed: unchanged.
        assert_eq!(canonical_notetype("Image Occlusion"), "Image Occlusion");
        assert_eq!(canonical_notetype("basic"), "basic");
        assert_eq!(canonical_notetype(""), "");
        assert!(is_seed_notetype("Basic"));
        assert!(is_seed_notetype("Hatto Basic"));
        assert!(is_seed_notetype("Cloze"));
        assert!(is_seed_notetype("Hatto Cloze"));
        assert!(!is_seed_notetype("Image Occlusion"));
        assert!(!is_seed_notetype("basic"));
        assert!(!is_seed_notetype(""));
        assert!(is_cloze_notetype("Cloze"));
        assert!(is_cloze_notetype("Hatto Cloze"));
        assert!(!is_cloze_notetype("Basic"));
        assert!(!is_cloze_notetype("Hatto Basic"));
    }

    #[test]
    fn table_has_five_distinct_names_and_ids() {
        let stock: HashSet<_> = ALIASES.iter().map(|row| row.0).collect();
        let hatto: HashSet<_> = ALIASES.iter().map(|row| row.1).collect();
        let ids: HashSet<_> = ALIASES.iter().map(|row| row.2).collect();
        assert_eq!((stock.len(), hatto.len(), ids.len()), (5, 5, 5));
        for (stock, hatto, id) in ALIASES {
            assert_eq!(hatto, format!("Hatto {stock}"));
            assert!((1_767_225_600_001..=1_767_225_600_005).contains(&id));
        }
    }
}
