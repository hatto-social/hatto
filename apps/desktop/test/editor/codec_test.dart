// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/editor/field_codec.dart';
import 'package:hatto_desktop/editor/corpus.dart';

void main() {
  test('codec round trip over Anki corpus', () {
    final sb = StringBuffer();
    var exact = 0, domEq = 0, lost = 0, opaque = 0;
    corpus.forEach((name, html) {
      final segs = parseField(html);
      final out = serializeField(segs);
      final isExact = out == html;
      final isDom = canon(out) == canon(html);
      final hasRaw = segs.any((s) => s.kind == TokenKind.raw);
      if (isExact) exact++; if (isDom) domEq++; if (!isDom) lost++; if (hasRaw) opaque++;
      sb.writeln('${isExact ? 'EXACT' : isDom ? 'DOMEQ' : 'DIFF '} ${hasRaw ? 'RAW ' : '    '}$name');
      if (!isExact) { sb.writeln('    in : $html'); sb.writeln('    out: $out'); sb.writeln('    segs: $segs'); }
    });
    sb.writeln('TOTAL ${corpus.length} exact=$exact domEquivalent=$domEq diff=$lost withOpaqueRaw=$opaque');
    final out = Directory('test_out/evidence')..createSync(recursive: true);
    File('${out.path}/b-codec-roundtrip.txt').writeAsStringSync(sb.toString());
    print(sb);
  });
}
