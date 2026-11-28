// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../../application/agent/run_result.dart';
import '../../application/agent/tool_set.dart';
import '../../application/approval/approval_channel.dart';
import '../../application/approvals_bloc.dart';
import '../../application/config/profile_loader.dart';
import '../../application/extensions_bloc.dart';
import '../../application/run_service.dart';
import '../../application/state_publisher.dart';
import '../../di/injection.dart';
import '../../di/provider_registry.dart';
import '../../domain/ids.dart';
import '../../domain/ports/journal_port.dart';
import '../../domain/ports/llm_port.dart';
import '../../domain/ports/manifest_verifier.dart';
import '../../domain/profile.dart';
import '../journal/hive_journal.dart';
import '../paths.dart';
import '../server/auth.dart';
import '../server/doctor.dart';
import '../server/http_api.dart';
import '../server/pairing.dart';
import '../server/routes.dart';
import '../server/scope.dart';
import '../server/token_store.dart';
import 'daemon_config.dart';
import 'instance_lock.dart';
import 'run_registry.dart';
import 'stop_signal.dart';

/// The composition root and lifecycle of the local daemon
/// (docs/spec/deployment.md, sections 18.1–18.3; docs/plan/M4.md Step 9).
///
/// The daemon owns the path and the lifetime of every long-lived component
/// (Q10): it resolves [HomePaths], acquires the single-instance lock, opens
/// the journal, registers the profile and the model port in the container,
/// builds the `shelf` server from [HttpApi] with the Step 5 resource ports
/// wired to real adapters, and serves it. [start] brings it up; [stop] runs
/// the section 18.2 shutdown sequence in order.
///
/// The business logic lives here, in the core. The `bin` entry point (Step 11)
/// only parses arguments and calls [start] and [stop]; a test drives the same
/// API with fakes and a temporary `ALTERIONE_HOME`.
final class Daemon {
  /// Creates the daemon over the resolved [paths] and merged [config].
  ///
  /// [serverInfo] is advertised on `GET /v1/info`. [shutdownTimeout] bounds
  /// step 2 of the shutdown (default 30 s, section 18.2). [environment] is the
  /// process environment the config loader reads `ALTERIONE_*` from; it
  /// defaults to [Platform.environment] and is injectable so a test does not
  /// touch the real environment.
  // The named parameters are public, so they are not initializing formals.
  new({
    required HomePaths paths,
    required DaemonConfig config,
    required ServerInfo serverInfo,
    this._shutdownTimeout = const Duration(seconds: 30),
    Map<String, String>? environment,
    // ignore: prefer_initializing_formals
  }) : _paths = paths,
       // ignore: prefer_initializing_formals
       _config = config,
       // ignore: prefer_initializing_formals
       _serverInfo = serverInfo,
       _environment = environment ?? Platform.environment;

  final HomePaths _paths;
  final DaemonConfig _config;
  final ServerInfo _serverInfo;
  final Duration _shutdownTimeout;
  final Map<String, String> _environment;

  HttpServer? _server;
  InstanceLock? _lock;
  RunRegistry? _runs;
  bool _started = false;
  bool _shuttingDown = false;
  StopSignal? _stopSignal;
  StreamSubscription<void>? _stopSubscription;
  final Completer<void> _stopped = Completer<void>();

  /// The profile the daemon runs, loaded from the merged config.
  Profile get profile => _profile!;
  Profile? _profile;

  /// The port the server listens on, available after [start].
  int get port => _server?.port ?? 0;

  /// The run registry backing `/v1/runs`, available after [start].
  RunRegistry get runs => _runs!;

  /// Whether the daemon is accepting new runs (started and not shutting down).
  bool get isAcceptingRuns => _started && !_shuttingDown;

  /// Completes when [stop] has finished the section 18.2 shutdown sequence.
  ///
  /// The composition root awaits it to exit after a stop signal (SIGTERM or
  /// the Windows IPC stop endpoint) has driven [stop]. It never completes if
  /// the daemon was never started.
  Future<void> get stopped => _stopped.future;

