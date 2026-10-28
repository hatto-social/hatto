import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_rslib_spike/src/frb_backend.dart';
import 'package:hatto_rslib_spike/src/roundtrip_flow.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('android file-path import/export roundtrip', (tester) async {
    final cache = await getTemporaryDirectory();
    final work = await cache.createTemp('hatto-frb-device-');
    await initFrb('libhatto_rslib_frb.so');
    await setTempDir(work.path);
    final report = await runRoundtrip(
      work: work,
      openBackend: FrbByteBackend.open,
    );
    expect(report.fields, ['alpha / beta', 'hello / world']);
    expect(report.importedStrippedReps, 0);
    expect(report.importedKeptReps, report.answeredReps);
    expect(report.answeredReps, greaterThan(0));
    // ignore: avoid_print
    print('FRB_DEVICE_OK fields=${report.fields} reps=${report.answeredReps}');
  }, timeout: const Timeout(Duration(minutes: 20)));
}
