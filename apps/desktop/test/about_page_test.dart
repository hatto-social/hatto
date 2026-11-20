// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/editor/anki_ui.dart';
import 'package:hatto_desktop/engine/anki_api.dart';
import 'package:hatto_desktop/engine/engine.dart';
import 'package:hatto_desktop/state/app_controller.dart';
import 'package:hatto_desktop/ui/shell.dart';
import 'package:path/path.dart' as p;
import 'package:rslib_bridge/rslib_bridge.dart';

void main() {
  testWidgets('the learning shell opens the about page', (tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final root = Directory.systemTemp.createTempSync('hatto-about');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final dataDir = p.join(root.path, 'collection');
    Directory(dataDir).createSync();
    late final Engine engine;
    late final FlowApi api;
    late final AppController app;
    await tester.runAsync(() async {
      await initRslibBridge();
      engine = await Engine.open(dataDir: dataDir);
      api = FlowApi(engine);
      await api.openCollection(dataDir);
      app = AppController(api);
      await app.refreshDecks();
    });
    addTearDown(() async {
      await api.closeCollection();
      engine.close();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: MainShell(app: app, colors: AnkiColors.light),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('nav-about')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final license = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(license.data, contains('GNU AFFERO GENERAL PUBLIC LICENSE'));
  });
}
