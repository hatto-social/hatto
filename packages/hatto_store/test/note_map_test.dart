import 'package:hatto_store/hatto_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late SideDb side;

  setUp(() {
    side = SideDb.openInMemory();
    side.putDeck(deckGuid: 'deck-a', rslibDeckId: 10);
    side.putDeck(deckGuid: 'deck-b', rslibDeckId: 20);
    side.putDeck(deckGuid: 'deck-c', rslibDeckId: 30);
  });

  tearDown(() => side.close());

  test('import sets home_deck_guid from the ord-0 card', () {
    side.importNote(
      noteGuid: 'note-1',
      rslibNoteId: 100,
      cards: const [
        ImportedNoteCard(ord: 1, rslibDeckId: 20),
        ImportedNoteCard(ord: 0, rslibDeckId: 10),
      ],
    );

    final row = side.note('note-1')!;
    expect(row.homeDeckGuid, 'deck-a');
    expect(row.rslibNoteId, 100);
    expect(row.noteGuid, 'note-1');

    side.tombstoneDeck('deck-b');
    side.putDeck(deckGuid: 'deck-b', rslibDeckId: 20);
    expect(side.deck('deck-b')!.tombstoned, isTrue);
    side.importNote(
      noteGuid: 'note-tomb',
      rslibNoteId: 101,
      cards: const [
        ImportedNoteCard(ord: 2, rslibDeckId: 10),
        ImportedNoteCard(ord: 0, rslibDeckId: 20),
      ],
    );
    expect(side.note('note-tomb')!.homeDeckGuid, 'deck-b');

    expect(
      () => side.importNote(
        noteGuid: 'note-missing-ord',
        rslibNoteId: 102,
        cards: const [ImportedNoteCard(ord: 1, rslibDeckId: 10)],
      ),
      throwsA(isA<SideDbException>()),
    );
    expect(side.note('note-missing-ord'), isNull);

    expect(
      () => side.importNote(
        noteGuid: 'note-two-ord0',
        rslibNoteId: 103,
        cards: const [
          ImportedNoteCard(ord: 0, rslibDeckId: 10),
          ImportedNoteCard(ord: 0, rslibDeckId: 20),
        ],
      ),
      throwsA(isA<SideDbException>()),
    );
    expect(side.note('note-two-ord0'), isNull);

    expect(
      () => side.importNote(
        noteGuid: 'note-unknown-deck',
        rslibNoteId: 104,
        cards: const [ImportedNoteCard(ord: 0, rslibDeckId: 99)],
      ),
      throwsA(isA<SideDbException>()),
    );
    expect(
      () => side.importNote(
        noteGuid: '',
        rslibNoteId: 105,
        cards: const [ImportedNoteCard(ord: 0, rslibDeckId: 10)],
      ),
      throwsA(isA<SideDbException>()),
    );
  });

  test('home_deck_guid stays fixed after the ord-0 card moves', () {
    side.importNote(
      noteGuid: 'note-1',
      rslibNoteId: 100,
      cards: const [
        ImportedNoteCard(ord: 1, rslibDeckId: 20),
        ImportedNoteCard(ord: 0, rslibDeckId: 10),
      ],
    );

    // The move is a later import of the same note: the ord-0 card now sits
    // in deck-c. That write must not replace the home deck.
    side.importNote(
      noteGuid: 'note-1',
      rslibNoteId: 100,
      cards: const [
        ImportedNoteCard(ord: 0, rslibDeckId: 30),
        ImportedNoteCard(ord: 1, rslibDeckId: 20),
      ],
    );

    expect(side.note('note-1')!.homeDeckGuid, 'deck-a');
    expect(side.note('note-1')!.rslibNoteId, 100);
    expect(
      () => side.importNote(
        noteGuid: 'note-1',
        rslibNoteId: 999,
        cards: const [ImportedNoteCard(ord: 0, rslibDeckId: 30)],
      ),
      throwsA(isA<SideDbException>()),
    );
    expect(side.note('note-1')!.homeDeckGuid, 'deck-a');
  });

  test('rewriteDeckGuid updates deck_map and home_deck_guid, including a tombstone', () {
    side.tombstoneDeck('deck-b');
    side.importNote(
      noteGuid: 'n-live',
      rslibNoteId: 1,
      cards: const [ImportedNoteCard(ord: 0, rslibDeckId: 10)],
    );
    side.importNote(
      noteGuid: 'n-dead',
      rslibNoteId: 2,
      cards: const [
        ImportedNoteCard(ord: 1, rslibDeckId: 10),
        ImportedNoteCard(ord: 0, rslibDeckId: 20),
      ],
    );
    side.importNote(
      noteGuid: 'n-dead-2',
      rslibNoteId: 3,
      cards: const [ImportedNoteCard(ord: 0, rslibDeckId: 20)],
    );
    side.importNote(
      noteGuid: 'n-other',
      rslibNoteId: 4,
      cards: const [ImportedNoteCard(ord: 0, rslibDeckId: 30)],
    );

    side.rewriteDeckGuid(fromGuid: 'deck-a', toGuid: 'server-a');
    side.rewriteDeckGuid(fromGuid: 'deck-b', toGuid: 'server-b');

    expect(side.deck('deck-a'), isNull);
    expect(side.deck('deck-b'), isNull);
    final live = side.deck('server-a')!;
    expect(live.rslibDeckId, 10);
    expect(live.tombstoned, isFalse);
    final dead = side.deck('server-b')!;
    expect(dead.rslibDeckId, 20);
    expect(dead.tombstoned, isTrue);
    expect(side.note('n-live')!.homeDeckGuid, 'server-a');
    expect(side.note('n-dead')!.homeDeckGuid, 'server-b');
    expect(side.note('n-dead-2')!.homeDeckGuid, 'server-b');
    expect(side.note('n-other')!.homeDeckGuid, 'deck-c');

    expect(
      () => side.rewriteDeckGuid(fromGuid: 'server-b', toGuid: 'deck-c'),
      throwsA(isA<SqliteException>()),
    );
    expect(side.deck('server-b')!.tombstoned, isTrue);
    expect(side.deck('deck-c')!.rslibDeckId, 30);
    expect(side.note('n-dead')!.homeDeckGuid, 'server-b');
    expect(side.note('n-dead-2')!.homeDeckGuid, 'server-b');
    expect(side.note('n-other')!.homeDeckGuid, 'deck-c');

    expect(
      () => side.rewriteDeckGuid(fromGuid: 'missing', toGuid: 'server-x'),
      throwsA(isA<SideDbException>()),
    );
    expect(
      () => side.rewriteDeckGuid(fromGuid: '', toGuid: 'server-x'),
      throwsA(isA<SideDbException>()),
    );
  });
}
