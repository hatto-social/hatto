// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Deck list rules (pure): which rows are visible, and which auto-created parents must be expanded.
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

/// Names of auto-created ancestors for a new deck set: "A::B::C" created when only "A" existed -> {"A::B"} (and "A" when it was new too).
Set<String> autoCreatedParents(Set<String> before, Iterable<String> after) {
  final out = <String>{};
  for (final n in after) {
    if (before.contains(n)) continue;
    final parts = n.split('::');
    for (var i = 1; i < parts.length; i++) { final anc = parts.take(i).join('::'); if (!before.contains(anc)) out.add(anc); }
  }
  return out;
}
