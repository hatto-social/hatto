// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/effect/engine_host.dart';
import 'package:hatto_desktop/ui/startup_failure.dart';
import 'package:hatto_store/hatto_store.dart';

void main() {
  test('already running, a newer schema, and lock errors use a dialog', () {
    expect(
      startupNotice(const AlreadyRunningException())?.body,
      alreadyRunningMessage,
    );
    expect(
      startupNotice(NewerSchemaException(2, 1))?.body,
      contains('newer than this app'),
    );
    expect(
      startupNotice(
        const InstanceLockException(
          'could not lock /tmp/hatto.lock (errno 13)',
        ),
      )?.body,
      contains('could not lock'),
    );
    expect(
      startupNotice(
        const InstanceLockException(
          'could not open /tmp/hatto.lock (errno 13)',
        ),
      )?.body,
      contains('could not open'),
    );
    expect(startupNotice(const SideDbException('some other failure')), isNull);
    expect(startupNotice(StateError('other')), isNull);
  });

  test('corrupt side database and collection open use the final copy', () {
    const sidePath = '/tmp/hatto/hatto.sqlite';
    const collectionPath = '/tmp/hatto/collection.anki2';
    final corrupt = startupNotice(
      SideDbCorruptException('malformed', path: sidePath),
    );
    expect(corrupt?.title, sideDbCorruptTitle);
    expect(corrupt?.body, sideDbCorruptBody);
    expect(corrupt?.path, sidePath);
    final missingSide = startupNotice(SideDbCorruptException('not a database'));
    expect(missingSide?.title, sideDbCorruptTitle);
    expect(missingSide?.path, isNull);

    final collection = startupNotice(
      CollectionOpenException(StateError('open'), path: collectionPath),
    );
    expect(collection?.title, collectionOpenTitle);
    expect(collection?.body, collectionOpenBody);
    expect(collection?.path, collectionPath);
    expect(collectionOpenTitle, contains('컬렉션'));
    expect(collectionOpenBody, contains('컬렉션'));
    expect(collectionOpenTitle, isNot(contains('컨렉션')));
    expect(collectionOpenBody, isNot(contains('컨렉션')));
    final missingCollection = startupNotice(
      CollectionOpenException(StateError('open')),
    );
    expect(missingCollection?.path, isNull);
  });

  testWidgets('the startup dialog shows the failure text', (tester) async {
    await tester.pumpWidget(
      const StartupFailureApp(
        notice: StartupNotice(body: alreadyRunningMessage),
        onDismiss: _noop,
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('startup-failure')), findsOneWidget);
    expect(find.text(alreadyRunningMessage), findsOneWidget);
    expect(find.text('확인'), findsOneWidget);
    expect(find.byKey(const ValueKey('startup-path')), findsNothing);
  });

  testWidgets('a corrupt side database shows the path when it is known', (
    tester,
  ) async {
    const path = '/abs/hatto.sqlite';
    await tester.pumpWidget(
      const StartupFailureApp(
        notice: StartupNotice(
          title: sideDbCorruptTitle,
          body: sideDbCorruptBody,
          path: path,
        ),
        onDismiss: _noop,
      ),
    );
    await tester.pump();
    expect(find.text(sideDbCorruptTitle), findsOneWidget);
    expect(find.text(sideDbCorruptBody), findsOneWidget);
    expect(find.text('$fileLocationPrefix$path'), findsOneWidget);
    expect(find.text('확인'), findsOneWidget);
  });

  testWidgets(
    'a corrupt side database omits the path line when it is unknown',
    (tester) async {
      await tester.pumpWidget(
        const StartupFailureApp(
          notice: StartupNotice(
            title: sideDbCorruptTitle,
            body: sideDbCorruptBody,
          ),
          onDismiss: _noop,
        ),
      );
      await tester.pump();
      expect(find.text(sideDbCorruptTitle), findsOneWidget);
      expect(find.text(sideDbCorruptBody), findsOneWidget);
      expect(find.byKey(const ValueKey('startup-path')), findsNothing);
    },
  );

  testWidgets('a collection open failure shows the path when it is known', (
    tester,
  ) async {
    const path = '/abs/collection.anki2';
    await tester.pumpWidget(
      const StartupFailureApp(
        notice: StartupNotice(
          title: collectionOpenTitle,
          body: collectionOpenBody,
          path: path,
        ),
        onDismiss: _noop,
      ),
    );
    await tester.pump();
    expect(find.text(collectionOpenTitle), findsOneWidget);
    expect(find.text(collectionOpenBody), findsOneWidget);
    expect(find.text('$fileLocationPrefix$path'), findsOneWidget);
  });

  testWidgets(
    'a collection open failure omits the path line when it is unknown',
    (tester) async {
      await tester.pumpWidget(
        const StartupFailureApp(
          notice: StartupNotice(
            title: collectionOpenTitle,
            body: collectionOpenBody,
          ),
          onDismiss: _noop,
        ),
      );
      await tester.pump();
      expect(find.text(collectionOpenTitle), findsOneWidget);
      expect(find.text(collectionOpenBody), findsOneWidget);
      expect(find.byKey(const ValueKey('startup-path')), findsNothing);
    },
  );
}

void _noop() {}
