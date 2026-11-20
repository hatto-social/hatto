// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Thrown when the desktop facade refuses a call before it reaches rslib.
class PolicyDenied implements Exception {
  PolicyDenied(this.rpc, this.reason);
  final String rpc;
  final String reason;
  @override
  String toString() => 'PolicyDenied($rpc: $reason)';
}
