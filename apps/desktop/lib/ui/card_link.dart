// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:hatto_desktop/effect/open_url.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as hp;

import '../state/open_url_policy.dart';

/// Opens [raw] only when it is https. Other schemes are ignored.
///
/// Rendering does not call this. A card calls it from the link's tap handler.
/// [raw] is one URI, not a shell command line.
Future<bool> openCardLink(
  String raw,
  Future<void> Function(Uri url) open,
) async {
  if (!isHttpsUrl(raw)) {
    return false;
  }
  await open(Uri.parse(raw));
  return true;
}

/// Card HTML as text and tappable links.
///
/// `<script>` and `<iframe>` are not executed. Their text is not shown.
/// Only an https link does anything, and only after a tap.
class CardHtmlView extends StatelessWidget {
  const CardHtmlView({
    super.key,
    required this.html,
    this.openUrl = openExternalUrl,
  });

  final String html;
  final Future<void> Function(Uri url) openUrl;

  @override
  Widget build(BuildContext context) {
    final fragment = hp.parseFragment(html);
    final links = <dom.Element>[];
    void walk(dom.Node node) {
      for (final child in node.nodes) {
        if (child is! dom.Element) {
          continue;
        }
        final name = child.localName;
        if (name == 'script' || name == 'iframe' || name == 'style') {
          continue;
        }
        if (name == 'a') {
          links.add(child);
        }
        walk(child);
      }
    }

    walk(fragment);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final link in links)
          TextButton(
            onPressed: () {
              final href = link.attributes['href'] ?? '';
              openCardLink(href, openUrl);
            },
            child: Text(link.text),
          ),
      ],
    );
  }
}
