// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hatto_store/hatto_store.dart';

import '../effect/engine_host.dart';

/// Final copy from the product owner. Existing status text in this app
/// also spells the word 컬렉션.
const sideDbCorruptTitle = '앱 데이터를 열 수 없어요';
const sideDbCorruptBody =
    'Hatto 앱 데이터 파일(hatto.sqlite)이 손상돼 열지 못했어요. 파일을 지우거나 옮기지 말고 앱을 다시 실행해 보세요.';
const collectionOpenTitle = '학습 컬렉션을 열 수 없어요';
const collectionOpenBody =
    '학습 컬렉션(collection.anki2)을 열지 못했어요. 카드와 복습 기록이 이 파일에 들어 있으니 지우거나 옮기지 말고 앱을 다시 실행해 보세요.';
const fileLocationPrefix = '파일 위치: ';

/// What the startup dialog shows. [path] is omitted when it is null.
class StartupNotice {
  const StartupNotice({this.title, required this.body, this.path});

  final String? title;
  final String body;
  final String? path;
}

/// Dialog content for a startup failure the user must see, or null to rethrow.
///
/// Covered cases are a second process, a newer side-database schema, an OS
/// lock error, a corrupt side database, and a collection that did not open.
StartupNotice? startupNotice(Object error) {
  if (error is AlreadyRunningException) {
    return const StartupNotice(body: alreadyRunningMessage);
  }
  if (error is NewerSchemaException) {
    return StartupNotice(body: error.message);
  }
  if (error is InstanceLockException) {
    return StartupNotice(body: error.message);
  }
  if (error is SideDbCorruptException) {
    return StartupNotice(
      title: sideDbCorruptTitle,
      body: sideDbCorruptBody,
      path: error.path,
    );
  }
  if (error is CollectionOpenException) {
    return StartupNotice(
      title: collectionOpenTitle,
      body: collectionOpenBody,
      path: error.path,
    );
  }
  return null;
}

/// Dialog shown before the study shell when startup cannot continue.
class StartupFailureApp extends StatelessWidget {
  const StartupFailureApp({super.key, required this.notice, this.onDismiss});

  final StartupNotice notice;

  /// Called when the user dismisses the dialog. Production exits the process.
  final void Function()? onDismiss;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: _StartupFailureScreen(notice: notice, onDismiss: onDismiss),
    );
  }
}

class _StartupFailureScreen extends StatefulWidget {
  const _StartupFailureScreen({required this.notice, required this.onDismiss});

  final StartupNotice notice;
  final void Function()? onDismiss;

  @override
  State<_StartupFailureScreen> createState() => _StartupFailureScreenState();
}

class _StartupFailureScreenState extends State<_StartupFailureScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final notice = widget.notice;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          return AlertDialog(
            key: const ValueKey('startup-failure'),
            title: notice.title == null ? null : Text(notice.title!),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(notice.body),
                if (notice.path != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    '$fileLocationPrefix${notice.path}',
                    key: const ValueKey('startup-path'),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  final dismiss = widget.onDismiss;
                  if (dismiss != null) {
                    dismiss();
                  } else {
                    exit(1);
                  }
                },
                child: const Text('확인'),
              ),
            ],
          );
        },
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: SizedBox.shrink());
  }
}
