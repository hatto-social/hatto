// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

/// What the home screen shows. IO that produced this lives in `effect/`.
class BootstrapState {
  const BootstrapState({
    required this.opened,
    required this.markerPresent,
    required this.message,
  });

  const BootstrapState.closed()
    : opened = false,
      markerPresent = false,
      message = '컬렉션이 아직 열리지 않았습니다.';

  final bool opened;
  final bool markerPresent;
  final String message;
}
