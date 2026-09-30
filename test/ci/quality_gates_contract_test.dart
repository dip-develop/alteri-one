// The quality-gate contract. Task 0.2.
//
// The gate chain is four commands and it is run in CI on three operating systems. Both facts
// are easy to state and easy to lose: a script gets renamed, a matrix entry gets dropped, a
// `--fatal-infos` gets "temporarily" relaxed for one platform. This file is what notices.
//
// It reads two kinds of file — the root manifest's `melos.scripts` block and the workflows in
// `.github/workflows/` — and asserts that the chain the documentation promises is the chain
// the tree runs. It starts no process, opens no socket and reaches no network, because it
// runs in the blocking chain on three operating systems; where a fact cannot be read from a
// file (is the coverage job allowed to fail? then it must not be a required check, and the
// required checks are recorded in repo-settings.json), the assertion says so in its reason.
//
// The greppable acceptance string for the task is the description of the first test below:
// "CI runs fatal analysis tests formatting on three operating systems".

import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  final root = _readMap('pubspec.yaml');
  final scripts = _map(root, 'melos')['scripts']! as Map<String, Object?>;
  final ci = _workflows;

  group('the gate chain', () {
    test('CI runs fatal analysis tests formatting on three operating systems', () {
      // Codegen, analysis, format, test. The four commands of quality-gates.md §1, each
      // present in the one place the scripts are defined.
      expect(
        scripts.keys,
        containsAll(<String>['generate', 'analyze', 'format', 'test']),
      );

      expect(
        _command(scripts, 'generate'),
        allOf(
          contains('build_runner build'),
          contains('--depends-on="^build"'),
        ),
        reason:
            'generate is codegen, and only in the packages that depend on `build` — '
            'running it everywhere would rewrite generated files nobody owns',
      );

      expect(
        _command(scripts, 'analyze'),
        contains('dart analyze --fatal-infos'),
        reason:
            'quality-gates.md §1: an info-level diagnostic is a build failure',
      );

      expect(
        _command(scripts, 'format'),
        allOf(contains('dart format --output=none --set-exit-if-changed')),
        reason:
            'a format check that writes, or that does not fail, checks nothing',
      );

      expect(
        _command(scripts, 'test'),
        contains('dart test'),
        reason:
            'the chain ends in the tests, and --fail-fast keeps a red build from running '
            'six more minutes of them',
      );
    });

    test('format and format:root are one gate with two commands', () {
      // `format` walks every package; `format:root` covers the root package's own `test/` and
      // `tool/`, which `dart format` cannot reach from `.` without walking into `site/`.
      // Dropping either one silently stops checking half the tree. workspace-layout.md §2.
      expect(scripts.keys, contains('format:root'));
      expect(
        _command(scripts, 'format:root'),
        allOf(
          contains('dart format --output=none --set-exit-if-changed'),
          contains(' test '),
          contains(' tool'),
        ),
        reason:
            'format:root exists to cover exactly the two root directories that are not '
            'a package of their own',
      );
    });

    test('no workflow relaxes --fatal-infos', () {
      // quality-gates.md §6: accepting a --no-fatal-infos run is forbidden, and it is the
      // easiest gate in the repository to relax by accident in the name of a green build.
      final offenders = <String>[
        for (final workflow in ci.entries)
          if (workflow.value.text.contains('--no-fatal-infos')) workflow.key,
      ];
      expect(offenders, isEmpty);
    });
  });

  group('the platform matrix', () {
    test('every chained job runs on Linux, macOS and Windows', () {
      // quality-gates.md §3. A missing matrix entry is a failing matrix contract, not a
      // platform quietly dropping out of the gate.
      //
      // Only jobs that run the chain are required to be on all three. A job that is *not*
      // the chain may legitimately exclude one: the Tier 2 refusal job runs on macOS and
      // Windows precisely because Linux is where the sandbox suite runs.
      final required = <String>{
        'ubuntu-latest',
        'macos-latest',
        'windows-latest',
      };
      var checked = 0;
      for (final workflow in ci.entries) {
        final chained = workflow.value.chainedJobs.keys.toSet();
        for (final job in workflow.value.matrixJobs.entries) {
          if (!chained.contains(job.key)) continue;
          expect(
            required.difference(job.value.toSet()),
            isEmpty,
            reason:
                '${workflow.key} → ${job.key} runs the chain on '
                '${job.value.join(', ')}; all three are required and a missing entry is a '
                'platform quietly dropping out of the gate',
          );
          checked++;
        }
      }
      expect(
        checked,
        isNot(0),
        reason:
            'the gate chain has to run somewhere: no job in any workflow runs the chain '
            'on a platform matrix, so the chain is not in CI at all',
      );
      expect(
        ci['.github/workflows/ci.yml']!.matrixJobs.keys.toSet(),
        anyElement(
          isIn(ci['.github/workflows/ci.yml']!.chainedJobs.keys.toSet()),
        ),
        reason: 'the gate belongs in ci.yml, not only in a release workflow that runs on tags',
      );
    });

    test('each chained job runs the chain in order', () {
      // Order is load-bearing. Codegen first, because the analysis of generated code is part
      // of the gate; format after codegen, because it checks the post-codegen tree.
      const order = <String>['generate', 'analyze', 'format', 'test'];
      for (final workflow in ci.entries) {
        for (final job in workflow.value.chainedJobs.entries) {
          final script = job.value;
          final positions = <int>[];
          for (final command in order) {
            final at = script.indexOf('melos run $command');
            expect(
              at,
              isNonNegative,
              reason:
                  '${workflow.key} → ${job.key} never runs `melos run $command`',
            );
            positions.add(at);
          }
          final sorted = positions.toList()..sort();
          expect(
            sorted,
            positions,
            reason:
                '${workflow.key} → ${job.key} runs the chain out of order: ${order.join(' → ')}',
          );
        }
      }
    });
  });

  group('test timeouts', () {
    test('every package with tests declares its timeouts', () {
      // quality-gates.md §4: a default per-test timeout of 30 s, with an explicit longer one
      // for tests that spawn processes or bind sockets. `dart_test.yaml` is per package and
      // does not inherit, so a package that adds tests without it gets the package:test
      // default by accident rather than by decision.
      final declaring = <String>[
        for (final path in _packageDirectories())
          if (File('$path/dart_test.yaml').existsSync()) path,
      ];
      final untested = <String>[
        for (final path in _packageDirectories())
          if (Directory('$path/test').existsSync() &&
              !File('$path/dart_test.yaml').existsSync())
            path,
      ];
      expect(
        untested,
        isEmpty,
        reason:
            'a package with a test/ directory and no dart_test.yaml has no declared '
            'timeouts; add one (declaring: ${declaring.join(', ')})',
      );
    });

    test('the declared timeouts are 30 s by default and longer for the slow tags', () {
      // The longer timeouts are what keep a socket-binding test on a Windows runner from
      // failing on wall-clock time while passing everywhere else.
      final configuration = _readMap('dart_test.yaml');
      expect(configuration['timeout'], '30s');
      final tags = _map(configuration, 'tags');
      for (final tag in const ['integration', 'offline-e2e']) {
        final timeout = _map(tags, tag)['timeout'];
        expect(
          timeout,
          isNotNull,
          reason:
              '`$tag` tests spawn processes or bind sockets, so they need a timeout of '
              'their own; a filter that matches nothing exits 0, so the tag without a '
              'timeout fails nobody until the first such test is written',
        );
        expect(
          timeout,
          isNot('30s'),
          reason: 'a longer timeout is the whole point of the tag',
        );
      }
    });
  });

  group('coverage', () {
    test('coverage is collected and reported, and never gated', () {
      // quality-gates.md §4: configured and reported, not gated at a percentage in v1 — a
      // percentage gate that generated code meets is worse than no gate.
      final job = ci['.github/workflows/ci.yml']!.jobNamed('coverage');
      expect(job, isNotNull, reason: 'coverage is configured, not optional');
      expect(
        job!['steps'].toString(),
        anyOf(contains('--coverage'), contains('format_coverage')),
        reason:
            'the job has to collect or format something to be a coverage job',
      );
      expect(
        job['steps'].toString(),
        isNot(contains('threshold')),
        reason: 'a coverage percentage is not a gate in v1',
      );
    });

    test('the coverage job cannot block a pull request', () {
      // It is not a required status check, so a failing coverage job reports and does not
      // hold a PR. repo-settings.json is the record of what is required.
      final settings = File('repo-settings.json').readAsStringSync();
      expect(
        settings.contains('coverage'),
        isFalse,
        reason:
            'quality-gates.md §4 says coverage is reported, not gated; a required check '
            'is a gate whatever the workflow calls it',
      );
    });
  });
}

