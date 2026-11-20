// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Pure note HTML. This library must not import Flutter or `dart:ui`.
///
/// The editor port fills this in. The file exists so the layering test
/// has a pure-Dart library to check.
library;

/// Marker for the layering test. Not a sanitizer.
bool noteHtmlIsPureDart() => true;
