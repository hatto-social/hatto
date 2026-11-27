// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// App state (ChangeNotifier). State/effect boundary:
//   pure state + sequencing  = AppController / ReviewSession (no Flutter widgets, no FFI types beyond protobuf messages)
//   effects                  = FlowApi -> Engine -> rslib (collection I/O, scheduling, search, render, import)
import 'package:flutter/foundation.dart';
import '../engine/anki_api.dart';
import '../services/audio_service.dart';
import 'review_session.dart';
import '../effect/sound_gate.dart';

enum Screen { decks, overview, review, browse, stats }

class AppController extends ChangeNotifier {
  AppController(FlowApi api, {AudioService? audio}) : _api = api, audio = audio ?? FakeAudioService();

  /// Widget tests that never open a collection.
  @visibleForTesting
  AppController.bare({AudioService? audio}) : _api = null, audio = audio ?? FakeAudioService();

  final FlowApi? _api;
  FlowApi get api {
    final value = _api;
    if (value == null) throw StateError('no collection is open');
    return value;
  }
  final AudioService audio;

  /// Saves unsaved editor edits before an import.
  Future<void> Function()? flushEditor;
  Future<void> flushPendingEdits() async {
    final flush = flushEditor;
    if (flush != null) await flush();
  }
  Screen screen = Screen.decks;
  DeckTreeNode? tree;
  int? deckId; String deckName = '';
  DeckTreeNode? overview;
  ReviewSession? session;
  String studiedToday = '';
  String? message; // one-line status (like Anki's tooltip)
  bool fsrsOn = false; // collection-wide scheduler switch (read from stats), drives the FSRS guidance copy
  int revision = 0; // bumped after any collection change; screens listen and refresh

  void _expand(DeckTreeNode node) {
    node.collapsed = false;
    for (final child in node.children) {
      _expand(child);
    }
  }

  void _changed() { revision++; notifyListeners(); }
  void toast(String m) { message = m; notifyListeners(); }
  void clearToast() { message = null; }

  Future<void> refreshDecks() async {
    tree = await api.deckTree();
    // SetDeckCollapsed is not in the contract, so the UI shows every deck
    // expanded. rslib's stored collapsed flag is left unchanged.
    if (tree != null) _expand(tree!);
    studiedToday = await api.studiedToday();
    if (deckId != null) overview = await api.deckTreeNode(deckId!);
    _changed();
  }

  Future<void> go(Screen s) async {
    if (s == Screen.decks || s == Screen.overview) await refreshDecks();
    if (s == Screen.overview && overview == null) s = Screen.decks;
    screen = s; _changed();
  }

  Future<void> openDeck(int id, String name) async {
    deckId = id; deckName = name;
    await api.setCurrentDeck(id);
    overview = await api.deckTreeNode(id);
    screen = Screen.overview; _changed();
  }

  Future<void> startStudy() async {
    fsrsOn = await api.fsrsEnabled();
    final s = ReviewSession(api);
    session = s;
    await s.loadNext();
    screen = Screen.review; _changed();
  }

  Future<void> renameDeck(int id, String name) async { await api.renameDeck(id, name); if (deckId == id) deckName = name; await refreshDecks(); }
  void touch() => _changed();

  /// Play a [sound:] file. The name must be a plain file in collection.media (see sound_gate.dart); anything else is refused with a toast.
  Future<SoundResolution> playSound(String name) async {
    final r = resolveSound(name, api.mediaDir);
    if (!r.ok) { toast(name == '(tts)' ? 'TTS는 지원하지 않아요' : '재생할 수 없는 소리예요 (${r.reject!.name})'); return r; }
    try { await audio.play(r.path!); } catch (e) { toast('소리 재생 실패: $e'); }
    return r;
  }
}
