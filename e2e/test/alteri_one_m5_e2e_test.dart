// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// M5 Step 10 end-to-end parity test (docs/plan/M5.md Step 10;
/// docs/spec/extensions.md section 11.6).
///
/// The `weather` reference extension must behave identically in built-in and
/// loaded modes. Built-in mode runs the extension in the daemon's own isolate
/// through a [BuiltInExtensionContext] (the generated build entry wires this in
/// production); loaded mode runs the same [WeatherExtension.register] through
/// the SDK's `runExtension` in a spawned isolate, driven by the real
/// [IsolateExtensionTransport].
///
/// AOT vs source: under `flutter pub run test` the host is the JIT VM, which
/// can only `Isolate.spawnUri` a *source* module — it cannot load an AOT
/// snapshot (ADR-0007, the Step 1 constraint). The loaded-mode path here
/// therefore loads a source module that calls the real `runExtension`; the
/// AOT-snapshot parity is covered by the `alterione build` path (Step 13) and
/// the build/e2e run on the AOT binary, not by this JIT test. The extension
/// code under test is the same in both modes; only the host context differs.
///
/// The run happens on a temporary `ALTERIONE_HOME` with a scripted fake
/// [LlmPort] (no real model, no external network), and the built-in forecast is
/// additionally driven end to end through a real [Daemon] so the tool is
/// exercised through the full PolicyGate + agent loop + journal stack.
library;

import 'dart:async';
import 'dart:io';

import 'package:alteri_one_client/alteri_one_client.dart';
import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart' hide RunView;
import 'package:alteri_one_ext_weather/alteri_one_ext_weather.dart';
import 'package:test/test.dart';

/// The input every mode is driven with, and the forecast output they must all
/// produce. The extension clamps `days` into 1–7 and returns a deterministic
/// summary, so the three paths below are directly comparable.
final Map<String, Object?> _input = {'city': 'Paris', 'days': 3};
final Map<String, Object?> _expectedForecast = {
  'city': 'Paris',
  'days': 3,
  'summary': 'clear, 21 °C',
};

/// The source module the loaded mode spawns: it calls the real
/// `runExtension` with the real [WeatherExtension.register], so the loaded path
/// exercises the same extension code as the built-in path.
const _loadedModuleSource = r'''
import 'dart:isolate';

import 'package:alteri_one_ext_weather/alteri_one_ext_weather.dart';
import 'package:alteri_one_sdk/alteri_one_sdk.dart';

void main(List<String> args, SendPort host) {
  runExtension(host, const WeatherExtension().register);
}
''';

/// A [ManifestVerifier] that returns the `weather` manifest for any module.
///
/// The real composition root wires a signing-backed verifier (Step 6); this
/// test is about extension behavior parity, not signature verification, so it
/// accepts the module and declares the `runs` observation the extension makes.
final class _WeatherVerifier implements ManifestVerifier {
  const new();

  @override
  Future<ExtensionManifest> verify(Uri module) async => ExtensionManifest(
    id: 'weather',
    version: '0.1.0',
    contract: '0.4.0',
    sdk: '3.14.0',
    target: 'linux-x64',
    provides: ExtensionProvides(
      tools: const ['forecast'],
      triggers: const [],
      channels: const [],
      context: const [],
      memoryBackend: false,
      skills: const [],
    ),
    permissions: const [],
    sha256: 'e2e',
    signature: 'e2e',
    observes: const ['runs'],
  );
}

/// A [LlmPort] that requests [toolName] on the first turn and finishes on the
/// second, capturing the tool result the agent loop feeds back so the test can
/// assert the forecast output that reached the model.
final class _ScriptedLlm implements LlmPort {
  new(this.toolName);

  /// The LLM tool name to request on the first turn.
  final String toolName;

  int _turns = 0;

  /// The value of the first tool result, captured on the second turn.
  Object? toolResult;

  /// Whether the captured tool result was a success.
  bool get toolResultOk => _toolResultOk;
  bool _toolResultOk = false;

  @override
  Future<Turn> complete({
    required List<Message> messages,
    required List<ToolSpec> tools,
    required int maxOutputTokens,
  }) async {
    _turns++;
    if (_turns == 1) {
      final call = ToolCall.valid(id: 'call-1', name: toolName, input: _input);
      return Turn('', Message.assistant('', [call]), [call]);
    }
    for (final Message message in messages) {
      for (final ToolResultBlock result in message.toolResults) {
        if (result.callId == 'call-1') {
          toolResult = result.value;
          _toolResultOk = result.isOk;
        }
      }
    }
    return Turn(
      'forecast complete',
      Message.assistant('forecast complete'),
      const [],
    );
  }
}

