// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_provider_api/alteri_one_provider_api.dart';
import 'package:test/test.dart';

/// A [LlmPort] that returns [turn] and records the requests it received.
final class _FakeLlm implements LlmPort {
  new(this.turn);

  final Turn turn;
  final List<int> outputCaps = <int>[];

  @override
  Future<Turn> complete({
    required List<Message> messages,
    required List<ToolSpec> tools,
    required int maxOutputTokens,
  }) async {
    outputCaps.add(maxOutputTokens);
    return turn;
  }
}

/// A [ModelProvider] with a fixed [kind] and a canned [LlmPort].
final class _FakeProvider implements ModelProvider {
  new(this.kind, this._port);

  @override
  final String kind;

  final LlmPort _port;

  @override
  Map<String, Object?> get optionsSchema => const <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'base_url': <String, Object?>{'type': 'string'},
    },
  };

  @override
  Future<LlmCapabilities> probe(Map<String, Object?> options) async =>
      LlmCapabilities(true, false, false, 8192);

  @override
  LlmPort create(Map<String, Object?> options, LlmCapabilities capabilities) =>
      _port;
}

void main() {
  group('model-call vocabulary', () {
    test('Message factories build the four roles', () {
      expect(Message.system('s').role, MessageRole.system);
      expect(Message.user('u').role, MessageRole.user);
      expect(Message.assistant('a').role, MessageRole.assistant);
      expect(Message.toolResults(const []).role, MessageRole.tool);
    });

    test('ToolCall.valid and ToolCall.malformed round-trip', () {
      final valid = ToolCall.valid(
        id: 'call_1',
        name: 'weather__forecast',
        input: const <String, Object?>{'city': 'Kyiv'},
      );
      expect(valid.isMalformed, isFalse);
      expect(valid.input, <String, Object?>{'city': 'Kyiv'});

      final malformed = ToolCall.malformed(
        id: 'call_2',
        name: 'weather__forecast',
        reason: 'invalid json',
      );
      expect(malformed.isMalformed, isTrue);
      expect(malformed.reason, 'invalid json');
      expect(malformed.input, isEmpty);
    });

    test('ToolResultBlock reports success and error', () {
      expect(ToolResultBlock.ok('call_1', 42).isOk, isTrue);
      expect(ToolResultBlock.error('call_1', 'denied').isOk, isFalse);
    });

    test('Turn exposes whether the model requested tools', () {
      final plain = Turn('hi', Message.assistant('hi'), const []);
      final withTools = Turn('calling', Message.assistant('calling'), [
        ToolCall.valid(id: 'c', name: 'n', input: const <String, Object?>{}),
      ]);
      expect(plain.hasToolCalls, isFalse);
      expect(withTools.hasToolCalls, isTrue);
    });
  });

  group('LlmPort', () {
    test('a fake port receives maxOutputTokens', () async {
      final llm = _FakeLlm(Turn('done', Message.assistant('done'), const []));

      final turn = await llm.complete(
        messages: const [],
        tools: const [],
        maxOutputTokens: 256,
      );

      expect(turn.text, 'done');
      expect(llm.outputCaps, <int>[256]);
    });
  });

  group('ModelProvider and LlmCapabilities', () {
    test('probe reports the declared capabilities', () async {
      final provider = _FakeProvider(
        'fake',
        _FakeLlm(Turn('done', Message.assistant('done'), const [])),
      );
      final capabilities = await provider.probe(const {});

      expect(capabilities.nativeTools, isTrue);
      expect(capabilities.parallelToolCalls, isFalse);
      expect(capabilities.contextTokens, 8192);
    });

    test('create hands out the port with the capabilities', () {
      final llm = _FakeLlm(Turn('done', Message.assistant('done'), const []));
      final provider = _FakeProvider('fake', llm);

      final created = provider.create(
        const {},
        LlmCapabilities(true, false, false, 4096),
      );

      expect(identical(created, llm), isTrue);
    });
  });

  group('LlmUnavailable', () {
    test('formats a status and a transport error', () {
      expect(
        const LlmUnavailable(503, 'loading').toString(),
        'LlmUnavailable(503: loading)',
      );
      expect(
        const LlmUnavailable(null, 'connection refused').toString(),
        'LlmUnavailable(-: connection refused)',
      );
    });
  });
}
