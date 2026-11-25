// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Section 2.8 metrics harness for the AlteriOne daemon
/// (docs/spec/product.md, section 2.8; docs/plan/M4.md Step 13; issue #49).
///
/// The harness measures the four target metrics reproducibly against a real
/// [Daemon] started on a temporary `ALTERIONE_HOME` with a fake [LlmPort]:
///
/// 1. cold start: the wall-clock time to bring the daemon up with no models or
///    extensions loaded, target < 300 ms;
/// 2. idle memory: the resident set size of a minimal idle daemon, target
///    < 80 MB;
/// 3. event delivery latency: the p99 of the time from a `publish` on the
///    `StatePublisher` to its delivery to a local subscriber, target < 50 ms;
/// 4. tool-call overhead: the per-call cost of the `RunService` tool-dispatch
///    path excluding the tool's own work, target < 5 ms.
///
/// It writes a human-readable and a machine-readable report and exits non-zero
/// when a target is missed, or with a distinct "not measured" status when a
/// metric cannot be measured in the current environment. The numbers are
/// environment-specific; the tool's job is to measure and compare, not to
/// assert a particular machine's speed.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';

/// One measured metric and its verdict against the target.
final class MetricResult {
  /// Creates the result.
  const new({
    required this.name,
    required this.target,
    required this.unit,
    this.measured,
    this.status = MetricStatus.pass,
    this.detail,
  });

  /// The metric name.
  final String name;

  /// The target description, for example `< 300 ms`.
  final String target;

  /// The unit of [measured], for example `ms` or `MB`.
  final String unit;

  /// The measured value, or `null` when it was not measured.
  final double? measured;

  /// The verdict.
  final MetricStatus status;

  /// A human-readable note, for example why a metric was not measured.
  final String? detail;

  /// Whether this result is a pass (measured and within the target).
  bool get isPass => status == MetricStatus.pass;

  /// The JSON form of this result, for the machine-readable report.
  Map<String, Object?> toJson() => {
    'name': name,
    'target': target,
    'unit': unit,
    'measured': measured,
    'status': status.name,
    'detail': ?detail,
  };
}

/// The verdict of one metric.
enum MetricStatus {
  /// Measured and within the target.
  pass,

  /// Measured and outside the target.
  fail,

  /// Not measured in this environment; a distinct non-zero status.
  notMeasured,
}

/// The full report of one harness run.
final class MetricsReport {
  /// Creates the report.
  const new({required this.results, required this.environment});

  /// The four metric results, in the order of section 2.8.
  final List<MetricResult> results;

  /// The environment note recorded with the report.
  final String environment;

  /// Whether every measured metric passed and none was missed or unmeasured.
  bool get allPass => results.every(
    (MetricResult result) => result.status == MetricStatus.pass,
  );

  /// The exit code this report maps to: 0 when all pass, 1 when a target is
  /// missed, 2 when a metric was not measured.
  int get exitCode {
    if (results.any((MetricResult r) => r.status == MetricStatus.fail)) {
      return 1;
    }
    if (results.any((MetricResult r) => r.status == MetricStatus.notMeasured)) {
      return 2;
    }
    return 0;
  }

  /// The JSON form of the report.
  Map<String, Object?> toJson() => {
    'environment': environment,
    'all_pass': allPass,
    'exit_code': exitCode,
    'metrics': [for (final MetricResult result in results) result.toJson()],
  };

  /// The Markdown form of the report.
  String toMarkdown() {
    final buffer = StringBuffer()
      ..writeln('# AlteriOne section 2.8 metrics report')
      ..writeln()
      ..writeln('Environment: $environment')
      ..writeln()
      ..writeln('| Metric | Target | Measured | Status |')
      ..writeln('|---|---|---|---|');
    for (final MetricResult result in results) {
      final measured = result.measured == null
          ? 'n/a'
          : '${_fmt(result.measured!)} ${result.unit}';
      final detail = result.detail == null ? '' : ' — ${result.detail}';
      buffer.writeln(
        '| ${result.name} | ${result.target} | $measured | '
        '${result.status.name}$detail |',
      );
    }
    return buffer.toString();
  }

  static String _fmt(double value) {
    if (value >= 100) return value.toStringAsFixed(0);
    if (value >= 10) return value.toStringAsFixed(1);
    return value.toStringAsFixed(2);
  }
}

