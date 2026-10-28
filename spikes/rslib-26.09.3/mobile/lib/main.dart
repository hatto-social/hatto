import 'package:flutter/material.dart';

void main() {
  runApp(const HattoRslibSpikeApp());
}

class HattoRslibSpikeApp extends StatelessWidget {
  const HattoRslibSpikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text(
            'rslib 26.09.3 spike\nHost and device checks live in flutter test.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
