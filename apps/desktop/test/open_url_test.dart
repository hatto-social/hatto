// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/state/open_url_policy.dart';

void main() {
  test('https is allowed', () {
    expect(isHttpsUrl('https://github.com/hatto-social/hatto'), isTrue);
  });

  test('other schemes and empty strings are rejected', () {
    expect(isHttpsUrl('http://github.com/hatto-social/hatto'), isFalse);
    expect(isHttpsUrl('file:///etc/passwd'), isFalse);
    expect(isHttpsUrl('javascript:alert(1)'), isFalse);
    expect(isHttpsUrl('github.com/hatto-social/hatto'), isFalse);
    expect(isHttpsUrl(''), isFalse);
    expect(isHttpsUrl('https:'), isFalse);
  });

  test('the opener uses Process.run without a shell', () {
    final source = File('lib/effect/open_url.dart').readAsStringSync();
    expect(source, contains('Process.run('));
    expect(source, contains('runInShell: false'));
    expect(source, contains("'open'"));
    expect(source, contains("'xdg-open'"));
    expect(source, isNot(contains('runInShell: true')));
    expect(source, isNot(contains('Process.start')));
  });
}
