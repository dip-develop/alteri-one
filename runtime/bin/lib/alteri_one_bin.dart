// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The `alterione` executable: it wires the CLI commands and the `serve`
/// command to the core, and nothing else.
///
/// This is the composition root of the binary (docs/spec/architecture.md,
/// section 6; docs/spec/clients-cli.md, section 19). It reads the token file
/// and the daemon base URL from [HomePaths], constructs an [AlteriOneCli] for
/// the client commands, and constructs and drives the core [Daemon] for
/// `serve`. The business logic lives in `alteri_one_cli` and `alteri_one_core`;
/// this package only wires them and maps the result to a process exit code.
///
/// The model port for `serve` is injected: a concrete build (or a test) hands
/// in the [LlmPort] produced by the provider DI (`registerProviders` /
/// [ProviderRegistry]). This package never imports a provider directly
/// (docs/spec/architecture.md, section 6).
library;

import 'dart:async';
import 'dart:io';

import 'package:alteri_one_cli/alteri_one_cli.dart';
import 'package:alteri_one_core/alteri_one_core.dart';

import 'src/build/build_command.dart';

/// Runs `alterione` with [args] and returns the process exit code.
///
/// [environment] is the process environment the paths and the config read;
/// [out] and [err] are the standard streams; [stdin] feeds the interactive
/// commands. [serveLlm] is the model port `serve` runs; [providers] is the
/// provider DI a build uses to produce it when [serveLlm] is absent. [serveStop]
/// completes to stop `serve`; it defaults to `SIGTERM` (section 18.2).
Future<int> runAlteriOne(
  List<String> args, {
  Map<String, String>? environment,
  StringSink? out,
  StringSink? err,
  Stream<String>? stdin,
  LlmPort? serveLlm,
  List<ModelProvider> providers = const <ModelProvider>[],
  ToolRegistry? toolRegistry,
  Stream<void>? serveStop,
}) async {
  final env = environment ?? Platform.environment;
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;

  if (args.isNotEmpty && (args.first == '--help' || args.first == '-h')) {
    _printUsage(stdoutSink);
    return ExitCode.success;
  }

  if (args.isNotEmpty && args.first == 'serve') {
    return await _serve(
      environment: env,
      out: stdoutSink,
      err: stderrSink,
      serveLlm: serveLlm,
      providers: providers,
      toolRegistry: toolRegistry,
      serveStop: serveStop,
    );
  }

  if (args.isNotEmpty && args.first == 'build') {
    return await runBuild(
      args.skip(1).toList(),
      out: stdoutSink,
      err: stderrSink,
    );
  }

  final paths = HomePaths.fromEnvironment(environment: env);
  final config = _loadConfig(paths, env);
  final baseUrl = Uri(
    scheme: 'http',
    host: config.bindHost,
    port: config.bindPort,
  );
  final token = TokenStore(paths.config).readExisting();
  final cli = AlteriOneCli(
    baseUrl: baseUrl,
    token: token,
    out: stdoutSink,
    err: stderrSink,
    stdin: stdin,
  );
  return await cli.run(args);
}

Future<int> _serve({
  required Map<String, String> environment,
  required StringSink out,
  required StringSink err,
  required LlmPort? serveLlm,
  required List<ModelProvider> providers,
  required ToolRegistry? toolRegistry,
  required Stream<void>? serveStop,
}) async {
  final LlmPort? llm = serveLlm ?? await _llmFromProviders(providers);
  if (llm == null) {
    err.writeln(
      'serve: no model provider is configured for this build; '
      'a personal build wires one into the binary',
    );
    return ExitCode.configuration;
  }

  final paths = HomePaths.fromEnvironment(environment: environment);
  final Daemon daemon;
  try {
    daemon = await Daemon.load(paths: paths, environment: environment);
  } on ConfigurationException catch (error) {
    err.writeln('serve: ${error.message}');
    return ExitCode.configuration;
  }

  final Stream<void> stop = serveStop ?? _sigterm();
  // The platform stop source (section 18.7, T20): a real IPC endpoint on
  // Windows, a documented no-op on Linux/macOS where SIGTERM stops the process.
  // The daemon listens to it and runs the same section 18.2 shutdown; the
  // SIGTERM/test [stop] stream drives the same [Daemon.stop] on every platform.
  // On Windows the bound port is written to the data dir so a stop helper (the
  // logon task) discovers the loopback endpoint without a fixed port.
  final StopSignal platformStop = await platformStopSignal(
    portFile: _join(paths.data, 'alterione.stop.port'),
  );
  final StreamSubscription<void> subscription = stop.listen(
    (_) => daemon.stop(),
  );

  try {
    await daemon.start(
      llm: llm,
      stopSignal: platformStop,
      toolRegistry: toolRegistry,
    );
  } on StateError catch (error) {
    await subscription.cancel();
    await platformStop.close();
    // A held single-instance lock (section 18.1) lands here: clear message,
    // non-zero exit.
    err.writeln('serve: ${error.message}');
    return ExitCode.failure;
  }

  out.writeln('alterione: serving on port ${daemon.port}');
  // Completes when the section 18.2 shutdown finishes, whichever stop source
  // fired (SIGTERM, the test stream, or the Windows IPC endpoint).
  await daemon.stopped;
  await subscription.cancel();
  return ExitCode.success;
}

/// Builds the model port from the provider DI, or `null` when none is given.
///
/// The first registered provider is probed and instantiated; a build that
/// needs a specific provider passes exactly that one. The provider packages are
/// never imported here (docs/spec/architecture.md, section 6). The options come
/// from the build's configuration in a later step; a build that needs options
/// supplies a ready [serveLlm] instead.
Future<LlmPort?> _llmFromProviders(List<ModelProvider> providers) async {
  if (providers.isEmpty) return null;
  final registry = ProviderRegistry()..registerAll(providers);
  final provider = registry[registry.kinds.first];
  final capabilities = await provider.probe(const <String, Object?>{});
  return provider.create(const <String, Object?>{}, capabilities);
}

DaemonConfig _loadConfig(HomePaths paths, Map<String, String> environment) {
  final file = File(_join(paths.config, DaemonConfigLoader.fileName));
  final fileYaml = file.existsSync() ? file.readAsStringSync() : null;
  return const DaemonConfigLoader().load(
    fileYaml: fileYaml,
    environment: environment,
  );
}

Stream<void> _sigterm() {
  if (Platform.isWindows) {
    // Windows has no SIGTERM for this purpose; the stop path is T20 (Step 12).
    return const Stream<void>.empty();
  }
  return ProcessSignal.sigterm.watch();
}

void _printUsage(StringSink out) {
  out.writeln('usage: alterione <command> [options]');
  out.writeln(
    'commands: serve, build, service, status, run, chat, watch, doctor',
  );
}

String _join(String base, String suffix) {
  final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  return '$b/$suffix';
}
