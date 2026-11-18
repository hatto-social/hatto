// ARM64 device smoke. Run on a real arm64-v8a phone:
//
//   flutter test integration_test/arm64_smoke_test.dart -d <serial> \
//     --dart-define=SMOKE_DIR=/data/user/0/social.hatto.hatto_mobile/files/smoke
//
// `tools/arm64-smoke/run_smoke.sh` copies the fixtures into that directory,
// runs this test, and passes the log to judge.py. This file prints
// `HATTO_SMOKE ...` lines. It does not decide pass/fail.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'smoke_flow.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('arm64 colpkg, fsrs, and notetype smoke', (tester) async {
    const smokeDir = String.fromEnvironment('SMOKE_DIR');
    if (smokeDir.isEmpty) {
      smokeLog(
        'HATTO_SMOKE_FAIL smoke SMOKE_DIR is empty. '
        'Pass --dart-define=SMOKE_DIR=<app files/smoke>.',
      );
      fail('SMOKE_DIR is empty');
    }
    await runArm64Smoke(smokeDir);
  }, timeout: const Timeout(Duration(minutes: 50)));
}
