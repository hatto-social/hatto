// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:hatto_store/hatto_store.dart';

/// The only desktop file that writes the side database.
///
/// Desktop v0 does not append edit-journal rows. [run] passes `journal:
/// false` and runs [map] in the same side-DB transaction that deletes the
/// intent. Reconciliation is the same module mobile can call.
class WriteGateway {
  WriteGateway({
    required this.db,
    required ProtoCommand command,
    void Function(WritePhase phase)? fault,
  }) : _writes = WriteWrapper(db: db, command: command, fault: fault);

  final SideDb db;
  final WriteWrapper _writes;

  Future<ProtoResponse> run({
    required String op,
    required String entityKind,
    required String guid,
    required int service,
    required int method,
    required Uint8List input,
    String? expected,
    MappingCallback? map,
    MediaJournal? media,
  }) {
    return _writes.run(
      op: op,
      entityKind: entityKind,
      guid: guid,
      service: service,
      method: method,
      input: input,
      expected: expected,
      journal: false,
      map: map,
      media: media,
    );
  }

  Future<ReconcileResult> reconcile(AnkiApi anki) {
    return reconcileCollection(db: db, anki: anki);
  }
}
