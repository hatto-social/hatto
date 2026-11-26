// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:hatto_store/hatto_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fake_collection.dart';
import 'fake_import_engine.dart';

const batchId = '11111111-1111-4111-8111-111111111111';

void main() {
  test(
    'T18 delete then re-import updates the stale note and adds a deck',
    () async {
      final db = SideDb.openInMemory();
      addTearDown(db.close);
      final oldSha = 'ab' * 32;
      final sourceSha = 'cd' * 32;
      db.putDeck(
        deckGuid: 'old-deck',
        rslibDeckId: 1,
        importBatchId: 'old-batch',
        originKind: 'import',
        originRole: 'primary',
        sourceSha256: oldSha,
        serverUnsynced: false,
      );
      db.markDeckDeleted(
        deckGuid: 'old-deck',
        deletedAt: '2020-01-01T00:00:00Z',
      );
      db.importNote(
        noteGuid: 'n-old',
        rslibNoteId: 10,
        cards: const [ImportedNoteCard(ord: 0, rslibDeckId: 1)],
      );
      final collection = FakeCollection()
        ..decks = const [CollectionDeck(id: 8, name: 'Spanish')]
        ..addNote(id: 20, guid: 'n-old', cardId: 200, deckId: 8);
      final engine = FakeImportEngine(deckIds: const {'Spanish': 8});
      _insertImport(
        db,
        _expected(
          sourceSha256: sourceSha,
          newGuids: const ['n-old'],
          deckNames: const ['Spanish'],
        ),
      );

      await db.exclusive(() async {
        final reconcile = await reconcileInTurn(db: db, anki: collection);
        expect(reconcile.reservedImportNotes, {'n-old': 20});
        expect(reconcile.reservedImportDecks, {'Spanish': 8});
        expect(db.note('n-old')!.rslibNoteId, 10);
        expect(db.note('n-old')!.homeDeckGuid, 'old-deck');
        expect(db.deckByRslibId(8), isNull);
        await recoverImports(
          db: db,
          anki: collection,
          engine: engine,
          reconcile: reconcile,
          dataDir: '/unused',
        );
      });

      final old = db.deck('old-deck')!;
      expect(old.rslibDeckId, 1);
      expect(old.importBatchId, 'old-batch');
      expect(old.originKind, 'import');
      expect(old.originRole, 'primary');
      expect(old.sourceSha256, oldSha);
      expect(old.serverUnsynced, isFalse);
      expect(old.deletedAt, '2020-01-01T00:00:00Z');

      final created = db.deckByRslibId(8)!;
      expect(created.deckGuid, isNot('old-deck'));
      expect(created.importBatchId, batchId);
      expect(created.sourceSha256, sourceSha);
      expect(created.serverUnsynced, isTrue);
      expect(created.originKind, 'import');
      expect(created.originRole, isNull);
      expect(created.deletedAt, isNull);
      expect(db.note('n-old')!.rslibNoteId, 20);
      expect(db.note('n-old')!.homeDeckGuid, created.deckGuid);
      expect(db.notes(), hasLength(1));
      expect(db.decks(), hasLength(2));
      expect(db.pendingIntents(), isEmpty);
      expect(db.journalRows(), isEmpty);
      expect(engine.lookupNoteIds, isEmpty);

      final snapshot = _dump(db);
      await db.exclusive(() async {
        final again = await reconcileInTurn(db: db, anki: collection);
        expect(again.reservedImportNotes, isEmpty);
        expect(again.reservedImportDecks, isEmpty);
        await recoverImports(
          db: db,
          anki: collection,
          engine: engine,
          reconcile: again,
          dataDir: '/unused',
        );
      });
      expect(_dump(db), snapshot);
    },
  );

  test('T-R1 adopts a reserved new guid and is idempotent', () async {
    final db = SideDb.openInMemory();
    addTearDown(db.close);
    final dir = await Directory.systemTemp.createTemp('hatto-tr1');
    addTearDown(() => dir.delete(recursive: true));
    final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
    final sourceSha = sha256.convert(bytes).toString();
    _writeRaw(dir.path, batchId, bytes);
    final collection = FakeCollection()
      ..decks = const [CollectionDeck(id: 7, name: 'Spanish')]
      ..addNote(id: 42, guid: 'g-new', cardId: 420, deckId: 7);
    final engine = FakeImportEngine(deckIds: const {'Spanish': 7});
    _insertImport(
      db,
      _expected(
        sourceSha256: sourceSha,
        newGuids: const ['g-new'],
        deckNames: const ['Spanish'],
      ),
    );

    final first = await _turn(
      db: db,
      collection: collection,
      engine: engine,
      dataDir: dir.path,
    );
    expect(first.reservedImportNotes, {'g-new': 42});
    expect(first.reservedImportDecks, {'Spanish': 7});
    final deck = db.deckByRslibId(7)!;
    expect(deck.importBatchId, batchId);
    expect(deck.sourceSha256, sourceSha);
    expect(deck.serverUnsynced, isTrue);
    expect(deck.originKind, 'import');
    expect(deck.originRole, isNull);
    expect(db.note('g-new')!.rslibNoteId, 42);
    expect(db.note('g-new')!.homeDeckGuid, deck.deckGuid);
    expect(db.pendingIntents(), isEmpty);
    expect(db.journalRows(), isEmpty);
    expect(engine.lookupNoteIds, isEmpty);
    final archived = File(importArchivePath(dir.path, sourceSha));
    expect(archived.readAsBytesSync(), bytes);

    final snapshot = _dump(db);
    final second = await _turn(
      db: db,
      collection: collection,
      engine: engine,
      dataDir: dir.path,
    );
    expect(second.reservedImportNotes, isEmpty);
    expect(_dump(db), snapshot);
    expect(archived.readAsBytesSync(), bytes);
    expect(db.decks(), hasLength(1));
    expect(db.notes(), hasLength(1));
  });

  test('T-R2 treats matching changed hashes as committed', () async {
    final db = SideDb.openInMemory();
    addTearDown(db.close);
    final sourceSha = 'ef' * 32;
    final fileHash = sha256.convert(utf8.encode('file')).toString();
    final beforeHash = sha256.convert(utf8.encode('before')).toString();
    db.putDeck(deckGuid: 'deck-old', rslibDeckId: 3, originKind: 'editor');
    db.importNote(
      noteGuid: 'g-old',
      rslibNoteId: 5,
      cards: const [ImportedNoteCard(ord: 0, rslibDeckId: 3)],
    );
    final collection = FakeCollection()
      ..decks = const [
        CollectionDeck(id: 3, name: 'Old'),
        CollectionDeck(id: 9, name: 'Spanish'),
      ]
      ..addNote(id: 5, guid: 'g-old', cardId: 50, deckId: 3);
    final engine = FakeImportEngine(
      notes: [
        ResidentNoteFacts(guid: 'g-old', id: 5, contentHashHex: fileHash),
      ],
      deckIds: const {'Old': 3, 'Spanish': 9},
    );
    _insertImport(
      db,
      _expected(
        sourceSha256: sourceSha,
        changed: {'g-old': fileHash},
        preChanged: {'g-old': beforeHash},
        preNoteCount: 7,
        deckNames: const ['Old', 'Spanish'],
        firstImport: false,
      ),
    );

    await _turn(
      db: db,
      collection: collection,
      engine: engine,
      dataDir: '/unused',
    );

    expect(engine.lookupNoteIds, [
      [5],
    ]);
    expect(db.pendingIntents(), isEmpty);
    expect(db.journalRows(), isEmpty);
    expect(db.note('g-old')!.rslibNoteId, 5);
    expect(db.note('g-old')!.homeDeckGuid, 'deck-old');
    expect(db.deckByRslibId(3)!.originKind, 'editor');
    expect(db.deckByRslibId(3)!.deckGuid, 'deck-old');
    final spanish = db.deckByRslibId(9)!;
    expect(spanish.originKind, 'import');
    expect(spanish.originRole, isNull);
    expect(spanish.serverUnsynced, isTrue);
    expect(spanish.sourceSha256, sourceSha);
    expect(spanish.importBatchId, batchId);
    expect(spanish.deletedAt, isNull);
  });

  test('T-R3 drops an import the resident collection did not commit', () async {
    final db = SideDb.openInMemory();
    addTearDown(db.close);
    final dir = await Directory.systemTemp.createTemp('hatto-tr3');
    addTearDown(() => dir.delete(recursive: true));
    final bytes = Uint8List.fromList([8, 8, 8]);
    final sourceSha = sha256.convert(bytes).toString();
    _writeRaw(dir.path, batchId, bytes);
    db.putDeck(deckGuid: 'keep', rslibDeckId: 1, originKind: 'editor');
    db.importNote(
      noteGuid: 'keep-note',
      rslibNoteId: 2,
      cards: const [ImportedNoteCard(ord: 0, rslibDeckId: 1)],
    );
    final collection = FakeCollection()
      ..decks = const [CollectionDeck(id: 1, name: 'Keep')]
      ..addNote(id: 2, guid: 'keep-note', cardId: 20, deckId: 1);
    final engine = FakeImportEngine(deckIds: const {'Keep': 1});
    _insertImport(
      db,
      _expected(
        sourceSha256: sourceSha,
        newGuids: const ['not-in-resident'],
        deckNames: const ['Keep'],
      ),
    );
    final before = _dump(db);
    expect(
      File(p.join(dir.path, 'import', 'staged', '$batchId.apkg')).existsSync(),
      isFalse,
    );

    await _turn(
      db: db,
      collection: collection,
      engine: engine,
      dataDir: dir.path,
    );

    expect(db.pendingIntents(), isEmpty);
    expect(db.journalRows(), isEmpty);
    expect(db.note('keep-note')!.rslibNoteId, 2);
    expect(db.note('keep-note')!.homeDeckGuid, 'keep');
    expect(db.deck('keep')!.originKind, 'editor');
    expect(db.deck('keep')!.importBatchId, isNull);
    expect(File(importArchivePath(dir.path, sourceSha)).existsSync(), isFalse);
    expect(File(importRawApkgPath(dir.path, batchId)).existsSync(), isTrue);
    expect(db.notes(), hasLength(1));
    expect(db.decks(), hasLength(1));
    expect(_dump(db).split('#').first, before.split('#').first);
  });

  test(
    'T-R3 changed hashes that do not match delete the intent only',
    () async {
      final db = SideDb.openInMemory();
      addTearDown(db.close);
      final sourceSha = '11' * 32;
      final fileHash = sha256.convert(utf8.encode('file')).toString();
      final residentHash = sha256.convert(utf8.encode('other')).toString();
      db.putDeck(deckGuid: 'deck-old', rslibDeckId: 3, originKind: 'editor');
      db.importNote(
        noteGuid: 'g-old',
        rslibNoteId: 5,
        cards: const [ImportedNoteCard(ord: 0, rslibDeckId: 3)],
      );
      final collection = FakeCollection()
        ..decks = const [
          CollectionDeck(id: 3, name: 'Old'),
          CollectionDeck(id: 9, name: 'Spanish'),
        ]
        ..addNote(id: 5, guid: 'g-old', cardId: 50, deckId: 3);
      final engine = FakeImportEngine(
        notes: [
          ResidentNoteFacts(guid: 'g-old', id: 5, contentHashHex: residentHash),
        ],
        deckIds: const {'Old': 3, 'Spanish': 9},
      );
      _insertImport(
        db,
        _expected(
          sourceSha256: sourceSha,
          changed: {'g-old': fileHash},
          deckNames: const ['Spanish'],
        ),
      );

      await _turn(
        db: db,
        collection: collection,
        engine: engine,
        dataDir: '/unused',
      );

      expect(db.pendingIntents(), isEmpty);
      expect(db.journalRows(), isEmpty);
      expect(db.note('g-old')!.rslibNoteId, 5);
      expect(db.note('g-old')!.homeDeckGuid, 'deck-old');
      expect(db.deckByRslibId(9), isNull);
      expect(db.decks(), hasLength(1));
      expect(engine.lookupNoteIds, [
        [5],
      ]);
    },
  );

  test(
    'T-R4 reserves resident notes and decks, then adopts them as import',
    () async {
      final db = SideDb.openInMemory();
      addTearDown(db.close);
      final sourceSha = '22' * 32;
      final collection = FakeCollection()
        ..decks = const [CollectionDeck(id: 7, name: 'Spanish')]
        ..addNote(id: 42, guid: 'g-new', cardId: 420, deckId: 7);
      final engine = FakeImportEngine(deckIds: const {'Spanish': 7});
      _insertImport(
        db,
        _expected(
          sourceSha256: sourceSha,
          newGuids: const ['g-new'],
          deckNames: const ['Spanish'],
        ),
      );

      await db.exclusive(() async {
        final reconcile = await reconcileInTurn(db: db, anki: collection);
        expect(reconcile.reservedImportNotes, {'g-new': 42});
        expect(reconcile.reservedImportDecks, {'Spanish': 7});
        expect(db.notes(), isEmpty);
        expect(db.decks(), isEmpty);
        expect(db.pendingIntents(), hasLength(1));
        await recoverImports(
          db: db,
          anki: collection,
          engine: engine,
          reconcile: reconcile,
          dataDir: '/unused',
        );
      });

      final deck = db.deckByRslibId(7)!;
      expect(deck.importBatchId, batchId);
      expect(deck.sourceSha256, sourceSha);
      expect(deck.serverUnsynced, isTrue);
      expect(deck.originKind, 'import');
      expect(deck.originRole, isNull);
      expect(deck.deletedAt, isNull);
      expect(db.note('g-new')!.rslibNoteId, 42);
      expect(db.note('g-new')!.homeDeckGuid, deck.deckGuid);
      expect(db.decks(), hasLength(1));
      expect(db.pendingIntents(), isEmpty);
      expect(db.journalRows(), isEmpty);
      expect(db.decks().single.originKind, isNot('editor'));
    },
  );

  test(
    'an empty import plan is deleted and a corrupt expected is kept',
    () async {
      final db = SideDb.openInMemory();
      addTearDown(db.close);
      final collection = FakeCollection()..decks = const [];
      _insertImport(db, _expected(sourceSha256: '33' * 32));
      await _turn(
        db: db,
        collection: collection,
        engine: FakeImportEngine(),
        dataDir: '/unused',
      );
      expect(db.pendingIntents(), isEmpty);
      expect(db.notes(), isEmpty);
      expect(db.decks(), isEmpty);
      expect(db.journalRows(), isEmpty);

      db.beginIntent(op: intentImport, targetKey: batchId, expected: '{');
      await expectLater(
        db.exclusive(() async {
          final reconcile = await reconcileInTurn(db: db, anki: collection);
          await recoverImports(
            db: db,
            anki: collection,
            engine: FakeImportEngine(),
            reconcile: reconcile,
            dataDir: '/unused',
          );
        }),
        throwsA(isA<SideDbException>()),
      );
      expect(db.pendingIntents().single.expected, '{');
      expect(db.notes(), isEmpty);
      expect(db.decks(), isEmpty);
    },
  );

  test('a stale note_map row is not a committed import', () async {
    final db = SideDb.openInMemory();
    addTearDown(db.close);
    db.putDeck(deckGuid: 'old-deck', rslibDeckId: 1, originKind: 'editor');
    db.importNote(
      noteGuid: 'n-old',
      rslibNoteId: 10,
      cards: const [ImportedNoteCard(ord: 0, rslibDeckId: 1)],
    );
    final collection = FakeCollection()..decks = const [];
    _insertImport(
      db,
      _expected(sourceSha256: 'aa' * 32, newGuids: const ['n-old']),
    );

    await _turn(
      db: db,
      collection: collection,
      engine: FakeImportEngine(),
      dataDir: '/unused',
    );

    expect(db.pendingIntents(), isEmpty);
    expect(db.note('n-old')!.rslibNoteId, 10);
    expect(db.note('n-old')!.homeDeckGuid, 'old-deck');
    expect(db.decks(), hasLength(1));
    expect(db.journalRows(), isEmpty);
  });

  test('a revived mapped note updates its home deck', () async {
    final db = SideDb.openInMemory();
    addTearDown(db.close);
    final sourceSha = 'bb' * 32;
    db.putDeck(deckGuid: 'old-deck', rslibDeckId: 1, originKind: 'editor');
    db.importNote(
      noteGuid: 'n-old',
      rslibNoteId: 10,
      cards: const [ImportedNoteCard(ord: 0, rslibDeckId: 1)],
    );
    final collection = FakeCollection()
      ..decks = const [CollectionDeck(id: 8, name: 'Spanish')]
      ..addNote(id: 10, guid: 'n-old', cardId: 100, deckId: 8);
    final engine = FakeImportEngine(deckIds: const {'Spanish': 8});
    _insertImport(
      db,
      _expected(
        sourceSha256: sourceSha,
        newGuids: const ['n-old'],
        deckNames: const ['Spanish'],
      ),
    );

    late ReconcileResult reconcile;
    await db.exclusive(() async {
      reconcile = await reconcileInTurn(db: db, anki: collection);
      expect(reconcile.reservedImportNotes, isEmpty);
      expect(reconcile.residentImportNotes, {'n-old': 10});
      expect(db.note('n-old')!.homeDeckGuid, 'old-deck');
      await recoverImports(
        db: db,
        anki: collection,
        engine: engine,
        reconcile: reconcile,
        dataDir: '/unused',
      );
    });

    final created = db.deckByRslibId(8)!;
    expect(created.deckGuid, isNot('old-deck'));
    expect(created.originKind, 'import');
    expect(db.note('n-old')!.rslibNoteId, 10);
    expect(db.note('n-old')!.homeDeckGuid, created.deckGuid);
    expect(db.deck('old-deck')!.rslibDeckId, 1);
    expect(db.pendingIntents(), isEmpty);
    expect(db.journalRows(), isEmpty);
  });

  test(
    'a changed note keeps its original home deck after the card moves',
    () async {
      final db = SideDb.openInMemory();
      addTearDown(db.close);
      final sourceSha = 'cc' * 32;
      final fileHash = sha256.convert(utf8.encode('file')).toString();
      db.putDeck(deckGuid: 'deck-old', rslibDeckId: 3, originKind: 'editor');
      db.putDeck(deckGuid: 'deck-other', rslibDeckId: 4, originKind: 'editor');
      db.importNote(
        noteGuid: 'g-old',
        rslibNoteId: 5,
        cards: const [ImportedNoteCard(ord: 0, rslibDeckId: 3)],
      );
      final collection = FakeCollection()
        ..decks = const [
          CollectionDeck(id: 3, name: 'Old'),
          CollectionDeck(id: 4, name: 'Other'),
        ]
        ..addNote(id: 5, guid: 'g-old', cardId: 50, deckId: 4);
      final engine = FakeImportEngine(
        notes: [
          ResidentNoteFacts(guid: 'g-old', id: 5, contentHashHex: fileHash),
        ],
        deckIds: const {'Old': 3, 'Other': 4},
      );
      _insertImport(
        db,
        _expected(
          sourceSha256: sourceSha,
          changed: {'g-old': fileHash},
          deckNames: const ['Old', 'Other'],
          firstImport: false,
        ),
      );

      await _turn(
        db: db,
        collection: collection,
        engine: engine,
        dataDir: '/unused',
      );

      expect(db.note('g-old')!.rslibNoteId, 5);
      expect(db.note('g-old')!.homeDeckGuid, 'deck-old');
      expect(db.deck('deck-other')!.rslibDeckId, 4);
      expect(db.decks(), hasLength(2));
      expect(db.pendingIntents(), isEmpty);
      expect(db.journalRows(), isEmpty);
    },
  );

  test('a raw digest mismatch leaves the intent pending', () async {
    final db = SideDb.openInMemory();
    addTearDown(db.close);
    final dir = await Directory.systemTemp.createTemp('hatto-raw-mismatch');
    addTearDown(() => dir.delete(recursive: true));
    final bytes = Uint8List.fromList([7, 7, 7]);
    final actual = sha256.convert(bytes).toString();
    final expectedSha = 'dd' * 32;
    _writeRaw(dir.path, batchId, bytes);
    final collection = FakeCollection()
      ..decks = const [CollectionDeck(id: 7, name: 'Spanish')]
      ..addNote(id: 42, guid: 'g-new', cardId: 420, deckId: 7);
    final engine = FakeImportEngine(deckIds: const {'Spanish': 7});
    _insertImport(
      db,
      _expected(
        sourceSha256: expectedSha,
        newGuids: const ['g-new'],
        deckNames: const ['Spanish'],
      ),
    );

    await expectLater(
      db.exclusive(() async {
        final reconcile = await reconcileInTurn(db: db, anki: collection);
        await recoverImports(
          db: db,
          anki: collection,
          engine: engine,
          reconcile: reconcile,
          dataDir: dir.path,
        );
      }),
      throwsA(isA<SideDbException>()),
    );

    expect(db.pendingIntents(), hasLength(1));
    expect(db.note('g-new'), isNull);
    expect(db.deckByRslibId(7), isNull);
    expect(db.journalRows(), isEmpty);
    expect(File(importArchivePath(dir.path, actual)).existsSync(), isTrue);
    expect(
      File(importArchivePath(dir.path, expectedSha)).existsSync(),
      isFalse,
    );
  });

  test('a soft-deleted deck row is reused for the same rslib id', () async {
    final db = SideDb.openInMemory();
    addTearDown(db.close);
    const deletedAt = '2020-01-01T00:00:00Z';
    db.putDeck(
      deckGuid: 'old-deck',
      rslibDeckId: 7,
      originKind: 'import',
      originRole: 'primary',
      sourceSha256: 'ee' * 32,
    );
    db.markDeckDeleted(deckGuid: 'old-deck', deletedAt: deletedAt);
    final collection = FakeCollection()
      ..decks = const [CollectionDeck(id: 7, name: 'Spanish')]
      ..addNote(id: 42, guid: 'g-new', cardId: 420, deckId: 7);
    final engine = FakeImportEngine(deckIds: const {'Spanish': 7});
    _insertImport(
      db,
      _expected(
        sourceSha256: 'ff' * 32,
        newGuids: const ['g-new'],
        deckNames: const ['Spanish'],
      ),
    );

    await _turn(
      db: db,
      collection: collection,
      engine: engine,
      dataDir: '/unused',
    );

    expect(db.decks(), hasLength(1));
    final deck = db.deck('old-deck')!;
    expect(deck.rslibDeckId, 7);
    expect(deck.deletedAt, deletedAt);
    expect(deck.originKind, 'import');
    expect(deck.originRole, 'primary');
    expect(deck.sourceSha256, 'ee' * 32);
    expect(db.deckByRslibId(7)!.deckGuid, 'old-deck');
    expect(db.note('g-new')!.rslibNoteId, 42);
    expect(db.note('g-new')!.homeDeckGuid, 'old-deck');
    expect(db.pendingIntents(), isEmpty);
    expect(db.journalRows(), isEmpty);
  });

  test('a mapped id whose live guid is in new_guids stays reserved', () async {
    final db = SideDb.openInMemory();
    addTearDown(db.close);
    final sourceSha = 'ab' * 32;
    db.putDeck(deckGuid: 'old-home', rslibDeckId: 1, originKind: 'editor');
    db.importNote(
      noteGuid: 'stale-guid',
      rslibNoteId: 7,
      cards: const [ImportedNoteCard(ord: 0, rslibDeckId: 1)],
    );
    final collection = FakeCollection()
      ..decks = const [CollectionDeck(id: 8, name: 'Spanish')]
      ..addNote(id: 7, guid: 'live-new', cardId: 70, deckId: 8);
    final engine = FakeImportEngine(deckIds: const {'Spanish': 8});
    _insertImport(
      db,
      _expected(
        sourceSha256: sourceSha,
        newGuids: const ['live-new'],
        deckNames: const ['Spanish'],
      ),
    );

    final reconcile = await _turn(
      db: db,
      collection: collection,
      engine: engine,
      dataDir: '/unused',
    );

    expect(reconcile.reservedImportNotes, {'live-new': 7});
    expect(reconcile.residentImportNotes, {'live-new': 7});
    expect(db.note('stale-guid'), isNull);
    expect(db.note('live-new')!.rslibNoteId, 7);
    final deck = db.deckByRslibId(8)!;
    expect(deck.originKind, 'import');
    expect(deck.originRole, isNull);
    expect(deck.importBatchId, batchId);
    expect(deck.sourceSha256, sourceSha);
    expect(deck.serverUnsynced, isTrue);
    expect(db.note('live-new')!.homeDeckGuid, deck.deckGuid);
    expect(db.deckByRslibId(1)!.originKind, 'editor');
    expect(db.pendingIntents(), isEmpty);
    expect(db.journalRows(), isEmpty);
  });

  test('recoverImports outside an exclusive turn throws', () async {
    final db = SideDb.openInMemory();
    addTearDown(db.close);
    await expectLater(
      recoverImports(
        db: db,
        anki: FakeCollection(),
        engine: FakeImportEngine(),
        reconcile: const ReconcileResult(skippedNotes: []),
        dataDir: '/unused',
      ),
      throwsA(isA<StateError>()),
    );
  });
}

