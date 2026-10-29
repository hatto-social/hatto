import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_rslib_spike/src/frb_backend.dart';
import 'package:hatto_rslib_spike/src/roundtrip_flow.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('host import/export roundtrip through flutter_rust_bridge', () async {
    final library = Platform.environment['HATTO_RSLIB_LIB'];
    expect(library, isNotNull, reason: 'HATTO_RSLIB_LIB must point at libhatto_rslib_frb.so');
    await initFrb(library!);
    final work = await Directory.systemTemp.createTemp('hatto-frb-host-');
    await setTempDir(work.path);
    final report = await runRoundtrip(
      work: work,
      openBackend: FrbByteBackend.open,
      inspectScript: Platform.environment['HATTO_INSPECT_APKG'],
    );
    expect(report.fields, ['alpha / beta', 'hello / world']);
    expect(report.strippedRevlog, 0);
    expect(report.keptRevlog, greaterThan(0));
    expect(report.importedStrippedReps, 0);
    expect(report.importedKeptReps, report.answeredReps);
    expect(report.answeredReps, greaterThan(0));
  });
}
