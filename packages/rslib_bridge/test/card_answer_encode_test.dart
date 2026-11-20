// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:rslib_bridge/src/anki_api/proto_encode.dart';

void main() {
  test('the wrapper fills answered_at_millis', () {
    final clock = DateTime.utc(2026, 1, 2, 3, 4, 5);
    final filled = encodeCardAnswer(
      cardId: 1,
      currentState: const [1],
      newState: const [2],
      rating: 2,
      millisecondsTaken: 1000,
      now: clock,
    );
    final explicit = encodeCardAnswer(
      cardId: 1,
      currentState: const [1],
      newState: const [2],
      rating: 2,
      millisecondsTaken: 1000,
      answeredAtMillis: clock.millisecondsSinceEpoch,
    );
    expect(filled, explicit);

    final supplied = encodeCardAnswer(
      cardId: 1,
      currentState: const [1],
      newState: const [2],
      rating: 2,
      millisecondsTaken: 1000,
      answeredAtMillis: 5,
      now: clock,
    );
    expect(supplied, isNot(filled));
  });
}
