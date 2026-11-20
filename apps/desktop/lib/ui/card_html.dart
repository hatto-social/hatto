// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Card HTML renderer. There is no in-tree webview for Flutter Linux, so card HTML is rendered NATIVELY with flutter_widget_from_html_core
// plus a tiny CSS subset (type/.class selectors from the notetype CSS that rslib returns). Known gaps are listed in README.
// TeX \(..\) / \[..\] is rendered with flutter_math_fork (math_html.dart; `$..$` is not math; parse failure -> raw). JS, @font-face, :hover, nightMode rules are NOT supported -> ignored.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;
import 'math_html.dart';

/// Decode cap for a media image. A large source is resized while decoding.
const kCardImageCacheWidth = 1280;

/// Fields larger than this, or nested or tagged past the caps below, are shown
/// as plain text so layout cannot recurse without a bound.
const kCardHtmlMaxBytes = 1 << 20;
const kCardHtmlMaxDepth = 64;
const kCardHtmlMaxTags = 2000;

/// Network, asset, and data images are never loaded. A `file:` image is loaded
/// only when its canonical path is a regular file inside [mediaDir].
class CardHtmlFactory extends WidgetFactory {
  CardHtmlFactory(this.mediaDir);
  final String mediaDir;

  @override
  ImageProvider? imageProviderFromNetwork(String url) => null;

  @override
  ImageProvider? imageProviderFromAsset(String url) => null;

  @override
  ImageProvider? imageProviderFromDataUri(String dataUri) => null;

  @override
  ImageProvider? imageProviderFromFileUri(String url) {
    final file = fileInsideMedia(mediaDir, url);
    if (file == null) return null;
    return ResizeImage(FileImage(file), width: kCardImageCacheWidth);
  }
}

/// An `<img src>` may name one file in [mediaDir]. Separators, a scheme, or
/// `..` (including one percent-decoding of them) are rejected before the
/// filesystem is touched.
File? cardImageFile(String mediaDir, String src) {
  if (src.isEmpty) return null;
  String decoded;
  try {
    decoded = Uri.decodeComponent(src.trim());
  } catch (_) {
    return null;
  }
  if (decoded.isEmpty ||
      decoded.contains('/') ||
      decoded.contains('\\') ||
      decoded.contains(':') ||
      decoded.contains('..')) {
    return null;
  }
  return _openInsideMedia(mediaDir, decoded);
}

/// A `file:` URL or absolute path used by the HTML factory. The canonical
/// file must stay inside [mediaDir], so a symlink that leaves the folder is
/// rejected.
File? fileInsideMedia(String mediaDir, String url) {
  String path;
  try {
    final uri = Uri.parse(url);
    if (uri.hasScheme && uri.scheme != 'file') return null;
    path = uri.scheme == 'file' ? uri.toFilePath() : url;
  } catch (_) {
    return null;
  }
  if (path.isEmpty) return null;
  return _openInsideMedia(mediaDir, path);
}

File? _openInsideMedia(String mediaDir, String path) {
  if (mediaDir.isEmpty) return null;
  String mediaCanon;
  try {
    mediaCanon = Directory(mediaDir).resolveSymbolicLinksSync();
  } catch (_) {
    return null;
  }
  final full = p.isAbsolute(path) ? path : p.join(mediaCanon, path);
  final candidate = File(p.normalize(full));
  if (!candidate.existsSync()) return null;
  String resolved;
  try {
    resolved = candidate.resolveSymbolicLinksSync();
  } catch (_) {
    return null;
  }
  if (!p.isWithin(mediaCanon, resolved)) return null;
  if (FileSystemEntity.typeSync(resolved, followLinks: false) != FileSystemEntityType.file) {
    return null;
  }
  return File(resolved);
}

/// Depth of the parsed tree. An unmatched closer such as `</b>` does not
/// reduce the depth of an open `<div>`, which is what the HTML parser does.
int cardHtmlTagDepth(String html) {
  return _elementDepth(html_parser.parseFragment(html));
}

