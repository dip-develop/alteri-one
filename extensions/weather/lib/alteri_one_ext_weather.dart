// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The reference extension for AlteriOne.
///
/// This package is the example that `docs/guides/` for extension authors points to:
/// tool registration, state observation, and both loading modes (built-in and loaded
/// AOT). Behavior must be identical in both modes.
///
/// The same [WeatherExtension.register] runs in both modes: the build entry point
/// calls it directly (built-in), and the AOT entry point calls it through
/// `runExtension` (loaded) (docs/spec/extensions.md, section 11.6).
library;

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_sdk/alteri_one_sdk.dart';

/// The `forecast` tool's specification.
///
/// The input schema is the raw JSON Schema map [ToolSpec] carries (no fixed
/// schema, docs/spec/contracts.md, section 10.2); the declared risk is
/// [Risk.external] because a real backend would call a weather service.
final ToolSpec forecastSpec = ToolSpec.defaults(
  name: 'forecast',
  llmName: 'weather__forecast',
  description:
      'Weather forecast for 1–7 days for a city. Call for weather questions.',
  risk: Risk.external,
  inputSchema: const {
    'type': 'object',
    'properties': {
      'city': {'type': 'string'},
      'days': {'type': 'integer', 'minimum': 1, 'maximum': 7},
    },
    'required': ['city'],
  },
);

/// The reference extension: a `forecast` tool and a `runs` observer.
///
/// The forecast is deterministic so the built-in and loaded modes produce
/// identical output (the e2e parity test, M5 Step 10); a production backend
/// would replace [_forecast] without changing the registration.
final class WeatherExtension implements AlteriOneExtension {
  /// Creates the extension.
  const new();

  @override
  void register(ExtensionContext ctx) {
    ctx.tool(forecastSpec, _forecast);
    ctx.observe(StateTopic.runs, _onRun);
  }

  Future<Object?> _forecast(Map<String, Object?> input) async {
    final Object? city = input['city'];
    if (city is! String || city.isEmpty) {
      throw const FormatException('forecast requires a non-empty city');
    }
    final int days = _clampDays(input['days']);
    return <String, Object?>{
      'city': city,
      'days': days,
      'summary': 'clear, 21 °C',
    };
  }

  /// The `runs` observer: the reference extension keeps no state, so it only
  /// acknowledges the event. It exists to show the observation surface; the
  /// host (M5 Step 12) delivers a snapshot then live `runs` events.
  Future<void> _onRun(AgentEvent event) async {}

  static int _clampDays(Object? value) {
    if (value is! int) return 1;
    return value.clamp(1, 7);
  }
}
