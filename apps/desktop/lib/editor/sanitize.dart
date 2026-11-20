// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Clipboard HTML paste filter. Not a security boundary.
//
// Source-edit save does not call this. A field the user typed, including
// script and iframe, is stored unchanged apart from rslib's own NFC and
// control-character removal. Paste uses this to drop active content and
// media that arrived with a copied web page.
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
