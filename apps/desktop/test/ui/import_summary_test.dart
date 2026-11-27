// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_desktop/ui/import_copy.dart';
import 'package:hatto_store/hatto_store.dart';

PreparedPlan plan({
  bool firstImport = true,
  List<String> deckNames = const [],
  int newNotes = 0,
  int changed = 0,
  int localNewer = 0,
  int same = 0,
  int blocked = 0,
  int dup = 0,
  int noCards = 0,
}) {
  return PreparedPlan(
    batchId: '11111111-1111-4111-8111-111111111111',
    stagedPath: '/tmp/staged.apkg',
    stagedSha256: 'ab',
    firstImport: firstImport,
    newGuids: const [],
    changed: const {},
    deckNames: deckNames,
    counts: ImportPlanCounts(
      newNotes: newNotes,
      same: same,
      changed: changed,
      localNewer: localNewer,
      blocked: blocked,
      dup: dup,
      noResidentCall: newNotes + changed == 0,
    ),
    cardlessNotes: noCards,
  );
}

void main() {
  const fileName = 'words.apkg';

  test('T-I5-C quotes are Korean single quotes', () {
    expect(kQuoteOpen.codeUnitAt(0), 0x2018);
    expect(kQuoteClose.codeUnitAt(0), 0x2019);
    expect(quoteName('덱'), '‘덱’');
  });

  test('T-I5-C copy spells 컬렉션', () {
    final text = File('lib/ui/import_copy.dart').readAsStringSync();
    expect(text.contains('콜렉션'), isFalse);
    expect(text.contains('컬렉션'), isTrue);
  });

  test('T-I5-C single non-Default deck titles', () {
    final first = formatImportSummary(
      plan: plan(
        firstImport: true,
        deckNames: const ['Default', '한국어'],
        newNotes: 2,
      ),
      fileName: fileName,
    );
    expect(first.title, '‘한국어’ 덱을 가져왔어요.');

    final update = formatImportSummary(
      plan: plan(firstImport: false, deckNames: const ['한국어'], changed: 1),
      fileName: fileName,
    );
    expect(update.title, '‘한국어’ 덱을 업데이트했어요.');
  });

  test('T-I5-C J-I5-3 zero or many non-Default decks use the file name', () {
    for (final names in const [
      <String>['Default'],
      <String>[],
      <String>['문법', '단어'],
      <String>['Default', '문법', '단어'],
    ]) {
      final summary = formatImportSummary(
        plan: plan(deckNames: names, newNotes: 1),
        fileName: fileName,
      );
      expect(summary.title, '‘words.apkg’을 가져왔어요.', reason: '$names');
    }
  });

  test('T-I5-C J-new-1 titles when nothing was added or changed', () {
    final first = formatImportSummary(
      plan: plan(firstImport: true),
      fileName: fileName,
    );
    expect(first.title, '가져온 노트가 없어요.');
    expect(first.isSingleLine, isTrue);

    final blocked = formatImportSummary(
      plan: plan(firstImport: false, blocked: 2),
      fileName: fileName,
    );
    expect(blocked.title, '업데이트한 노트가 없어요.');
    expect(blocked.details, ['노트타입이 달라 2개는 업데이트하지 못했어요.']);
    expect(blocked.footer, isNull);

    final sameDeck = formatImportSummary(
      plan: plan(firstImport: false),
      fileName: fileName,
    );
    expect(sameDeck.title, '이미 가져온 덱이에요. 바뀐 내용이 없어서 그대로 뒀어요.');
    expect(sameDeck.isSingleLine, isTrue);

    final firstBlocked = formatImportSummary(
      plan: plan(firstImport: true, blocked: 1),
      fileName: fileName,
    );
    expect(firstBlocked.title, '가져온 노트가 없어요.');
  });

  test('T-I5-C detail lines keep order and hide zeroes', () {
    final full = formatImportSummary(
      plan: plan(
        firstImport: false,
        deckNames: const ['문법'],
        newNotes: 1,
        changed: 2,
        localNewer: 3,
        same: 4,
        blocked: 5,
        noCards: 6,
        dup: 7,
      ),
      fileName: fileName,
    );
    expect(full.details, [
      '새 노트 1개를 추가했어요.',
      '바뀐 노트 2개를 업데이트했어요.',
      '내가 고쳐서 유지 3개',
      '바뀐 내용이 없는 노트 4개는 그대로 뒀어요.',
      '노트타입이 달라 5개는 업데이트하지 못했어요.',
      '카드가 없는 노트 6개는 가져오지 않았어요.',
      '파일 안에서 ID가 겹친 노트 7개는 따로따로 가져왔어요.',
    ]);
    expect(full.footer, kLearningRecord);
    expect(full.lines.last, kLearningRecord);

    final changedOnly = formatImportSummary(
      plan: plan(firstImport: false, changed: 2, deckNames: const ['문법']),
      fileName: fileName,
    );
    expect(changedOnly.details, ['바뀐 노트 2개를 업데이트했어요.']);
    expect(changedOnly.details.join('\n'), isNot(contains('새 노트')));
  });

  test('T-I5-C G-I5-4 footer follows changed, localNewer, or same', () {
    expect(
      formatImportSummary(
        plan: plan(changed: 1, deckNames: const ['문법']),
        fileName: fileName,
      ).footer,
      kLearningRecord,
    );
    expect(
      formatImportSummary(
        plan: plan(firstImport: false, localNewer: 1),
        fileName: fileName,
      ).footer,
      kLearningRecord,
    );
    expect(
      formatImportSummary(
        plan: plan(firstImport: false, same: 4),
        fileName: fileName,
      ).footer,
      kLearningRecord,
    );
    expect(
      formatImportSummary(
        plan: plan(firstImport: false, blocked: 9),
        fileName: fileName,
      ).footer,
      isNull,
    );
    expect(
      formatImportSummary(
        plan: plan(newNotes: 3, deckNames: const ['문법']),
        fileName: fileName,
      ).footer,
      isNull,
    );
    final cardless = formatImportSummary(
      plan: plan(newNotes: 1, noCards: 2, deckNames: const ['문법']),
      fileName: fileName,
    );
    expect(cardless.lines.join('\n'), isNot(contains('카드 ')));
    expect(cardless.lines.join('\n'), contains('카드가 없는 노트 2개'));
  });

  test('T-I5-C O4 error messages use the fixed prefixes', () {
    expect(
      messageForImportFailure(
        outcome: ImportOutcome.failedBeforeCommit,
        error: 'format: not a zip',
        fileName: fileName,
      ),
      kFormatFailure,
    );
    expect(
      messageForImportFailure(
        outcome: ImportOutcome.failedBeforeCommit,
        error: Exception('too_large:compressed: 999'),
        fileName: fileName,
      ),
      '‘words.apkg’ 파일은 너무 커서 가져올 수 없어요. 512 MiB 이하 파일만 가져올 수 있어요.',
    );
    expect(
      messageForImportFailure(
        outcome: ImportOutcome.failedBeforeCommit,
        error: 'too_large:uncompressed: overflow',
        fileName: fileName,
      ),
      '‘words.apkg’ 파일은 너무 커서 가져올 수 없어요. 2 GiB 이하 파일만 가져올 수 있어요.',
    );
    expect(
      messageForImportFailure(
        outcome: ImportOutcome.failedBeforeCommit,
        error: StateError('disk'),
        fileName: fileName,
      ),
      '‘words.apkg’을 가져오지 못했어요. 컬렉션은 바뀌지 않았어요.',
    );
    final adoption = messageForImportFailure(
      outcome: ImportOutcome.failedAfterCommit,
      error: StateError('adopt'),
      fileName: fileName,
    );
    expect(
      adoption,
      '‘words.apkg’은 컬렉션에 들어갔지만 정리를 끝내지 못했어요. 앱을 다시 실행하면 마무리돼요.',
    );
    expect(adoption, isNot(contains('바뀌지 않았어요')));

    final unknown = messageForImportFailure(
      outcome: ImportOutcome.failedUnknown,
      error: StateError('later'),
      fileName: fileName,
    );
    expect(unknown, '‘words.apkg’을 가져오지 못했어요.');
    expect(unknown, isNot(contains('바뀌지 않았어요')));
  });

  test('extension check is ASCII case-insensitive', () {
    expect(isApkgFileName('Deck.apkg'), isTrue);
    expect(isApkgFileName('Deck.APKG'), isTrue);
    expect(isApkgFileName('Deck.Apkg'), isTrue);
    expect(isApkgFileName(r'C:\cards\Deck.APKG'), isTrue);
    expect(isApkgFileName('deck.json'), isFalse);
    expect(isApkgFileName('deck.apkg.bak'), isFalse);
    expect(isApkgFileName('notes.txt'), isFalse);
  });
}
