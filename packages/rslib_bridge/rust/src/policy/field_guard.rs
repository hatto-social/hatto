// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Reject-only field checks for new note content.
//!
//! This is not a sanitizer and not a proof that the field is safe. A field
//! that fails any rule is denied. A field that passes is still untrusted.

const FIELD_MAX_BYTES: usize = 512 * 1024;

const ACTIVE_TAGS: &[&str] = &[
    "script", "iframe", "object", "embed", "link", "meta", "base", "form", "input", "button",
    "textarea", "select", "frame", "applet", "style",
];

const URL_ATTRS: &[&str] = &["href", "src", "xlink:href", "action", "formaction"];

pub(crate) fn check_field(field: &str) -> Result<(), String> {
    if field.len() > FIELD_MAX_BYTES {
        return Err("field is larger than 512 KiB".into());
    }
    if field.chars().any(is_forbidden_control) {
        return Err("field contains a control character".into());
    }
    let lower = field.to_ascii_lowercase();
    for name in ACTIVE_TAGS {
        if has_start_tag(&lower, name) {
            return Err(format!("field contains <{name}"));
        }
    }
    for interior in tag_interiors(field) {
        if has_event_attr(&interior.to_ascii_lowercase()) {
            return Err("field contains an event attribute".into());
        }
        if dangerous_url(&interior) {
            return Err("field contains a dangerous url".into());
        }
        if bad_img_src(&interior) {
            return Err("field image src must be a plain media file name".into());
        }
    }
    if bad_sound(field) {
        return Err("field sound name must be a plain media file name".into());
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

pub(crate) fn check_deck_name(name: &str) -> Result<(), String> {
    let trimmed = name.trim();
    if trimmed.is_empty() || name.split("::").any(|part| part.is_empty()) {
        return Err("deck name is empty or has an empty segment".into());
    }
    if name.len() > 255 {
        return Err("deck name is longer than 255 bytes".into());
    }
    if name.chars().any(is_forbidden_control) {
        return Err("deck name contains a control character".into());
    }
    Ok(())
}

fn is_forbidden_control(c: char) -> bool {
    matches!(c as u32, 0x00..=0x08 | 0x0B | 0x0C | 0x0E..=0x1F | 0x7F)
}

fn has_start_tag(lower: &str, name: &str) -> bool {
    let bytes = lower.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'<' {
            let mut j = i + 1;
            if j < bytes.len() && bytes[j] == b'/' {
                j += 1;
            }
            while j < bytes.len() && bytes[j].is_ascii_whitespace() {
                j += 1;
            }
            if lower[j..].starts_with(name) {
                let end = j + name.len();
                let boundary = bytes.get(end).copied();
                if boundary.is_none_or(|b| !b.is_ascii_alphanumeric()) {
                    return true;
                }
            }
        }
        i += 1;
    }
    false
}

fn tag_interiors(html: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = html;
    while let Some(start) = rest.find('<') {
        rest = &rest[start + 1..];
        if let Some(end) = rest.find('>') {
            out.push(rest[..end].to_string());
            rest = &rest[end + 1..];
        } else {
            break;
        }
    }
    out
}

fn has_event_attr(lower_tag: &str) -> bool {
    let bytes = lower_tag.as_bytes();
    let mut i = 0;
    while i + 3 < bytes.len() {
        let boundary = i == 0 || !bytes[i - 1].is_ascii_alphanumeric();
        if boundary
            && bytes[i] == b'o'
            && bytes[i + 1] == b'n'
            && bytes[i + 2].is_ascii_alphabetic()
        {
            let mut j = i + 2;
            while j < bytes.len() && bytes[j].is_ascii_alphabetic() {
                j += 1;
            }
            while j < bytes.len() && bytes[j].is_ascii_whitespace() {
                j += 1;
            }
            if j < bytes.len() && bytes[j] == b'=' {
                return true;
            }
        }
        i += 1;
    }
    false
}

fn dangerous_url(tag: &str) -> bool {
    for name in URL_ATTRS {
        for value in attr_values(tag, name) {
            let decoded = compact(&decode_entities(&value)).to_ascii_lowercase();
            if decoded.starts_with("javascript:")
                || decoded.starts_with("vbscript:")
                || decoded.starts_with("data:")
                || decoded.starts_with("file:")
            {
                return true;
            }
        }
    }
    false
}

fn bad_img_src(tag: &str) -> bool {
    let lower = tag.to_ascii_lowercase();
    let name = lower.trim_start();
    if !(name.starts_with("img")
        && name
            .as_bytes()
            .get(3)
            .is_none_or(|b| !b.is_ascii_alphanumeric()))
    {
        return false;
    }
    for value in attr_values(tag, "src") {
        let decoded = compact(&decode_entities(&value));
        if decoded.is_empty()
            || decoded.contains('/')
            || decoded.contains('\\')
            || decoded.contains("..")
            || decoded.contains(':')
        {
            return true;
        }
    }
    false
}

fn bad_sound(field: &str) -> bool {
    let lower = field.to_ascii_lowercase();
    let mut offset = 0;
    while let Some(rel) = lower[offset..].find("[sound:") {
        let start = offset + rel + "[sound:".len();
        let Some(end_rel) = lower[start..].find(']') else {
            break;
        };
        let name = &field[start..start + end_rel];
        if name.is_empty()
            || name.contains('/')
            || name.contains('\\')
            || name.contains("..")
            || name.contains(':')
        {
            return true;
        }
        offset = start + end_rel + 1;
    }
    false
}

fn attr_values(tag: &str, name: &str) -> Vec<String> {
    let lower = tag.to_ascii_lowercase();
    let mut out = Vec::new();
    let mut from = 0;
    while let Some(rel) = lower[from..].find(name) {
        let abs = from + rel;
        let before_ok = abs == 0 || !lower.as_bytes()[abs - 1].is_ascii_alphanumeric();
        let mut j = abs + name.len();
        let bytes = lower.as_bytes();
        if before_ok {
            while j < bytes.len() && bytes[j].is_ascii_whitespace() {
                j += 1;
            }
            if j < bytes.len() && bytes[j] == b'=' {
                j += 1;
                while j < bytes.len() && bytes[j].is_ascii_whitespace() {
                    j += 1;
                }
                if j < tag.len() {
                    out.push(read_value(&tag[j..]));
                }
            }
        }
        from = abs + name.len();
    }
    out
}

fn read_value(rest: &str) -> String {
    let mut chars = rest.chars();
    match chars.next() {
        Some(q @ '"' | q @ '\'') => rest[q.len_utf8()..]
            .split(q)
            .next()
            .unwrap_or("")
            .to_string(),
        Some(_) => rest
            .split(|c: char| c.is_whitespace())
            .next()
            .unwrap_or("")
            .to_string(),
        None => String::new(),
    }
}

fn compact(value: &str) -> String {
    value.chars().filter(|c| !c.is_whitespace()).collect()
}

fn decode_entities(input: &str) -> String {
    let mut out = String::new();
    let mut rest = input;
    while let Some(start) = rest.find('&') {
        out.push_str(&rest[..start]);
        rest = &rest[start + 1..];
        if let Some(end) = rest.find(';') {
            if let Some(ch) = entity_char(&rest[..end]) {
                out.push(ch);
                rest = &rest[end + 1..];
                continue;
            }
        }
        out.push('&');
    }
    out.push_str(rest);
    out
}

fn entity_char(body: &str) -> Option<char> {
    match body.to_ascii_lowercase().as_str() {
        "amp" => Some('&'),
        "lt" => Some('<'),
        "gt" => Some('>'),
        "quot" => Some('"'),
        "apos" => Some('\''),
        "colon" => Some(':'),
        hex if hex.starts_with("#x") => u32::from_str_radix(&hex[2..], 16)
            .ok()
            .and_then(char::from_u32),
        dec if dec.starts_with('#') => dec[1..].parse::<u32>().ok().and_then(char::from_u32),
        _ => None,
    }
}
