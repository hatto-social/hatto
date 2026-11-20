// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:protobuf/protobuf.dart';
import 'package:rslib_bridge/rslib_bridge.dart';

import '../src/gen/anki/backend.pb.dart';
import 'methods.g.dart';

class BackendException implements Exception {
  BackendException(this.rpc, this.error);
  final Rpc rpc;
  final BackendError error;
  String get kind => error.kind.name;
  @override
  String toString() => 'BackendException(${rpc.name}: $kind: ${error.message})';
}

/// Method name to the protobuf service that owns it.
///
/// Indexes come from [serviceMethodIndex] at the call, not from the
/// prototype table in `methods.g.dart`. Names that are not here are not
/// sent to rslib.
const desktopServices = <String, String>{
  'open_collection': 'BackendCollectionService',
  'close_collection': 'BackendCollectionService',
  'get_undo_status': 'BackendCollectionService',
  'deck_tree': 'BackendDecksService',
  'new_deck': 'BackendDecksService',
  'add_deck': 'BackendDecksService',
  'get_deck_names': 'BackendDecksService',
  'set_current_deck': 'BackendDecksService',
  'get_notetype_names': 'BackendNotetypesService',
  'get_field_names': 'BackendNotetypesService',
  'new_note': 'BackendNotesService',
  'get_note': 'BackendNotesService',
  'defaults_for_adding': 'BackendNotesService',
  'remove_notes': 'BackendNotesService',
  'cards_of_note': 'BackendNotesService',
  'note_fields_check': 'BackendNotesService',
  'all_tags': 'BackendTagsService',
  'build_search_string': 'BackendSearchService',
  'search_cards': 'BackendSearchService',
  'search_notes': 'BackendSearchService',
  'browser_row_for_id': 'BackendSearchService',
  'get_card': 'BackendCardsService',
  'bury_or_suspend_cards': 'BackendSchedulerService',
  'restore_buried_and_suspended_cards': 'BackendSchedulerService',
  'get_queued_cards': 'BackendSchedulerService',
  'describe_next_states': 'BackendSchedulerService',
  'answer_card': 'BackendSchedulerService',
  'congrats_info': 'BackendSchedulerService',
  'studied_today': 'BackendSchedulerService',
  'render_existing_card': 'BackendCardRenderingService',
  'extract_av_tags': 'BackendCardRenderingService',
  'export_anki_package': 'BackendImportExportService',
  'graphs': 'BackendStatsService',
};

class Engine {
  Engine._(this._backend);
  final AnkiBackend _backend;
  bool _open = true;
  bool get isOpen => _open;

  static Future<Engine> open({
    List<String> langs = const ['en'],
    required String dataDir,
  }) async {
    final backend = await openDesktopBackend(
      initMsg: encodeBackendInit(),
      dataDir: dataDir,
    );
    return Engine._(backend);
  }

  Future<O> call<O extends GeneratedMessage>(
    Rpc rpc,
    GeneratedMessage req,
    O Function(List<int>) parse,
  ) async {
    final service = desktopServices[rpc.name];
    if (service == null) {
      throw BackendException(
        rpc,
        BackendError(
          message: 'not on the desktop profile',
          kind: BackendError_Kind.INVALID_INPUT,
        ),
      );
    }
    final index = serviceMethodIndex(service: service, method: rpc.name);
    if (index == null) {
      throw BackendException(
        rpc,
        BackendError(
          message: 'no index for $service.${rpc.name}',
          kind: BackendError_Kind.INVALID_INPUT,
        ),
      );
    }
    final response = await command(
      backend: _backend,
      service: index.service,
      method: index.method,
      input: req.writeToBuffer(),
    );
    if (!response.success) {
      throw BackendException(rpc, BackendError.fromBuffer(response.payload));
    }
    return parse(response.payload);
  }

  void close() {
    _open = false;
  }
}
