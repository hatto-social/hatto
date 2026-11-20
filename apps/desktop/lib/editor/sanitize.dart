// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// STAND-IN sanitizer. GAP: the Hatto repo has no Dart sanitizer yet (scope doc E9(다) specifies one for paste;
// anki rslib only has dead-code `ammonia::clean`). This stand-in is NOT a security boundary; it exists so the
// source-edit save path and the HTML paste path have a hook with the contract's shape:
//
// Product decision (2026-11-20): saving a field must preserve HTML byte-for-byte.
// `<script>` and `<iframe>` must NOT be stripped on save. The renderer is what
// must refuse to execute them. Do not treat this stand-in, or the Rust
// field_guard reject list, as the save rule until that decision is applied.
//   - returns the input UNCHANGED (byte-exact) when nothing needs removing,
//   - otherwise removes unsafe nodes/attrs and reports how many things were removed (never silent).
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as hp;

class SanitizeResult { SanitizeResult(this.html, this.removed); final String html; final int removed; }
typedef Sanitizer = SanitizeResult Function(String html);

const _dropTags = {'script', 'style', 'iframe', 'object', 'embed', 'link', 'meta', 'base', 'form', 'input', 'button', 'textarea', 'select', 'frame', 'frameset', 'applet'};
const _mediaTags = {'img', 'picture', 'source', 'video', 'audio', 'svg'};
final _jsUrl = RegExp(r'^[\s\x00-\x20]*(javascript|vbscript|data|file)\s*:', caseSensitive: false);

/// [allowImages]=true for the source-edit save path (the user's own field), false for pasted HTML (scope E9(다)).
Sanitizer sanitizer({bool allowImages = true}) => (String html) {
  final frag = hp.parseFragment(html);
  var removed = 0;
  void walk(dom.Node n) {
    for (final c in n.nodes.toList()) {
      if (c is dom.Element) {
        final t = c.localName!;
        if (_dropTags.contains(t) || (!allowImages && _mediaTags.contains(t))) { c.remove(); removed++; continue; }
        for (final k in c.attributes.keys.toList()) {
          final v = c.attributes[k.toString()] ?? '';
          final ks = k.toString().toLowerCase();
          if (ks.startsWith('on') || ((ks == 'href' || ks == 'src' || ks == 'xlink:href' || ks == 'action') && _jsUrl.hasMatch(v) && !(ks == 'src' && allowImages && v.toLowerCase().startsWith('data:image/'))) ||
              (!allowImages && (ks == 'srcset' || (ks == 'style' && v.toLowerCase().contains('url('))))) { c.attributes.remove(k); removed++; }
        }
        walk(c);
      }
    }
  }
  walk(frag);
  if (removed == 0) return SanitizeResult(html, 0);
  return SanitizeResult(frag.nodes.map((n) => n is dom.Element ? n.outerHtml : n is dom.Text ? n.data.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;') : n is dom.Comment ? '<!--${n.data}-->' : '').join(), removed);
};
