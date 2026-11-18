// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:path/path.dart' as p;

/// Side-database file under the app documents directory.
///
/// [documentsDirectory] is `getApplicationDocumentsDirectory().path`. The
/// Anki collection is a different file and is opened only by rslib.
String sideDbPath(String documentsDirectory) {
  return p.join(documentsDirectory, 'hatto', 'hatto.sqlite');
}
