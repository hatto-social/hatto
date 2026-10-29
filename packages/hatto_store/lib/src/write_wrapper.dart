import 'dart:typed_data';

import 'proto.dart';
import 'side_db.dart';

/// One rslib write, serialized through the side DB.
///
/// Order, matching the v0 crash rule: record an intent, call rslib, then in one
/// side-DB transaction mark the intent done and append the journal row.
/// A returned backend error abandons the intent. A thrown error leaves it
/// pending so a later startup can reconcile it. Reconciliation itself is not
/// implemented in this skeleton.
typedef ProtoCommand = Future<ProtoResponse> Function(
  int service,
  int method,
  Uint8List input,
);

class WriteWrapper {
  WriteWrapper({required this.db, required this.command});

  final SideDb db;
  final ProtoCommand command;

  Future<ProtoResponse> run({
    required String op,
    required String entityKind,
    required String guid,
    String? field,
    required int service,
    required int method,
    required Uint8List input,
  }) async {
    final intentId = db.beginIntent(op: op, targetKey: guid);
    final ProtoResponse response;
    try {
      response = await command(service, method, input);
    } catch (_) {
      // The process may have died in the same window. Leave the intent pending.
      rethrow;
    }
    if (!response.success) {
      db.abandonIntent(intentId);
      return response;
    }
    db.completeIntent(
      intentId: intentId,
      entityKind: entityKind,
      guid: guid,
      field: field,
    );
    return response;
  }
}
