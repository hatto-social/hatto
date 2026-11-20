// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Deck list rules (pure): which rows are visible.
import '../engine/anki_api.dart';

/// Rows in display order. Collapsed decks hide their children. The empty built-in Default deck (id 1, no cards, no children)
/// is hidden whenever any other deck exists (2026-11-19); if it is the only deck it stays visible.
List<DeckTreeNode> visibleDeckRows(DeckTreeNode root) {
  final all = root.children;
  final otherExists = all.any((n) => !_isEmptyDefault(n));
  final out = <DeckTreeNode>[];
  void walk(DeckTreeNode n) { for (final c in n.children) { out.add(c); if (!c.collapsed) walk(c); } }
  walk(root);
  return out.where((n) => !(otherExists && _isEmptyDefault(n))).toList();
}
bool _isEmptyDefault(DeckTreeNode n) => n.deckId.toInt() == 1 && n.totalIncludingChildren == 0 && n.children.isEmpty;
