// How much visible text ends up hidden inside raw chips? (v0 contract: all out-of-scope elements are opaque atoms.)
import 'dart:convert';
import 'dart:io';
import 'package:editor_proto/field_codec.dart';
import 'package:html/parser.dart' as hp;

void main() {
  final seen = <String>{}; var rich = 0, withRaw = 0, mostlyHidden = 0, allHidden = 0, noOutsideText = 0;
  final tagCount = <String, int>{}; final tagHidden = <String, int>{};
  final corpusPath = Platform.environment['ANKI_FIELDS_JSONL'] ?? '/workspace/anki-html-usage/extract/all_fields.jsonl';
  final corpusFile = File(corpusPath);
  if (!corpusFile.existsSync()) {
    print('public-deck corpus absent ($corpusPath); chip stats skipped');
    return;
  }
  for (final line in corpusFile.readAsLinesSync()) {
    final t = (jsonDecode(line) as Map)['text'] as String;
    if (t.isEmpty || !seen.add(t)) continue;
    final a = analyzeField(t);
    if (!a.richOk) continue;
    rich++;
    var outside = 0, inside = 0; var hasRaw = false;
    for (final s in a.segs) {
      if (s.isToken && s.kind == TokenKind.raw) {
        hasRaw = true;
        final inner = hp.parseFragment(s.token!).text?.trim().length ?? 0; inside += inner;
        final m = RegExp(r'^<\s*([a-zA-Z0-9-]+)').firstMatch(s.token!); final tag = m?.group(1)?.toLowerCase() ?? (s.token!.startsWith('<!--') ? 'comment' : '?');
        tagCount[tag] = (tagCount[tag] ?? 0) + 1; if (inner > 0) tagHidden[tag] = (tagHidden[tag] ?? 0) + 1;
      } else if (!s.isToken) { outside += s.text.trim().length; }
    }
    if (!hasRaw) continue;
    withRaw++;
    if (inside > outside) mostlyHidden++;
    if (outside == 0 && inside > 0) allHidden++;
  }
  print('rich fields: $rich; with >=1 raw atom: $withRaw (${(100 * withRaw / rich).toStringAsFixed(2)}%)');
  print('  of those, more visible text inside chips than outside: $mostlyHidden; ALL text inside chips (nothing editable outside): $allHidden (${(100 * allHidden / rich).toStringAsFixed(2)}% of rich fields)');
  final top = tagCount.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  print('top raw tags (atoms / atoms carrying text): ${top.take(12).map((e) => '${e.key}=${e.value}/${tagHidden[e.key] ?? 0}').join(', ')}');
}
