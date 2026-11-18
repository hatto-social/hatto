import 'dart:convert';

/// Read-only gate in front of rslib `RunDbCommand`.
///
/// rslib's `kind: query` still executes the SQL, so an `update` sent as
/// `query` writes. A leading `with` is not a read either: it can be a
/// data-modifying CTE (`with ... update`). [run] is the path that may call
/// rslib. It accepts only `kind` `query` and a statement in [statements].
class SqlAllowlist {
  const SqlAllowlist._();

  /// Selects the mobile `RunDbCommand` caller already issues. Match is exact
  /// after trim, case folding, and whitespace collapse. A write added here
  /// is still rejected.
  static const List<String> statements = <String>[
    'select count(*) from notes',
    'select count(*) from cards',
    'select count(*) from revlog',
    'select count(*) from revlog where cid in (select id from cards)',
    'select crt, mod, scm, usn from col',
    'select count(*), sum(length(val)) from config',
    'select n.name, count(*) from notes x join notetypes n on n.id = x.mid group by n.name',
    'select id, guid from notes',
    'select id from decks',
    'select distinct mid from notes order by mid',
    'select id from notes where mid = ?',
    'select scm from col',
  ];

  /// Checks [sql] and [kind], then calls [command] with the `RunDbCommand`
  /// JSON body. [command] is rslib. A rejected call throws [SqlRejected]
  /// first and does not invoke [command].
  ///
  /// The encoded `kind` is always `query`. Any other [kind] is rejected.
  static Future<T> run<T>({
    required String sql,
    required Future<T> Function(String jsonBody) command,
    List<Object?> args = const <Object?>[],
    bool firstRowOnly = false,
    String kind = 'query',
  }) async {
    if (kind != 'query') {
      throw const SqlRejected('RunDbCommand kind must be query');
    }
    check(sql);
    final body = jsonEncode(<String, Object?>{
      'kind': 'query',
      'sql': sql,
      'args': args,
      'first_row_only': firstRowOnly,
    });
    return command(body);
  }

  static void check(String sql) {
    final normalized = sql.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) {
      throw const SqlRejected('empty SQL');
    }
    final lower = normalized.toLowerCase();
    if (lower.contains(';')) {
      throw const SqlRejected('multiple SQL statements are not allowed');
    }
    if (!_isRead(lower)) {
      throw const SqlRejected('write SQL is not allowed');
    }
    final allowed = statements
        .map(
          (statement) =>
              statement.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase(),
        )
        .toSet();
    if (!allowed.contains(lower)) {
      throw const SqlRejected('SQL is not on the allowlist');
    }
  }

  static bool _isRead(String lower) {
    return lower.startsWith('select ') || lower == 'select';
  }
}

class SqlRejected implements Exception {
  const SqlRejected(this.message);

  final String message;

  @override
  String toString() => 'SqlRejected: $message';
}
