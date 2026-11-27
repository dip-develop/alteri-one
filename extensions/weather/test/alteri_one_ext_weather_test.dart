// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_ext_weather/alteri_one_ext_weather.dart';
import 'package:alteri_one_sdk/alteri_one_sdk.dart';
import 'package:test/test.dart';

/// A [ExtensionContext] that records what the extension registers.
final class _RecordingContext implements ExtensionContext {
  final Map<String, ToolHandler> tools = {};
  final Map<StateTopic, OnEvent> observers = {};
  final List<MemoryBackendHandle> memoryBackends = [];

  @override
  void tool(ToolSpec spec, ToolHandler handler) => tools[spec.name] = handler;

  @override
  void observe(StateTopic topic, OnEvent handler) => observers[topic] = handler;

  @override
  void provideMemoryBackend(MemoryBackendHandle backend) =>
      memoryBackends.add(backend);
}

void main() {
  group('WeatherExtension.register', () {
    late _RecordingContext ctx;

    setUp(() {
      ctx = _RecordingContext();
      const WeatherExtension().register(ctx);
    });

    test('registers the forecast tool with external risk', () {
      expect(ctx.tools.keys, ['forecast']);
      expect(forecastSpec.name, 'forecast');
      expect(forecastSpec.risk, Risk.external);
      expect(forecastSpec.llmName, 'weather__forecast');
    });

    test('observes the runs topic', () {
      expect(ctx.observers.keys, [StateTopic.runs]);
    });

    test('forecast returns a deterministic summary for a city', () async {
      final handler = ctx.tools['forecast']!;
      final Object? output = await handler({'city': 'Berlin', 'days': 3});

      expect(output, {'city': 'Berlin', 'days': 3, 'summary': 'clear, 21 °C'});
    });

    test('forecast clamps days into 1–7 and defaults to 1', () async {
      final handler = ctx.tools['forecast']!;

      expect(await handler({'city': 'Rome', 'days': 99}), {
        'city': 'Rome',
        'days': 7,
        'summary': 'clear, 21 °C',
      });
      expect(await handler({'city': 'Rome', 'days': 0}), {
        'city': 'Rome',
        'days': 1,
        'summary': 'clear, 21 °C',
      });
      expect(await handler({'city': 'Rome'}), {
        'city': 'Rome',
        'days': 1,
        'summary': 'clear, 21 °C',
      });
    });

    test('forecast rejects a missing or empty city', () async {
      final handler = ctx.tools['forecast']!;

      expect(() => handler({}), throwsA(isA<FormatException>()));
      expect(() => handler({'city': ''}), throwsA(isA<FormatException>()));
    });

    test('the runs observer completes without error', () async {
      final observer = ctx.observers[StateTopic.runs]!;
      final event = RunStarted(
        at: DateTime.utc(2026),
        runId: 'r-1',
        profile: 'assistant',
      );
      expect(observer(event), completes);
    });
  });
}
