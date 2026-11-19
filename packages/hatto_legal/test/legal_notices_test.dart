// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_legal/hatto_legal.dart';

void main() {
  testWidgets('legal notices name copyright, warranty, and AGPL', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: LegalNoticesSection())),
    );

    expect(
      find.text('Copyright © 2026 Hatto Social contributors'),
      findsOneWidget,
    );
    expect(
      find.text('rslib: Copyright Ankitects Pty Ltd and contributors'),
      findsOneWidget,
    );
    expect(
      find.text('관련 법률이 허용하는 한도에서 이 프로그램은 어떠한 보증도 없이 제공됩니다.'),
      findsOneWidget,
    );
    expect(
      find.text(
        'THERE IS NO WARRANTY FOR THE PROGRAM, TO THE EXTENT PERMITTED BY APPLICABLE LAW.',
      ),
      findsOneWidget,
    );
    expect(
      find.text('이 앱은 AGPL-3.0-or-later 조건으로 수정·재배포할 수 있습니다'),
      findsOneWidget,
    );
    expect(find.text('오픈소스 고지'), findsOneWidget);
    expect(find.text('라이선스 전문 보기'), findsOneWidget);
  });

  testWidgets('full license view shows the bundled AGPL text', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: LegalNoticesSection())),
    );

    await tester.tap(find.text('라이선스 전문 보기'));
    await tester.pumpAndSettle();

    final license = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(license.data, contains('GNU AFFERO GENERAL PUBLIC LICENSE'));
    expect(license.data, contains('Version 3, 19 November 2007'));
    expect(license.data, contains('15. Disclaimer of Warranty.'));
    expect(
      license.data,
      contains('How to Apply These Terms to Your New Programs'),
    );
  });
}
