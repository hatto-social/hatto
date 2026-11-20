// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Typed facade over the rslib protobuf channel. Pure "effects" layer: every method = ONE backend call (or a trivial composition).
// Scheduling, storage, search, card rendering and import all happen inside rslib; nothing is reimplemented here.
import 'dart:io';
import 'package:fixnum/fixnum.dart';
import 'package:path/path.dart' as p;
import '../src/gen/anki/card_rendering.pb.dart';
import '../src/gen/anki/cards.pb.dart';
import '../src/gen/anki/collection.pb.dart';
import '../src/gen/anki/decks.pb.dart';
import '../src/gen/anki/generic.pb.dart' as g;
import '../src/gen/anki/import_export.pb.dart';
import '../src/gen/anki/media.pb.dart';
import '../src/gen/anki/notes.pb.dart';
import '../src/gen/anki/notetypes.pb.dart';
import '../src/gen/anki/scheduler.pb.dart';
import '../src/gen/anki/search.pb.dart';
import '../src/gen/anki/stats.pb.dart';
import 'call_policy.dart';
import 'engine.dart';
import 'methods.g.dart';

export '../src/gen/anki/card_rendering.pb.dart' show RenderCardResponse, RenderedTemplateNode;
export '../src/gen/anki/cards.pb.dart' show Card;
export '../src/gen/anki/decks.pb.dart' show DeckTreeNode, DeckNameId;
export '../src/gen/anki/notes.pb.dart' show Note;
export '../src/gen/anki/notetypes.pb.dart' show NotetypeNameId;
export '../src/gen/anki/scheduler.pbenum.dart' show QueuedCards_Queue;
export '../src/gen/anki/scheduler.pb.dart' show QueuedCards, QueuedCards_QueuedCard, SchedulingStates, CongratsInfoResponse, CardAnswer_Rating, BuryOrSuspendCardsRequest_Mode;
export '../src/gen/anki/notes.pbenum.dart' show NoteFieldsCheckResponse_State;
export '../src/gen/anki/search.pbenum.dart' show BrowserRow_Color;
export '../src/gen/anki/search.pb.dart' show BrowserRow, BrowserColumns;
export '../src/gen/anki/stats.pb.dart' show GraphsResponse;
export 'engine.dart' show BackendException;
export 'call_policy.dart' show PolicyDenied;

/// Anki's stock notetype kinds we expose in the Add screen.
enum StockKind { basic, basicReversed, cloze }

/// Browser columns used by the Browse screen (rslib column keys; see rslib/src/browser_table.rs).
const kBrowserColumns = ['noteFld', 'template', 'deck', 'cardDue', 'cardIvl', 'noteTags'];

class FlowApi {
  FlowApi(this.engine);
  final Engine engine;
  String? dir;

  g.Empty _e(List<int> b) => g.Empty.fromBuffer(b);
  Future<g.Empty> _send(Rpc r, req) => engine.call(r, req, _e);

  // ---- collection ----
  /// Open `<dir>/collection.anki2`. FSRS init runs inside the bridge.
  /// `SetActiveBrowserColumns` stays deferred, so browse uses rslib's columns.
  Future<void> openCollection(String directory, {bool fsrsDefault = true}) async {
    dir = directory;
    await Directory(directory).create(recursive: true);
    await Directory(p.join(directory, 'collection.media')).create(recursive: true);
    await _send(Rpcs.openCollection, OpenCollectionRequest(
      collectionPath: p.join(directory, 'collection.anki2'),
      mediaFolderPath: p.join(directory, 'collection.media'),
      mediaDbPath: p.join(directory, 'collection.media.db')));
  }
  String get mediaDir => p.join(dir!, 'collection.media');
  Future<void> closeCollection() => _send(Rpcs.closeCollection, CloseCollectionRequest());

