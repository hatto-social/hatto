// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

/// License and source placeholder. The source archive itself is not built here.
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('라이선스')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('AGPL-3.0-or-later'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                showLicensePage(
                  context: context,
                  applicationName: 'Hatto',
                  applicationLegalese: 'AGPL-3.0-or-later',
                );
              },
              child: const Text('오픈소스 고지'),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (context) {
                    return AlertDialog(
                      content: const Text('이 버전의 소스 링크는 아직 없습니다.'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('닫기'),
                        ),
                      ],
                    );
                  },
                );
              },
              child: const Text('소스 코드'),
            ),
          ],
        ),
      ),
    );
  }
}
