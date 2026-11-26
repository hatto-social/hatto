// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/foundation.dart';
import 'package:hatto_store/hatto_store.dart';

import '../ui/import_copy.dart';

/// Progress state the dialog reads. [onPhase] updates it before returning.
class ImportProgressModel extends ChangeNotifier {
  ImportProgressModel(this.token);

  final ImportCancellationToken token;
  ImportProgressView view = progressForPhase(null);

  /// True once [ImportPhase.afterIntent] has been observed.
  bool pastIntent = false;

  void onPhase(ImportPhase phase) {
    view = progressForPhase(phase);
    if (!view.cancelEnabled) {
      pastIntent = true;
    }
    notifyListeners();
  }

  /// Records a cancel request. Does not toast.
  void requestCancel() {
    if (!view.cancelEnabled) {
      return;
    }
    token.cancel();
  }
}
