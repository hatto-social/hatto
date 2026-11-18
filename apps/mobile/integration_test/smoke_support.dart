// Protobuf helpers for the arm64 device smoke.
//
// apps/mobile has no generated Anki protobuf library. These builders and
// readers cover only the messages the smoke calls, using the field numbers
// from Anki 26.09.3. rslib itself is not modified; the bytes go through
// rslib_bridge `command`.

import 'dart:convert';
import 'dart:typed_data';

const namespaceUrl = '6ba7b811-9dad-11d1-80b4-00c04fd430c8';

const cardedRevlogSql =
    'select count(*) from revlog where cid in (select id from cards)';

class PbWriter {
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  void varint(int value) {
    // Dart's `<<` is a wrapping 64-bit shift, so a negative int64 is written
    // as nine low groups plus the sign bit. Protobuf sign-extends to 64 bits.
    if (value >= 0) {
      var rest = value;
      while (rest > 0x7f) {
        _bytes.addByte((rest & 0x7f) | 0x80);
        rest >>= 7;
      }
      _bytes.addByte(rest);
      return;
    }
    var rest = value;
    for (var i = 0; i < 9; i++) {
      _bytes.addByte((rest & 0x7f) | 0x80);
      rest >>= 7;
    }
    _bytes.addByte(0x01);
  }

  void _key(int field, int wire) => varint((field << 3) | wire);

  void varintField(int field, int value) {
    _key(field, 0);
    varint(value);
  }

  /// Proto3 scalar. Zero is the default and is not written.
  void int64Field(int field, int value) {
    if (value == 0) {
      return;
    }
    varintField(field, value);
  }

  void boolField(int field, bool value) {
    if (!value) {
      return;
    }
    varintField(field, 1);
  }

  void bytesField(int field, List<int> payload) {
    _key(field, 2);
    varint(payload.length);
    _bytes.add(payload);
  }

  void stringField(int field, String value, {bool omitEmpty = true}) {
    if (omitEmpty && value.isEmpty) {
      return;
    }
    bytesField(field, utf8.encode(value));
  }

  void packedVarints(int field, List<int> values) {
    if (values.isEmpty) {
      return;
    }
    final inner = PbWriter();
    for (final value in values) {
      inner.varint(value);
    }
    bytesField(field, inner.takeBytes());
  }

  Uint8List takeBytes() => _bytes.takeBytes();
}

class PbField {
  PbField({
    required this.number,
    required this.wire,
    this.varintValue = 0,
    Uint8List? bytes,
  }) : bytes = bytes ?? Uint8List(0);

  final int number;
  final int wire;
  final int varintValue;
  final Uint8List bytes;
}

List<PbField> parseFields(Uint8List data) {
  final out = <PbField>[];
  var index = 0;

  int readVarint() {
    // Multiply by 128 instead of shifting. `1 << 63` is negative on the Dart
    // VM, and that wrapping is what turns a 10-byte sign-extended varint
    // (usn = -1) back into a negative int.
    var result = 0;
    var place = 1;
    for (var i = 0; i < 10; i++) {
      if (index >= data.length) {
        throw const FormatException('truncated varint');
      }
      final byte = data[index++];
      result += (byte & 0x7f) * place;
      if ((byte & 0x80) == 0) {
        return result;
      }
      place *= 128;
    }
    throw const FormatException('varint too long');
  }

  while (index < data.length) {
    final key = readVarint();
    final number = key >> 3;
    final wire = key & 7;
    switch (wire) {
      case 0:
        out.add(PbField(number: number, wire: wire, varintValue: readVarint()));
      case 1:
        if (index + 8 > data.length) {
          throw const FormatException('truncated fixed64');
        }
        out.add(
          PbField(
            number: number,
            wire: wire,
            bytes: Uint8List.fromList(data.sublist(index, index + 8)),
          ),
        );
        index += 8;
      case 2:
        final length = readVarint();
        if (length < 0 || index + length > data.length) {
          throw const FormatException('truncated length-delimited field');
        }
        out.add(
          PbField(
            number: number,
            wire: wire,
            bytes: Uint8List.fromList(data.sublist(index, index + length)),
          ),
        );
        index += length;
      case 5:
        if (index + 4 > data.length) {
          throw const FormatException('truncated fixed32');
        }
        out.add(
          PbField(
            number: number,
            wire: wire,
            bytes: Uint8List.fromList(data.sublist(index, index + 4)),
          ),
        );
        index += 4;
      default:
        throw FormatException('unsupported wire type $wire');
    }
  }
  return out;
}