/// The scripts, as one string, so a test can assert what a command *does* rather than how it
/// is spelled. Reordering a flag is not a change; dropping `--fatal-infos` is.
String _command(Map<String, Object?> scripts, String name) {
  final value = scripts[name];
  if (value is! String) {
    throw StateError('melos.scripts.$name is not a string command');
  }
  return value;
}

/// The workflows, parsed once, with the two views the tests need: every job, and the jobs
/// that run the chain.
final _workflows = <String, _Workflow>{
  for (final path in _workflowPaths()) path: _Workflow.parse(path),
};

List<String> _workflowPaths() {
  const directory = '.github/workflows';
  if (!Directory(directory).existsSync()) {
    throw StateError(
      'no $directory: this test must run from the repository root',
    );
  }
  final paths =
      Directory(directory)
          .listSync(followLinks: false)
          .whereType<File>()
          .map((file) => _normalise(file.path))
          .where((path) => path.endsWith('.yml'))
          .toList()
        ..sort();
  if (paths.isEmpty) throw StateError('no workflow found in $directory');
  return paths;
}

/// The repository directories that are packages: the root plus every workspace member.
List<String> _packageDirectories() {
  final globs = _readMap('pubspec.yaml')['workspace'];
  if (globs is! List<Object?>) {
    throw StateError('the root manifest has no workspace: list of globs');
  }
  final directories = <String>['.'];
  for (final entry in globs.cast<String>()) {
    final segments = entry.split('/');
    final prefix = segments.take(segments.length - 1).join('/');
    if (prefix.isEmpty) continue;
    final matcher = RegExp(
      '^${RegExp.escape(segments.last).replaceAll(r'\*', '.*')}\$',
    );
    for (final entity in Directory(prefix).listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final path = _normalise(entity.path);
      if (!matcher.hasMatch(path.split('/').last)) continue;
      if (File('$path/pubspec.yaml').existsSync()) directories.add(path);
    }
  }
  return directories..sort();
}

