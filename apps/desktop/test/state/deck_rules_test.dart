// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Deck list rules: empty Default hidden when other decks exist.
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/engine/anki_api.dart';
import 'package:hatto_desktop/state/deck_view.dart';

DeckTreeNode node(int id, String name, {int total = 0, bool collapsed = false, List<DeckTreeNode> kids = const []}) =>
  DeckTreeNode(deckId: Int64(id), name: name, collapsed: collapsed, children: kids)..totalIncludingChildren = total;

void main() {
  group('visibleDeckRows (pure)', () {
    test('empty Default is hidden when another deck exists', () {
      final root = DeckTreeNode(children: [node(1, 'Default'), node(2, '한국어')]);
      expect(visibleDeckRows(root).map((n) => n.name), ['한국어']);
    });
    test('Default stays visible when it is the only deck, or when it has cards', () {
      expect(visibleDeckRows(DeckTreeNode(children: [node(1, 'Default')])).map((n) => n.name), ['Default']);
      expect(visibleDeckRows(DeckTreeNode(children: [node(1, 'Default', total: 3), node(2, 'B')])).map((n) => n.name), ['Default', 'B']);
    });
    test('collapsed parents hide children; expanded show them', () {
      final kid = node(3, 'A::B');
      expect(visibleDeckRows(DeckTreeNode(children: [node(2, 'A', collapsed: true, kids: [kid])])).map((n) => n.name), ['A']);
      expect(visibleDeckRows(DeckTreeNode(children: [node(2, 'A', kids: [kid])])).map((n) => n.name), ['A', 'A::B']);
    });
  });

}
