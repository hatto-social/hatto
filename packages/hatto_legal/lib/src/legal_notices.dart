// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'build_info.dart';

/// Asset key for the AGPL text bundled with this package.
///
/// The bytes are the repository root `LICENSE`. `tools/license/check.sh`
/// checks that copy.
const bundledLicenseAsset = 'packages/hatto_legal/assets/LICENSE';

/// Loads the bundled AGPL text. Works offline; the file is in the asset
/// bundle, not fetched.
Future<String> loadBundledLicense() {
  return rootBundle.loadString(bundledLicenseAsset);
}

/// Copyright, warranty, and license actions for an About screen.
///
/// The host app keeps its own app bar and its own source-code control.
/// Desktop and mobile both use this widget.
class LegalNoticesSection extends StatelessWidget {
  const LegalNoticesSection({super.key, this.info = BuildInfo.environment});

  final BuildInfo info;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Copyright © 2026 Hatto Social contributors'),
        const SizedBox(height: 8),
        const Text('rslib: Copyright Ankitects Pty Ltd and contributors'),
        const SizedBox(height: 16),
        const Text('관련 법률이 허용하는 한도에서 이 프로그램은 어떠한 보증도 없이 제공됩니다.'),
        const SizedBox(height: 8),
        const Text(
          'THERE IS NO WARRANTY FOR THE PROGRAM, TO THE EXTENT PERMITTED BY APPLICABLE LAW.',
        ),
        const SizedBox(height: 16),
        const Text('이 앱은 AGPL-3.0-or-later 조건으로 수정·재배포할 수 있습니다'),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (context) => const FullLicensePage(),
              ),
            );
          },
          child: const Text('라이선스 전문 보기'),
        ),
        const SizedBox(height: 12),
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
      ],
    );
  }
}

/// Offline view of the bundled AGPL text.
class FullLicensePage extends StatefulWidget {
  const FullLicensePage({super.key});

  @override
  State<FullLicensePage> createState() => _FullLicensePageState();
}

class _FullLicensePageState extends State<FullLicensePage> {
  late final Future<String> _text = loadBundledLicense();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('라이선스 전문')),
      body: FutureBuilder<String>(
        future: _text,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Text('라이선스 전문을 열지 못했습니다.\n${snapshot.error}'),
            );
          }
          final text = snapshot.data;
          if (text == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return Scrollbar(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: SelectableText(text),
            ),
          );
        },
      ),
    );
  }
}