double readFloat32(Uint8List bytes) {
  if (bytes.length != 4) {
    throw FormatException('expected 4-byte float, got ${bytes.length}');
  }
  return ByteData.sublistView(bytes).getFloat32(0, Endian.little);
}

List<double> readPackedFloats(Uint8List bytes) {
  if (bytes.length % 4 != 0) {
    throw FormatException('packed floats length ${bytes.length}');
  }
  final view = ByteData.sublistView(bytes);
  return [
    for (var offset = 0; offset < bytes.length; offset += 4)
      view.getFloat32(offset, Endian.little),
  ];
}

Uint8List sha1Bytes(List<int> message) {
  final bitLength = message.length * 8;
  var paddedLength = message.length + 1;
  while (paddedLength % 64 != 56) {
    paddedLength++;
  }
  final padded = Uint8List(paddedLength + 8);
  padded.setRange(0, message.length, message);
  padded[message.length] = 0x80;
  final view = ByteData.sublistView(padded);
  view.setUint32(padded.length - 8, bitLength ~/ 0x100000000, Endian.big);
  view.setUint32(padded.length - 4, bitLength & 0xffffffff, Endian.big);

  var h0 = 0x67452301;
  var h1 = 0xefcdab89;
  var h2 = 0x98badcfe;
  var h3 = 0x10325476;
  var h4 = 0xc3d2e1f0;
  final words = List<int>.filled(80, 0);

  for (var offset = 0; offset < padded.length; offset += 64) {
    for (var i = 0; i < 16; i++) {
      words[i] = view.getUint32(offset + (i * 4), Endian.big);
    }
    for (var i = 16; i < 80; i++) {
      words[i] = _rotl(
        words[i - 3] ^ words[i - 8] ^ words[i - 14] ^ words[i - 16],
        1,
      );
    }
    var a = h0;
    var b = h1;
    var c = h2;
    var d = h3;
    var e = h4;
    for (var i = 0; i < 80; i++) {
      final int f;
      final int k;
      if (i < 20) {
        f = (b & c) | ((~b) & d);
        k = 0x5a827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ed9eba1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8f1bbcdc;
      } else {
        f = b ^ c ^ d;
        k = 0xca62c1d6;
      }
      final next =
          (_rotl(a, 5) + (f & 0xffffffff) + e + k + words[i]) & 0xffffffff;
      e = d;
      d = c;
      c = _rotl(b, 30);
      b = a;
      a = next;
    }
    h0 = (h0 + a) & 0xffffffff;
    h1 = (h1 + b) & 0xffffffff;
    h2 = (h2 + c) & 0xffffffff;
    h3 = (h3 + d) & 0xffffffff;
    h4 = (h4 + e) & 0xffffffff;
  }

  final out = Uint8List(20);
  final digest = ByteData.sublistView(out);
  digest.setUint32(0, h0, Endian.big);
  digest.setUint32(4, h1, Endian.big);
  digest.setUint32(8, h2, Endian.big);
  digest.setUint32(12, h3, Endian.big);
  digest.setUint32(16, h4, Endian.big);
  return out;
}

int _rotl(int value, int bits) {
  final masked = value & 0xffffffff;
  return ((masked << bits) | (masked >> (32 - bits))) & 0xffffffff;
}