int _elementDepth(dom.Node node) {
  var maxDepth = 0;
  for (final child in node.nodes) {
    final nested = _elementDepth(child);
    final here = child is dom.Element ? nested + 1 : nested;
    if (here > maxDepth) maxDepth = here;
  }
  return maxDepth;
}

bool cardHtmlNeedsPlainFallback(String html) {
  return html.length > kCardHtmlMaxBytes ||
      cardHtmlTagDepth(html) > kCardHtmlMaxDepth ||
      '<'.allMatches(html).length > kCardHtmlMaxTags;
}

class CssRules {
  CssRules(this.rules);
  final List<(String, Map<String, String>)> rules;
  factory CssRules.parse(String css) {
    css = css.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
    final out = <(String, Map<String, String>)>[];
    for (final m in RegExp(r'([^{}@]+)\{([^{}]*)\}').allMatches(css)) {
      final props = <String, String>{};
      for (final d in m.group(2)!.split(';')) {
        final i = d.indexOf(':'); if (i < 0) continue;
        props[d.substring(0, i).trim().toLowerCase()] = d.substring(i + 1).trim().replaceAll('!important', '').trim();
      }
      for (final sel in m.group(1)!.split(',')) { out.add((sel.trim(), props)); }
    }
    return CssRules(out);
  }
  Map<String, String> forSelector(String sel) { final r = <String, String>{}; for (final (s, p) in rules) { if (s == sel) r.addAll(p); } return r; }
  /// supports `tag`, `.class`, `tag.class`, `#id` selectors (no combinators).
  Map<String, String> forElement(dom.Element e) {
    final r = <String, String>{}; final classes = e.classes;
    for (final (s, p) in rules) {
      if (s.isEmpty || s.contains(' ') || s.contains('>') || s.contains(':')) continue;
      final m = RegExp(r'^([a-zA-Z][a-zA-Z0-9]*)?((?:\.[\w-]+)*)(#[\w-]+)?$').firstMatch(s); if (m == null) continue;
      final tag = m.group(1); final cls = (m.group(2) ?? '').split('.').where((x) => x.isNotEmpty); final id = m.group(3);
      if (tag != null && tag != e.localName) continue;
      if (!cls.every(classes.contains)) continue;
      if (id != null && '#${e.id}' != id) continue;
      if (tag == null && cls.isEmpty && id == null) continue;
      r.addAll(p);
    }
    return r;
  }
}

Color? parseCssColor(String? v) {
  if (v == null) return null; v = v.trim().toLowerCase();
  const named = {'black': 0xff000000, 'white': 0xffffffff, 'blue': 0xff0000ff, 'red': 0xffff0000, 'green': 0xff008000, 'gray': 0xff808080, 'grey': 0xff808080};
  if (named.containsKey(v)) return Color(named[v]!);
  final h = RegExp(r'^#([0-9a-f]{3}|[0-9a-f]{6})$').firstMatch(v); if (h == null) return null;
  var x = h.group(1)!; if (x.length == 3) x = x.split('').map((c) => c + c).join();
  return Color(0xff000000 | int.parse(x, radix: 16));
}

class CardView extends StatelessWidget {
  const CardView({super.key, required this.html, required this.css, required this.mediaDir, this.dark = false, this.onPlay});
  final String html, css, mediaDir; final bool dark; final void Function(String file)? onPlay;

  static String preprocess(String html) => preprocessMath(html).replaceAllMapped(RegExp(r'\[anki:play:([qa]):(\d+)\]'), (m) => '<hatto-play data-side="${m.group(1)}" data-idx="${m.group(2)}"></hatto-play>');

