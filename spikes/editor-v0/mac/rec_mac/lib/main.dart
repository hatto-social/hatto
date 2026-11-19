// Spike m4a (macOS): record 5 s with the `record` plugin (AAC-LC .m4a), then print afinfo + play with afplay.
// NOT run on a Mac by Dmitry (no macOS available). Results go to ~/Desktop/rec_mac_result.txt
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

void main() => runApp(const MaterialApp(home: Home()));

class Home extends StatefulWidget { const Home({super.key}); @override State<Home> createState() => _S(); }
class _S extends State<Home> {
  final rec = AudioRecorder(); String out = 'press Record (5 s)';
  Future<void> go() async {
    final sb = StringBuffer();
    try {
      sb.writeln('hasPermission=${await rec.hasPermission()}');
      sb.writeln('aacLc supported=${await rec.isEncoderSupported(AudioEncoder.aacLc)}');
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/rec_mac_test.m4a';
      if (File(path).existsSync()) File(path).deleteSync();
      await rec.start(const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 44100, numChannels: 1, bitRate: 128000), path: path);
      setState(() => out = 'recording... speak for 5 s');
      await Future.delayed(const Duration(seconds: 5));
      final p = await rec.stop();
      sb.writeln('stopped path=$p size=${p == null ? null : File(p).lengthSync()}');
      if (p != null) {
        sb.writeln((await Process.run('afinfo', [p])).stdout);
        sb.writeln((await Process.run('file', [p])).stdout);
        File(p).copySync('${Platform.environment['HOME']}/Desktop/rec_mac_test.m4a');
        setState(() => out = 'playing with afplay...');
        sb.writeln('afplay exit=${(await Process.run('afplay', [p])).exitCode}');
      }
    } catch (e) { sb.writeln('ERROR $e'); }
    File('${Platform.environment['HOME']}/Desktop/rec_mac_result.txt').writeAsStringSync(sb.toString());
    setState(() => out = sb.toString());
  }
  @override Widget build(BuildContext c) => Scaffold(body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [ElevatedButton(onPressed: go, child: const Text('Record')), const SizedBox(height: 12), SelectableText(out)])));
}
