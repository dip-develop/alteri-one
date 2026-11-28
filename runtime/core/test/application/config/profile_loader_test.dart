// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

void main() {
  group('ProfileLoader', () {
    test('loads a valid profile', () async {
      const loader = ProfileLoader();

      final profile = await loader.load('''
id: assistant
model: local
prompt: assistant
tools: [weather__forecast, memory__recall]
budget:
  max_steps: 4
  max_tokens: 1000
  max_seconds: 30
  max_output_tokens: 64
risk_rules:
  read: allow
  write: ask
  external: ask
  destructive: deny
''');

      expect(profile.id, 'assistant');
      expect(profile.model, 'local');
      expect(profile.prompt, 'assistant');
      expect(profile.tools, ['weather__forecast', 'memory__recall']);
      expect(profile.budget.maxSteps, 4);
      expect(profile.budget.maxTokens, 1000);
      expect(profile.budget.maxDuration, const Duration(seconds: 30));
      expect(profile.budget.maxOutputTokens, 64);
      expect(profile.riskRules, {
        Risk.read: Decision.allow,
        Risk.write: Decision.ask,
        Risk.external: Decision.ask,
        Risk.destructive: Decision.deny,
      });
      // Unset keys keep the domain defaults.
      expect(profile.toolRisks, isEmpty);
      expect(profile.memory, MemoryRights.propose);
      expect(profile.taskConfig, isNull);
    });

    test('keeps the default budget when no budget block is given', () async {
      const loader = ProfileLoader();

      final profile = await loader.load('''
id: assistant
model: local
prompt: assistant
''');

      final defaults = Budget.standard();
      expect(profile.budget.maxSteps, defaults.maxSteps);
      expect(profile.budget.maxTokens, defaults.maxTokens);
      expect(profile.budget.maxDuration, defaults.maxDuration);
      expect(profile.budget.maxOutputTokens, defaults.maxOutputTokens);
    });

    test('loads the task-mode keys into a TaskConfig', () async {
      const loader = ProfileLoader();

      final profile = await loader.load('''
id: fixer
model: local
prompt: fixer
workspace:
  root: /repo
  allowed_paths: [src, test]
auto_resume: true
shell_allowlist:
  - [dart, analyze]
  - [dart, test]
''');

      final task = profile.taskConfig;
      expect(task, isNotNull);
      expect(task!.workspace.root, '/repo');
      expect(task.workspace.allowedPaths, ['src', 'test']);
      expect(task.autoResume, isTrue);
      expect(task.shellAllowlist, [
        ['dart', 'analyze'],
        ['dart', 'test'],
      ]);
    });

    test('defaults autoResume to false and shellAllowlist to empty', () async {
      const loader = ProfileLoader();

      final profile = await loader.load('''
id: fixer
model: local
prompt: fixer
workspace:
  root: /repo
''');

      final task = profile.taskConfig;
      expect(task, isNotNull);
      expect(task!.autoResume, isFalse);
      expect(task.shellAllowlist, isEmpty);
      expect(task.workspace.allowedPaths, isEmpty);
    });

    test('rejects a task option without a workspace block', () {
      const loader = ProfileLoader();

      expect(
        () => loader.parse({
          'id': 'fixer',
          'model': 'local',
          'prompt': 'fixer',
          'auto_resume': true,
        }),
        throwsA(
          isA<ConfigurationException>().having(
            (error) => error.message,
            'message',
            contains('workspace'),
          ),
        ),
      );
    });

    test('rejects an empty workspace root', () {
      const loader = ProfileLoader();

      expect(
        () => loader.parse({
          'id': 'fixer',
          'model': 'local',
          'prompt': 'fixer',
          'workspace': {'root': ''},
        }),
        throwsA(
          isA<ConfigurationException>().having(
            (error) => error.message,
            'message',
            contains('root'),
          ),
        ),
      );
    });

    test('rejects an unknown workspace key', () {
      const loader = ProfileLoader();

      expect(
        () => loader.parse({
          'id': 'fixer',
          'model': 'local',
          'prompt': 'fixer',
          'workspace': {'root': '/repo', 'escape': true},
        }),
        throwsA(
          isA<ConfigurationException>().having(
            (error) => error.message,
            'message',
            contains('escape'),
          ),
        ),
      );
    });

    test('rejects an unknown top-level key', () {
      const loader = ProfileLoader();

      expect(
        () => loader.parse({
          'id': 'assistant',
          'model': 'local',
          'prompt': 'assistant',
          'surprise': true,
        }),
        throwsA(
          isA<ConfigurationException>().having(
            (error) => error.message,
            'message',
            contains('surprise'),
          ),
        ),
      );
    });

    test('rejects an unknown budget key', () {
      const loader = ProfileLoader();

      expect(
        () => loader.parse({
          'id': 'assistant',
          'model': 'local',
          'prompt': 'assistant',
          'budget': {'max_steps': 4, 'max_days': 2},
        }),
        throwsA(
          isA<ConfigurationException>().having(
            (error) => error.message,
            'message',
            contains('max_days'),
          ),
        ),
      );
    });

    test('rejects an unknown risk_rules key', () {
      const loader = ProfileLoader();

      expect(
        () => loader.parse({
          'id': 'assistant',
          'model': 'local',
          'prompt': 'assistant',
          'risk_rules': {'catastrophic': 'deny'},
        }),
        throwsA(
          isA<ConfigurationException>().having(
            (error) => error.message,
            'message',
            contains('catastrophic'),
          ),
        ),
      );
    });

    test('rejects an unknown risk_rules decision', () {
      const loader = ProfileLoader();

      expect(
        () => loader.parse({
          'id': 'assistant',
          'model': 'local',
          'prompt': 'assistant',
          'risk_rules': {'read': 'maybe'},
        }),
        throwsA(
          isA<ConfigurationException>().having(
            (error) => error.message,
            'message',
            contains('maybe'),
          ),
        ),
      );
    });

    test('rejects an unknown tool_risks risk', () {
      const loader = ProfileLoader();

      expect(
        () => loader.parse({
          'id': 'assistant',
          'model': 'local',
          'prompt': 'assistant',
          'tool_risks': {'wipe': 'catastrophic'},
        }),
        throwsA(
          isA<ConfigurationException>().having(
            (error) => error.message,
            'message',
            contains('wipe'),
          ),
        ),
      );
    });

    test('rejects an unknown memory rights value', () {
      const loader = ProfileLoader();

      expect(
        () => loader.parse({
          'id': 'assistant',
          'model': 'local',
          'prompt': 'assistant',
          'memory': 'remember',
        }),
        throwsA(
          isA<ConfigurationException>().having(
            (error) => error.message,
            'message',
            contains('remember'),
          ),
        ),
      );
    });

    test('rejects a negative budget value', () {
      const loader = ProfileLoader();

      expect(
        () => loader.parse({
          'id': 'assistant',
          'model': 'local',
          'prompt': 'assistant',
          'budget': {'max_steps': -1},
        }),
        throwsA(
          isA<ConfigurationException>().having(
            (error) => error.message,
            'message',
            contains('max_steps'),
          ),
        ),
      );
    });

    test('rejects a budget that is not a mapping', () {
      const loader = ProfileLoader();

      expect(
        () => loader.parse({
          'id': 'assistant',
          'model': 'local',
          'prompt': 'assistant',
          'budget': 12,
        }),
        throwsA(isA<ConfigurationException>()),
      );
    });

    test(r'substitutes ${env:NAME}', () async {
      const loader = ProfileLoader(
        env: {'ALTERIONE_MODEL': 'local', 'ALTERIONE_PROMPT': 'assistant'},
      );

      final profile = await loader.load(r'''
id: assistant
model: ${env:ALTERIONE_MODEL}
prompt: ${env:ALTERIONE_PROMPT}
risk_rules:
  read: allow
''');

      expect(profile.model, 'local');
      expect(profile.prompt, 'assistant');
      expect(profile.riskRules, {Risk.read: Decision.allow});
    });

    test(r'rejects a missing ${env:NAME} without leaking a value', () async {
      const loader = ProfileLoader(env: {'ALTERIONE_TOKEN': 's3cr3t-value'});

      await expectLater(
        loader.load(r'''
id: assistant
model: local
prompt: assistant
tools: [weather__forecast]
risk_rules:
  read: ${env:ALTERIONE_MISSING}
'''),
        throwsA(
          isA<ConfigurationException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('ALTERIONE_MISSING'),
              isNot(contains('s3cr3t-value')),
            ),
          ),
        ),
      );
    });

    test('rejects a lower tool_risks than declared', () async {
      const loader = ProfileLoader();

      final profile = await loader.load(r'''
id: assistant
model: local
prompt: assistant
tool_risks:
  wipe: read
''');

      expect(profile.toolRisks, {'wipe': Risk.read});
      expect(
        () => profile.validateToolRisks({'wipe': Risk.destructive}),
        throwsA(
          isA<ConfigurationException>().having(
            (error) => error.message,
            'message',
            contains('wipe'),
          ),
        ),
      );
    });

    test('accepts a raised tool_risks', () async {
      const loader = ProfileLoader();

      final profile = await loader.load(r'''
id: assistant
model: local
prompt: assistant
tool_risks:
  wipe: destructive
''');

      expect(
        () => profile.validateToolRisks({'wipe': Risk.read}),
        returnsNormally,
      );
    });
  });

  group('Budget.task', () {
    test('is the large task budget: 200 steps and 8 hours', () {
      final task = Budget.task();

      expect(task.maxSteps, 200);
      expect(task.maxDuration, const Duration(hours: 8));
      // The per-reply cap and token budget match the chat defaults; the profile
      // overrides max_tokens (docs/spec/task-mode.md, section 29.5).
      final standard = Budget.standard();
      expect(task.maxTokens, standard.maxTokens);
      expect(task.maxOutputTokens, standard.maxOutputTokens);
    });
  });

  group('mergeConfigLayers', () {
    test('lets the last layer win', () {
      final merged = mergeConfigLayers([
        {'id': 'assistant', 'model': 'local', 'prompt': 'assistant'},
        {'model': 'remote'},
      ]);

      expect(merged, {
        'id': 'assistant',
        'model': 'remote',
        'prompt': 'assistant',
      });
    });

    test('merges nested maps key by key', () {
      final merged = mergeConfigLayers([
        {
          'budget': {'max_steps': 4, 'max_tokens': 1000},
          'tools': ['a'],
        },
        {
          'budget': {'max_steps': 12},
          'tools': ['b'],
        },
      ]);

      expect(merged, {
        'budget': {'max_steps': 12, 'max_tokens': 1000},
        'tools': ['b'],
      });
    });
  });
}