  /// Builds the daemon from the environment and CLI flags, loading the
  /// configuration and the profile (section 14.2 merge).
  ///
  /// This is the factory the `bin` entry point calls: it reads
  /// `alterione.yaml` and the profile file from the configuration directory,
  /// merges the `ALTERIONE_*` environment and the CLI flags, and loads the
  /// profile through [ProfileLoader]. [cliFlags] are the already-parsed
  /// `--key value` flags.
  static Future<Daemon> load({
    required HomePaths paths,
    Map<String, String>? environment,
    Map<String, String> cliFlags = const {},
    ServerInfo? serverInfo,
    Duration shutdownTimeout = const Duration(seconds: 30),
  }) async {
    final env = environment ?? Platform.environment;
    final loader = const DaemonConfigLoader();
    final configFile = _readIfExists(
      _join(paths.config, DaemonConfigLoader.fileName),
    );
    final profileFile = _readIfExists(
      _join(
        _join(paths.config, 'profiles'),
        DaemonConfigLoader.profileFileName,
      ),
    );
    final config = loader.load(
      fileYaml: configFile,
      profileFileYaml: profileFile,
      environment: env,
      cliFlags: cliFlags,
    );
    // The profile runs the full section 14.3 pipeline (substitute, validate,
    // map) on the merged profile map; `parse` is the map entry point that
    // applies the semantic checks and the domain mapping.
    final profile = ProfileLoader(env: env).parse(config.profile);
    return Daemon(
      paths: paths,
      config: config,
      serverInfo: serverInfo ?? _defaultServerInfo(),
      shutdownTimeout: shutdownTimeout,
      environment: env,
    ).._profile = profile;
  }

  /// Acquires the lock, opens the journal, registers the profile and the model
  /// port, builds the server, and starts serving.
  ///
  /// Throws [StateError] when the lock is held by another instance (the
  /// message is clear and the caller exits non-zero), when the daemon is
  /// already started, or when [registerLlmPort] is required but no port was
  /// bound. [llm] is the model port the runs use; [approvalChannel], when
  /// given, lets an `ask` rule reach the owner; [toolRegistry], when given,
  /// replaces the empty default so a run can call tools (the e2e and daemon
  /// tests inject one; production builds it from the loaded extensions).
  /// [stopSignal], when given, is the platform stop source (section 18.7,
  /// T20): the daemon calls [stop] when it emits, so Windows stops without
  /// SIGTERM. On Linux/macOS the caller passes none and stops on SIGTERM.
  Future<void> start({
    required LlmPort llm,
    ApprovalChannel? approvalChannel,
    PairingService? pairing,
    ToolRegistry? toolRegistry,
    StopSignal? stopSignal,
  }) async {
    if (_started) throw StateError('The daemon is already started');
    final lock = InstanceLock.acquire(_paths.data);
    switch (lock) {
      case LockHeld(:final message):
        throw StateError(message);
      case LockAcquired(:final lock):
        _lock = lock;
    }

    configureCore(environment: 'prod');
    await registerJournal(directory: _paths.journalDirectory);
    _profile ??= ProfileLoader(env: _environment).parse(_config.profile);
    registerProfile(profile: _profile!, channel: approvalChannel);
    registerLlmPort(llm);
    if (toolRegistry != null) {
      // Replace the fail-closed empty registry before RunService is first
      // resolved, so the agent deps capture the injected tools.
      if (getIt.isRegistered<ToolRegistry>()) {
        await getIt.unregister<ToolRegistry>();
      }
      getIt.registerSingleton<ToolRegistry>(toolRegistry);
    }

    final service = getIt<RunService>();
    final publisher = getIt<StatePublisher>();
    final journal = getIt<JournalPort>();
    final approvalsBloc = getIt<ApprovalsBloc>();
    final registry = RunRegistry(
      service: service,
      journal: journal,
      publisher: publisher,
    )..profile = _profile!;
    _runs = registry;

    final token = TokenStore(_paths.config).loadOrCreate();
    final tokenResolver = _TokenMapResolver({token: _ownerToken()});

    final api = HttpApi(
      serverInfo: _serverInfo,
      allowedHosts: _allowedHosts(),
      pairing: pairing ?? PairingService(),
      tokenResolver: tokenResolver,
      runs: registry,
      approvals: _ApprovalsResource(approvalsBloc),
      extensions: _ExtensionsResource(getIt<ExtensionsBloc>(), _paths),
      doctor: _DoctorResource(
        config: _config,
        registry: getIt<ProviderRegistry>(),
        extensions: getIt<ExtensionsBloc>(),
        verifier: getIt<ManifestVerifier>(),
        fetch: _defaultToolsFetch,
      ),
      publisher: publisher,
      journal: journal,
    );

    // The shutdown guard (section 18.2, step 1): once [_shuttingDown] flips,
    // a request that would start or drive a run gets `503 shutting_down`
    // before it reaches the resource port. Reads stay served so a client can
    // drain state while the daemon stops.
    final handler = const Pipeline()
        .addMiddleware(_shutdownGuard)
        .addHandler(api.handler);
    _server = await shelf_io.serve(handler, _config.bindHost, _config.bindPort);
    _started = true;

    // The platform stop source (section 18.7, T20): a Windows logon task has
    // no SIGTERM, so the daemon listens for the IPC stop endpoint and runs the
    // same [stop] sequence when it emits. A no-op signal never emits.
    if (stopSignal != null) {
      _stopSignal = stopSignal;
      _stopSubscription = stopSignal.onStop.listen((_) => stop());
    }
  }

