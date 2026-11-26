// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:hatto_store/hatto_store.dart';

import 'import_engine_mobile.dart';
import 'mobile_anki.dart';
import 'mobile_write_gateway.dart';
import 'resident_collection.dart';

/// Result of one startup pass. The collection and the side database are
/// both closed before this is returned.
class MobileStartupReport {
  const MobileStartupReport({
    required this.schemaVersion,
    required this.pendingIntents,
    required this.recoveryRan,
    this.startupError,
  });

  final int schemaVersion;
  final int pendingIntents;

  /// True when [importStartupNeeded] was true and recovery was attempted.
  final bool recoveryRan;

  /// Set when recovery threw. Null when recovery was skipped or finished.
  final Object? startupError;

  /// Side-database line, plus one failure line when recovery threw.
  String get statusLine {
    final base = 'side db v$schemaVersion, pending intents: $pendingIntents';
    final error = startupError;
    if (error == null) {
      return base;
    }
    return '$base\nimport startup failed: $error';
  }
}

/// Opens the side database and the resident collection, runs import
/// recovery when [importStartupNeeded] is true, then closes both.
///
/// The caller opens the collection again afterwards. Two backends are not
/// open on the same collection at once.
Future<MobileStartupReport> openResidentAndRecover({
  required String documentsDirectory,
  required String residentDirectory,
}) async {
  final side = SideDb.open(
    path: sideDbPath(documentsDirectory),
    deviceId: 'local-device',
  );
  ResidentCollection? resident;
  var opened = false;
  Object? startupError;
  var recoveryRan = false;
  try {
    resident = await ResidentCollection.open(residentDirectory);
    opened = true;
    final gateway = MobileWriteGateway(db: side);
    gateway.attachImport(
      anki: MobileAnkiApi(resident),
      engine: MobileImportEngine(
        backend: resident.backend,
        dataDir: residentDirectory,
      ),
      dataDir: residentDirectory,
    );
    if (importStartupNeeded(side, residentDirectory)) {
      recoveryRan = true;
      try {
        await gateway.recoverImportsAtStartup();
      } catch (err) {
        gateway.noteImportStartupFailure(err);
        startupError = err;
      }
    }
    return MobileStartupReport(
      schemaVersion: side.schemaVersion,
      pendingIntents: side.pendingIntentCount(),
      recoveryRan: recoveryRan,
      startupError: startupError,
    );
  } finally {
    Object? closeError;
    StackTrace? closeStack;
    if (opened && resident != null) {
      try {
        await resident.close();
      } catch (err, stack) {
        closeError = err;
        closeStack = stack;
      }
    }
    side.close();
    if (closeError != null) {
      Error.throwWithStackTrace(closeError, closeStack!);
    }
  }
}
