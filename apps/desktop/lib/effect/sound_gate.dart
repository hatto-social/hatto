// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// [sound:NAME] gate (pure + file existence). Only a plain file NAME that exists directly in collection.media is playable.
// Rejected: empty, URLs / any scheme, absolute paths, path separators, "..", percent-encoded forms of those, control chars, non-files, symlinks.
import 'dart:io';
import 'package:path/path.dart' as p;

enum SoundReject { empty, url, absolute, separator, traversal, controlChar, notFound, notRegularFile }

class SoundResolution {
  const SoundResolution.ok(this.path) : reject = null;
  const SoundResolution.rejected(this.reject) : path = null;
  final String? path; final SoundReject? reject;
  bool get ok => path != null;
}

SoundReject? _checkName(String s) {
  if (s.isEmpty) return SoundReject.empty;
  if (s.contains(RegExp(r'[\x00-\x1f\x7f]'))) return SoundReject.controlChar;
  if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*:').hasMatch(s) || s.startsWith('//')) return SoundReject.url; // http:, file:, data:, C:, ...
  if (s.startsWith('/') || s.startsWith('\\') || s.startsWith('~')) return SoundReject.absolute;
  if (s.contains('/') || s.contains('\\')) return SoundReject.separator;
  if (s == '.' || s == '..' || s.contains('..')) return SoundReject.traversal;
  return null;
}

SoundResolution resolveSound(String name, String mediaDir) {
  final n = name.trim();
  var bad = _checkName(n);
  if (bad == null && n.contains('%')) { // one level of percent-decoding must not reveal anything forbidden
    String dec; try { dec = Uri.decodeFull(n); } catch (_) { return const SoundResolution.rejected(SoundReject.separator); }
    if (dec != n) bad = _checkName(dec) ?? (dec.contains('/') || dec.contains('\\') ? SoundReject.separator : null);
  }
  if (bad != null) return SoundResolution.rejected(bad);
  final full = p.join(mediaDir, n);
  if (p.dirname(p.normalize(full)) != p.normalize(mediaDir)) return const SoundResolution.rejected(SoundReject.separator);
  if (FileSystemEntity.isLinkSync(full)) return const SoundResolution.rejected(SoundReject.notRegularFile);
  final t = FileSystemEntity.typeSync(full, followLinks: false);
  if (t == FileSystemEntityType.notFound) return const SoundResolution.rejected(SoundReject.notFound);
  if (t != FileSystemEntityType.file) return const SoundResolution.rejected(SoundReject.notRegularFile);
  return SoundResolution.ok(full);
}