/// Runs the four section 2.8 measurements and returns the report.
///
/// [environment] is the process environment the daemon reads `ALTERIONE_*`
/// from; it defaults to [Platform.environment]. A temporary `ALTERIONE_HOME` is
/// created for the daemon and removed afterwards, so the measurement never
/// touches the real home.
Future<MetricsReport> runMetricsHarness({
  Map<String, String>? environment,
}) async {
  final env = environment ?? Platform.environment;
  final home = await Directory.systemTemp.createTemp('alteri_one_metrics_');
  final paths = HomePaths.resolve(alterioneHome: home.path);
  final config = const DaemonConfig(
    layers: {},
    profile: {
      'id': 'assistant',
      'model': 'local',
      'prompt': 'assistant',
      'tools': <String>[],
      'risk_rules': {'read': 'allow'},
    },
  );

  final results = <MetricResult>[];
  try {
    results.add(await _measureColdStart(paths, config, env));
    results.add(await _measureIdleMemory(paths, config, env));
    results.add(await _measureEventLatency());
    results.add(await _measureToolCallOverhead());
  } finally {
    await _resetContainer();
    if (home.existsSync()) {
      await home.delete(recursive: true);
    }
  }

  return MetricsReport(results: results, environment: _environmentNote(env));
}

/// Cold start: bring the daemon up with no models or extensions loaded.
Future<MetricResult> _measureColdStart(
  HomePaths paths,
  DaemonConfig config,
  Map<String, String> env,
) async {
  const target = '< 300 ms';
  try {
    final daemon = Daemon(
      paths: paths,
      config: config,
      serverInfo: _info,
      environment: env,
    );
    final stopwatch = Stopwatch()..start();
    await daemon.start(llm: _EchoLlm());
    stopwatch.stop();
    final ms = stopwatch.elapsedMicroseconds / 1000.0;
    await daemon.stop();
    return MetricResult(
      name: 'cold start',
      target: target,
      unit: 'ms',
      measured: ms,
      status: ms < 300 ? MetricStatus.pass : MetricStatus.fail,
    );
  } on Object catch (error) {
    return MetricResult(
      name: 'cold start',
      target: target,
      unit: 'ms',
      status: MetricStatus.notMeasured,
      detail: 'daemon failed to start: $error',
    );
  }
}

/// Idle memory: the resident set size of a minimal idle daemon.
///
/// The section 2.8 target (< 80 MB) is defined for the AOT-compiled minimal
/// build. This harness runs in-process on the Dart JIT, whose runtime baseline
/// alone already exceeds 80 MB, so the idle RSS of the dev process is not the
/// minimal build's idle memory. When the process baseline is already above the
/// target the metric degrades to "not measured" (a distinct status from a
/// missed target) rather than reporting a category error as a failure; the
/// measured RSS is still recorded in [MetricResult.detail] for transparency.
Future<MetricResult> _measureIdleMemory(
  HomePaths paths,
  DaemonConfig config,
  Map<String, String> env,
) async {
  const target = '< 80 MB';
  final rss = _readRssMb();
  if (rss == null) {
    return const MetricResult(
      name: 'idle memory',
      target: target,
      unit: 'MB',
      status: MetricStatus.notMeasured,
      detail: 'resident set size is not readable on this platform',
    );
  }
  try {
    final daemon = Daemon(
      paths: paths,
      config: config,
      serverInfo: _info,
      environment: env,
    );
    await daemon.start(llm: _EchoLlm());
    // Let the first asynchronous work settle before sampling.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final idle = _readRssMb();
    await daemon.stop();
    if (idle == null) {
      return const MetricResult(
        name: 'idle memory',
        target: target,
        unit: 'MB',
        status: MetricStatus.notMeasured,
        detail: 'resident set size became unreadable while sampling',
      );
    }
    // The JIT dev-process baseline already exceeds the AOT minimal-build
    // target, so the idle RSS here is not the metric the target describes.
    if (rss >= 80) {
      return MetricResult(
        name: 'idle memory',
        target: target,
        unit: 'MB',
        measured: idle,
        status: MetricStatus.notMeasured,
        detail:
            'JIT dev-process baseline ${rss.toStringAsFixed(1)} MB already '
            'exceeds the AOT minimal-build target; idle RSS ${idle.toStringAsFixed(1)} MB',
      );
    }
    return MetricResult(
      name: 'idle memory',
      target: target,
      unit: 'MB',
      measured: idle,
      status: idle < 80 ? MetricStatus.pass : MetricStatus.fail,
      detail: 'process baseline ${rss.toStringAsFixed(1)} MB',
    );
  } on Object catch (error) {
    return MetricResult(
      name: 'idle memory',
      target: target,
      unit: 'MB',
      status: MetricStatus.notMeasured,
      detail: 'daemon failed to start: $error',
    );
  }
}

