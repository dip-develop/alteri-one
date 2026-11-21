// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

Profile _profile({
  List<String> tools = const [],
  Map<Risk, Decision> riskRules = const {},
  Map<String, Risk> toolRisks = const {},
  MemoryRights memory = MemoryRights.propose,
}) => Profile(
  'assistant',
  'local',
  'assistant',
  tools,
  Budget.standard(),
  riskRules,
  toolRisks,
  memory,
);

void main() {
  group('Profile', () {
    test('keeps its risk rules and defaults', () {
      final profile = Profile(
        'assistant',
        'local',
        'assistant',
        ['weather__forecast'],
        Budget.standard(),
        const {Risk.read: Decision.allow, Risk.destructive: Decision.deny},
        const {'wipe': Risk.destructive},
      );

      expect(profile.riskRules, {
        Risk.read: Decision.allow,
        Risk.destructive: Decision.deny,
      });
      expect(profile.toolRisks, {'wipe': Risk.destructive});
      expect(profile.memory, MemoryRights.propose);
      expect(profile.tools, ['weather__forecast']);
    });

    test('copies its tools and maps into unmodifiable views', () {
      final tools = ['weather__forecast'];
      final riskRules = <Risk, Decision>{Risk.read: Decision.allow};
      final toolRisks = <String, Risk>{'wipe': Risk.destructive};
      final profile = Profile(
        'assistant',
        'local',
        'assistant',
        tools,
        Budget.standard(),
        riskRules,
        toolRisks,
      );

      tools.add('memory__recall');
      riskRules[Risk.write] = Decision.ask;
      toolRisks['save'] = Risk.write;

      expect(profile.tools, ['weather__forecast']);
      expect(profile.riskRules, {Risk.read: Decision.allow});
      expect(profile.toolRisks, {'wipe': Risk.destructive});
      expect(() => profile.tools.add('x'), throwsUnsupportedError);
      expect(
        () => profile.riskRules[Risk.write] = Decision.deny,
        throwsUnsupportedError,
      );
      expect(() => profile.toolRisks['x'] = Risk.read, throwsUnsupportedError);
    });

    test('validateToolRisks rejects a configured risk lower than declared', () {
      final profile = _profile(toolRisks: {'wipe': Risk.read});

      expect(
        () => profile.validateToolRisks({'wipe': Risk.destructive}),
        throwsA(
          isA<ConfigurationException>().having(
            (e) => e.message,
            'message',
            contains('wipe'),
          ),
        ),
      );
    });

    test('validateToolRisks accepts an equal or higher configured risk', () {
      final equal = _profile(toolRisks: {'wipe': Risk.destructive});
      final higher = _profile(toolRisks: {'read': Risk.destructive});

      expect(
        () => equal.validateToolRisks({'wipe': Risk.destructive}),
        returnsNormally,
      );
      expect(
        () => higher.validateToolRisks({'read': Risk.read}),
        returnsNormally,
      );
      // A configured risk for a tool the run does not declare is not lowered.
      expect(() => equal.validateToolRisks(const {}), returnsNormally);
    });
  });
}
