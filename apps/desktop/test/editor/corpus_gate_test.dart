// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Gates (a)/(b) over real public-deck Anki field HTML (/workspace/anki-html-usage/extract/all_fields.jsonl).
// CORPUS_LIMIT=n limits for quick dev runs. Writes ../evidence/b-v0-gates.txt.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/editor/field_codec.dart';
import 'package:hatto_desktop/editor/corpus.dart';
import 'package:hatto_desktop/editor/proto_editable.dart';

class _Chars { final List<String> ch = []; final List<int> f = []; final List<String?> c = []; final List<String?> atom = []; }
final bool kWs = Platform.environment['WS'] == '1';
_Chars flat(String html) {
  final r = _Chars();
  for (final s in parseField(html, specialsAsTokens: false, wsNormalize: kWs)) {
    if (s.isToken) { r.ch.add('\uFFFC'); r.f.add(0); r.c.add(null); r.atom.add(s.token); continue; }
    final fl = (s.bold ? 1 : 0) | (s.italic ? 2 : 0) | (s.underline ? 4 : 0) | (s.sup ? 8 : 0) | (s.sub ? 16 : 0);
    for (var i = 0; i < s.text.length; i++) { r.ch.add(s.text[i]); r.f.add(fl); r.c.add(s.color); r.atom.add(null); }
  }
  return r;
}

