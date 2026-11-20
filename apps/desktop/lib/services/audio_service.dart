// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// AudioService: the UI/state layers only know this interface. Production = audioplayers (MIT; Linux uses GStreamer, needs gst-libav [추정]).
// Tests/CI use FakeAudioService. The service receives ONLY absolute paths that state/sound_gate.dart already validated.
import 'package:audioplayers/audioplayers.dart';

abstract class AudioService {
  Future<void> play(String absolutePath);
  Future<void> stop();
  Future<void> dispose();
}

class AudioplayersAudioService implements AudioService {
  AudioplayersAudioService() : _p = AudioPlayer();
  final AudioPlayer _p;
  @override Future<void> play(String absolutePath) async { await _p.stop(); await _p.play(DeviceFileSource(absolutePath)); }
  @override Future<void> stop() => _p.stop();
  @override Future<void> dispose() => _p.dispose();
}

class FakeAudioService implements AudioService {
  final played = <String>[]; int stops = 0; bool disposed = false;
  @override Future<void> play(String absolutePath) async { played.add(absolutePath); }
  @override Future<void> stop() async { stops++; }
  @override Future<void> dispose() async { disposed = true; }
}