  // ---- decks ----
  Future<DeckTreeNode> deckTree() => engine.call(Rpcs.deckTree, DeckTreeRequest(now: Int64(DateTime.now().millisecondsSinceEpoch ~/ 1000)), DeckTreeNode.fromBuffer);
  Future<int> addDeck(String name) async {
    final d = await engine.call(Rpcs.newDeck, g.Empty(), Deck.fromBuffer);
    d.name = name;
    final r = await engine.call(Rpcs.addDeck, d, OpChangesWithId.fromBuffer);
    return r.id.toInt();
  }
  Future<void> renameDeck(int id, String name) => engine.call(Rpcs.renameDeck, RenameDeckRequest(deckId: Int64(id), newName: name), OpChanges.fromBuffer);
  Future<int> removeDecks(List<int> ids) async => (await engine.call(Rpcs.removeDecks, DeckIds(dids: ids.map(Int64.new)), OpChangesWithCount.fromBuffer)).count;
  Future<List<DeckNameId>> deckNames() async => (await engine.call(Rpcs.getDeckNames, GetDeckNamesRequest(skipEmptyDefault: true, includeFiltered: false), DeckNames.fromBuffer)).entries;
  Future<void> setDeckCollapsed(int id, bool c) => engine.call(Rpcs.setDeckCollapsed, SetDeckCollapsedRequest(deckId: Int64(id), collapsed: c, scope: SetDeckCollapsedRequest_Scope.REVIEWER), OpChanges.fromBuffer);
  Future<void> setCurrentDeck(int id) => engine.call(Rpcs.setCurrentDeck, DeckId(did: Int64(id)), OpChanges.fromBuffer);
  Future<DeckTreeNode?> deckTreeNode(int id) async {
    DeckTreeNode? walk(DeckTreeNode n) { if (n.deckId.toInt() == id) return n; for (final c in n.children) { final r = walk(c); if (r != null) return r; } return null; }
    return walk(await deckTree());
  }

  // ---- notetypes / notes ----
  Future<List<NotetypeNameId>> notetypeNames() async => (await engine.call(Rpcs.getNotetypeNames, g.Empty(), NotetypeNames.fromBuffer)).entries;
  Future<List<String>> fieldNames(int ntid) async => (await engine.call(Rpcs.getFieldNames, NotetypeId(ntid: Int64(ntid)), g.StringList.fromBuffer)).vals;
  Future<Note> newNote(int ntid) => engine.call(Rpcs.newNote, NotetypeId(ntid: Int64(ntid)), Note.fromBuffer);
  Future<int> addNote(Note n, int deckId) async => (await engine.call(Rpcs.addNote, AddNoteRequest(note: n, deckId: Int64(deckId)), AddNoteResponse.fromBuffer)).noteId.toInt();
  Future<Note> getNote(int id) => engine.call(Rpcs.getNote, NoteId(nid: Int64(id)), Note.fromBuffer);
  Future<void> updateNote(Note n) => engine.call(Rpcs.updateNotes, UpdateNotesRequest(notes: [n], skipUndoEntry: false), OpChanges.fromBuffer);
  Future<DeckAndNotetype> defaultsForAdding() => engine.call(Rpcs.defaultsForAdding, DefaultsForAddingRequest(), DeckAndNotetype.fromBuffer);
  Future<List<String>> allTags() async => (await engine.call(Rpcs.allTags, g.Empty(), g.StringList.fromBuffer)).vals;
  Future<int> removeNotes(List<int> noteIds) async => (await engine.call(Rpcs.removeNotes, RemoveNotesRequest(noteIds: noteIds.map(Int64.new)), OpChangesWithCount.fromBuffer)).count;
  Future<List<int>> cardsOfNote(int nid) async => (await engine.call(Rpcs.cardsOfNote, NoteId(nid: Int64(nid)), CardIds.fromBuffer)).cids.map((e) => e.toInt()).toList();
  /// rslib's field-check (duplicate / empty first field / cloze with no cloze).
  Future<NoteFieldsCheckResponse_State> checkNote(Note n) async => (await engine.call(Rpcs.noteFieldsCheck, n, NoteFieldsCheckResponse.fromBuffer)).state;

