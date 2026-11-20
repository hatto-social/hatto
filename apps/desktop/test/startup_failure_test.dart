// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/ui/startup_failure.dart';
import 'package:hatto_store/hatto_store.dart';

void main() {
  test('already running, a newer schema, and lock errors use a dialog', () {
    expect(
      startupDialogMessage(const AlreadyRunningException()),
      alreadyRunningMessage,
    );
    expect(
      startupDialogMessage(NewerSchemaException(2, 1)),
      contains('newer than this app'),
    );
    expect(
      startupDialogMessage(
        const InstanceLockException('could not lock /tmp/hatto.lock (errno 13)'),
      ),
      contains('could not lock'),
    );
    expect(
      startupDialogMessage(
        const InstanceLockException('could not open /tmp/hatto.lock (errno 13)'),
      ),
      contains('could not open'),
    );
    expect(
      startupDialogMessage(const SideDbException('some other failure')),
      isNull,
    );
    expect(startupDialogMessage(StateError('other')), isNull);
  });

  testWidgets('the startup dialog shows the failure text', (tester) async {
    await tester.pumpWidget(
      const StartupFailureApp(message: alreadyRunningMessage, onDismiss: _noop),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('startup-failure')), findsOneWidget);
    expect(find.text(alreadyRunningMessage), findsOneWidget);
    expect(find.text('확인'), findsOneWidget);
  });
}

void _noop() {}
