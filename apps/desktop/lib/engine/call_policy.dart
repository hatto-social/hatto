// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Default-deny call policy + write-intent log for the prototype's Engine (mirrors the contract shape: name-keyed allowlist,
// a request validator on every allowed call, intent written before a write and closed after it).
// NOTE: the real contract list (85 -> 87 names) lives in the repo's rslib_bridge, not here. This is the SUBSET the prototype calls,
// plus the two names decided on 2026-11-19 (BuryOrSuspendCards, RestoreBuriedAndSuspendedCards). Keys are snake_case method names.
import 'package:protobuf/protobuf.dart';
import '../src/gen/anki/cards.pb.dart';
import '../src/gen/anki/import_export.pb.dart';
import '../src/gen/anki/scheduler.pb.dart';
import 'methods.g.dart';

class PolicyDenied implements Exception {
  PolicyDenied(this.rpc, this.reason);
  final String rpc, reason;
  @override String toString() => 'PolicyDenied($rpc: $reason)';
}

/// Returns a rejection reason, or null when the request is acceptable.
typedef Validator = String? Function(GeneratedMessage req);

String? _any(GeneratedMessage _) => null;

/// BuryOrSuspendCards: SUSPEND only; card_ids non-empty; note_ids empty. ("all cards exist" needs the collection: see AnkiApi.suspendCards.)
String? validateBuryOrSuspend(GeneratedMessage r) {
  final q = r as BuryOrSuspendCardsRequest;
  if (q.mode != BuryOrSuspendCardsRequest_Mode.SUSPEND) return 'only mode SUSPEND is allowed (${q.mode.name})';
  if (q.cardIds.isEmpty) return 'card_ids must not be empty';
  if (q.noteIds.isNotEmpty) return 'note_ids must be empty';
  if (q.cardIds.toSet().length != q.cardIds.length) return 'card_ids must be unique';
  return null;
}

String? validateRestore(GeneratedMessage r) {
  final q = r as CardIds;
  if (q.cids.isEmpty) return 'card ids must not be empty';
  if (q.cids.toSet().length != q.cids.length) return 'card ids must be unique';
  return null;
}

/// Export is fixed to cards + media: with_scheduling=false, with_deck_configs=false (2026-11-19).
String? validateExport(GeneratedMessage r) {
  final o = (r as ExportAnkiPackageRequest).options;
  if (o.withScheduling) return 'with_scheduling must be false';
  if (o.withDeckConfigs) return 'with_deck_configs must be false';
  return null;
}

String? validateQueued(GeneratedMessage r) {
  final q = r as GetQueuedCardsRequest;
  return q.fetchLimit > 50 ? 'fetch_limit must be <= 50' : null;
}

String? validateAnswer(GeneratedMessage r) {
  final q = r as CardAnswer;
  if (q.millisecondsTaken > 60000) return 'milliseconds_taken must be <= 60000';
  return null;
}

class CallPolicy {
  CallPolicy(this._allow, this.prototypeOnly);
  final Map<String, Validator> _allow;
  /// Names the prototype uses that the contract does NOT allow in v0 (demo/import/picker stubs). Listed so they stay visible.
  final Set<String> prototypeOnly;

  bool isAllowed(String name) => _allow.containsKey(name);
  int get size => _allow.length;
  Iterable<String> get names => _allow.keys;

  void check(Rpc rpc, GeneratedMessage req) {
    final v = _allow[rpc.name];
    if (v == null) throw PolicyDenied(rpc.name, 'not on the allowlist (default deny)');
    final why = v(req);
    if (why != null) throw PolicyDenied(rpc.name, why);
  }

  static const _prototypeOnlyNames = {'add_media_from_path', 'import_anki_package', 'export_anki_package', 'set_active_browser_columns'};

  /// Everything the prototype calls. Each entry has a validator (trivial ones are explicit `_any`, read-only or checked elsewhere).
  static final CallPolicy prototype = CallPolicy({
    // collection / decks
    'open_collection': _any, 'close_collection': _any, 'deck_tree': _any, 'new_deck': _any, 'add_deck': _any, 'rename_deck': _any, 'remove_decks': _any,
    'get_deck_names': _any, 'set_deck_collapsed': _any, 'set_current_deck': _any,
    // notetypes / notes
    'get_notetype_names': _any, 'get_field_names': _any, 'new_note': _any, 'add_note': _any, 'get_note': _any, 'update_notes': _any, 'defaults_for_adding': _any,
    'all_tags': _any, 'remove_notes': _any, 'cards_of_note': _any, 'note_fields_check': _any,
    // search / browse
    'search_cards': _any, 'search_notes': _any, 'browser_row_for_id': _any, 'get_card': _any,
    'bury_or_suspend_cards': validateBuryOrSuspend, 'restore_buried_and_suspended_cards': validateRestore,
    // study
    'get_queued_cards': validateQueued, 'describe_next_states': _any, 'answer_card': validateAnswer, 'render_existing_card': _any, 'extract_av_tags': _any,
    'get_undo_status': _any, 'undo': _any, 'congrats_info': _any, 'studied_today': _any, 'graphs': _any,
    // prototype-only (not in the v0 contract)
    for (final n in _prototypeOnlyNames) n: _any,
    'export_anki_package': validateExport,
  }, _prototypeOnlyNames);
}

enum IntentState { pending, done, failed }
class Intent { Intent(this.rpc, this.internal); final String rpc; final bool internal; IntentState state = IntentState.pending; }

/// In-memory stand-in for the contract's "write intent before, mark done after" rule (the durable journal is the repo core's job).
class IntentLog {
  final entries = <Intent>[];
  static const writes = {
    'add_deck', 'rename_deck', 'remove_decks', 'set_deck_collapsed', 'set_current_deck', 'add_note', 'update_notes', 'remove_notes', 'answer_card',
    'bury_or_suspend_cards', 'restore_buried_and_suspended_cards', 'import_anki_package', 'add_media_from_path', 'undo', 'update_deck_configs',
  };
  Intent? begin(String rpc, {bool internal = false}) {
    if (!writes.contains(rpc)) return null;
    final i = Intent(rpc, internal); entries.add(i); return i;
  }
  void done(Intent? i) => i?.state = IntentState.done;
  void fail(Intent? i) => i?.state = IntentState.failed;
}
