/// Read-only SQL gate in front of rslib `RunDbCommand`.
///
/// v0 has not settled the concrete statement list (spec section 10). Until it
/// does, the allowlist is empty: every statement is rejected, and write
/// statements are rejected even if they are later added by mistake.
class SqlAllowlist {
  const SqlAllowlist._();

  static const List<String> statements = <String>[];

  static void check(String sql) {
    final normalized = sql.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) {
      throw SqlRejected('empty SQL');
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
    return lower.startsWith('select ') ||
        lower.startsWith('with ') ||
        lower == 'select' ||
        lower == 'with';
  }
}

class SqlRejected implements Exception {
  const SqlRejected(this.message);

  final String message;

  @override
  String toString() => 'SqlRejected: $message';
}
