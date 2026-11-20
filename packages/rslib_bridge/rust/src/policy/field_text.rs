// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Stateless field text checks.
//!
//! Size and ASCII control characters only. HTML such as script and iframe
//! is stored. The renderer is what must not execute it.

pub(crate) const FIELD_MAX_BYTES: usize = 512 * 1024;

pub(crate) fn check_field_text(field: &str) -> Result<(), String> {
    if field.len() > FIELD_MAX_BYTES {
        return Err("field is larger than 512 KiB".into());
    }
    if field.chars().any(is_forbidden_control) {
        return Err("field contains a control character".into());
    }
    Ok(())
}

pub(crate) fn check_tags(tags: &[String]) -> Result<(), String> {
    if tags.len() > 100 {
        return Err("too many tags".into());
    }
    for tag in tags {
        if tag.is_empty() || tag.chars().any(char::is_whitespace) {
            return Err("tag is empty or contains whitespace".into());
        }
        if tag.len() > 255 {
            return Err("tag is longer than 255 bytes".into());
        }
    }
    Ok(())
}

/// Lowercase hyphenated UUID whose version nibble is 4 or 5.
pub(crate) fn is_wrapper_guid(guid: &str) -> bool {
    let bytes = guid.as_bytes();
    if bytes.len() != 36 {
        return false;
    }
    for (index, byte) in bytes.iter().enumerate() {
        let ok = match index {
            8 | 13 | 18 | 23 => *byte == b'-',
            14 => *byte == b'4' || *byte == b'5',
            19 => matches!(*byte, b'8' | b'9' | b'a' | b'b'),
            _ => byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'),
        };
        if !ok {
            return false;
        }
    }
    true
}

fn is_forbidden_control(c: char) -> bool {
    matches!(c as u32, 0x00..=0x08 | 0x0B | 0x0C | 0x0E..=0x1F | 0x7F)
}
