// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_core/src/config/profile_schema.dart';
import 'package:test/test.dart';

void main() {
  group('ProfileConfig schema', () {
    test('generated JSON Schema has the profile properties', () {
      final schema = ProfileConfig.$schema.jsonSchema();
      final properties = schema['properties'] as Map<String, Object?>;

      expect(
        properties.keys,
        containsAll(<String>[
          'id',
          'model',
          'prompt',
          'tools',
          'budget',
          'risk_rules',
          'tool_risks',
          'memory',
        ]),
      );
      expect(schema['required'], ['id', 'model', 'prompt']);
      expect(properties['tools'], {
        'type': 'array',
        'items': {'type': 'string'},
      });
      // The token maps stay open strings: the loader owns the token check.
      expect(properties['risk_rules'], {
        'type': 'object',
        'additionalProperties': {'type': 'string'},
      });
      expect(properties['tool_risks'], {
        'type': 'object',
        'additionalProperties': {'type': 'string'},
      });

      // The nested budget is inlined, so its properties are visible.
      final budget = properties['budget'] as Map<String, Object?>;
      final budgetProperties = budget['properties'] as Map<String, Object?>;
      expect(
        budgetProperties.keys,
        containsAll(<String>[
          'max_steps',
          'max_tokens',
          'max_seconds',
          'max_output_tokens',
        ]),
      );
    });

    test('fromJson rejects a wrong type', () {
      final config = ProfileConfig.fromJson({
        'id': 42,
        'model': 'local',
        'prompt': 'assistant',
      });

      expect(() => config.id, throwsA(isA<TypeError>()));

      final budget = ProfileConfig.fromJson({
        'id': 'assistant',
        'model': 'local',
        'prompt': 'assistant',
        'budget': {'max_steps': 'many'},
      });

      expect(() => budget.budget?.maxSteps, throwsA(isA<TypeError>()));
    });

    test('fromJson reads the snake_case keys', () {
      final config = ProfileConfig.fromJson({
        'id': 'assistant',
        'model': 'local',
        'prompt': 'assistant',
        'tools': ['weather__forecast'],
        'budget': {'max_steps': 4, 'max_seconds': 30},
        'risk_rules': {'read': 'allow'},
        'tool_risks': {'wipe': 'destructive'},
        'memory': 'auto',
      });

      expect(config.id, 'assistant');
      expect(config.tools, ['weather__forecast']);
      expect(config.budget?.maxSteps, 4);
      expect(config.budget?.maxSeconds, 30);
      expect(config.riskRules, {'read': 'allow'});
      expect(config.toolRisks, {'wipe': 'destructive'});
      expect(config.memory, 'auto');
    });
  });
}