  // ---- media ----
  /// Copies a file into collection.media (rslib decides the final, de-duplicated file name).
  Future<String> addMediaFromPath(String path) async => (await engine.call(Rpcs.addMediaFromPath, AddMediaFromPathRequest(path: path), g.String.fromBuffer)).val;

  // ---- search / browse ----
  Future<String> _builtSearch(String q) async {
    final built = await engine.call(
      Rpcs.buildSearchString,
      SearchNode(parsableText: q),
      g.String.fromBuffer,
    );
    return built.val;
  }

  Future<List<int>> searchCards(String q, {String column = 'noteFld', bool reverse = false}) async {
    final search = await _builtSearch(q);
    return (await engine.call(Rpcs.searchCards, SearchRequest(search: search, order: SortOrder(builtin: SortOrder_Builtin(column: column, reverse: reverse))), SearchResponse.fromBuffer)).ids.map((e) => e.toInt()).toList();
  }
  Future<List<int>> searchNotes(String q) async {
    final search = await _builtSearch(q);
    return (await engine.call(Rpcs.searchNotes, SearchRequest(search: search), SearchResponse.fromBuffer)).ids.map((e) => e.toInt()).toList();
  }
  Future<BrowserRow> browserRow(int id) => engine.call(Rpcs.browserRowForId, g.Int64(val: Int64(id)), BrowserRow.fromBuffer);
  Future<Card> getCard(int id) => engine.call(Rpcs.getCard, CardId(cid: Int64(id)), Card.fromBuffer);
  Future<void> buryOrSuspend(List<int> cardIds, BuryOrSuspendCardsRequest_Mode mode) =>
      engine.call(Rpcs.buryOrSuspendCards, BuryOrSuspendCardsRequest(cardIds: cardIds.map(Int64.new), mode: mode), OpChangesWithCount.fromBuffer);
  Future<void> restoreBuriedAndSuspended(List<int> cardIds) => engine.call(Rpcs.restoreBuriedAndSuspendedCards, CardIds(cids: cardIds.map(Int64.new)), OpChanges.fromBuffer);
  // Bury (UnburyDeck, BURY_*) and SetDueDate are denied by the call policy; there is intentionally no API for them.
  static String _cids(Iterable<int> ids) => 'cid:${ids.join(',')}';
  /// Cards among [ids] that exist / are currently suspended (queue = -1), read through Search (`is:suspended`).
  Future<int> countExisting(List<int> ids) async => ids.isEmpty ? 0 : (await searchCards(_cids(ids))).length;
  Future<int> countSuspended(List<int> ids) async => ids.isEmpty ? 0 : (await searchCards('${_cids(ids)} is:suspended')).length;
  /// Suspend (mode SUSPEND only). Rejects the whole request when [ids] is empty or any card does not exist.
  Future<void> suspendCards(List<int> ids) async {
    final u = ids.toSet().toList();
    if (u.isEmpty) throw PolicyDenied('bury_or_suspend_cards', 'card_ids must not be empty');
    if (await countExisting(u) != u.length) throw PolicyDenied('bury_or_suspend_cards', 'not all cards exist');
    await buryOrSuspend(u, BuryOrSuspendCardsRequest_Mode.SUSPEND);
  }
  /// Unsuspend via RestoreBuriedAndSuspendedCards (which would also unbury): only when EVERY card is suspended now; otherwise rejects the whole request.
  Future<void> unsuspendCards(List<int> ids) async {
    final u = ids.toSet().toList();
    if (u.isEmpty) throw PolicyDenied('restore_buried_and_suspended_cards', 'card ids must not be empty');
    if (await countSuspended(u) != u.length) throw PolicyDenied('restore_buried_and_suspended_cards', 'not every card is currently suspended (queue=-1)');
    await restoreBuriedAndSuspended(u);
  }

