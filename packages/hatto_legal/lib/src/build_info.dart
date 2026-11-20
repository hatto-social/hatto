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

/// Opens the GitHub page for one release. The host app supplies this.
typedef OpenSourceUrl = Future<void> Function(Uri url);

/// Release page that holds this version's source, or null for a dev build.
///
/// The tag is the git tag, including a leading `v` when the tag has one.
String? releaseSourceUrl(String tag) {
  if (tag.isEmpty) {
    return null;
  }
  return 'https://github.com/hatto-social/hatto/releases/tag/${Uri.encodeComponent(tag)}';
}