Uint8List uuidToBytes(String uuid) {
  final hex = uuid.replaceAll('-', '');
  if (hex.length != 32) {
    throw FormatException('not a uuid: $uuid');
  }
  final out = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String formatUuid(Uint8List bytes) {
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-'
      '${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}

/// RFC 4122 UUID version 5. [namespace] is a UUID string.
String uuid5(String namespace, String name) {
  final hash = sha1Bytes([...uuidToBytes(namespace), ...utf8.encode(name)]);
  final bytes = Uint8List.fromList(hash.sublist(0, 16));
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  return formatUuid(bytes);
}

class NoteView {
  NoteView({
    required this.id,
    required this.guid,
    required this.notetypeId,
    required this.mtimeSecs,
    required this.usn,
    required this.tags,
    required this.fields,
  });

  final int id;
  String guid;
  final int notetypeId;
  final int mtimeSecs;
  final int usn;
  final List<String> tags;
  final List<String> fields;
}

Uint8List encodeNote(NoteView note) {
  final writer = PbWriter()
    ..int64Field(1, note.id)
    ..stringField(2, note.guid, omitEmpty: false)
    ..int64Field(3, note.notetypeId);
  if (note.mtimeSecs != 0) {
    writer.varintField(4, note.mtimeSecs);
  }
  if (note.usn != 0) {
    writer.int64Field(5, note.usn);
  }
  for (final tag in note.tags) {
    writer.stringField(6, tag, omitEmpty: false);
  }
  for (final field in note.fields) {
    writer.stringField(7, field, omitEmpty: false);
  }
  return writer.takeBytes();
}

NoteView decodeNote(Uint8List bytes) {
  var id = 0;
  var guid = '';
  var notetypeId = 0;
  var mtimeSecs = 0;
  var usn = 0;
  final tags = <String>[];
  final fields = <String>[];
  for (final field in parseFields(bytes)) {
    switch (field.number) {
      case 1:
        id = field.varintValue;
      case 2:
        guid = utf8.decode(field.bytes);
      case 3:
        notetypeId = field.varintValue;
      case 4:
        mtimeSecs = field.varintValue;
      case 5:
        usn = field.varintValue;
      case 6:
        tags.add(utf8.decode(field.bytes));
      case 7:
        fields.add(utf8.decode(field.bytes));
    }
  }
  return NoteView(
    id: id,
    guid: guid,
    notetypeId: notetypeId,
    mtimeSecs: mtimeSecs,
    usn: usn,
    tags: tags,
    fields: fields,
  );
}

Uint8List backendInit() {
  final writer = PbWriter()..stringField(1, 'en');
  return writer.takeBytes();
}

Uint8List openCollectionRequest({
  required String collectionPath,
  required String mediaFolderPath,
  required String mediaDbPath,
}) {
  final writer = PbWriter()
    ..stringField(1, collectionPath)
    ..stringField(2, mediaFolderPath)
    ..stringField(3, mediaDbPath);
  return writer.takeBytes();
}

Uint8List importCollectionPackageRequest({
  required String colPath,
  required String backupPath,
  required String mediaFolder,
  required String mediaDb,
}) {
  final writer = PbWriter()
    ..stringField(1, colPath)
    ..stringField(2, backupPath)
    ..stringField(3, mediaFolder)
    ..stringField(4, mediaDb);
  return writer.takeBytes();
}

Uint8List _importAnkiPackageOptions() {
  final writer = PbWriter()
    ..varintField(2, 2)
    ..varintField(3, 2)
    ..boolField(4, true)
    ..boolField(5, true);
  return writer.takeBytes();
}

Uint8List importAnkiPackageRequest(String packagePath) {
  final writer = PbWriter()
    ..stringField(1, packagePath)
    ..bytesField(2, _importAnkiPackageOptions());
  return writer.takeBytes();
}

Uint8List exportWholeCollectionRequest(String outPath) {
  final options = PbWriter()
    ..boolField(1, true)
    ..boolField(2, true)
    ..boolField(3, true);
  final limit = PbWriter()..bytesField(1, const <int>[]);
  final writer = PbWriter()
    ..stringField(1, outPath)
    ..bytesField(2, options.takeBytes())
    ..bytesField(3, limit.takeBytes());
  return writer.takeBytes();
}

/// `search=""`, `ignore_revlogs_before_ms=0`, `num_of_relearning_steps=1`,
/// `health_check=false`. Defaults are omitted.
Uint8List computeFsrsRequest() {
  final writer = PbWriter()..varintField(4, 1);
  return writer.takeBytes();
}

Uint8List idMessage(int id) {
  final writer = PbWriter()..int64Field(1, id);
  return writer.takeBytes();
}

Uint8List deckIdsMessage(List<int> dids) {
  final writer = PbWriter()..packedVarints(1, dids);
  return writer.takeBytes();
}

Uint8List updateNotesRequest(List<NoteView> notes) {
  final writer = PbWriter();
  for (final note in notes) {
    writer.bytesField(1, encodeNote(note));
  }
  return writer.takeBytes();
}

Uint8List changeNotetypeRequest({
  required List<int> noteIds,
  required List<int> newFields,
  required List<int> newTemplates,
  required int oldNotetypeId,
  required int newNotetypeId,
  required int currentSchema,
  required String oldNotetypeName,
}) {
  final writer = PbWriter()
    ..packedVarints(1, noteIds)
    ..packedVarints(2, newFields)
    ..packedVarints(3, newTemplates)
    ..int64Field(4, oldNotetypeId)
    ..int64Field(5, newNotetypeId)
    ..int64Field(6, currentSchema)
    ..stringField(7, oldNotetypeName);
  return writer.takeBytes();
}

Uint8List pbJson(String json) {
  final writer = PbWriter()..bytesField(1, utf8.encode(json));
  return writer.takeBytes();
}

String readJsonString(Uint8List message) {
  for (final field in parseFields(message)) {
    if (field.number == 1 && field.wire == 2) {
      return utf8.decode(field.bytes);
    }
  }
  throw const FormatException('json payload missing');
}

int readVarintField(Uint8List message, {int number = 1}) {
  for (final field in parseFields(message)) {
    if (field.number == number && field.wire == 0) {
      return field.varintValue;
    }
  }
  return 0;
}

class FsrsParams {
  const FsrsParams({required this.params, required this.items});

  final List<double> params;
  final int items;
}

FsrsParams readFsrsResponse(Uint8List message) {
  final params = <double>[];
  var items = 0;
  for (final field in parseFields(message)) {
    // ComputeFsrsParamsResponse.params is `repeated float`, not double.
    if (field.number == 1 && field.wire == 2) {
      params.addAll(readPackedFloats(field.bytes));
    } else if (field.number == 1 && field.wire == 5) {
      params.add(readFloat32(field.bytes));
    } else if (field.number == 2 && field.wire == 0) {
      items = field.varintValue;
    }
  }
  return FsrsParams(params: params, items: items);
}

class ImportCounts {
  const ImportCounts({required this.created, required this.duplicate});

  final int created;
  final int duplicate;
}

ImportCounts readImportCounts(Uint8List message) {
  var created = 0;
  var duplicate = 0;
  for (final log in parseFields(message)) {
    if (log.number != 2 || log.wire != 2) {
      continue;
    }
    for (final field in parseFields(log.bytes)) {
      if (field.wire != 2) {
        continue;
      }
      if (field.number == 1) {
        created++;
      } else if (field.number == 3) {
        duplicate++;
      }
    }
  }
  return ImportCounts(created: created, duplicate: duplicate);
}

List<String> readNotetypeNames(Uint8List message) {
  final names = <String>[];
  for (final entry in parseFields(message)) {
    if (entry.number != 1 || entry.wire != 2) {
      continue;
    }
    for (final field in parseFields(entry.bytes)) {
      if (field.number == 2 && field.wire == 2) {
        names.add(utf8.decode(field.bytes));
      }
    }
  }
  return names;
}

String describeBackendError(Uint8List bytes) {
  try {
    String? message;
    int? kind;
    for (final field in parseFields(bytes)) {
      if (field.number == 1 && field.wire == 2) {
        message = utf8.decode(field.bytes);
      } else if (field.number == 2 && field.wire == 0) {
        kind = field.varintValue;
      }
    }
    if (message == null) {
      return 'undecodable backend error (${bytes.length} bytes)';
    }
    return kind == null ? message : '$message (kind=$kind)';
  } catch (_) {
    return 'undecodable backend error (${bytes.length} bytes)';
  }
}

int asInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is double && value.isFinite && value == value.roundToDouble()) {
    return value.toInt();
  }
  throw StateError('expected an integer from SQL, got $value');
}