  // ---- study ----
  Future<QueuedCards> queuedCards({int limit = 1}) => engine.call(Rpcs.getQueuedCards, GetQueuedCardsRequest(fetchLimit: limit), QueuedCards.fromBuffer);
  Future<List<String>> describeNextStates(SchedulingStates s) async => (await engine.call(Rpcs.describeNextStates, s, g.StringList.fromBuffer)).vals;
  Future<void> answerCard(QueuedCards_QueuedCard qc, CardAnswer_Rating rating, {int millisTaken = 0}) {
    final s = qc.states;
    final next = switch (rating) { CardAnswer_Rating.AGAIN => s.again, CardAnswer_Rating.HARD => s.hard, CardAnswer_Rating.GOOD => s.good, _ => s.easy };
    return engine.call(Rpcs.answerCard, CardAnswer(cardId: qc.card.id, currentState: s.current, newState: next, rating: rating,
        answeredAtMillis: Int64(DateTime.now().millisecondsSinceEpoch), millisecondsTaken: millisTaken), OpChanges.fromBuffer);
  }
  Future<RenderCardResponse> renderCard(int cardId, {bool browser = false}) => engine.call(Rpcs.renderExistingCard, RenderExistingCardRequest(cardId: Int64(cardId), browser: browser), RenderCardResponse.fromBuffer);
  Future<ExtractAvTagsResponse> extractAvTags(String text, bool question) => engine.call(Rpcs.extractAvTags, ExtractAvTagsRequest(text: text, questionSide: question), ExtractAvTagsResponse.fromBuffer);
  Future<UndoStatus> undoStatus() => engine.call(Rpcs.getUndoStatus, g.Empty(), UndoStatus.fromBuffer);
  Future<UndoStatus> undo() async { await engine.call(Rpcs.undo, g.Empty(), OpChangesAfterUndo.fromBuffer); return undoStatus(); }
  Future<UndoStatus> redo() async { await engine.call(Rpcs.redo, g.Empty(), OpChangesAfterUndo.fromBuffer); return undoStatus(); }
  Future<CongratsInfoResponse> congratsInfo() => engine.call(Rpcs.congratsInfo, g.Empty(), CongratsInfoResponse.fromBuffer);
  Future<String> studiedToday() async => (await engine.call(Rpcs.studiedToday, g.Empty(), g.String.fromBuffer)).val;

  // ---- import / stats ----
  Future<ImportResponse> importApkg(String path) => engine.call(Rpcs.importAnkiPackage, ImportAnkiPackageRequest(packagePath: path, options: ImportAnkiPackageOptions(mergeNotetypes: true, updateNotes: ImportAnkiPackageUpdateCondition.IMPORT_ANKI_PACKAGE_UPDATE_CONDITION_IF_NEWER, updateNotetypes: ImportAnkiPackageUpdateCondition.IMPORT_ANKI_PACKAGE_UPDATE_CONDITION_IF_NEWER, withScheduling: true, withDeckConfigs: true)), ImportResponse.fromBuffer);
  /// Export one deck (cards + media only; with_scheduling=false and with_deck_configs=false are FIXED, no parameter) as .apkg through rslib's exporter (used to generate the demo sample deck).
  Future<int> exportApkg(String outPath, int deckId) async => (await engine.call(Rpcs.exportAnkiPackage, ExportAnkiPackageRequest(outPath: outPath, options: ExportAnkiPackageOptions(withScheduling: false, withDeckConfigs: false, withMedia: true, legacy: false), limit: ExportLimit(deckId: Int64(deckId))), g.UInt32.fromBuffer)).val;
  /// FSRS is a collection-wide switch; stats reports it (GraphsResponse.fsrs).
  Future<bool> fsrsEnabled() async => (await graphs(days: 1)).fsrs;
  Future<GraphsResponse> graphs({String search = '', int days = 30}) async {
    final built = await _builtSearch(search);
    return engine.call(Rpcs.graphs, GraphsRequest(search: built, days: days), GraphsResponse.fromBuffer);
  }
}