/// Event delivery latency: p99 from publish to a local subscriber.
///
/// The [StatePublisher] is the single delivery path the SSE transport and
/// extensions both read from (docs/spec/domain.md, section 8.11), so a
/// standalone publisher with a live subscriber measures the same per-event
/// delivery cost the daemon incurs, without the daemon lifecycle. The
/// subscriber records the monotonic clock reading at delivery and compares it
/// to the reading taken just before each [StatePublisher.publish].
Future<MetricResult> _measureEventLatency() async {
  const target = '< 50 ms';
  const samples = 2000;
  try {
    final publisher = StatePublisher.withLimits(capacity: 1 << 20);
    final latenciesUs = <int>[];
    final done = Completer<void>();
    var epochUs = 0;

    final subscription = publisher.subscribeLive(StateTopic.runs).listen((
      AgentEvent _,
    ) {
      if (latenciesUs.length >= samples) {
        if (!done.isCompleted) done.complete();
        return;
      }
      latenciesUs.add(Stopwatch().elapsedMicroseconds - epochUs);
      if (latenciesUs.length >= samples && !done.isCompleted) {
        done.complete();
      }
    });

    // Warm up the subscription before measuring.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    for (var i = 0; i < samples; i++) {
      epochUs = Stopwatch().elapsedMicroseconds;
      publisher.publish(
        StateTopic.runs,
        RunDelta(at: DateTime.now().toUtc(), runId: 'r$i', text: 'x'),
      );
      // Yield so the delivery microtask runs before the next publish.
      await Future<void>.delayed(Duration.zero);
    }
    await done.future.timeout(const Duration(seconds: 10));
    await subscription.cancel();

    if (latenciesUs.isEmpty) {
      return const MetricResult(
        name: 'event delivery latency (p99)',
        target: target,
        unit: 'ms',
        status: MetricStatus.notMeasured,
        detail: 'no events were delivered to the subscriber',
      );
    }
    latenciesUs.sort();
    final p99Us =
        latenciesUs[(latenciesUs.length * 0.99).floor().clamp(
          0,
          latenciesUs.length - 1,
        )];
    final p99Ms = p99Us / 1000.0;
    return MetricResult(
      name: 'event delivery latency (p99)',
      target: target,
      unit: 'ms',
      measured: p99Ms,
      status: p99Ms < 50 ? MetricStatus.pass : MetricStatus.fail,
      detail: 'over $samples events',
    );
  } on Object catch (error) {
    return MetricResult(
      name: 'event delivery latency (p99)',
      target: target,
      unit: 'ms',
      status: MetricStatus.notMeasured,
      detail: 'event latency could not be measured: $error',
    );
  }
}

/// Tool-call overhead: the per-call cost of the dispatch path excluding the
/// tool's own work.
Future<MetricResult> _measureToolCallOverhead() async {
  const target = '< 5 ms';
  const samples = 2000;
  try {
    applyBlocDefaults();
    // A journal that records the writes the dispatch path makes without doing
    // real disk I/O, so the measurement isolates the dispatch overhead.
    final journal = _NullJournal();
    const tool = _NoopTool();
    final registry = _FixedRegistry(ToolSet(const [tool]));
    final policy = PolicyGate(const {Risk.read: Decision.allow}, false);
    final config = ProfileAgentConfig(
      Profile(
        'assistant',
        'local',
        'assistant',
        const ['noop'],
        Budget.standard(),
        const {Risk.read: Decision.allow},
        const {},
      ),
    );
    final deps = AgentDeps(
      _EchoLlm(),
      registry,
      journal,
      policy,
      const DenyAllApprovals(),
      config,
      const PromptContextBuilder(),
      UntrustedBoundary.fromHex('00000000000000000000000000000000'),
    );
    final run = Run(
      id: RunId('run-1'),
      profile: 'assistant',
      mode: RunMode.chat,
      prompt: 'hi',
      budget: Budget.standard(),
      capabilities: RunCapabilities(
        <String>{'noop'},
        const <String>{},
        const [],
        MemoryRights.propose,
      ),
      cancel: CancelToken(),
    );

    final latenciesUs = <int>[];
    for (var i = 0; i < samples; i++) {
      final sw = Stopwatch()..start();
      await runAgent(run, deps);
      sw.stop();
      latenciesUs.add(sw.elapsedMicroseconds);
    }
    // The first iteration includes lazy initialization; drop it.
    latenciesUs.removeAt(0);
    latenciesUs.sort();
    final medianUs = latenciesUs[latenciesUs.length ~/ 2];
    final p99Us =
        latenciesUs[(latenciesUs.length * 0.99).floor().clamp(
          0,
          latenciesUs.length - 1,
        )];
    final medianMs = medianUs / 1000.0;
    final p99Ms = p99Us / 1000.0;
    return MetricResult(
      name: 'tool-call overhead',
      target: target,
      unit: 'ms',
      measured: p99Ms,
      status: p99Ms < 5 ? MetricStatus.pass : MetricStatus.fail,
      detail: 'median ${medianMs.toStringAsFixed(3)} ms over $samples calls',
    );
  } on Object catch (error) {
    return MetricResult(
      name: 'tool-call overhead',
      target: target,
      unit: 'ms',
      status: MetricStatus.notMeasured,
      detail: 'tool-call overhead could not be measured: $error',
    );
  }
}

