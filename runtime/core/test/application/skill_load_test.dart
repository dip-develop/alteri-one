// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

import 'agent_fakes.dart';

/// A `genkit_middleware`-style `SKILL.md` sample (T10): YAML frontmatter with
/// `name` and `description` between `---` lines, then a markdown body.
const String _genkitStyleSkill =
    '---\n'
    'name: debugging_expert\n'
    'description: Expert advice on debugging complex issues.\n'
    '---\n'
    '# Debugging Expert\n'
    '\n'
    'You are an expert at debugging. Always follow these steps:\n'
    '1. Analyze the stack trace.\n';

void main() {
  group('SkillMdParser', () {
    const parser = SkillMdParser();

    test('parses a genkit_middleware-style SKILL.md (T10)', () {
      final skill = parser.parse(_genkitStyleSkill);

      expect(skill.name, 'debugging_expert');
      expect(skill.description, 'Expert advice on debugging complex issues.');
      expect(skill.body, contains('# Debugging Expert'));
      expect(skill.body, contains('Analyze the stack trace'));
    });

    test('rejects a document without frontmatter', () {
      expect(
        () => parser.parse('# Just a body\n\nNo frontmatter here.'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects frontmatter missing the description', () {
      expect(
        () => parser.parse('---\nname: only_name\n---\nbody'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('description'),
          ),
        ),
      );
    });

    test('rejects frontmatter that is not a mapping', () {
      expect(
        () => parser.parse('---\n- a\n- b\n---\nbody'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects invalid YAML in the frontmatter', () {
      expect(
        () => parser.parse('---\nname: [unclosed\n---\nbody'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('SkillRegistry approval gate', () {
    final approved = Skill(
      'debugging_expert',
      'Debug complex issues.',
      'Body.',
    );
    final unapproved = Skill('secret_skill', 'Not approved.', 'Hidden body.');

    test('registers an approved skill and resolves its body', () {
      final registry = SkillRegistry()
        ..register(approved, approvedNames: {'debugging_expert'});

      expect(registry.approved.map((skill) => skill.name), [
        'debugging_expert',
      ]);
      expect(registry.resolve('debugging_expert'), same(approved));
    });

    test('drops an unapproved skill', () {
      final registry = SkillRegistry()
        ..register(unapproved, approvedNames: const {});

      expect(registry.approved, isEmpty);
      expect(registry.resolve('secret_skill'), isNull);
    });
  });

  group('skill.load tool', () {
    final approved = Skill(
      'debugging_expert',
      'Debug complex issues.',
      'Body.',
    );

    SkillRegistry registry() =>
        SkillRegistry()
          ..register(approved, approvedNames: {'debugging_expert'});

    test('returns the body of an approved skill', () async {
      final tool = SkillLoadTool(registry());

      final out = await tool.call(const {
        'name': 'debugging_expert',
      }, CancelToken());

      expect(out, {'name': 'debugging_expert', 'body': 'Body.'});
    });

    test('refuses a skill that is not approved', () async {
      final tool = SkillLoadTool(registry());

      await expectLater(
        tool.call(const {'name': 'secret_skill'}, CancelToken()),
        throwsA(
          isA<SkillLoadRefused>().having(
            (error) => error.name,
            'name',
            'secret_skill',
          ),
        ),
      );
    });

    test('refuses a call without a name', () async {
      final tool = SkillLoadTool(registry());

      await expectLater(
        tool.call(const {}, CancelToken()),
        throwsA(isA<SkillLoadRefused>()),
      );
    });
  });

  group('prompt listing', () {
    final approved = Skill(
      'debugging_expert',
      'Debug complex issues.',
      'Body.',
    );
    final unapproved = Skill('secret_skill', 'Not approved.', 'Hidden body.');

    test('lists approved name and description, not the body', () async {
      final registry = SkillRegistry()
        ..register(approved, approvedNames: {'debugging_expert'})
        ..register(unapproved, approvedNames: const {});
      final builder = PromptContextBuilder(skills: registry);

      final messages = await builder.build(fakeRun());

      final system = messages.first;
      expect(system.role, MessageRole.system);
      expect(system.text, contains('debugging_expert'));
      expect(system.text, contains('Debug complex issues.'));
      expect(system.text, isNot(contains('Body.')));
      // The unapproved skill is excluded from the prompt.
      expect(system.text, isNot(contains('secret_skill')));
      // The owner prompt is still the last message.
      expect(messages.last.role, MessageRole.user);
    });

    test('starts from the prompt alone when no skill is approved', () async {
      final builder = PromptContextBuilder(skills: SkillRegistry());

      final messages = await builder.build(fakeRun());

      expect(messages, hasLength(1));
      expect(messages.single.role, MessageRole.user);
    });
  });
}