String canonSql(Object? value) {
  if (value == null) {
    return 'null';
  }
  if (value is int) {
    return value.toString();
  }
  if (value is double && value.isFinite && value == value.roundToDouble()) {
    return value.toInt().toString();
  }
  return value.toString();
}

bool sameSqlRows(List<List<Object?>> left, List<List<Object?>> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var row = 0; row < left.length; row++) {
    if (left[row].length != right[row].length) {
      return false;
    }
    for (var column = 0; column < left[row].length; column++) {
      if (canonSql(left[row][column]) != canonSql(right[row][column])) {
        return false;
      }
    }
  }
  return true;
}

bool isFilteredDeck(Object? dyn) => dyn == 1 || dyn == true;

bool fsrsValuesFinite(List<double> params) =>
    params.isNotEmpty &&
    params.every((value) => value.isFinite && value > 0 && value <= 100);

bool fsrsRunsMatch({
  required int itemsA,
  required List<double> paramsA,
  required int itemsB,
  required List<double> paramsB,
}) {
  if (itemsA != itemsB || paramsA.length != paramsB.length) {
    return false;
  }
  for (var i = 0; i < paramsA.length; i++) {
    if (paramsA[i] != paramsB[i]) {
      return false;
    }
  }
  return true;
}

class ColCounts {
  const ColCounts({
    required this.notes,
    required this.cards,
    required this.revlogTotal,
    required this.revlogWithCard,
  });

