// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:hatto_legal/hatto_legal.dart';

import 'about/about_page.dart';
import 'state/bootstrap_state.dart';

/// Desktop shell. Tests pass [openUrl] so the source button does not
/// start a process.
class HattoDesktopApp extends StatelessWidget {
  const HattoDesktopApp({super.key, required this.state, this.openUrl});

  final BootstrapState state;
  final OpenSourceUrl? openUrl;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hatto',
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Noto Sans',
        fontFamilyFallback: const ['Noto Sans KR'],
      ),
      home: HomePage(state: state, openUrl: openUrl),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.state, this.openUrl});

  final BootstrapState state;
  final OpenSourceUrl? openUrl;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Hatto'),
        actions: [
          PopupMenuButton<String>(
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('메뉴'),
            ),
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'about', child: Text('라이선스')),
            ],
            onSelected: (value) {
              if (value != 'about') {
                return;
              }
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => AboutPage(openUrl: openUrl),
                ),
              );
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(state.message, key: const Key('home-status')),
      ),
    );
  }
}
