// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_provider_api/alteri_one_provider_api.dart';
import 'package:test/test.dart';

/// Name of scenario 1: a valid tool call is parsed.
const String scenario1Name = 'scenario 1: a valid tool call is parsed';

/// Name of scenario 2: schema-mismatched arguments reach the caller.
const String scenario2Name =
    'scenario 2: schema-mismatched arguments reach the caller';

/// Name of scenario 3: invalid JSON arguments never throw.
const String scenario3Name = 'scenario 3: invalid JSON arguments never throw';

/// Name of scenario 4: two dependent calls share a result.
const String scenario4Name = 'scenario 4: two dependent calls share a result';

/// Name of scenario 5: a request that needs no tool calls none.
const String scenario5Name =
    'scenario 5: a request that needs no tool calls none';

/// Name of scenario 6: a large context with tools still completes.
const String scenario6Name = 'scenario 6: a large context with tools completes';

/// The tools every provider conformance scenario uses.
///
/// The names are the model-facing names (`llmName`), which is what a provider
/// receives and echoes back. `never` is a tool the model should not need, so a
/// provider that calls it on a plain question fails scenario 5.
final class ConformanceTools {
  /// Creates the conformance tool set.
  new()
    : echo = ToolSpec.defaults(
        name: 'echo',
        llmName: 'echo',
        description: 'Echo the given text back to the caller.',
        risk: Risk.read,
        inputSchema: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'text': <String, Object?>{'type': 'string'},
          },
          'required': <Object?>['text'],
          'additionalProperties': false,
        },
      ),
      add = ToolSpec.defaults(
        name: 'add',
        llmName: 'add',
        description: 'Add two integers and return the sum.',
        risk: Risk.read,
        inputSchema: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'a': <String, Object?>{'type': 'integer'},
            'b': <String, Object?>{'type': 'integer'},
          },
          'required': <Object?>['a', 'b'],
          'additionalProperties': false,
        },
      ),
      never = ToolSpec.defaults(
        name: 'never',
        llmName: 'never',
        description: 'Do not call this tool; it is never needed.',
        risk: Risk.read,
      );

  /// The `echo` tool: one string argument.
  final ToolSpec echo;

  /// The `add` tool: two integer arguments.
  final ToolSpec add;

  /// A tool the model should never need.
  final ToolSpec never;

  /// Every tool, in a stable order.
  List<ToolSpec> get all => <ToolSpec>[echo, add, never];
}

/// One conformance scenario: a name and the body that asserts it.
final class ConformanceScenario {
  /// Creates a scenario.
  new(this.name, this.body);

  /// The scenario name shown by `package:test`.
  final String name;

  /// The scenario body; it throws when the provider violates the scenario.
  final Future<void> Function() body;
}

/// Builds the ordered list of provider conformance scenarios.
///
/// The scenarios are pure functions of [port] and [tools], so a test can run
/// one body directly to prove that the harness catches a violation. Use
/// [runProviderConformance] to register them with `package:test`.
List<ConformanceScenario> providerConformanceScenarios({
  required LlmPort port,
  ConformanceTools? tools,
}) {
  final t = tools ?? ConformanceTools();
  return <ConformanceScenario>[
    ConformanceScenario(scenario1Name, () => _validToolCall(port, t)),
    ConformanceScenario(scenario2Name, () => _schemaMismatch(port, t)),
    ConformanceScenario(scenario3Name, () => _invalidJson(port, t)),
    ConformanceScenario(scenario4Name, () => _dependentCalls(port, t)),
    ConformanceScenario(scenario5Name, () => _noToolNeeded(port, t)),
    ConformanceScenario(scenario6Name, () => _bigContext(port, t)),
  ];
}

/// Registers the provider conformance scenarios with `package:test`.
///
/// A provider that declares `nativeTools: true` must pass scenarios 1–4. The
/// scenarios run against [port] unchanged; tool execution is the agent loop's
/// job, not the provider's, so the suite never executes a tool.
void runProviderConformance({required LlmPort port, ConformanceTools? tools}) {
  group('provider conformance', () {
    for (final scenario in providerConformanceScenarios(
      port: port,
      tools: tools,
    )) {
      test(scenario.name, scenario.body);
    }
  });
}