void main() {
  test('v0 gates (a) unedited save == original bytes, (b) edited save DOM-equivalent + raw atoms byte-identical', () {
    final limit = int.tryParse(Platform.environment['CORPUS_LIMIT'] ?? '') ?? 1 << 30;
    final seen = <String>{}; final fields = <String>[];
    for (final e in corpus.values) { if (seen.add(e)) fields.add(e); }
    final nSpike = fields.length;
    final f = File('/workspace/anki-html-usage/extract/all_fields.jsonl');
    var rawLines = 0, empty = 0;
    if (!f.existsSync()) {
      // The public-deck extract is not in this repo. The embedded corpus still runs.
    } else {
    for (final line in f.readAsLinesSync()) {
      rawLines++;
      final t = (jsonDecode(line) as Map)['text'] as String;
      if (t.isEmpty) { empty++; continue; }
      if (seen.add(t)) fields.add(t);
      if (fields.length >= limit) break;
    }
    }
    final sb = StringBuffer();
    var rich = 0, srcMode = 0, strictSrc = 0, a_fail = 0, b1_fail = 0, b1_strictEq = 0, b2_fail = 0, b2_n = 0, atomsTotal = 0, withRaw = 0;
    final reasons = <String, int>{}; final fails = <String>[];
    var idx = 0;
    for (final html in fields) {
      idx++;
      final an = analyzeField(html, wsNormalize: kWs);
      final st = analyzeField(html, strict: true, wsNormalize: kWs);
      if (!st.richOk) strictSrc++;
      // gate (a)
      final c = FieldController(html, wsNormalize: kWs);
      if (c.save() != html || c.dirty) { a_fail++; if (fails.length < 10) fails.add('A $idx ${jsonEncode(html)}'); }
      if (!an.richOk) { srcMode++; for (final r in an.reasons.toSet()) { reasons[r] = (reasons[r] ?? 0) + 1; } if (c.isRich) { a_fail++; fails.add('mode mismatch $idx'); } continue; }
      rich++;
      final orig = flat(html);
      final origAtoms = orig.atom.whereType<String>().toList();
      atomsTotal += origAtoms.length; if (origAtoms.any((a) => !a.startsWith('<img'))) withRaw++;
      // (b1) forced re-encode
      final enc = c.toHtml();
      final atomsOut = flat(enc).atom.whereType<String>().toList();
      final eq = canonFlat(enc, collapseNewlines: kWs) == canonFlat(html, collapseNewlines: kWs);
      if (canon(enc) == canon(html)) b1_strictEq++;
      if (!eq || atomsOut.join('\u0000') != origAtoms.join('\u0000')) { b1_fail++; if (fails.length < 25) fails.add('B1 $idx in=${jsonEncode(html)} out=${jsonEncode(enc)}'); }
      // (b2) real edit through the controller: type 'X' at a pseudo-random caret + toggle bold on a range
      b2_n++;
      final n = c.text.length; final p = (idx * 7919) % (n + 1);
      c.value = TextEditingValue(text: c.text.replaceRange(p, p, 'X'), selection: TextSelection.collapsed(offset: p + 1));
      final s1 = (idx * 31) % (n + 1), e1 = s1 + ((idx * 13) % 6) + 1;
      c.selection = TextSelection(baseOffset: s1.clamp(0, c.text.length), extentOffset: e1.clamp(0, c.text.length));
      c.toggleMark(RK.bold);
      final out = c.save();
      final o2 = flat(out);
      // expected from independent (codec-only) model
      final ex = _Chars();
      ex.ch..addAll(orig.ch)..insert(p, 'X'); ex.f..addAll(orig.f)..insert(p, p > 0 ? (orig.atom[p - 1] == null ? orig.f[p - 1] : 0) : (p < orig.f.length && orig.atom[p] == null ? orig.f[p] : 0));
      ex.c..addAll(orig.c)..insert(p, p > 0 ? (orig.atom[p - 1] == null ? orig.c[p - 1] : null) : (p < orig.c.length && orig.atom[p] == null ? orig.c[p] : null));
      ex.atom..addAll(orig.atom)..insert(p, null);
      final a2 = c.text.length; final ss = s1.clamp(0, a2), ee = e1.clamp(0, a2);
      if (ss < ee) {
        final idxs = [for (var i = ss; i < ee; i++) if (ex.atom[i] == null) i];
        if (idxs.isNotEmpty) { final on = idxs.every((i) => ex.f[i] & 1 != 0); for (final i in idxs) { ex.f[i] = on ? ex.f[i] & ~1 : ex.f[i] | 1; } }
      }
      final ok = o2.ch.join() == ex.ch.join() && o2.f.join(',') == ex.f.join(',') && o2.c.join(',') == ex.c.join(',') &&
          o2.atom.join('\u0000') == ex.atom.join('\u0000') && analyzeField(out, wsNormalize: kWs).richOk;
      if (!ok) { b2_fail++; if (fails.length < 40) fails.add('B2 $idx in=${jsonEncode(html)} out=${jsonEncode(out)} p=$p sel=$ss-$ee'); }
    }
    sb.writeln('corpus: spike corpus ${corpus.length} (+dedupe ${nSpike}), public-deck fields read: $rawLines lines, empty $empty, unique non-empty tested ${fields.length}');
    sb.writeln('open mode: rich=$rich  source-edit fallback=$srcMode (${(100 * srcMode / fields.length).toStringAsFixed(2)}%)  [strict-DOM canon would put $strictSrc (${(100 * strictSrc / fields.length).toStringAsFixed(2)}%) in source mode]');
    reasons.forEach((k, v) => sb.writeln('  fallback reason: $k = $v'));
    sb.writeln('rich fields containing out-of-scope raw atoms: $withRaw; atoms total: $atomsTotal');
    sb.writeln('GATE (a) unedited save == original bytes: ${fields.length - a_fail}/${fields.length} pass (fail $a_fail)');
    sb.writeln('GATE (b1) forced re-encode DOM(flat)-equivalent + raw atoms byte-identical: ${rich - b1_fail}/$rich pass (strict-DOM identical: $b1_strictEq/$rich)');
    sb.writeln('GATE (b2) edit(insert+bold toggle) via controller -> save == expected model, raw atoms byte-identical: ${b2_n - b2_fail}/$b2_n pass');
    for (final x in fails) { sb.writeln('  FAIL $x'); }
    Directory('test_out/evidence').createSync(recursive: true);
    File('test_out/evidence/b-v0-gates${kWs ? '-wsnormalize' : ''}${limit < (1 << 20) ? '-limit$limit' : ''}.txt').writeAsStringSync(sb.toString());
    print(sb);
    expect(a_fail, 0); expect(b1_fail, 0); expect(b2_fail, 0);
  }, timeout: const Timeout(Duration(minutes: 30)));
}
