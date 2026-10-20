// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

RunCapabilities _caps({
  Set<String> tools = const {'weather__forecast'},
  Set<String> netHosts = const {},
  List<String> fsRoots = const [],
  MemoryRights memory = MemoryRights.read,
}) => RunCapabilities(tools, netHosts, fsRoots, memory);

void main() {
  group('effectiveRisk', () {
    test('null configuration keeps the declared risk', () {
      expect(effectiveRisk(Risk.read, null), Risk.read);
    });

    test('configuration may raise the risk', () {
      expect(effectiveRisk(Risk.read, Risk.write), Risk.write);
      expect(effectiveRisk(Risk.read, Risk.destructive), Risk.destructive);
    });

    test('configuration may never lower the risk', () {
      expect(effectiveRisk(Risk.external, Risk.read), Risk.external);
      expect(effectiveRisk(Risk.destructive, Risk.write), Risk.destructive);
    });
  });

  group('RunCapabilities.narrow', () {
    test('intersects tools and hosts', () {
      final parent = _caps(tools: {'a', 'b'}, netHosts: {'h1'});
      final narrowed = parent.narrow(
        _caps(tools: {'a', 'c'}, netHosts: {'h1', 'h2'}),
      );
      expect(narrowed.tools, {'a'});
      expect(narrowed.netHosts, {'h1'});
    });

    test('keeps only requested roots under a parent root', () {
      final parent = _caps(fsRoots: ['/home/owner', '/tmp']);
      final narrowed = parent.narrow(
        _caps(fsRoots: ['/home/owner/work', '/etc']),
      );
      expect(narrowed.fsRoots, ['/home/owner/work']);
    });

    test('memory takes the more restrictive right', () {
      final parent = _caps(memory: MemoryRights.auto);
      final narrowed = parent.narrow(_caps(memory: MemoryRights.propose));
      expect(narrowed.memory, MemoryRights.propose);

      final narrowParent = _caps(memory: MemoryRights.none);
      final widened = narrowParent.narrow(_caps());
      expect(widened.memory, MemoryRights.none);
    });
  });

  group('PolicyGate.decide', () {
    test('a tool outside the capabilities is denied without asking', () {
      final gate = PolicyGate({
        Risk.read: Decision.allow,
        Risk.external: Decision.allow,
      }, true);
      final decision = gate.decide(
        tool: 'weather__forecast',
        risk: Risk.read,
        taints: {},
        caps: _caps(tools: {'other__tool'}),
      );
      expect(decision, Decision.deny);
    });

    test('a risk without a profile rule is denied (fail closed)', () {
      final gate = PolicyGate(const {}, true);
      expect(
        gate.decide(
          tool: 'weather__forecast',
          risk: Risk.read,
          taints: {},
          caps: _caps(),
        ),
        Decision.deny,
      );
    });

    test('an allowed risk is allowed on a clean run', () {
      final gate = PolicyGate({Risk.read: Decision.allow}, false);
      expect(
        gate.decide(
          tool: 'weather__forecast',
          risk: Risk.read,
          taints: {},
          caps: _caps(),
        ),
        Decision.allow,
      );
    });

    test('ask degrades to deny without an interactive channel', () {
      final withChannel = PolicyGate({Risk.external: Decision.ask}, true);
      final withoutChannel = PolicyGate({Risk.external: Decision.ask}, false);
      final args = (risk: Risk.external, taints: <UntrustedSource>{});
      expect(
        withChannel.decide(
          tool: 'weather__forecast',
          risk: args.risk,
          taints: args.taints,
          caps: _caps(),
        ),
        Decision.ask,
      );
      expect(
        withoutChannel.decide(
          tool: 'weather__forecast',
          risk: args.risk,
          taints: args.taints,
          caps: _caps(),
        ),
        Decision.deny,
      );
    });

    test('a tainted run cannot act externally without a human', () {
      final gate = PolicyGate({Risk.external: Decision.allow}, true);
      final decision = gate.decide(
        tool: 'weather__forecast',
        risk: Risk.external,
        taints: {UntrustedSource('web')},
        caps: _caps(),
      );
      expect(decision, Decision.ask);
    });

    test('a tainted run is denied externally without a channel', () {
      final gate = PolicyGate({Risk.external: Decision.allow}, false);
      final decision = gate.decide(
        tool: 'weather__forecast',
        risk: Risk.external,
        taints: {UntrustedSource('web')},
        caps: _caps(),
      );
      expect(decision, Decision.deny);
    });

    test('a tainted run is denied destructive actions even with a channel', () {
      final gate = PolicyGate({Risk.destructive: Decision.allow}, true);
      final decision = gate.decide(
        tool: 'weather__forecast',
        risk: Risk.destructive,
        taints: {UntrustedSource('web')},
        caps: _caps(),
      );
      expect(decision, Decision.deny);
    });

    test('taint does not restrict write actions below external', () {
      final gate = PolicyGate({Risk.write: Decision.allow}, false);
      final decision = gate.decide(
        tool: 'weather__forecast',
        risk: Risk.write,
        taints: {UntrustedSource('web')},
        caps: _caps(),
      );
      expect(decision, Decision.allow);
    });
  });
}