  /// Runs the section 18.2 shutdown sequence in order
  /// (docs/spec/deployment.md, section 18.2).
  ///
  /// 1. New runs get `503 shutting_down`: [_shuttingDown] flips first, so the
  ///    shutdown guard answers a run-mutating request with 503 before it
  ///    reaches the resource port.
  /// 2. Active tool calls finish, up to [shutdownTimeout].
  /// 3. Unfinished runs are marked `interrupted`.
  /// 4. SSE clients receive `server.shutdown`.
  /// 5. Extensions are unloaded.
  /// 6. Hive is flushed and the lock is released.
  ///
  /// After the timeout the remaining work is forced: the server is closed and
  /// the journal and lock are released regardless. Idempotent: a second call
  /// is a no-op.
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    // 1. Refuse new runs from here on.
    _shuttingDown = true;

    // Stop listening for the platform stop source; the shutdown is under way.
    await _stopSubscription?.cancel();
    _stopSubscription = null;

    // 2. Let active tool calls finish, bounded by the shutdown timeout.
    final registry = _runs;
    final active = registry?.activeExecutions ?? const <Future<RunResult>>[];
    if (active.isNotEmpty) {
      try {
        await Future.wait(active).timeout(_shutdownTimeout);
      } on TimeoutException {
        // Force path: fall through and mark whatever is left interrupted.
      }
    }

    // 3. Mark unfinished runs interrupted (journalled and published).
    await registry?.markUnfinishedInterrupted();

    final publisher = getIt.isRegistered<StatePublisher>()
        ? getIt<StatePublisher>()
        : null;
    // 4. Tell SSE clients the server is shutting down.
    publisher?.publish(
      StateTopic.runs,
      ServerShutdown(at: DateTime.now().toUtc()),
    );

    // 5. Extensions are unloaded (the registry is drained in M5; closing the
    //    bloc drops the registry here).
    if (getIt.isRegistered<ExtensionsBloc>()) {
      await getIt<ExtensionsBloc>().close();
    }

    // Close the server so new connections are refused.
    await _server?.close(force: true);
    _server = null;

    // 6. Flush Hive and release the lock.
    if (getIt.isRegistered<HiveJournal>()) {
      await getIt<HiveJournal>().close();
    }
    _lock?.release();
    _lock = null;
    if (getIt.isRegistered<ApprovalsBloc>()) {
      await getIt<ApprovalsBloc>().close();
    }
    await getIt.reset();