  final int notes;
  final int cards;
  final int revlogTotal;
  final int revlogWithCard;
}

String formatColLine(String filename, ColCounts extracted, ColCounts resident) {
  return 'HATTO_SMOKE col:$filename'
      ' E_notes=${extracted.notes}'
      ' E_cards=${extracted.cards}'
      ' E_revlog_total=${extracted.revlogTotal}'
      ' E_revlog_with_card=${extracted.revlogWithCard}'
      ' R_notes=${resident.notes}'
      ' R_cards=${resident.cards}'
      ' R_revlog_total=${resident.revlogTotal}'
      ' R_revlog_with_card=${resident.revlogWithCard}';
}

String formatSeconds(double seconds) {
  var text = seconds.toStringAsFixed(3);
  text = text.replaceFirst(RegExp(r'0+$'), '');
  text = text.replaceFirst(RegExp(r'\.$'), '');
  return text;
}

String formatFsrsLine({
  required int importNotes,
  required int importCards,
  required int importRevlog,
  required int fsrsItems,
  required List<double> params,
  required bool secondIdentical,
  required bool colUnchanged,
  required bool configUnchanged,
  required double seconds,
}) {
  final finite = fsrsValuesFinite(params);
  final rendered = params.map((value) => value.toString()).join(',');
  final paramsField = rendered.isEmpty ? 'params=""' : 'params=$rendered';
  return 'HATTO_SMOKE fsrs'
      ' import_notes=$importNotes'
      ' import_cards=$importCards'
      ' import_revlog=$importRevlog'
      ' fsrs_items=$fsrsItems'
      ' n_params=${params.length}'
      ' finite=${finite ? 1 : 0}'
      ' second_identical=${secondIdentical ? 1 : 0}'
      ' col_unchanged=${colUnchanged ? 1 : 0}'
      ' config_unchanged=${configUnchanged ? 1 : 0}'
      ' seconds=${formatSeconds(seconds)}'
      ' $paramsField';
}

String formatNotetypeLine({
  required String job,
  required int before,
  required int after,
  required List<String> newNames,
  required int newNotes,
  required int duplicates,
  String? notesPerNotetype,
}) {
  final names = [...newNames]..sort();
  final buffer = StringBuffer('HATTO_SMOKE nt:$job')
    ..write(' before=$before')
    ..write(' after=$after')
    ..write(' new_names="${names.join('|')}"')
    ..write(' new_notes=$newNotes')
    ..write(' dup=$duplicates');
  if (notesPerNotetype != null) {
    buffer.write(' notes_per_notetype="$notesPerNotetype"');
  }
  return buffer.toString();
}

String formatNotesPerNotetype(List<({String name, int count})> rows) {
  final sorted = [...rows]..sort((a, b) => a.name.compareTo(b.name));
  return sorted.map((row) => '${row.name}=${row.count}').join('|');
}
