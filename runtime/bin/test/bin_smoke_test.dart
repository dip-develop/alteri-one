// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Smoke tests for the `alterione` binary wiring (docs/plan/M4.md Step 11):
/// `--help`, `status` against a stopped daemon, and `serve` startup/shutdown.
///
/// The daemon runs on a temporary `ALTERIONE_HOME` with a fake [LlmPort] and an
/// ephemeral port, so the test never touches the developer's home directory or
/// binds a fixed external port.
library;

import 'dart:async';
import 'dart:io';

import 'package:alteri_one_bin/alteri_one_bin.dart';
import 'package:alteri_one_cli/alteri_one_cli.dart';
import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

/// A [LlmPort] that finishes every turn with no tool calls.
final class _FakeLlm implements LlmPort {
  @override
  Future<Turn> complete({
    required List<Message> messages,
    required List<ToolSpec> tools,
    required int maxOutputTokens,
  }) async => Turn('ok', Message.assistant('ok'), const <ToolCall>[]);
}

void main() {
  late Directory home;
  late Map<String, String> environment;

  setUp(() async {
    applyBlocDefaults();
    home = await Directory.systemTemp.createTemp('bin_test_');
    environment = {'ALTERIONE_HOME': home.path};
    // A minimal profile the daemon's config loader accepts (section 14.3).
    final profiles = Directory('${home.path}/.config/alterione/profiles');
    await profiles.create(recursive: true);
    await File('${profiles.path}/assistant.yaml').writeAsString(
      'id: assistant\n'
      'model: local\n'
      'prompt: assistant\n'
      'risk_rules:\n'
      '  read: allow\n',
    );
  });

  tearDown(() async {
    if (getIt.isRegistered<HiveJournal>()) {
      await getIt<HiveJournal>().close();
    }
    await getIt.reset();
    if (home.existsSync()) {
      await home.delete(recursive: true);
    }
  });

  test('--help exits 0 and prints usage', () async {
    final StringBuffer out = StringBuffer();
    final int code = await runAlteriOne(
      <String>['--help'],
      environment: environment,
      out: out,
      err: StringBuffer(),
    );
    expect(code, ExitCode.success);
    expect(out.toString(), contains('usage: alterione'));
  });

  test('status against a stopped daemon exits 3 and suggests serve', () async {
    final StringBuffer err = StringBuffer();
    final int code = await runAlteriOne(
      <String>['status'],
      environment: environment,
      out: StringBuffer(),
      err: err,
    );
    expect(code, ExitCode.daemonUnavailable);
    expect(err.toString(), contains('alterione serve'));
  });

  test('serve starts and shuts down cleanly on stop', () async {
    final StringBuffer out = StringBuffer();
    final StreamController<void> stop = StreamController<void>();

    final Future<int> running = runAlteriOne(
      <String>['serve'],
      environment: environment,
      out: out,
      err: StringBuffer(),
      serveLlm: _FakeLlm(),
      serveStop: stop.stream,
    );

    // Wait until the daemon reports it is serving (ephemeral port).
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!out.toString().contains('serving on port') &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(out.toString(), contains('serving on port'));

    // Signal the stop the way SIGTERM would; the daemon runs section 18.2.
    stop.add(null);
    final int code = await running;
    await stop.close();

    expect(code, ExitCode.success);
  });
}
