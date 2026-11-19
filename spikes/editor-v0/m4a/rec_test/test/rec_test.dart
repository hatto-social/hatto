import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:record_linux/record_linux.dart';
import 'package:record_platform_interface/record_platform_interface.dart';

void main() {
  test('record_linux -> aacLc .m4a via parecord+ffmpeg', () async {
    final r = RecordLinux();
    await r.create('t');
    print('supports aacLc: ${r.toString()}');
    final path = '${Directory.systemTemp.path}/hatto_editor_spike_plugin_rec.m4a';
    if (File(path).existsSync()) File(path).deleteSync();
    final cfg = const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 44100, numChannels: 1, bitRate: 128000);
    print('encoders: ${await r.isEncoderSupported('t', AudioEncoder.aacLc)}');
    await r.start('t', cfg, path: path);
    await Future.delayed(const Duration(seconds: 3));
    final out = await r.stop('t');
    print('stop returned: $out');
    await r.dispose('t');
    expect(File(path).existsSync(), true);
  }, timeout: const Timeout(Duration(seconds: 40)));
}
