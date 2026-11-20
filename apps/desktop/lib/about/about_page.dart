// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:hatto_legal/hatto_legal.dart';

import '../effect/open_url.dart';

/// License screen. The source button uses the desktop process opener.
class AboutPage extends StatelessWidget {
  const AboutPage({super.key, this.openUrl});

  /// Widget tests pass a fake. A running app uses [openExternalUrl].
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
