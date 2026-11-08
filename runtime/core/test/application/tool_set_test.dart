// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

final class _FakeTool implements ToolPort {
  new(this.spec);

  @override
  final ToolSpec spec;

  @override
  Future<Object?> call(Map<String, Object?> input, CancelToken cancel) =>
      Future<Object?>.value();
}

ToolSpec _spec(String name, String llmName) => ToolSpec.defaults(
  name: name,
  llmName: llmName,
  description: 'test tool $name',
  risk: Risk.read,
);

void main() {
  group('ToolSet.specs', () {
    test('preserves the order of the tools', () {
      final first = _FakeTool(_spec('alpha', 'ext__alpha'));
      final second = _FakeTool(_spec('beta', 'ext__beta'));
      final set = ToolSet([first, second]);

      expect(set.specs.map((s) => s.name), ['alpha', 'beta']);
      expect(set.specs.map((s) => s.llmName), ['ext__alpha', 'ext__beta']);
    });

    test('copies the list given to it', () {
      final first = _FakeTool(_spec('alpha', 'ext__alpha'));
      final source = [first];
      final set = ToolSet(source);

      source
        ..clear()
        ..add(_FakeTool(_spec('beta', 'ext__beta')));

      expect(set.specs.map((s) => s.name), ['alpha']);
      expect(set.byLlmName('ext__alpha'), same(first));
      expect(set.byLlmName('ext__beta'), isNull);
    });
  });

  group('ToolSet.byLlmName', () {
    test('matches the LLM name, not the canonical name', () {
      final tool = _FakeTool(_spec('forecast', 'weather__forecast'));
      final set = ToolSet([tool]);

      expect(set.byLlmName('weather__forecast'), same(tool));
      expect(set.byLlmName('forecast'), isNull);
    });

    test('returns null for an unknown name', () {
      final set = ToolSet([_FakeTool(_spec('alpha', 'ext__alpha'))]);

      expect(set.byLlmName('ext__other'), isNull);
      expect(set.byLlmName(''), isNull);
    });

    test('an empty set has no tools', () {
      final set = ToolSet(const []);

      expect(set.specs, isEmpty);
      expect(set.byLlmName('ext__alpha'), isNull);
    });

    test('the first of duplicate LLM names wins', () {
      final first = _FakeTool(_spec('first', 'ext__dup'));
      final second = _FakeTool(_spec('second', 'ext__dup'));
      final set = ToolSet([first, second]);

      expect(set.byLlmName('ext__dup'), same(first));
    });
  });
}
