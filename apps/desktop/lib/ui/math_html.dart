// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// TeX in card HTML (reviewer + card preview ONLY; the editor keeps plain text). Decision 2026-11-19 (Gina/Justin):
//   inline \( .. \) and display \[ .. \] are rendered with flutter_math_fork 0.7.4; `$ .. $` is NEVER math;
//   on a parse/build failure the original text (with its delimiters) is shown raw.
import 'package:flutter/widgets.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'dart:convert' show HtmlEscape, HtmlEscapeMode;
import 'package:html/parser.dart' as hp;

class MathSpan {
  const MathSpan(this.tex, this.raw, this.display);
  final String tex, raw; final bool display;
}

/// Entity-decoded TeX body with tags (<br>, <div> ...) flattened to spaces. Null when nothing is left.
String? _cleanTex(String body) {
  final withSpaces = body.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' ');
  final t = (hp.parseFragment(withSpaces).text ?? '').replaceAll('\u00a0', ' ').trim();
  return t.isEmpty ? null : t;
}

/// Finds math spans in an HTML string. Returns (start, end, span) triples in order; no overlap.
///
/// A single left-to-right scan. An unclosed `\(` or `\[` advances past the
/// opener instead of asking a reluctant regex to rescan the rest of the string.
List<(int, int, MathSpan)> findMath(String html) {
  final out = <(int, int, MathSpan)>[];
  var i = 0;
  while (i < html.length) {
    final open = html.indexOf(r'\', i);
    if (open < 0 || open + 1 >= html.length) break;
    final marker = html[open + 1];
    if (marker != '(' && marker != '[') {
      i = open + 1;
      continue;
    }
    final closer = marker == '(' ? r'\)' : r'\]';
    final end = html.indexOf(closer, open + 2);
    if (end < 0) {
      i = open + 2;
      continue;
    }
    final display = marker == '[';
    final tex = _cleanTex(html.substring(open + 2, end));
    if (tex != null) {
      final rawText = (hp.parseFragment(html.substring(open, end + 2)).text ?? '').trim();
      out.add((open, end + 2, MathSpan(tex, rawText, display)));
    }
    i = end + 2;
  }
  return out;
}

const _attr = HtmlEscape(HtmlEscapeMode.attribute);

/// Replaces math spans with hatto-math elements (rendered by CardView). Everything else, including `$..$`, is untouched.
String preprocessMath(String html) {
  final spans = findMath(html); if (spans.isEmpty) return html;
  final b = StringBuffer(); var at = 0;
  for (final (s, e, m) in spans) {
    b.write(html.substring(at, s));
    final el = '<hatto-math data-display="${m.display ? 1 : 0}" data-tex="${_attr.convert(m.tex)}" data-raw="${_attr.convert(m.raw)}"></hatto-math>';
    b.write(m.display ? '<div style="text-align:center">$el</div>' : el);
    at = e;
  }
  b.write(html.substring(at));
  return b.toString();
}

/// The widget for one span; falls back to the raw text on any parse/build error.
Widget buildMath(String tex, String raw, bool display, TextStyle style, {Key? key}) =>
  Math.tex(tex, key: key, mathStyle: display ? MathStyle.display : MathStyle.text, textStyle: style, onErrorFallback: (_) => Text(raw, key: const ValueKey('math-raw'), style: style));
