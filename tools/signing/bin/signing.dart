// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

const _usage = '''
Usage: signing <command> [options]

Commands:
  sign       Sign data with a private key (not implemented)
  verify     Verify a signature with a public key (not implemented)
  keygen     Generate an Ed25519 key pair (not implemented)

Options:
  --help     Show this help message and exit
''';

void main(List<String> args) {
  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    stdout.write(_usage);
    exitCode = 0;
    return;
  }

  final command = args.first;
  if (command == 'sign' || command == 'verify' || command == 'keygen') {
    stderr.writeln('not implemented');
    exitCode = 1;
    return;
  }

  stderr.write(_usage);
  exitCode = 1;
}
