// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_mobile/main.dart';
import 'package:hatto_mobile/third_party_licenses.dart';

void main() {
  testWidgets('main screen opens the about page', (tester) async {
    await tester.pumpWidget(const HattoApp());
    expect(find.text('라이선스'), findsOneWidget);

    await tester.tap(find.text('라이선스'));
    await tester.pumpAndSettle();

    expect(find.text('라이선스 전문 보기'), findsOneWidget);
    expect(find.text('오픈소스 고지'), findsOneWidget);
    expect(
      find.text('Copyright © 2026 Hatto Social contributors'),
      findsOneWidget,
    );
  });

  testWidgets('about page shows the legal notices and the full license', (
    tester,
  ) async {
    await tester.pumpWidget(const HattoApp());
    await tester.tap(find.text('라이선스'));
    await tester.pumpAndSettle();

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
    expect(find.text('소스 코드'), findsOneWidget);

    await tester.tap(find.text('라이선스 전문 보기'));
    await tester.pumpAndSettle();
    final license = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(license.data, contains('GNU AFFERO GENERAL PUBLIC LICENSE'));
    expect(license.data, contains('15. Disclaimer of Warranty.'));

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('소스 코드'));
    await tester.pumpAndSettle();
    expect(find.text('개발 빌드: 커밋 (없음)'), findsOneWidget);
    expect(find.text('닫기'), findsOneWidget);
  });

  test(
    'bundled notices register Anki separately from third-party crates',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final entries = await loadBundledLicenseEntries();
      final anki = entries.where(
        (entry) => entry.packages.contains('anki 0.0.0'),
      );
      expect(anki, hasLength(1));
      expect(anki.single.packages, contains('anki_proto 0.0.0'));
      expect(anki.single.packages, isNot(contains('anki_proto_gen 0.0.0')));
      expect(anki.single.text, contains('NOTICE.md'));

      final ring = entries.where(
        (entry) => entry.packages.contains('ring 0.17.14'),
      );
      expect(ring, isNotEmpty);

      final gradle = entries.where(
        (entry) => entry.packages.any((package) => package.contains(':')),
      );
      expect(gradle, isNotEmpty);
      final icons = entries.where(
        (entry) => entry.packages.contains('MaterialIcons-Regular.otf'),
      );
      expect(icons, hasLength(1));
      expect(icons.single.text, contains('Creative Commons Attribution 4.0'));
    },
  );
}