Future<ReconcileResult> _turn({
  required SideDb db,
  required FakeCollection collection,
  required FakeImportEngine engine,
  required String dataDir,
}) {
  return db.exclusive(() async {
    final reconcile = await reconcileInTurn(db: db, anki: collection);
    await recoverImports(
      db: db,
      anki: collection,
      engine: engine,
      reconcile: reconcile,
      dataDir: dataDir,
    );
    return reconcile;
  });
}

void _insertImport(SideDb db, ImportIntentExpected expected) {
  db.beginIntent(
    op: intentImport,
    targetKey: batchId,
    expected: encodeImportIntentExpected(expected),
  );
}

ImportIntentExpected _expected({
  required String sourceSha256,
  List<String> newGuids = const [],
  Map<String, String> changed = const {},
  Map<String, String>? preChanged,
  List<String> deckNames = const [],
  int preNoteCount = 0,
  bool firstImport = true,
}) {
  return ImportIntentExpected(
    sourceSha256: sourceSha256,
    stagedSha256: sourceSha256,
    firstImport: firstImport,
    newGuids: newGuids,
    changed: changed,
    deckNames: deckNames,
    pre: ImportIntentPre(
      noteCount: preNoteCount,
      changed: preChanged ?? changed,
    ),
  );
}

void _writeRaw(String dataDir, String batch, List<int> bytes) {
  final file = File(importRawApkgPath(dataDir, batch));
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
}

String _dump(SideDb db) {
  final notes = [
    for (final row in db.notes())
      '${row.noteGuid}:${row.rslibNoteId}:${row.homeDeckGuid}',
  ].join('|');
  final decks = [
    for (final row in db.decks())
      '${row.deckGuid}:${row.rslibDeckId}:${row.importBatchId}:'
          '${row.originKind}:${row.originRole}:${row.sourceSha256}:'
          '${row.serverUnsynced}:${row.deletedAt}',
  ].join('|');
  final intents = [
    for (final row in db.pendingIntents())
      '${row.op}:${row.targetKey}:${row.expected}',
  ].join('|');
  return '$notes#$decks#$intents#${db.journalRows().length}';
}
