// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:typed_data';

import 'intent_ops.dart';
import 'media_journal.dart';
import 'proto.dart';
import 'schema.dart';
import 'side_db.dart';

/// One rslib write, serialized through the side DB.
///
/// Order: record an intent, call rslib, then in one side-DB transaction run
/// [map], delete the intent, and (when [journal] is true) append the journal
/// row. The journal `field` is null in v0. The default payload is the
/// protobuf input. `media.add` stores [MediaJournal] instead, never the
/// file bytes.
///
/// A returned backend error deletes the intent. A thrown error leaves the
/// intent row so a later reconcile can recover it. rslib is not retried.
typedef ProtoCommand = Future<ProtoResponse> Function(
  int service,
  int method,
  Uint8List input,
);

/// Called after the rslib response is in hand, inside the side-DB
/// transaction that deletes the intent.
typedef MappingCallback = FutureOr<void> Function(ProtoResponse response);

/// Points where a test can throw to simulate a crash.
enum WritePhase {
  /// Intent is committed. rslib has not been called.
  afterIntent,

  /// rslib has returned success. The side-DB transaction has not started.
  /// This is the window between the rslib commit and the side-DB commit.
  afterRslibCommit,

  /// Inside the side-DB transaction, before the mapping callback.
  duringSideCommit,
}

class WriteWrapper {
  WriteWrapper({required this.db, required this.command, this.fault});

  final SideDb db;
  final ProtoCommand command;

  /// Test hook. Production callers leave this null.
  final void Function(WritePhase phase)? fault;

  Future<ProtoResponse> run({
    required String op,
    required String entityKind,
    required String guid,
    required int service,
    required int method,
    required Uint8List input,
    String? expected,
    bool journal = true,
    MappingCallback? map,
    MediaJournal? media,
  }) {
    return db.exclusive(
      () => _run(
        op: op,
        entityKind: entityKind,
        guid: guid,
        service: service,
        method: method,
        input: input,
        expected: expected,
        journal: journal,
        map: map,
        media: media,
      ),
    );
  }

  Future<ProtoResponse> _run({
    required String op,
    required String entityKind,
    required String guid,
    required int service,
    required int method,
    required Uint8List input,
    String? expected,
    required bool journal,
    MappingCallback? map,
    MediaJournal? media,
  }) async {
    if (op == intentMediaAdd && media == null) {
      throw const SideDbException(
        'media.add stores the final filename, size, and sha1',
      );
    }
    final intentId = db.beginIntent(
      op: op,
      targetKey: guid,
      expected: expected,
    );
    fault?.call(WritePhase.afterIntent);
    final ProtoResponse response;
    try {
      response = await command(service, method, input);
    } catch (_) {
      // The process may have died in the same window. Leave the intent.
      rethrow;
    }
    if (!response.success) {
      db.abandonIntent(intentId);
      return response;
    }
    fault?.call(WritePhase.afterRslibCommit);
    final payload = media?.encode() ?? input;
    await db.completeIntent(
      intentId: intentId,
      op: op,
      entityKind: entityKind,
      guid: guid,
      payload: payload,
      journal: journal,
      map: () async {
        fault?.call(WritePhase.duringSideCommit);
        final callback = map;
        if (callback != null) {
          await callback(response);
        }
      },
    );
    return response;
  }
}
