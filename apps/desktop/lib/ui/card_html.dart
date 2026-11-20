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

/// Cap on [String.length]. That count is UTF-16 code units, not UTF-8 bytes.
/// A field past this length, or nested or tagged past the caps below, is shown
/// as plain text so layout cannot recurse without a bound.
const kCardHtmlMaxBytes = 1 << 20;
const kCardHtmlMaxDepth = 64;
const kCardHtmlMaxTags = 2000;

/// How much of an over-cap field is scanned when turning it into plain text.
const kCardHtmlPlainPrefix = 4000;

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
      _hasControl(src) ||
      _hasControl(decoded) ||
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

bool _hasControl(String value) {
  for (final unit in value.codeUnits) {
    if (unit < 0x20 || unit == 0x7f) return true;
  }
  return false;
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

/// How many times the depth check parsed HTML. A repeated call with the same
/// string does not increment this.
int cardHtmlParseCount = 0;

String? _fallbackHtml;
bool _fallbackValue = false;

/// Depth of the parsed tree. An unmatched closer such as `</b>` does not
/// reduce the depth of an open `<div>`, which is what the HTML parser does.
/// The walk is iterative and returns as soon as the depth passes the cap.
int cardHtmlTagDepth(String html) {
  cardHtmlParseCount++;
  final root = html_parser.parseFragment(html);
  final stack = <(dom.Node, int)>[];
  void pushChildren(dom.Node parent, int parentDepth) {
    final children = parent.nodes;
    for (var i = children.length - 1; i >= 0; i--) {
      final child = children[i];
      final depth = child is dom.Element ? parentDepth + 1 : parentDepth;
      stack.add((child, depth));
    }
  }

  pushChildren(root, 0);
  var maxDepth = 0;
  while (stack.isNotEmpty) {
    final (node, depth) = stack.removeLast();
    if (depth > maxDepth) maxDepth = depth;
    if (maxDepth > kCardHtmlMaxDepth) return maxDepth;
    pushChildren(node, depth);
  }
  return maxDepth;
}

bool _tooManyTags(String html) {
  var count = 0;
  for (var i = 0; i < html.length; i++) {
    if (html.codeUnitAt(i) != 0x3c) continue;
    count++;
    if (count > kCardHtmlMaxTags) return true;
  }
  return false;
}

bool _fallbackUncached(String html) {
  if (html.length > kCardHtmlMaxBytes || _tooManyTags(html)) return true;
  return cardHtmlTagDepth(html) > kCardHtmlMaxDepth;
}

/// True when [html] must be shown as plain text. The tag-count cap runs before
/// any parse. The decision for one string is remembered so a rebuild does not
/// parse it again.
bool cardHtmlNeedsPlainFallback(String html) {
  if (html == _fallbackHtml) return _fallbackValue;
  final value = _fallbackUncached(html);
  _fallbackHtml = html;
  _fallbackValue = value;
  return value;
}

/// Drops the remembered fallback decision. Widget tests call this so one case
/// cannot satisfy the next.
void resetCardHtmlFallbackCache() {
  _fallbackHtml = null;
  _fallbackValue = false;
  cardHtmlParseCount = 0;
}

/// The first [max] code units of [value]. A cut that would keep only the high
/// half of a surrogate pair drops that unit too.
String cardHtmlLimit(String value, int max) {
  if (value.length <= max) return value;
  var end = max;
  final unit = value.codeUnitAt(end - 1);
  if (unit >= 0xD800 && unit <= 0xDBFF) end--;
  return value.substring(0, end);
}

/// Plain text for an over-cap field. Only the first [kCardHtmlPlainPrefix]
/// code units are scanned, and a tag cannot contain another `<`, so a long
/// run of `<` does not rescan the rest of the string.
String cardHtmlFallbackText(String html) {
  final slice = cardHtmlLimit(html, kCardHtmlPlainPrefix);
  return slice.replaceAll(RegExp(r'<[^<>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Counts characters [CssRules.parse] looks at. Tests use it to reject a
/// quadratic scan of a stylesheet that contains no `{`.
class CssScan {
  int steps = 0;
}

String _withoutCssComments(String css, CssScan? scan) {
  final buffer = StringBuffer();
  final n = css.length;
  var i = 0;
  while (i < n) {
    scan?.steps++;
    if (i + 1 < n && css.codeUnitAt(i) == 0x2f && css.codeUnitAt(i + 1) == 0x2a) {
      final end = css.indexOf('*/', i + 2);
      if (end < 0) {
        scan?.steps += n - (i + 2);
        break;
      }
      scan?.steps += end - (i + 2);
      i = end + 2;
      continue;
    }
    buffer.writeCharCode(css.codeUnitAt(i));
    i++;
  }
  return buffer.toString();
}

class CssRules {
  CssRules(this.rules);
  final List<(String, Map<String, String>)> rules;
  factory CssRules.parse(String css, {CssScan? scan}) {
    final source = _withoutCssComments(css, scan);
    final out = <(String, Map<String, String>)>[];
    final n = source.length;
    var i = 0;
    while (i < n) {
      final open = source.indexOf('{', i);
      if (open < 0) {
        scan?.steps += n - i;
        break;
      }
      scan?.steps += open - i + 1;
      final close = source.indexOf('}', open + 1);
      if (close < 0) {
        scan?.steps += n - (open + 1);
        break;
      }
      final nested = source.indexOf('{', open + 1);
      if (nested >= 0 && nested < close) {
        scan?.steps += nested - open;
        i = open + 1;
        continue;
      }
      scan?.steps += close - open;
      var selector = source.substring(i, open);
      final at = selector.lastIndexOf('@');
      if (at >= 0) selector = selector.substring(at + 1);
      if (selector.isNotEmpty) {
        final props = <String, String>{};
        for (final declaration in source.substring(open + 1, close).split(';')) {
          final colon = declaration.indexOf(':');
          if (colon < 0) continue;
          props[declaration.substring(0, colon).trim().toLowerCase()] =
              declaration.substring(colon + 1).trim().replaceAll('!important', '').trim();
        }
        for (final sel in selector.split(',')) {
          out.add((sel.trim(), props));
        }
      }
      i = close + 1;
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
      final text = cardHtmlFallbackText(html);
      final shown = cardHtmlLimit(text, 200);
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
