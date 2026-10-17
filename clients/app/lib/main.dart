// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';

void main() {
  // TODO(m9): the real client (ConnectionCubit, ChatBloc, ApprovalsBloc, ...)
  // follows the milestones in docs/spec/roadmap.md. This placeholder only
  // proves that the build works.
  runApp(const AlteriOnePlaceholderApp());
}

/// Placeholder entry point until the real client is implemented (see M9).
final class AlteriOnePlaceholderApp extends StatelessWidget {
  /// Creates the placeholder application shell.
  const AlteriOnePlaceholderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'AlteriOne',
      home: ColoredBox(
        color: Color(0xFF101418),
        child: Center(child: Text('AlteriOne')),
      ),
    );
  }
}
