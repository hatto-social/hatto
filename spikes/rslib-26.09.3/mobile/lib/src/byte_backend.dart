import 'dart:typed_data';

/// The protobuf bytes contract shared with the napi spike.
abstract class ByteBackend {
  Future<Uint8List> run(int service, int method, Uint8List input);
  Future<void> close();
}