Future<void> _validToolCall(LlmPort port, ConformanceTools tools) async {
  final turn = await port.complete(
    messages: <Message>[Message.user('Echo the text hello.')],
    tools: tools.all,
    maxOutputTokens: 128,
  );
  final call = _callNamed(turn.toolCalls, tools.echo.llmName);
  expect(
    call.isMalformed,
    isFalse,
    reason: 'a well-formed call must not be reported as malformed',
  );
  expect(
    call.input['text'],
    isA<String>(),
    reason: 'the parsed arguments must carry the string argument',
  );
}

Future<void> _schemaMismatch(LlmPort port, ConformanceTools tools) async {
  final turn = await port.complete(
    messages: <Message>[
      Message.user(
        'Echo a value that does not match the schema: use the number 42 for '
        'text.',
      ),
    ],
    tools: tools.all,
    maxOutputTokens: 128,
  );
  final call = _callNamed(turn.toolCalls, tools.echo.llmName);
  expect(
    call.isMalformed,
    isFalse,
    reason:
        'a schema mismatch is returned to the caller, not turned into a '
        'malformed call',
  );
  expect(
    call.input.containsKey('text'),
    isTrue,
    reason: 'the arguments must be preserved so the loop can correct them',
  );
}

Future<void> _invalidJson(LlmPort port, ConformanceTools tools) async {
  // The point of the scenario: the call must not throw. A provider that
  // rethrows the raw `jsonDecode` error fails here.
  final turn = await port.complete(
    messages: <Message>[
      Message.user(
        'Call echo with arguments that are invalid JSON, for example the '
        'literal text {not json}.',
      ),
    ],
    tools: tools.all,
    maxOutputTokens: 128,
  );
  final call = _callNamed(turn.toolCalls, tools.echo.llmName);
  if (call.isMalformed) {
    expect(call.reason, isNotNull);
    expect(call.input, isEmpty);
  } else {
    // A model that produced valid JSON is acceptable; the run must not fail.
    expect(call.input, isA<Map<String, Object?>>());
  }
}

Future<void> _dependentCalls(LlmPort port, ConformanceTools tools) async {
  final first = await port.complete(
    messages: <Message>[Message.user('Add 2 and 3.')],
    tools: tools.all,
    maxOutputTokens: 128,
  );
  final add = _callNamed(first.toolCalls, tools.add.llmName);
  expect(add.isMalformed, isFalse);
  final a = add.input['a'] as num;
  final b = add.input['b'] as num;
  final sum = a + b;

  final second = await port.complete(
    messages: <Message>[
      Message.user('Add 2 and 3.'),
      Message.assistant(first.text, first.toolCalls),
      Message.toolResults(<ToolResultBlock>[ToolResultBlock.ok(add.id, sum)]),
      Message.user('Now add 1 to that result.'),
    ],
    tools: tools.all,
    maxOutputTokens: 128,
  );
  final again = _callNamed(second.toolCalls, tools.add.llmName);
  expect(again.isMalformed, isFalse);
  expect(
    again.input['a'],
    sum,
    reason: 'the second call must use the result of the first',
  );
}

Future<void> _noToolNeeded(LlmPort port, ConformanceTools tools) async {
  final turn = await port.complete(
    messages: <Message>[
      Message.user('What is the capital of France? Answer with one word.'),
    ],
    tools: tools.all,
    maxOutputTokens: 64,
  );
  expect(
    turn.toolCalls,
    isEmpty,
    reason: 'a request that needs no tool must not call one',
  );
}

Future<void> _bigContext(LlmPort port, ConformanceTools tools) async {
  // About 32k tokens: roughly four characters per token.
  const sentence = 'The quick brown fox jumps over the lazy dog. ';
  final filler = sentence * 3000;
  final turn = await port.complete(
    messages: <Message>[Message.user('$filler\nEcho the word ok.')],
    tools: tools.all,
    maxOutputTokens: 128,
  );
  expect(
    turn.text.isNotEmpty || turn.toolCalls.isNotEmpty,
    isTrue,
    reason: 'a ~32k-token context with tools must still produce a reply',
  );
}

ToolCall _callNamed(List<ToolCall> calls, String name) {
  expect(
    calls.map((call) => call.name),
    contains(name),
    reason: 'the model must request the $name tool',
  );
  return calls.firstWhere((call) => call.name == name);
}
