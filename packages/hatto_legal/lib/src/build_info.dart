// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Release identity baked in with `--dart-define`.
///
/// `HATTO_RELEASE_TAG` is empty for a dev build. `HATTO_GIT_SHA` is the
/// commit the binary was built from, when the build script knows it.
class BuildInfo {
  const BuildInfo({this.releaseTag = '', this.gitSha = ''});

  /// Values from the compile-time environment. Tests pass an explicit
  /// [BuildInfo] instead of this one.
  static const environment = BuildInfo(
    releaseTag: String.fromEnvironment('HATTO_RELEASE_TAG'),
    gitSha: String.fromEnvironment('HATTO_GIT_SHA'),
  );

  final String releaseTag;
  final String gitSha;

  bool get hasReleaseTag => releaseTag.isNotEmpty;
}
