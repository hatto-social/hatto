// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/editor/anki_ui.dart';
import 'package:hatto_desktop/effect/import_progress_model.dart';
import 'package:hatto_desktop/ui/common.dart';
import 'package:hatto_desktop/ui/import_copy.dart';
import 'package:hatto_desktop/ui/import_progress.dart';
import 'package:hatto_store/hatto_store.dart';

void main() {
  test('T-I5-J3 stage mapping is synchronous', () {
    final token = ImportCancellationToken();
    final model = ImportProgressModel(token);
    expect(model.view.label, kStageChecking);
    expect(model.view.cancelEnabled, isTrue);

    model.onPhase(ImportPhase.afterReconcile);
    expect(model.view.label, kStageChecking);
    expect(model.view.cancelEnabled, isTrue);

    model.onPhase(ImportPhase.afterStage);
    expect(model.view.label, kStageComparing);
    expect(model.view.cancelEnabled, isTrue);
    expect(model.pastIntent, isFalse);

    model.onPhase(ImportPhase.afterNoteMap);
    expect(model.view.label, kStageComparing);
    expect(model.view.cancelEnabled, isTrue);

    model.onPhase(ImportPhase.afterResidentLookup);
    expect(model.view.label, kStageComparing);
    expect(model.view.cancelEnabled, isTrue);

    model.onPhase(ImportPhase.afterFinish);
    expect(model.view.label, kStageComparing);
    expect(model.view.cancelEnabled, isTrue);
    expect(model.pastIntent, isFalse);

    model.onPhase(ImportPhase.afterPre);
    expect(model.view.cancelEnabled, isTrue);

    model.onPhase(ImportPhase.afterIntent);
    expect(model.view.label, kStageApplying);
    expect(model.view.cancelEnabled, isFalse);
    expect(model.view.blockedNote, kCancelBlocked);
    expect(model.pastIntent, isTrue);
    model.requestCancel();
    expect(token.isCancelled, isFalse);

    model.onPhase(ImportPhase.afterArchive);
    expect(model.view.label, kStageApplying);
    expect(model.view.cancelEnabled, isFalse);
  });

  testWidgets(
    'T-I5-J3 the dialog shows the three labels and disables cancel at afterIntent',
    (tester) async {
      final model = ImportProgressModel(ImportCancellationToken());
      await tester.pumpWidget(
        MaterialApp(
          home: AnkiTheme(
            colors: AnkiColors.light,
            child: ImportProgressDialog(
              model: model,
              onCancel: model.requestCancel,
            ),
          ),
        ),
      );

      expect(find.text(kStageChecking), findsOneWidget);
      expect(
        tester
            .widget<QtPush>(find.byKey(const ValueKey('import-cancel')))
            .onTap,
        isNotNull,
      );
      expect(find.text(kCancelBlocked), findsNothing);

      model.onPhase(ImportPhase.afterStage);
      await tester.pump();
      expect(find.text(kStageComparing), findsOneWidget);
      expect(find.text(kStageChecking), findsNothing);
      expect(
        tester
            .widget<QtPush>(find.byKey(const ValueKey('import-cancel')))
            .onTap,
        isNotNull,
      );

      model.onPhase(ImportPhase.afterNoteMap);
      await tester.pump();
      expect(find.text(kStageComparing), findsOneWidget);

      model.onPhase(ImportPhase.afterResidentLookup);
      await tester.pump();
      expect(find.text(kStageComparing), findsOneWidget);

      final pop = tester
          .element(find.byKey(const ValueKey('import-progress')))
          .findAncestorWidgetOfExactType<PopScope>();
      expect(pop, isNotNull);
      expect(pop!.canPop, isFalse);

      model.onPhase(ImportPhase.afterFinish);
      await tester.pump();
      expect(find.text(kStageComparing), findsOneWidget);
      expect(
        tester
            .widget<QtPush>(find.byKey(const ValueKey('import-cancel')))
            .onTap,
        isNotNull,
      );

      model.onPhase(ImportPhase.afterIntent);
      expect(model.view.cancelEnabled, isFalse);
      await tester.pump();
      expect(find.text(kStageApplying), findsOneWidget);
      expect(find.text(kCancelBlocked), findsOneWidget);
      expect(
        tester
            .widget<QtPush>(find.byKey(const ValueKey('import-cancel')))
            .onTap,
        isNull,
      );

      await tester.tap(find.byKey(const ValueKey('import-cancel')));
      await tester.pump();
      expect(model.token.isCancelled, isFalse);
    },
  );

  testWidgets(
    'cancel in stage 1 sets the token and does not close the dialog',
    (tester) async {
      final model = ImportProgressModel(ImportCancellationToken());
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () {
                  showDialog<void>(
                    context: context,
                    barrierDismissible: false,
                    builder: (context) => AnkiTheme(
                      colors: AnkiColors.light,
                      child: ImportProgressDialog(
                        model: model,
                        onCancel: model.requestCancel,
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final route = ModalRoute.of(
        tester.element(find.byKey(const ValueKey('import-progress'))),
      );
      expect(route, isNotNull);
      expect(route!.barrierDismissible, isFalse);

      await tester.tap(find.byKey(const ValueKey('import-cancel')));
      await tester.pump();
      expect(model.token.isCancelled, isTrue);
      expect(find.byKey(const ValueKey('import-progress')), findsOneWidget);

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.pop();
      await tester.pump();
      expect(find.byKey(const ValueKey('import-progress')), findsOneWidget);
    },
  );
}