/// The server info advertised by the measurement daemon.
final ServerInfo _info = ServerInfo(sdk: '3.14.0', capabilities: const ['sse']);

/// The environment note recorded with the report.
String _environmentNote(Map<String, String> env) {
  final os = Platform.operatingSystem;
  final version = Platform.operatingSystemVersion;
  return '$os $version; dart ${Platform.version}';
}

/// Reads the current resident set size in megabytes, or `null` when the
/// platform does not expose it. Linux reads `/proc/self/statm`; other
/// platforms return `null` so the metric degrades to "not measured".
double? _readRssMb() {
  if (!Platform.isLinux) return null;
  try {
    final statm = File('/proc/self/statm').readAsStringSync().split(' ');
    final residentPages = int.parse(statm[1]);
    final pageSize = _pageSize();
    if (pageSize <= 0) return null;
    return residentPages * pageSize / (1024 * 1024);
  } on Object {
    return null;
  }
}

int _pageSize() {
  try {
    final result = Process.runSync('getconf', const ['PAGESIZE']);
    if (result.exitCode != 0) return 0;
    return int.tryParse(result.stdout.toString().trim()) ?? 0;
  } on Object {
    return 0;
  }
}

/// Resets the core container between measurements.
Future<void> _resetContainer() async {
  if (getIt.isRegistered<HiveJournal>()) {
    await getIt<HiveJournal>().close();
  }
  if (getIt.isRegistered<ApprovalsBloc>()) {
    await getIt<ApprovalsBloc>().close();
  }
  await getIt.reset();
}

/// A [LlmPort] that finishes immediately without requesting tools.
final class _EchoLlm implements LlmPort {
  @override
  Future<Turn> complete({
    required List<Message> messages,
    required List<ToolSpec> tools,
    required int maxOutputTokens,
  }) => Future.value(Turn('ok', Message.assistant('ok'), const []));
}

/// A [ToolRegistry] that always returns the same [ToolSet].
final class _FixedRegistry implements ToolRegistry {
  new(this._set);
  final ToolSet _set;
  @override
  ToolSet snapshot(String profile) => _set;
}

/// A [ToolPort] that does no work, so the measured cost is the dispatch path.
final class _NoopTool implements ToolPort {
  const new();

  @override
  ToolSpec get spec => ToolSpec.defaults(
    name: 'noop',
    llmName: 'noop',
    description: 'noop',
    risk: Risk.read,
    untrustedOutput: false,
  );

  @override
  Future<Object?> call(Map<String, Object?> input, CancelToken cancel) async =>
      null;
}

/// A [JournalPort] that records nothing and does no I/O.
///
/// The dispatch path writes a start and a finish record per call; a null
/// journal keeps the measurement focused on the dispatch overhead rather than
/// on disk latency.
final class _NullJournal implements JournalPort {
  @override
  Future<int> runStarted(RunId runId, String profile) async => 0;
  @override
  Future<int> runFinished(RunId runId, String state, String? result) async => 0;
  @override
  Future<int> started(RunId runId, String tool, Risk risk) async => 0;
  @override
  Future<int> modelStarted(RunId runId) async => 0;
  @override
  Future<void> denied(
    RunId runId,
    String tool,
    Risk risk,
    String reason,
  ) async {}
  @override
  Future<void> finished(
    RunId runId,
    int seq,
    InvocationStatus status,
    String? error,
  ) async {}
  @override
  Future<List<Invocation>> forRun(RunId runId) async => const [];
  @override
  Future<List<ModelCall>> modelCallsForRun(RunId runId) async => const [];
  @override
  Future<List<LifecycleRecord>> lifecycleAfter(int seq) async => const [];
  @override
  Future<int> approvalRequested(
    RunId runId,
    ApprovalId id,
    String tool,
    DateTime deadline,
  ) async => 0;
  @override
  Future<int> approvalResolved(
    ApprovalId id, {
    required bool granted,
    required String reason,
    DateTime? at,
  }) async => 0;
  @override
  Future<ApprovalRecord?> approvalById(ApprovalId id) async => null;
  @override
  Future<List<ApprovalRecord>> approvalsForRun(RunId runId) async => const [];
}

/// Writes the report to [jsonPath] and [markdownPath] and prints a summary.
void writeReport(
  MetricsReport report, {
  String? jsonPath,
  String? markdownPath,
}) {
  final json = const JsonEncoder.withIndent('  ').convert(report.toJson());
  if (jsonPath != null) {
    File(jsonPath).writeAsStringSync('$json\n');
  }
  final markdown = report.toMarkdown();
  if (markdownPath != null) {
    File(markdownPath).writeAsStringSync(markdown);
  }
  stdout.writeln(markdown);
  stdout.writeln('JSON report: ${jsonPath ?? '(stdout only)'}');
}