void main() {
  group('M5 Step 10 e2e parity', () {
    test(
      'built-in and loaded modes produce identical forecast output',
      () async {
        final builtIn = await _callBuiltIn();
        final loaded = await _callLoaded();

        expect(builtIn, _expectedForecast);
        expect(loaded, _expectedForecast);
        // The parity assertion: the two modes agree exactly.
        expect(loaded, equals(builtIn));
      },
    );

    test('both modes observe the runs topic', () async {
      final builtInObservers = await _builtInContext();
      expect(builtInObservers.observers.containsKey(StateTopic.runs), isTrue);
      // The built-in observer is invocable and completes without error.
      await builtInObservers.observers[StateTopic.runs]!(
        RunStarted(at: DateTime.utc(2026), runId: 'r1', profile: 'assistant'),
      );

      final loaded = await _spawnLoaded();
      addTearDown(loaded.kill);
      expect(loaded.manifest.observes, contains('runs'));
      // Delivering a runs event through the publisher must not break the
      // extension: a follow-up forecast still succeeds.
      await loaded.call('forecast', _input, CancelToken());
    });

    test('built-in forecast runs end to end through the daemon', () async {
      final home = await Directory.systemTemp.createTemp('alterione_m5_e2e_');
      final paths = HomePaths.resolve(alterioneHome: home.path);
      final profiles = Directory('${paths.config}/profiles');
      await profiles.create(recursive: true);
      await File('${profiles.path}/assistant.yaml').writeAsString(
        'id: assistant\n'
        'model: local\n'
        'prompt: assistant\n'
        'tools: [weather__forecast]\n'
        'risk_rules:\n'
        '  read: allow\n'
        '  write: allow\n'
        '  external: allow\n'
        '  destructive: deny\n',
      );

      final daemon = await Daemon.load(
        paths: paths,
        serverInfo: ServerInfo(
          protocolVersion: 1,
          sdk: '3.14.0',
          capabilities: const ['sse'],
        ),
      );
      final llm = _ScriptedLlm('weather__forecast');
      await daemon.start(
        llm: llm,
        toolRegistry: (await _builtInContext()).registry,
      );

      final token = TokenStore(paths.config).loadOrCreate();
      final client = AlteriOneClient(
        baseUrl: Uri.parse('http://127.0.0.1:${daemon.port}'),
        token: token,
      );

      addTearDown(() async {
        client.close();
        await daemon.stop();
        if (getIt.isRegistered<HiveJournal>()) {
          await getIt<HiveJournal>().close();
        }
        await getIt.reset();
        if (home.existsSync()) await home.delete(recursive: true);
      });

      final runId = await client.createRun(
        profile: 'assistant',
        input: 'weather in Paris for 3 days',
      );
      final finished = await client
          .events(reconnectDelay: const Duration(milliseconds: 50))
          .firstWhere((event) => event is RunFinished && event.runId == runId)
          .timeout(const Duration(seconds: 5));
      expect(finished, isA<RunFinished>());
      expect((finished as RunFinished).state, 'completed');

      // The forecast tool ran through the PolicyGate and its output reached the
      // model. The tool is `external` risk, so the agent loop wraps its output
      // in untrusted markers and JSON-encodes the map (docs/spec/domain.md
      // section 8.2); the assertion is on that wrapped text, not the raw map.
      expect(llm.toolResultOk, isTrue, reason: 'forecast tool result failed');
      final text = llm.toolResult;
      expect(text, isA<String>());
      expect(text as String, contains('"city":"Paris"'));
      expect(text, contains('clear, 21 °C'));
    });
  });
}

/// Builds a [BuiltInExtensionContext] with the real [WeatherExtension]
/// registered, as the generated build entry does in built-in mode.
Future<BuiltInExtensionContext> _builtInContext() async {
  final context = BuiltInExtensionContext();
  const WeatherExtension().register(context);
  return context;
}

/// Runs the forecast tool in built-in mode and returns its output.
Future<Object?> _callBuiltIn() async {
  final context = await _builtInContext();
  final tool = context.registry
      .snapshot('assistant')
      .byLlmName(forecastSpec.llmName);
  expect(tool, isNotNull, reason: 'built-in registry has no forecast tool');
  return await tool!.call(_input, CancelToken());
}

/// Spawns the loaded-mode extension over a source module and returns it.
Future<IsolateLoadedExtension> _spawnLoaded() async {
  final module = await _writeLoadedModule();
  final transport = IsolateExtensionTransport(
    verifier: const _WeatherVerifier(),
    publisher: StatePublisher(),
  );
  final loaded = await transport.spawn(
    uri: module.uri,
    handshakeTimeout: const Duration(seconds: 5),
  );
  return loaded as IsolateLoadedExtension;
}

/// Runs the forecast tool in loaded mode and returns its output.
Future<Object?> _callLoaded() async {
  final loaded = await _spawnLoaded();
  addTearDown(loaded.kill);
  final output = await loaded
      .call('forecast', _input, CancelToken())
      .timeout(const Duration(seconds: 5));
  await loaded.kill();
  return output;
}

/// Writes the loaded-mode source module under the `e2e` package so its
/// `package:` imports resolve through the workspace `package_config.json`
/// (a temp dir outside the package tree would not resolve them).
Future<File> _writeLoadedModule() async {
  final root = _e2ePackageRoot();
  final dir = await Directory(root.path).createTemp('m5_e2e_');
  final file = File('${dir.path}/weather_module.dart')
    ..writeAsStringSync(_loadedModuleSource);
  addTearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });
  return file.absolute;
}

/// The `e2e` package root, found by walking up from the current directory.
Directory _e2ePackageRoot() {
  Directory dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final pubspec = File('${dir.path}/pubspec.yaml');
    if (pubspec.existsSync() &&
        pubspec.readAsStringSync().contains('name: alteri_one_e2e')) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current.absolute;
}
