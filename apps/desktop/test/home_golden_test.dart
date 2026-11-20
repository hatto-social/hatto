// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

@Tags(['golden'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/app.dart';
import 'package:hatto_desktop/state/bootstrap_state.dart';

void main() {
  testWidgets('home uses the committed OFL fonts', (tester) async {
    await tester.pumpWidget(
      const HattoDesktopApp(
        state: BootstrapState(
          opened: true,
          markerPresent: true,
          message: '컬렉션이 열려 있습니다. FSRS 초기화 마커가 있습니다.',
        ),
      ),
    );
    await expectLater(
      find.byType(HattoDesktopApp),
      matchesGoldenFile('goldens/home.png'),
    );
  });
}
