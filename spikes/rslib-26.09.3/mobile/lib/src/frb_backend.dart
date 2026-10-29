import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:hatto_rslib_spike/src/byte_backend.dart';
import 'package:hatto_rslib_spike/src/rust/api.dart' as api;
import 'package:hatto_rslib_spike/src/rust/frb_generated.dart';

Future<void> initFrb(String libraryPath) {
  return RustLib.init(externalLibrary: ExternalLibrary.open(libraryPath));
}

Future<void> setTempDir(String path) => api.setTempDir(path: path);

class FrbByteBackend implements ByteBackend {
  FrbByteBackend(this._handle);
  final api.BackendHandle _handle;

  static Future<FrbByteBackend> open(Uint8List init) async {
    return FrbByteBackend(await api.open(init: init));
  }

  @override
  Future<Uint8List> run(int service, int method, Uint8List input) async {
    final out = await _handle.run(service: service, method: method, input: input);
    return Uint8List.fromList(out);
  }

  @override
  Future<void> close() => _handle.close();
}
