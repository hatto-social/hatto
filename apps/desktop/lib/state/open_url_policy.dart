// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Whether [raw] is an https URL the desktop opener may pass to `open`
/// or `xdg-open`.
///
/// `http`, `file`, `javascript`, a missing scheme, and an empty string
/// are rejected. The host must be present, so `https:` alone is rejected.
bool isHttpsUrl(String raw) {
  if (raw.isEmpty) {
    return false;
  }
  final uri = Uri.tryParse(raw);
  if (uri == null || !uri.hasScheme) {
    return false;
  }
  return uri.scheme == 'https' && uri.host.isNotEmpty;
}
