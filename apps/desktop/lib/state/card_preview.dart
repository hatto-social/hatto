// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Rendered card sides (question/answer HTML + CSS + [sound:] file names), shared by the reviewer and the browse preview.
// rslib renders the templates; we only split the AV tags out.
import '../engine/anki_api.dart';

class RenderedCard {
  RenderedCard(this.questionHtml, this.answerHtml, this.css, this.avQuestion, this.avAnswer);
  final String questionHtml, answerHtml, css;
  /// File names from [sound:NAME] in order (index = the idx of the play button), '(tts)' for TTS tags.
  final List<String> avQuestion, avAnswer;

  static Future<RenderedCard> load(FlowApi api, int cardId, {bool browser = false}) async {
    final r = await api.renderCard(cardId, browser: browser);
    final qa = await api.extractAvTags(r.questionNodes.map((n) => n.text).join(), true);
    final aa = await api.extractAvTags(r.answerNodes.map((n) => n.text).join(), false);
    return RenderedCard(qa.text, aa.text, r.css,
      [for (final t in qa.avTags) t.hasSoundOrVideo() ? t.soundOrVideo : '(tts)'], [for (final t in aa.avTags) t.hasSoundOrVideo() ? t.soundOrVideo : '(tts)']);
  }

  /// Play-button id ('q:0' / 'a:1') -> file name, or null when out of range.
  String? soundFor(String id) {
    final p = id.split(':'); if (p.length != 2) return null;
    final i = int.tryParse(p[1]); final l = p[0] == 'q' ? avQuestion : (p[0] == 'a' ? avAnswer : null);
    return (l == null || i == null || i < 0 || i >= l.length) ? null : l[i];
  }
}
