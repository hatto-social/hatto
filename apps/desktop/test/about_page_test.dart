// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/app.dart';
import 'package:hatto_desktop/state/bootstrap_state.dart';

void main() {
  testWidgets('main menu opens the about page', (tester) async {
    await tester.pumpWidget(
      const HattoDesktopApp(state: BootstrapState.closed()),
    );
    await tester.tap(find.text('메뉴'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('라이선스'));
    await tester.pumpAndSettle();

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

    await tester.tap(find.text('라이선스 전문 보기'));
    await tester.pumpAndSettle();
    final license = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(license.data, contains('GNU AFFERO GENERAL PUBLIC LICENSE'));
  });
}