  @override
  Widget build(BuildContext context) {
    final rules = CssRules.parse(css); final card = rules.forSelector('.card');
    var bg = parseCssColor(card['background-color']) ?? Colors.white; var fg = parseCssColor(card['color']) ?? Colors.black;
    if (dark && bg == Colors.white && fg == Colors.black) { bg = const Color(0xff2c2c2c); fg = const Color(0xfffcfcfc); } // Anki's .nightMode .card for the stock CSS
    final size = double.tryParse((card['font-size'] ?? '20px').replaceAll('px', '')) ?? 20;
    final align = switch (card['text-align']) { 'left' => TextAlign.left, 'right' => TextAlign.right, _ => TextAlign.center };
    final family = card['font-family']?.split(',').first.replaceAll(RegExp('["\']'), '').trim();
    final style = TextStyle(color: fg, fontSize: size, fontFamily: family == 'arial' || family == null ? 'Liberation Sans' : family, fontFamilyFallback: const ['NanumGothic'], height: 1.25);
    final alignName = switch (align) { TextAlign.left => 'left', TextAlign.right => 'right', _ => 'center' };
    if (cardHtmlNeedsPlainFallback(html)) {
      final text = html.replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
      final shown = text.length > 200 ? text.substring(0, 200) : text;
      return ColoredBox(color: bg, child: Text(shown, key: const ValueKey('card-html-fallback'), style: style));
    }
    final body = HtmlWidget('<div style="text-align:$alignName">${preprocess(html)}</div>', key: ValueKey(html), textStyle: style,
      factoryBuilder: () => CardHtmlFactory(mediaDir),
      customStylesBuilder: (e) {
        final s = <String, String>{...rules.forElement(e)};
        if (e.localName == 'hr') return {'margin': '14px 0', 'border-top': '1px solid ${dark ? '#888' : '#555'}'};
        if (s.isEmpty) return null;
        // keep only properties the widget supports; drop layout we do not emulate
        for (final bad in ['background', 'width', 'height', 'display', 'position', 'float', 'cursor', 'transition']) { s.remove(bad); }
        return s;
      },
      customWidgetBuilder: (e) {
        if (e.localName == 'img') {
          final src = e.attributes['src'] ?? '';
          final file = cardImageFile(mediaDir, src);
          return InlineCustomWidget(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640, maxHeight: 420),
              child: file == null
                  ? Container(key: const ValueKey('card-img-placeholder'), width: 64, height: 48, color: Colors.black12, alignment: Alignment.center, child: const Text('⚠', style: TextStyle(fontSize: 18)))
                  : Image.file(file, key: const ValueKey('card-img'), cacheWidth: kCardImageCacheWidth)));
        }
        if (e.localName == 'hatto-math') {
          final disp = e.attributes['data-display'] == '1';
          final w = buildMath(e.attributes['data-tex'] ?? '', e.attributes['data-raw'] ?? '', disp, style, key: ValueKey('math-${disp ? 'display' : 'inline'}'));
          return disp ? SizedBox(width: double.infinity, child: Center(child: w)) : InlineCustomWidget(child: w);
        }
        if (e.localName == 'hatto-play') {
          return InlineCustomWidget(child: _PlayStub(side: e.attributes['data-side'] ?? 'q', idx: int.tryParse(e.attributes['data-idx'] ?? '0') ?? 0, onPlay: onPlay));
        }
        return null;
      });
    return ColoredBox(color: bg, child: SizedBox.expand(child: SingleChildScrollView(child: Padding(padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
      child: DefaultTextStyle(style: style, textAlign: align, child: SizedBox(width: double.infinity, child: body))))));
  }
}

/// [sound:...] tags: a play button. `onPlay('q:0')` is resolved by the state layer (sound_gate) -> AudioService; nothing is played from here.
class _PlayStub extends StatelessWidget {
  const _PlayStub({required this.side, required this.idx, this.onPlay});
  final String side; final int idx; final void Function(String)? onPlay;
  @override
  Widget build(BuildContext context) => GestureDetector(key: ValueKey('play-$side-$idx'), onTap: () => onPlay?.call('$side:$idx'),
    child: Container(width: 30, height: 30, margin: const EdgeInsets.symmetric(horizontal: 4), decoration: const BoxDecoration(color: Color(0xffe8e8e8), shape: BoxShape.circle), child: const Icon(Icons.play_arrow, size: 20, color: Color(0xff333333))));
}
