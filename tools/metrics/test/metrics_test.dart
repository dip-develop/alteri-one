// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Unit tests for the section 2.8 metrics report logic
/// (docs/plan/M4.md Step 13; issue #49).
///
/// The full harness is environment-dependent and slow, so most tests cover
/// the pure mapping from metric results to the report, its exit code, and its
/// JSON and Markdown rendering — the branching the harness relies on. One
/// regression test runs the harness once to prove the event-latency sampler
/// reads real elapsed time rather than a never-started stopwatch.
library;

import 'dart:convert';

import 'package:alteri_one_metrics/metrics.dart';
import 'package:test/test.dart';

void main() {
  group('MetricsReport.exitCode', () {
    test('all pass maps to 0', () {
      final report = const MetricsReport(
        results: [
          MetricResult(
            name: 'cold start',
            target: '< 300 ms',
            unit: 'ms',
            measured: 100,
          ),
        ],
        environment: 'test',
      );
      expect(report.exitCode, 0);
      expect(report.allPass, isTrue);
    });

    test('a missed target maps to 1', () {
      final report = const MetricsReport(
        results: [
          MetricResult(
            name: 'cold start',
            target: '< 300 ms',
            unit: 'ms',
            measured: 100,
          ),
          MetricResult(
            name: 'idle memory',
            target: '< 80 MB',
            unit: 'MB',
            measured: 200,
            status: MetricStatus.fail,
          ),
        ],
        environment: 'test',
      );
      expect(report.exitCode, 1);
      expect(report.allPass, isFalse);
    });

    test('a not-measured metric maps to 2, distinct from a miss', () {
      final report = const MetricsReport(
        results: [
          MetricResult(
            name: 'idle memory',
            target: '< 80 MB',
            unit: 'MB',
            status: MetricStatus.notMeasured,
            detail: 'unreadable',
          ),
        ],
        environment: 'test',
      );
      expect(report.exitCode, 2);
      expect(report.allPass, isFalse);
    });

    test('a miss wins over a not-measured metric', () {
      final report = const MetricsReport(
        results: [
          MetricResult(
            name: 'a',
            target: '< 1',
            unit: 'ms',
            measured: 2,
            status: MetricStatus.fail,
          ),
          MetricResult(
            name: 'b',
            target: '< 1',
            unit: 'ms',
            status: MetricStatus.notMeasured,
          ),
        ],
        environment: 'test',
      );
      expect(report.exitCode, 1);
    });
  });

  group('MetricsReport rendering', () {
    test('toJson carries the metrics and the exit code', () {
      final report = const MetricsReport(
        results: [
          MetricResult(
            name: 'tool-call overhead',
            target: '< 5 ms',
            unit: 'ms',
            measured: 0.5,
          ),
        ],
        environment: 'linux',
      );
      final json = report.toJson();
      expect(json['environment'], 'linux');
      expect(json['all_pass'], isTrue);
      expect(json['exit_code'], 0);
      final metrics = json['metrics'] as List<Object?>;
      expect(metrics, hasLength(1));
      final first = metrics.single as Map<String, Object?>;
      expect(first['name'], 'tool-call overhead');
      expect(first['measured'], 0.5);
      expect(first['status'], 'pass');
    });

    test('toMarkdown renders a table row per metric', () {
      final report = const MetricsReport(
        results: [
          MetricResult(
            name: 'cold start',
            target: '< 300 ms',
            unit: 'ms',
            measured: 250,
          ),
          MetricResult(
            name: 'idle memory',
            target: '< 80 MB',
            unit: 'MB',
            status: MetricStatus.notMeasured,
            detail: 'unreadable',
          ),
        ],
        environment: 'linux',
      );
      final markdown = report.toMarkdown();
      expect(markdown, contains('| Metric | Target | Measured | Status |'));
      expect(markdown, contains('cold start'));
      expect(markdown, contains('250 ms'));
      expect(markdown, contains('notMeasured'));
      expect(markdown, contains('unreadable'));
    });
  });

  test('MetricResult.toJson round-trips through jsonEncode', () {
    const result = MetricResult(
      name: 'event delivery latency (p99)',
      target: '< 50 ms',
      unit: 'ms',
      measured: 1.25,
      detail: 'over 2000 events',
    );
    final decoded = jsonDecode(jsonEncode(result.toJson()));
    expect(decoded, isA<Map<String, Object?>>());
    expect((decoded as Map<String, Object?>)['measured'], 1.25);
  });

  // Regression: the latency sampler once read a never-started [Stopwatch], so
  // every sample was 0 and p99 was a false 0.00 ms pass. A real in-process
  // publish-to-deliver path always takes a non-zero time, so the measured p99
  // must be positive and within the 50 ms target.
  test('event delivery latency is measured from real elapsed time', () async {
    final report = await runMetricsHarness();
    final latency = report.results.firstWhere(
      (MetricResult r) => r.name.contains('event delivery latency'),
    );
    expect(latency.measured, isNotNull);
    expect(latency.measured, greaterThan(0));
    expect(latency.status, MetricStatus.pass);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
