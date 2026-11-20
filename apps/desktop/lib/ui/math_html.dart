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

/// Counts characters the math scan looks at. Tests use it to check that a
/// longer unclosed input does not do quadratic work.
class MathScan {
  int steps = 0;
}

/// Finds math spans in an HTML string. Returns (start, end, span) triples in order; no overlap.
///
/// One left-to-right pass. After a search for `\)` or `\]` fails, no later
/// opener of that kind looks past that point again.
List<(int, int, MathSpan)> findMath(String html, {MathScan? scan}) {
  final out = <(int, int, MathSpan)>[];
  final limit = html.length;
  var parenDead = limit;
  var bracketDead = limit;
  var i = 0;
  while (i < limit) {
    scan?.steps++;
    if (html.codeUnitAt(i) != 0x5c) {
      i++;
      continue;
    }
    if (i + 1 >= limit) break;
    final marker = html.codeUnitAt(i + 1);
    final inline = marker == 0x28;
    final display = marker == 0x5b;
    if (!inline && !display) {
      i++;
      continue;
    }
    final dead = inline ? parenDead : bracketDead;
    if (i + 2 >= dead) {
      i += 2;
      continue;
    }
    final close = inline ? 0x29 : 0x5d;
    var j = i + 2;
    var found = -1;
    while (j + 1 < dead) {
      scan?.steps++;
      if (html.codeUnitAt(j) == 0x5c && html.codeUnitAt(j + 1) == close) {
        found = j;
        break;
      }
      j++;
    }
    if (found < 0) {
      if (inline) {
        parenDead = i + 2;
      } else {
        bracketDead = i + 2;
      }
      i += 2;
      continue;
    }
    final tex = _cleanTex(html.substring(i + 2, found));
    if (tex != null) {
      final rawText = (hp.parseFragment(html.substring(i, found + 2)).text ?? '').trim();
      out.add((i, found + 2, MathSpan(tex, rawText, display)));
    }
    i = found + 2;
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
