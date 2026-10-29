import 'dart:typed_data';

/// Result of one rslib protobuf call.
///
/// The bridge crate returns the same shape. This package stays free of Flutter
/// and of generated bindings so the wrapper can be tested with a fake command.
class ProtoResponse {
  const ProtoResponse({required this.success, required this.payload});

  final bool success;
  final Uint8List payload;

  static final emptyOk = ProtoResponse(success: true, payload: Uint8List(0));
}
