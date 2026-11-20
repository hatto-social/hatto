// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Deck list rules: auto-created parents expanded; empty Default hidden when other decks exist.
import 'dart:io';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/engine/anki_api.dart';
import 'package:rslib_bridge/rslib_bridge.dart';
import 'package:hatto_desktop/engine/engine.dart';
import 'package:hatto_desktop/state/app_controller.dart';
import 'package:hatto_desktop/state/deck_view.dart';

DeckTreeNode node(int id, String name, {int total = 0, bool collapsed = false, List<DeckTreeNode> kids = const []}) =>
  DeckTreeNode(deckId: Int64(id), name: name, collapsed: collapsed, children: kids)..totalIncludingChildren = total;

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await initRslibBridge();
  });
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

  test('autoCreatedParents', () {
    expect(autoCreatedParents({'A'}, {'A', 'A::B::C', 'A::B'}), {'A::B'});
    expect(autoCreatedParents({}, {'X::Y::Z', 'X::Y', 'X'}), {'X', 'X::Y'});
    expect(autoCreatedParents({'A', 'A::B'}, {'A', 'A::B', 'A::B::C'}), isEmpty);
  });

  group('AppController (real rslib)', () {
    late Directory tmp;
    setUp(() async { tmp = await Directory.systemTemp.createTemp('hf_deck_'); });
    tearDown(() async { try { await tmp.delete(recursive: true); } catch (_) {} });

    test('createDeck is denied while AddDeck stays closed', () async {
      final e = await Engine.open(langs: ['en'], dataDir: tmp.path); final api = FlowApi(e); await api.openCollection(tmp.path, fsrsDefault: false);
      final app = AppController(api);
      expect(
        app.createDeck('한국어::기초::회화'),
        throwsA(isA<BackendException>()),
        reason: 'AddDeck has no consumer in the learning PR',
      );
      expect(
        api.setDeckCollapsed(1, true),
        throwsA(isA<BackendException>()),
        reason: 'SetDeckCollapsed is not in the 87-call contract',
      );
      await api.closeCollection(); e.close();
    });
  });
}
