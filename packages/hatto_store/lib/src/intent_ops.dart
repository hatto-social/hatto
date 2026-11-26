// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Intent `op` values the desktop v0 wrapper writes.
///
/// The vocabulary is not a wire format. v1 can rename it. Names follow
/// `<target>.<verb>`.
const String intentNoteAdd = 'note.add';
const String intentNoteUpdate = 'note.update';
const String intentDeckAdd = 'deck.add';
const String intentDeckRename = 'deck.rename';
const String intentMediaAdd = 'media.add';
const String intentUndo = 'undo';
const String intentRedo = 'redo';

/// Import batch. The row is the prepared state.
///
/// Recovery deletes it when the resident import committed and when it did
/// not. Reconcile does not. This name is not `<target>.<verb>`.
const String intentImport = 'import';
