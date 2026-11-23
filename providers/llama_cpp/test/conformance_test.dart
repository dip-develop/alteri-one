// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_provider_api/alteri_one_provider_api.dart';
import 'package:alteri_one_provider_llama_cpp/alteri_one_provider_llama_cpp.dart';
import 'package:alteri_one_testkit/alteri_one_testkit.dart';
import 'package:test/test.dart';

import 'fake_llama_pulse_server.dart';

/// The fake-server level of the conformance suite (docs/spec/providers.md,
/// section 12.4): it verifies response parsing on every run, without a model.
void main() {
  final server = FakeLlamaPulseServer();
  final port = _DeferredLlm();
  setUpAll(() async {
    await server.start();
    port.port = LlamaCppLlm(
      options: LlamaCppOptions(baseUrl: server.baseUrl.toString()),
    );
  });
  tearDownAll(server.close);

  runProviderConformance(port: port, tools: ConformanceTools());

  test(
    'the whole large prompt reaches the server, not a truncated one',
    () async {
      final lastUser = 'x' * 135_000;
      await port.complete(
        messages: <Message>[Message.user(lastUser)],
        tools: const <ToolSpec>[],
        maxOutputTokens: 16,
      );
      expect(server.requests, isNotEmpty);
      expect(
        server.requests.last.body.length,
        greaterThan(135_000),
        reason: 'the whole prompt must reach the server',
      );
      expect(
        server.lastUserLengths.last,
        greaterThanOrEqualTo(lastUser.length),
        reason: 'a provider that truncated the context would record less',
      );
    },
  );
}

/// A port that forwards to the real [LlamaCppLlm] once the server is up.
///
/// The server binds an ephemeral port, so the port can only be built after
/// `setUpAll` starts it; the conformance scenarios still receive a stable
/// [LlmPort] to close over.
final class _DeferredLlm implements LlmPort {
  /// The real port, set by `setUpAll`.
  LlamaCppLlm? port;

  @override
  Future<Turn> complete({
    required List<Message> messages,
    required List<ToolSpec> tools,
    required int maxOutputTokens,
  }) {
    final inner = port;
    if (inner == null) {
      throw StateError('the fake server is not started');
    }
    return inner.complete(
      messages: messages,
      tools: tools,
      maxOutputTokens: maxOutputTokens,
    );
  }
}
