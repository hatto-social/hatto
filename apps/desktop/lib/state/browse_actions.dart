// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Browse actions (state layer; effects go through AnkiApi). Suspend toggle follows Anki: all selected suspended -> unsuspend, else suspend.
import '../engine/anki_api.dart';

enum SuspendAction { suspend, unsuspend }

/// Pure rule: unsuspend only when the selection is non-empty and EVERY selected card is suspended.
SuspendAction decideSuspendToggle({required int total, required int suspended}) =>
    total > 0 && suspended == total ? SuspendAction.unsuspend : SuspendAction.suspend;

class BrowseActions {
  BrowseActions(this.api);
  final FlowApi api;

  /// Reads state with Search (`cid:.. is:suspended`), then suspends or unsuspends. Returns null for an empty selection.
  Future<SuspendAction?> toggleSuspend(Iterable<int> ids) async {
    final u = ids.toSet().toList();
    if (u.isEmpty) return null;
    final act = decideSuspendToggle(total: u.length, suspended: await api.countSuspended(u));
    if (act == SuspendAction.unsuspend) { await api.unsuspendCards(u); } else { await api.suspendCards(u); }
    return act;
  }
}