    // Release the platform stop source (the IPC endpoint socket), then signal
    // the composition root that the shutdown is complete.
    await _stopSignal?.close();
    _stopSignal = null;
    if (!_stopped.isCompleted) _stopped.complete();
  }

  Set<String> _allowedHosts() => const {'localhost', '127.0.0.1'};

  DeviceToken _ownerToken() => DeviceToken('owner', const {
    Scope.read,
    Scope.readIo,
    Scope.run,
    Scope.approve,
    Scope.admin,
  });

  /// The shutdown guard middleware (section 18.2, step 1).
  ///
  /// While [_shuttingDown] is set, a `POST` that would create or drive a run
  /// (`/v1/runs` and its `:action` routes) is answered `503 shutting_down`
  /// before it reaches the resource port. Reads and the public routes stay
  /// served so a client can drain state during the stop.
  Middleware get _shutdownGuard {
    return (Handler inner) {
      return (Request request) async {
        if (!_shuttingDown) return await inner(request);
        final path = request.url.path;
        final isRunMutation =
            request.method == 'POST' &&
            (path == 'v1/runs' || path.startsWith('v1/runs/'));
        if (isRunMutation) {
          return Response(
            503,
            body: ApiErrorCode.shuttingDown,
            headers: const {'content-type': 'text/plain; charset=utf-8'},
          );
        }
        return await inner(request);
      };
    };
  }

  static ServerInfo _defaultServerInfo() =>
      ServerInfo(sdk: _sdkVersion(), capabilities: const ['sse']);

  static String _sdkVersion() {
    // The SDK version is stamped by the build; a constant keeps the daemon
    // free of a Platform.version parse at startup.
    return '3.14.0';
  }

  static String? _readIfExists(String path) {
    final file = File(path);
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  static String _join(String base, String suffix) {
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    return '$b/$suffix';
  }
}

/// A [TokenResolver] backed by a fixed token-to-device map.
final class _TokenMapResolver implements TokenResolver {
  new(this._tokens);
  final Map<String, DeviceToken> _tokens;
  @override
  DeviceToken? resolve(String token) => _tokens[token];
}

/// The real [ApprovalResourcePort] over [ApprovalsBloc]
/// (docs/spec/api.md, section 16.3).
///
/// `pendingApprovals` reads the bloc's current pending map;
/// `decideApproval` records the decision as an [ApprovalDecidedEvent] (the
/// first decision wins because the bloc ignores a decision for an id that is
/// no longer pending) and reports a conflict when the id was not pending.
final class _ApprovalsResource implements ApprovalResourcePort {
  new(this._bloc);
  final ApprovalsBloc _bloc;

  @override
  Future<List<ApprovalRequestView>> pendingApprovals() async => [
    for (final approval in _bloc.state.pending.values)
      ApprovalRequestView(
        id: approval.id.value,
        runId: approval.runId.value,
        tool: approval.tool,
        deadline: approval.deadline,
      ),
  ];

  @override
  Future<ApprovalDecisionResult> decideApproval(
    String id,
    bool approved,
  ) async {
    final approvalId = ApprovalId(id);
    if (!_bloc.state.pending.containsKey(approvalId)) {
      return const ApprovalNotFound();
    }
    _bloc.add(ApprovalDecidedEvent(approvalId, granted: approved));
    return ApprovalDecided(ApprovalDecisionView(id: id, approved: approved));
  }
}

/// The real [ExtensionResourcePort] over [ExtensionsBloc]
/// (docs/spec/api.md, section 16.3; M5 Step 16).
///
/// [listExtensions] reads the registry. [loadExtension] resolves the module at
/// `<data>/extensions/<id>.aot`, rejects a duplicate id, and adds a
/// [ExtensionLoadRequestedEvent] so the bloc spawns, verifies, and registers it;
/// [unloadExtension] adds an [ExtensionUnloadRequestedEvent] so the bloc drains
/// it to `stopped`. The action is applied to the bloc asynchronously, so the
/// returned view reflects the intended state; a concurrent `GET /v1/extensions`
/// reports the settled state.
final class _ExtensionsResource implements ExtensionResourcePort {
  new(this._bloc, this._paths);
  final ExtensionsBloc _bloc;
  final HomePaths _paths;

