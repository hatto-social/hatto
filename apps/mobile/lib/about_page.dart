// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hatto_legal/hatto_legal.dart';

const _openUrlChannel = MethodChannel('social.hatto/open_url');

/// Opens [url] in the Android view handler. No extra plugin: the activity
/// sends `ACTION_VIEW`. Widget tests pass their own [OpenSourceUrl].
Future<void> openExternalUrl(Uri url) {
  return _openUrlChannel.invokeMethod<void>('open', url.toString());
}

/// License screen. A release build's source button opens the tag's release page.
class AboutPage extends StatelessWidget {
  const AboutPage({super.key, this.openUrl});

  final OpenSourceUrl? openUrl;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('라이선스')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [LegalNoticesSection(openUrl: openUrl ?? openExternalUrl)],
      ),
    );
  }
}
