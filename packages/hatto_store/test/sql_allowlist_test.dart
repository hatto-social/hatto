// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:hatto_store/hatto_store.dart';
import 'package:test/test.dart';

/// Selects the mobile `RunDbCommand` caller already issues. These must keep
/// reaching the command. Anything else must not.
const legitimateReads = <String>[
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

void main() {
  test('with-prefixed writes are rejected before rslib', () async {
    const writes = <String>[
      "with x as (select 1) update notes set guid='HACKED2'",
      "WITH x AS (select 1) INSERT INTO notes (guid) VALUES ('HACKED2')",
      'with x as (select 1)\ndelete from notes',
    ];
    for (final sql in writes) {
      await _expectRejected(sql: sql, message: 'write SQL is not allowed');
    }
  });

  test('a with prefix is not a read, even for a select CTE', () async {
    await _expectRejected(
      sql: 'with x as (select 1) select 1',
      message: 'write SQL is not allowed',
    );
  });

  test('a write sent as kind=query is rejected before rslib', () async {
    const writes = <String>[
      "update notes set guid='HACKED2'",
      "UPDATE notes SET guid='HACKED2' WHERE id = 1",
      "insert into notes (guid) values ('HACKED2')",
      'delete from notes',
    ];
    for (final sql in writes) {
      await _expectRejected(
        sql: sql,
        kind: 'query',
        message: 'write SQL is not allowed',
      );
    }
  });

  test('RunDbCommand kind other than query is rejected before rslib', () async {
    const kinds = <String>[
      'executemany',
      'begin',
      'commit',
      'rollback',
      'execute',
      'Query',
    ];
    for (final kind in kinds) {
      await _expectRejected(
        sql: 'select count(*) from notes',
        kind: kind,
        message: 'RunDbCommand kind must be query',
      );
    }
  });

  test('allowlisted read queries still reach rslib as kind=query', () async {
    expect(SqlAllowlist.statements, legitimateReads);
    for (final sql in legitimateReads) {
      final calls = <String>[];
      await SqlAllowlist.run(
        sql: sql,
        args: sql.contains('?') ? <Object?>[7] : const <Object?>[],
        command: (jsonBody) async {
          calls.add(jsonBody);
        },
      );
      expect(calls, hasLength(1), reason: sql);
      final decoded = jsonDecode(calls.single) as Map<String, Object?>;
      expect(decoded['kind'], 'query', reason: sql);
      expect(decoded['sql'], sql, reason: sql);
      expect(decoded['first_row_only'], isFalse, reason: sql);
    }

    final calls = <String>[];
    await SqlAllowlist.run(
      sql: '  SELECT   count(*)  FROM notes  ',
      command: (jsonBody) async {
        calls.add(jsonBody);
      },
    );
    expect(calls, hasLength(1));
    final decoded = jsonDecode(calls.single) as Map<String, Object?>;
    expect(decoded['kind'], 'query');
    expect(decoded['sql'], '  SELECT   count(*)  FROM notes  ');
  });

  test('a select that is not allowlisted does not reach rslib', () async {
    await _expectRejected(
      sql: 'SELECT * FROM cards',
      message: 'SQL is not on the allowlist',
    );
  });
}

Future<void> _expectRejected({
  required String sql,
  String kind = 'query',
  required String message,
}) async {
  var called = false;
  await expectLater(
    SqlAllowlist.run(
      sql: sql,
      kind: kind,
      command: (_) async {
        called = true;
      },
    ),
    throwsA(
      isA<SqlRejected>().having((error) => error.message, 'message', message),
    ),
  );
  expect(called, isFalse, reason: '$kind $sql');
}