  @override
  Future<List<ExtensionView>> listExtensions() async => [
    for (final entry in _bloc.state.registry.entries)
      ExtensionView(id: entry.key, state: entry.value.name),
  ];

  @override
  Future<ExtensionActionResult> loadExtension(String id) async {
    if (_bloc.state.registry.containsKey(id)) {
      return const ExtensionActionRejected();
    }
    final module = File('${_paths.data}/extensions/$id.aot');
    if (!module.existsSync()) {
      return const ExtensionUnavailable();
    }
    _bloc.add(ExtensionLoadRequestedEvent(extensionId: id, uri: module.uri));
    return ExtensionActionApplied(ExtensionView(id: id, state: 'loaded'));
  }

  @override
  Future<ExtensionActionResult> unloadExtension(String id) async {
    if (!_bloc.state.registry.containsKey(id)) {
      return const ExtensionUnavailable();
    }
    _bloc.add(ExtensionUnloadRequestedEvent(id));
    return ExtensionActionApplied(ExtensionView(id: id, state: 'stopped'));
  }
}

/// The real [DoctorResourcePort] over the daemon's configuration, extension
/// registry, provider, and manifest verifier (docs/spec/clients-cli.md,
/// section 19; M4 Step 14, M5 Step 16).
///
/// It reports the facts only the core knows: the configuration loaded (a
/// `ConfigurationException` would have stopped the daemon at `load`), the
/// registered extensions' signatures (re-verified through the wired
/// [ManifestVerifier], or `skipped` when none is wired), the registered
/// providers, the `llama-server` built-in tools list (proxied from the provider
/// `base_url`), and the `distribution.yaml` match (a build-time artifact the
/// running binary does not carry yet, so it is `skipped`). TLS and
/// token-strength checks are M4b.
final class _DoctorResource implements DoctorResourcePort {
  new({
    required this.config,
    required this.registry,
    required this.extensions,
    required this.verifier,
    required this.fetch,
  });
  final DaemonConfig config;
  final ProviderRegistry registry;
  final ExtensionsBloc extensions;
  final ManifestVerifier? verifier;
  final ToolsFetcher fetch;

  @override
  Future<DoctorReport> report(DeviceToken token) async {
    final checks = <DoctorCheck>[
      DoctorCheck(
        name: 'configuration',
        status: DoctorStatus.ok,
        detail: 'configuration loaded (mode: ${config.mode})',
      ),
      await checkExtensionSignatures(
        modules: [
          for (final module in extensions.loadedModules)
            ExtensionModuleRef(id: module.id, uri: module.uri),
        ],
        verifier: verifier,
      ),
      _providerCheck(),
      await checkLlamaServerTools(baseUrl: _providerBaseUrl(), fetch: fetch),
      await checkDistribution(running: null, declared: null),
    ];
    return DoctorReport(
      checks: checks,
      scopes: <String>[for (final scope in token.scopes) scope.wire],
    );
  }

  DoctorCheck _providerCheck() {
    final kinds = registry.kinds.toList();
    if (kinds.isEmpty) {
      return const DoctorCheck(
        name: 'providers',
        status: DoctorStatus.skipped,
        detail: 'no model provider registered',
      );
    }
    return DoctorCheck(
      name: 'providers',
      status: DoctorStatus.ok,
      detail: 'providers: ${kinds.join(', ')}',
    );
  }

  /// The first `base_url` under `models` in the merged config, or `null`.
  String? _providerBaseUrl() {
    final models = config.layers['models'];
    if (models is Map) {
      for (final Object? entry in models.values) {
        if (entry is Map && entry['base_url'] is String) {
          return entry['base_url']! as String;
        }
      }
    }
    return null;
  }
}

/// The default [ToolsFetcher]: a one-shot `dart:io` `GET` (docs/spec/providers.md,
/// section 12.3). The core does not depend on `package:http`, so the proxy uses
/// `dart:io` directly.
Future<({int status, String body})> _defaultToolsFetch(Uri url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(url);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return (status: response.statusCode, body: body);
  } finally {
    client.close();
  }
}
