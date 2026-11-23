// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_provider_api/alteri_one_provider_api.dart';
import 'package:alteri_one_testkit/alteri_one_testkit.dart';
import 'package:test/test.dart';

void main() {
  final tools = ConformanceTools();

  test(
    'the harness catches a provider that throws on invalid JSON (scenario 3)',
    () async {
      final scenarios = providerConformanceScenarios(
        port: _ThrowingPort(),
        tools: tools,
      );
      await expectLater(
        _body(scenarios, scenario3Name)(),
        throwsA(anything),
        reason: 'scenario 3 must fail when the provider rethrows jsonDecode',
      );
    },
  );

  test(
    'the harness catches a provider that calls the unneeded tool (scenario 5)',
    () async {
      final scenarios = providerConformanceScenarios(
        port: _OvereagerPort(tools),
        tools: tools,
      );
      await expectLater(
        _body(scenarios, scenario5Name)(),
        throwsA(anything),
        reason: 'scenario 5 must fail when the provider calls an unneeded tool',
      );
    },
  );

  test('a conformant fake passes every scenario', () async {
    final scenarios = providerConformanceScenarios(
      port: _ConformantPort(tools),
      tools: tools,
    );
    for (final scenario in scenarios) {
      await scenario.body();
    }
  });
}

Future<void> Function() _body(
  List<ConformanceScenario> scenarios,
  String name,
) {
  for (final scenario in scenarios) {
    if (scenario.name == name) return scenario.body;
  }
  throw StateError('scenario not found: $name');
}

String _text(List<Message> messages) =>
    messages.map((message) => message.text).join('\n');

/// A port that rethrows on invalid JSON, as `genkit_openai` once did.
final class _ThrowingPort implements LlmPort {
  @override
  Future<Turn> complete({
    required List<Message> messages,
    required List<ToolSpec> tools,
    required int maxOutputTokens,
  }) async {
    if (_text(messages).contains('not json')) {
      throw StateError('provider rethrew the jsonDecode error');
    }
    return Turn('ok', Message.assistant('ok'), const <ToolCall>[]);
  }
}

/// A port that calls the unneeded tool on a plain question.
final class _OvereagerPort implements LlmPort {
  /// Creates the port.
  new(this.tools);

  /// The conformance tool set.
  final ConformanceTools tools;

  @override
  Future<Turn> complete({
    required List<Message> messages,
    required List<ToolSpec> tools,
    required int maxOutputTokens,
  }) async {
    if (_text(messages).contains('capital of France')) {
      final call = ToolCall.valid(
        id: 'call_1',
        name: this.tools.echo.llmName,
        input: const <String, Object?>{'text': 'x'},
      );
      return Turn('', Message.assistant('', <ToolCall>[call]), <ToolCall>[
        call,
      ]);
    }
    return Turn('ok', Message.assistant('ok'), const <ToolCall>[]);
  }
}

/// A port that behaves as the conformance suite expects.
final class _ConformantPort implements LlmPort {
  /// Creates the port.
  new(this.tools);

  /// The conformance tool set.
  final ConformanceTools tools;

  @override
  Future<Turn> complete({
    required List<Message> messages,
    required List<ToolSpec> tools,
    required int maxOutputTokens,
  }) async {
    final text = _text(messages);
    if (text.contains('not json')) {
      return _withCall(
        ToolCall.malformed(
          id: 'call_bad',
          name: this.tools.echo.llmName,
          reason: 'arguments are not valid JSON',
        ),
      );
    }
    if (text.contains('capital of France')) {
      return Turn('Paris', Message.assistant('Paris'), const <ToolCall>[]);
    }
    if (text.contains('does not match the schema')) {
      return _withCall(
        ToolCall.valid(
          id: 'call_bad',
          name: this.tools.echo.llmName,
          input: const <String, Object?>{'text': 42},
        ),
      );
    }
    if (messages.any((message) => message.role == MessageRole.tool)) {
      return _withCall(
        ToolCall.valid(
          id: 'call_add_2',
          name: this.tools.add.llmName,
          input: const <String, Object?>{'a': 5, 'b': 1},
        ),
      );
    }
    if (text.contains('Add 2 and 3')) {
      return _withCall(
        ToolCall.valid(
          id: 'call_add_1',
          name: this.tools.add.llmName,
          input: const <String, Object?>{'a': 2, 'b': 3},
        ),
      );
    }
    if (text.contains('Echo the text hello')) {
      return _withCall(
        ToolCall.valid(
          id: 'call_echo',
          name: this.tools.echo.llmName,
          input: const <String, Object?>{'text': 'hello'},
        ),
      );
    }
    return Turn('ok', Message.assistant('ok'), const <ToolCall>[]);
  }

  Turn _withCall(ToolCall call) =>
      Turn('', Message.assistant('', <ToolCall>[call]), <ToolCall>[call]);
}
