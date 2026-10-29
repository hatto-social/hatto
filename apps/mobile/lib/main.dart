import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hatto_store/hatto_store.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:rslib_bridge/rslib_bridge.dart' hide ProtoResponse;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initRslibBridge();
  final cache = await getTemporaryDirectory();
  prepareRuntime(tmpDir: cache.path);
  runApp(const HattoApp());
}

class HattoApp extends StatelessWidget {
  const HattoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(title: 'Hatto', home: HomePage());
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _status = 'Collection is not open yet.';
  bool _busy = false;

  Future<void> _open() async {
    setState(() {
      _busy = true;
      _status = 'Opening collection…';
    });
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory(p.join(support.path, 'resident'))
        ..createSync(recursive: true);
      final summary = await smokeOpenCollection(dir: dir.path);
      final side = SideDb.open(
        path: p.join(dir.path, 'hatto.sqlite'),
        deviceId: 'local-device',
      );
      final pending = side.pendingIntentCount();
      side.close();
      if (!mounted) {
        return;
      }
      setState(() {
        _status = '$summary\nside db pending intents: $pending';
      });
    } catch (err) {
      if (!mounted) {
        return;
      }
      setState(() => _status = 'Open failed: $err');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Hatto')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Local-first. This build does not talk to a server.'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _open,
              child: const Text('Open collection'),
            ),
            const SizedBox(height: 16),
            Text(_status, key: const Key('smoke-status')),
          ],
        ),
      ),
    );
  }
}
