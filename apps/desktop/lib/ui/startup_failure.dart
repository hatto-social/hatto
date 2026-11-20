// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hatto_store/hatto_store.dart';

/// Message for a startup failure the user must see, or null to rethrow.
///
/// Covered cases are a second process, a side database newer than this
/// app, and an OS lock error. Other failures stay on the console.
String? startupDialogMessage(Object error) {
  if (error is AlreadyRunningException) {
    return alreadyRunningMessage;
  }
  if (error is NewerSchemaException) {
    return error.message;
  }
  if (error is InstanceLockException) {
    return error.message;
  }
  return null;
}

/// Dialog shown before the study shell when startup cannot continue.
class StartupFailureApp extends StatelessWidget {
  const StartupFailureApp({super.key, required this.message, this.onDismiss});

  final String message;

  /// Called when the user dismisses the dialog. Production exits the process.
  final void Function()? onDismiss;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: _StartupFailureScreen(message: message, onDismiss: onDismiss),
    );
  }
}

class _StartupFailureScreen extends StatefulWidget {
  const _StartupFailureScreen({required this.message, required this.onDismiss});

  final String message;
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
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          return AlertDialog(
            key: const ValueKey('startup-failure'),
            content: Text(widget.message),
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
