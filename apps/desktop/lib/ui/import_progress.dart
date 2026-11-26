// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import '../editor/anki_ui.dart';
import '../effect/import_progress_model.dart';
import 'common.dart';
import 'import_copy.dart';

/// Modal body for an in-flight import. The route sets `barrierDismissible`
/// to false. This widget refuses to pop.
class ImportProgressDialog extends StatelessWidget {
  const ImportProgressDialog({
    super.key,
    required this.model,
    required this.onCancel,
  });

  final ImportProgressModel model;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Focus(
        autofocus: true,
        child: ListenableBuilder(
          listenable: model,
          builder: (context, _) {
            final view = model.view;
            final k = AnkiTheme.of(context);
            return WindowFrame(
              key: const ValueKey('import-progress'),
              title: '가져오기',
              width: 440,
              height: 200,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      view.label,
                      key: const ValueKey('import-stage'),
                      style: ankiText(k, size: 15),
                    ),
                    if (view.blockedNote != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          view.blockedNote!,
                          key: const ValueKey('import-cancel-blocked'),
                          style: ankiText(k, size: 13, color: k.fgSubtle),
                        ),
                      ),
                    const Spacer(),
                    Align(
                      alignment: Alignment.centerRight,
                      child: QtPush(
                        '취소',
                        key: const ValueKey('import-cancel'),
                        onTap: view.cancelEnabled ? onCancel : null,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Closable summary for a multi-line import result.
class ImportSummaryDialog extends StatelessWidget {
  const ImportSummaryDialog({super.key, required this.summary});

  final ImportSummaryText summary;

  @override
  Widget build(BuildContext context) {
    final k = AnkiTheme.of(context);
    return WindowFrame(
      key: const ValueKey('import-summary'),
      title: '가져오기',
      width: 460,
      height: 320,
      onClose: () => Navigator.pop(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              summary.title,
              key: const ValueKey('import-summary-title'),
              style: ankiText(k, size: 15, w: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final line in summary.details)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(line, style: ankiText(k, size: 14)),
                      ),
                    if (summary.footer != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          summary.footer!,
                          key: const ValueKey('import-summary-footer'),
                          style: ankiText(k, size: 14),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: QtPush(
                '닫기',
                key: const ValueKey('import-summary-close'),
                onTap: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
