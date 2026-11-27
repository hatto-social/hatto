// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/foundation.dart';
import 'package:hatto_store/hatto_store.dart';

import '../state/import_copy.dart';

/// Progress state the dialog reads. [onPhase] updates it before returning.
class ImportProgressModel extends ChangeNotifier {
  ImportProgressModel(this.token);

  final ImportCancellationToken token;
  ImportProgressView view = progressForPhase(null);

  /// True once [ImportPhase.afterIntent] has been observed.
  bool pastIntent = false;

  /// True after [requestCancel] accepted a tap or Esc.
  ///
  /// Later phases keep the stage label but leave cancel disabled, so a
  /// second tap or key repeat cannot request cancel again.
  bool cancelRequested = false;

  void onPhase(ImportPhase phase) {
    final next = progressForPhase(phase);
    if (!next.cancelEnabled) {
      pastIntent = true;
    }
    view = cancelRequested
        ? ImportProgressView(
            label: next.label,
            cancelEnabled: false,
            blockedNote: next.blockedNote,
          )
        : next;
    notifyListeners();
  }

  /// Records a cancel request and disables the button. Does not toast.
  void requestCancel() {
    if (!view.cancelEnabled || cancelRequested) {
      return;
    }
    cancelRequested = true;
    token.cancel();
    view = ImportProgressView(
      label: view.label,
      cancelEnabled: false,
      blockedNote: view.blockedNote,
    );
    notifyListeners();
  }
}
