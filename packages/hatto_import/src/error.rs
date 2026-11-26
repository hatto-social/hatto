// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

use std::fmt;

use anki_proto::backend::backend_error::Kind;

/// Failure of the E pipeline, a path check, or a folder scan.
#[derive(Debug)]
pub struct ImportError {
    message: String,
    kind: Option<i32>,
}

impl ImportError {
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            kind: None,
        }
    }

    pub(crate) fn from_backend(message: impl Into<String>, kind: i32) -> Self {
        Self {
            message: message.into(),
            kind: Some(kind),
        }
    }

    pub fn message(&self) -> &str {
        &self.message
    }

    /// rslib `NOT_FOUND_ERROR`. A deck-name callback maps this to "no deck".
    pub fn is_not_found(&self) -> bool {
        self.kind == Some(Kind::NotFoundError as i32)
    }
}

impl fmt::Display for ImportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for ImportError {}
