// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// [sound:NAME]: only a plain file that exists in collection.media is played; traversal / absolute / separators / URLs are rejected.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/engine/anki_api.dart';
import 'package:rslib_bridge/rslib_bridge.dart';
import 'package:hatto_desktop/engine/engine.dart';
import 'package:hatto_desktop/services/audio_service.dart';
import 'package:hatto_desktop/state/app_controller.dart';
import 'package:hatto_desktop/effect/sound_gate.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await initRslibBridge();
  });
  late Directory tmp; late String media;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('hf_snd_'); media = '${tmp.path}/collection.media'; Directory(media).createSync();
    File('$media/hello.mp3').writeAsBytesSync([1, 2, 3]); File('$media/한국어 소리.ogg').writeAsBytesSync([1]);
    Directory('$media/sub').createSync(); File('$media/sub/x.mp3').writeAsBytesSync([1]);
    File('${tmp.path}/secret.mp3').writeAsBytesSync([9]); // outside media
    Link('$media/link.mp3').createSync('${tmp.path}/secret.mp3');
  });
  tearDown(() async { try { await tmp.delete(recursive: true); } catch (_) {} });

  test('plain file names in collection.media resolve (incl. Korean + spaces)', () {
    expect(resolveSound('hello.mp3', media).path, '$media/hello.mp3');
    expect(resolveSound('한국어 소리.ogg', media).ok, isTrue);
  });

  test('rejections', () {
    final cases = <String, SoundReject>{
      '': SoundReject.empty, '   ': SoundReject.empty,
      '../secret.mp3': SoundReject.separator, '..': SoundReject.traversal, 'a..b.mp3': SoundReject.traversal,
      '/etc/passwd': SoundReject.absolute, '\\windows\\x.mp3': SoundReject.absolute, '~/x.mp3': SoundReject.absolute,
      'sub/x.mp3': SoundReject.separator, 'sub\\x.mp3': SoundReject.separator,
      'http://example.com/a.mp3': SoundReject.url, 'https://x/a.mp3': SoundReject.url, 'file:///etc/passwd': SoundReject.url, 'data:audio/mp3;base64,AAAA': SoundReject.url,
      '//host/share/a.mp3': SoundReject.url, 'C:\\a.mp3': SoundReject.url, 'C:/a.mp3': SoundReject.url,
      '%2e%2e%2fsecret.mp3': SoundReject.separator, '..%2fsecret.mp3': SoundReject.traversal, 'sub%2fx.mp3': SoundReject.separator, '%2Fetc%2Fpasswd': SoundReject.absolute,
      'a\u0000b.mp3': SoundReject.controlChar, 'a\nb.mp3': SoundReject.controlChar,
      'missing.mp3': SoundReject.notFound, 'sub': SoundReject.notRegularFile, 'link.mp3': SoundReject.notRegularFile,
    };
    cases.forEach((name, why) {
      final r = resolveSound(name, media);
      expect(r.ok, isFalse, reason: 'should reject "$name"');
      expect(r.reject, why, reason: name);
    });
  });

  test('AppController.playSound: plays only gated paths through the AudioService; rejections never reach it', () async {
    final e = await Engine.open(langs: ['en'], dataDir: tmp.path); final api = FlowApi(e); api.dir = tmp.path;
    final fake = FakeAudioService(); final app = AppController(api, audio: fake);
    await app.playSound('hello.mp3');
    expect(fake.played, ['$media/hello.mp3']);
    for (final bad in ['../secret.mp3', '/etc/passwd', 'http://x/a.mp3', 'missing.mp3', 'sub/x.mp3', 'link.mp3', '(tts)']) { await app.playSound(bad); }
    expect(fake.played, ['$media/hello.mp3'], reason: 'nothing else was played');
    expect(app.message, isNotNull);
    e.close();
  });
}
