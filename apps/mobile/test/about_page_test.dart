// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_mobile/main.dart';
import 'package:hatto_mobile/third_party_licenses.dart';

void main() {
  testWidgets('about page names the license and a source placeholder', (
    tester,
  ) async {
    await tester.pumpWidget(const HattoApp());
    await tester.tap(find.text('라이선스'));
    await tester.pumpAndSettle();

    expect(find.text('AGPL-3.0-or-later'), findsOneWidget);
    expect(find.text('오픈소스 고지'), findsOneWidget);
    expect(find.text('소스 코드'), findsOneWidget);

    await tester.tap(find.text('소스 코드'));
    await tester.pumpAndSettle();
    expect(find.text('이 버전의 소스 링크는 아직 없습니다.'), findsOneWidget);
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