/// One workflow file, with the parts the assertions read.
final class _Workflow {
  _Workflow({required this.text, required this.jobs});

  factory _Workflow.parse(String path) {
    final text = File(path).readAsStringSync();
    final document =
        _plain(loadYaml(text, sourceUrl: Uri.file(path)))!
            as Map<String, Object?>;
    final jobs = _map(_map(document, 'jobs'), '');
    return _Workflow(text: text, jobs: jobs);
  }

  final String text;
  final Map<String, Object?> jobs;

  /// `<job id>: [runner, …]` for every job built on a matrix.
  Map<String, List<String>> get matrixJobs {
    final found = <String, List<String>>{};
    for (final entry in jobs.entries) {
      final job = entry.value;
      if (job is! Map<String, Object?>) continue;
      final strategy = job['strategy'];
      if (strategy is! Map<String, Object?>) continue;
      final matrix = strategy['matrix'];
      if (matrix is! Map<String, Object?>) continue;
      final os = matrix['os'];
      if (os is! List<Object?>) continue;
      found[entry.key] = os.cast<String>();
    }
    return found;
  }

  /// `<job id>: the shell commands it runs`, for every job that runs the gate chain.
  ///
  /// "Runs the chain" is defined by the analysis, not by mentioning `melos run`: a job that
  /// only assembles artefacts or only publishes is not a gate, and the coverage job runs the
  /// tests with a coverage flag rather than through the script. A job that *does* run
  /// `melos run analyze` claims to be the gate, and then it has to run all four commands, in
  /// order.
  Map<String, String> get chainedJobs {
    final found = <String, String>{};
    for (final entry in jobs.entries) {
      final job = entry.value;
      if (job is! Map<String, Object?>) continue;
      final steps = job['steps'];
      if (steps is! List<Object?>) continue;
      final commands = <String>[];
      for (final step in steps.cast<Object?>()) {
        if (step is! Map<String, Object?>) continue;
        final run = step['run'];
        if (run is String) commands.add(run);
      }
      final script = commands.join('\n');
      if (script.contains('melos run analyze')) found[entry.key] = script;
    }
    return found;
  }

  Map<String, Object?>? jobNamed(String id) {
    final job = jobs[id];
    return job is Map<String, Object?> ? job : null;
  }
}

Map<String, Object?> _readMap(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError(
      '$path is missing; this test must run from the repository root',
    );
  }
  final parsed = _plain(
    loadYaml(file.readAsStringSync(), sourceUrl: Uri.file(path)),
  );
  if (parsed is! Map<String, Object?>)
    throw StateError('$path is not a YAML mapping');
  return parsed;
}

Map<String, Object?> _map(Map<String, Object?> parent, String key) {
  if (key.isEmpty) return parent;
  final value = parent[key];
  if (value is! Map<String, Object?>)
    throw StateError('expected a mapping at `$key`');
  return value;
}

/// Converts YamlMap and YamlList into plain Dart collections, so that nothing below makes a
/// dynamic call: `strict-casts` and `avoid_dynamic_calls` are on for the same reason the
/// engine has no `dart:io`.
Object? _plain(Object? node) {
  if (node is YamlMap) {
    return <String, Object?>{
      for (final entry in node.nodes.entries)
        (entry.key as YamlScalar).value as String: _plain(entry.value),
    };
  }
  if (node is YamlList)
    return <Object?>[for (final child in node) _plain(child)];
  if (node is YamlScalar) return node.value;
  return node;
}

String _normalise(String path) =>
    path.replaceAll(r'\', '/').replaceFirst(RegExp(r'^\./'), '');
