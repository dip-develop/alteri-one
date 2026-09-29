// The workspace contract. Task 0.1.
//
// What this file is: the mechanical half of the layout decision. Everything it asserts is
// also written down in prose — the root manifest in architecture/workspace-layout.md §2, the
// dependency rules in architecture/overview.md §3, the naming in ADR-0016 — and this test is
// what stops the prose from drifting away from the tree. A layout change is therefore a
// change to this file too, which is the intent, not a side effect: the membership is a
// decision, and a decision that nothing checks is a preference.
//
// What this file is not: a general-purpose linter. It reads manifests and sources as text and
// says only what the specification says. It imports nothing but `package:test` and
// `package:yaml`, both dev_dependencies of the root package, and it starts no process, opens
// no socket and reaches no network — it runs in the blocking chain on three operating
// systems, so anything slower or flakier than a file read does not belong here.
//
// The greppable acceptance string for the task is the description of the first test below:
// "workspace uses pub workspaces and melos 8 configuration".

import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  final workspace = _Workspace.load();

  group('the root manifest', () {
    test('workspace uses pub workspaces and melos 8 configuration', () {
      expect(workspace.root.name, 'alteri_one_workspace');
      expect(workspace.root.pubspec['publish_to'], 'none');

      // pub workspaces, not a directory of convenience: the root is a package, and
      // `resolution: workspace` is what makes pub resolve the whole tree through one
      // lockfile. ADR-0001.
      expect(workspace.root.pubspec['workspace'], isNotEmpty);
      for (final member in workspace.members.entries) {
        expect(
          member.value.pubspec['resolution'],
          'workspace',
          reason: '${member.key} is a workspace member and must say so',
        );
      }

      // Melos 8 reads its configuration from this file; melos.yaml and
      // pubspec.workspaces.yaml are not created and are not to be created.
      expect(workspace.root.pubspec['melos'], isA<Map<String, Object?>>());
      expect(workspace.legacyConfig, isEmpty);

      final melos = workspace.root.pubspec['melos']! as Map<String, Object?>;
      expect(melos['useRootAsPackage'], isTrue);
      expect((melos['scripts']! as Map<String, Object?>), isNotEmpty);

      final devDependencies =
          workspace.root.pubspec['dev_dependencies']! as Map<String, Object?>;
      expect(
        _majorVersion(devDependencies['melos']),
        8,
        reason: 'melos 8 is the pinned orchestration toolchain (ADR-0001)',
      );
      expect(
        devDependencies.keys,
        containsAll(<String>['melos', 'build_runner', 'test']),
        reason:
            'test/ is the root package\'s own directory, so `test` is one of its '
            'dev_dependencies (ADR-0021)',
      );
    });

    test(
      'the SDK constraint is written with an explicit upper bound everywhere',
      () {
        // `^3.13.0` appears nowhere: freezed 4.x requires the explicit bound. This is a
        // workspace contract, not a style preference.
        for (final entry in <String, Map<String, Object?>>{
          'pubspec.yaml': workspace.root.pubspec,
          for (final member in workspace.members.entries)
            member.key: member.value.pubspec,
        }.entries) {
          final environment =
              entry.value['environment']! as Map<String, Object?>;
          expect(
            environment['sdk'],
            '>=3.13.0 <4.0.0',
            reason: '${entry.key} must use the explicit upper-bound form',
          );
        }

        for (final path in workspace.pubspecPaths) {
          final text = File(path).readAsStringSync();
          expect(
            RegExp(r'\^3\.13\.0').hasMatch(text),
            isFalse,
            reason: '$path uses the caret form of the SDK constraint',
          );
        }
      },
    );

    test('the root lockfile is committed and is not ignored', () {
      // pub workspaces resolve the whole tree through one lockfile, so it is the thing that
      // makes CI and a fresh clone agree.
      expect(File('pubspec.lock').existsSync(), isTrue);
      expect(
        workspace.gitignoreIgnores('pubspec.lock'),
        isFalse,
        reason: '.gitignore must not ignore pubspec.lock; it is the reproducible resolution',
      );
    });
  });

  group('workspace membership', () {
    test('membership is exactly the set of packages the globs reach', () {
      // The hard-coded list is the point. Task 0.1 asserts the membership for its phase and
      // task 5.1 re-asserts it when the Phase 5 packages exist.
      expect(workspace.members.keys.toList()..sort(), _expectedMembers);
    });

    test('every glob in the root manifest matches at least one package', () {
      // `dart pub get` refuses to resolve when a glob matches nothing, which is why the
      // manifest is exact rather than aspirational. ADR-0021.
      for (final glob in workspace.globs) {
        expect(
          workspace.packagesUnder(glob),
          isNotEmpty,
          reason:
              '`$glob` matches no package, so `dart pub get` fails at the root',
        );
      }
    });

    test('no package in the tree is outside the globs', () {
      // A package the globs do not reach is a package that is not resolved, not linked and
      // not built — the failure mode of a forgotten glob entry. The website is the one
      // documented exception: its toolchain cannot be resolved in the same graph
      // (ADR-0020), so it has its own lockfile and is not a member.
      expect(workspace.unreachedPubspecs, isEmpty);
    });
  });

  group('the dependency rules of overview.md §3', () {
    test('every in-repository dependency is one the table allows', () {
      for (final member in workspace.members.entries) {
        expect(
          _allowedDependencies.containsKey(member.value.name),
          isTrue,
          reason:
              '${member.key} is not in the dependency table; add it to '
              'architecture/overview.md §3 and to this test together',
        );
        final allowed = _allowedDependencies[member.value.name];
        if (allowed == null)
          continue; // `apps/*` may compose everything public.
        expect(
          member.value.workspaceDependencies.toSet().difference(allowed),
          isEmpty,
          reason:
              '${member.key} depends on a package the table does not allow it to '
              'depend on',
        );
      }
    });

    test('a package name states the noun its subproject is', () {
      // The subproject is the taxonomy, and the name is the cheapest place to notice a
      // package that does not fit it. ADR-0014.
      for (final member in workspace.members.values) {
        final root = member.path.split('/').first;
        final prefixes = _nounInTheName[root];
        if (prefixes == null) continue;
        expect(
          prefixes.any(member.name.startsWith),
          isTrue,
          reason:
              '${member.path} is a $root/ package, so its name must start with '
              '${prefixes.join(' or ')}',
        );
      }
    });

    test('no source identifier uses the product spelling', () {
      // Inside the source tree Dart convention applies; `alterione` names the artefact a user
      // installs. The one exception is the bootstrap package itself, whose pub.dev name is
      // part of the decision. ADR-0016.
      for (final member in workspace.members.values) {
        if (member.path == 'apps/bootstrap') continue;
        final offenders = <String>[
          for (final file in _filesIn(Directory(member.path)))
            if (!file.path.endsWith('.g.dart') &&
                file.readAsStringSync().contains('alterione'))
              _normalise(file.path),
        ];
        expect(
          offenders,
          isEmpty,
          reason:
              '${member.path} spells the product name in a source identifier; the product '
              'spelling belongs to the release (ADR-0016)',
        );
      }
    });

    test('the in-repository graph has no cycle', () {
      expect(workspace.cycles, isEmpty);
    });

    test('a library, tool, injection or plugin never depends on an app', () {
      // An app is a host. If core could reach an app, the composition root would stop being
      // the only place that knows which implementations are wired together.
      expect(workspace.dependentsOfApps, isEmpty);
    });

    test('the bootstrap package depends on no other AlteriOne package', () {
      // apps/bootstrap is an install-only composition root: it resolves, verifies and plans
      // an install and never takes a reference to the core. It is the one package a user may
      // install without ever running the product. architecture/overview.md §4.
      final bootstrap = workspace.memberNamed('alterione');
      if (bootstrap == null)
        return; // apps/bootstrap lands with the extension set.
      expect(bootstrap.workspaceDependencies, isEmpty);
    });
  });

  group('the boundary rules in the sources', () {
    test('no library imports dart:io where the specification forbids it', () {
      // `dart:io` never appears in protocol or core. The web implementation of
      // alteri_one_platform is what keeps that rule real rather than aspirational.
      for (final name in const ['alteri_one_protocol', 'alteri_one_core']) {
        final member = workspace.memberNamed(name)!;
        expect(
          member.importsOf('dart:io'),
          isEmpty,
          reason: '$name must not import dart:io (architecture/overview.md §3)',
        );
      }
    });

    test('alteri_one_memory imports neither hive_ce nor dart:io', () {
      // The Hive adapter belongs to alteri_one_platform, behind StoragePort. Memory owns
      // domain records and repositories. architecture/overview.md §3.1.
      final memory = workspace.memberNamed('alteri_one_memory');
      if (memory == null)
        return; // plugins/memory lands with the extension set.
      expect(memory.importsOf('hive_ce'), isEmpty);
      expect(memory.importsOf('dart:io'), isEmpty);
    });

    test('no product library imports an extension package', () {
      // The registry is generated from the resolved graph; a library that imported an
      // extension would fix the extension set at compile time.
      final extensionNames = workspace.members.values
          .where((member) => member.isExtension)
          .map((member) => member.name)
          .toSet();
      if (extensionNames.isEmpty) return;

      for (final member in workspace.members.values) {
        if (member.isExtension) continue;
        final offending = member.imports.where(extensionNames.contains).toSet();
        expect(
          offending,
          isEmpty,
          reason: '${member.path} is not an extension and must not import one',
        );
      }
    });
  });
}

/// The members task 0.1 asserts. A later phase appends to this list, and appending to it is
/// part of creating a package: the membership is reviewed, not discovered.
const _expectedMembers = <String>[
  'apps/bootstrap',
  'apps/cli',
  'injections/skill',
  'packages/alteri_one_core',
  'packages/alteri_one_platform',
  'packages/alteri_one_protocol',
  'plugins/memory',
];

/// The allowed *in-repository* direct dependencies, from architecture/overview.md §3.
///
/// A `null` value means the document puts no limit on the package: `apps/*` may depend on
/// everything public in the workspace, because the composition root is what composes. An
/// absent key is a finding, not a permission — a new package must be added here and to the
/// document in the same change.
const _allowedDependencies = <String, Set<String>?>{
  'alteri_one_protocol': <String>{},
  'alteri_one_platform': <String>{'alteri_one_protocol'},
  'alteri_one_core': <String>{'alteri_one_protocol', 'alteri_one_platform'},
  'alteri_one_memory': <String>{'alteri_one_core', 'alteri_one_platform'},
  'alteri_one_injection_skill': <String>{
    'alteri_one_core',
    'alteri_one_protocol',
  },
  'alteri_one_cli': null,
  'alterione': <String>{},
};

/// The noun a package's name has to state, per subproject, from ADR-0014 and ADR-0016.
///
/// The subproject is the taxonomy: `tools/` is the Tool noun and nothing else, so a package
/// that lives there and does not say so in its name is a package in the wrong place, or a
/// package that wants to be two nouns. `alteri_one_memory` is the documented exception — the
/// memory plugin predates the convention and is named for what it stores, not for its noun.
/// `apps/` is exempt: an app is named for the app, and `alterione` is the one package the
/// product spelling is allowed in (ADR-0016).
const _nounInTheName = <String, List<String>>{
  'injections': <String>['alteri_one_injection_'],
  'plugins': <String>['alteri_one_plugin_', 'alteri_one_memory'],
  'tools': <String>['alteri_one_tool_'],
};

/// Directories that may hold a `pubspec.yaml` without being a workspace member.
const _documentedNonMembers = <String>{'site'};

/// The four extension subprojects, from ADR-0014. A package in one of them is an extension;
/// a package in `packages/` is a product library. Nothing else is a package in this tree.
const _extensionRoots = <String>['apps', 'tools', 'injections', 'plugins'];

/// One package in the workspace.
final class _Member {
  _Member(this.path, this.pubspec);

  /// Repository-relative path, e.g. `packages/alteri_one_core`.
  final String path;

  final Map<String, Object?> pubspec;

  late final String name = pubspec['name']! as String;

  bool get isExtension {
    final root = path.split('/').first;
    return _extensionRoots.contains(root);
  }

  /// Direct dependencies that are packages of this workspace, sorted.
  List<String> get workspaceDependencies {
    final dependencies = <String>{
      ...?_stringKeys(pubspec['dependencies']),
      ...?_stringKeys(pubspec['dev_dependencies']),
    };
    return dependencies.where((name) => name != this.name).toList()..sort();
  }

  /// Every library URI imported or exported by this package's own sources.
  Set<String> get imports {
    final found = <String>{};
    for (final file in _dartFilesIn(Directory(path))) {
      for (final match in _importPattern.allMatches(file.readAsStringSync())) {
        found.add(match.group(1)!);
      }
    }
    return found;
  }

  Set<String> importsOf(String library) =>
      imports.where((uri) => uri == library).toSet();
}

/// The repository as the specification describes it, read once.
final class _Workspace {
  _Workspace({
    required this.root,
    required this.globs,
    required this.members,
    required this.legacyConfig,
    required this.unreachedPubspecs,
    required this.pubspecPaths,
  });

  final _Member root;
  final List<String> globs;
  final Map<String, _Member> members;

  /// Legacy Melos configuration that must never be created.
  final List<String> legacyConfig;

  /// `pubspec.yaml` files in the tree that no glob reaches and that are not documented
  /// non-members.
  final List<String> unreachedPubspecs;

  final List<String> pubspecPaths;

  Iterable<String> get appNames => members.values
      .where((member) => member.path.split('/').first == 'apps')
      .map((member) => member.name);

  /// Member names an app package depends on, keyed by the package that depends on it.
  List<String> get dependentsOfApps {
    final apps = appNames.toSet();
    final offenders = <String>[];
    for (final member in members.values) {
      if (apps.contains(member.name)) continue;
      for (final dependency in member.workspaceDependencies) {
        if (apps.contains(dependency))
          offenders.add('${member.path} → $dependency');
      }
    }
    return offenders..sort();
  }

  /// Dependency cycles between workspace packages, each rendered as `a → b → a`.
  List<String> get cycles {
    final found = <String>[];
    final state = <String, _Visit>{};

    void visit(String name, List<String> path) {
      if (state[name] == _Visit.done) return;
      if (state[name] == _Visit.open) {
        final start = path.indexOf(name);
        found.add(
          <String>[...path.sublist(start == -1 ? 0 : start), name].join(' → '),
        );
        return;
      }
      state[name] = _Visit.open;
      for (final dependency
          in members[name]?.workspaceDependencies ?? const <String>[]) {
        if (members.containsKey(dependency))
          visit(dependency, <String>[...path, name]);
      }
      state[name] = _Visit.done;
    }

    for (final name in members.keys) {
      visit(name, const <String>[]);
    }
    return found;
  }

  _Member? memberNamed(String name) {
    for (final member in members.values) {
      if (member.name == name) return member;
    }
    return null;
  }

  /// The package directories a `workspace:` glob reaches, repository-relative.
  List<String> packagesUnder(String glob) => _packagesUnder(glob);

  bool gitignoreIgnores(String path) {
    if (!File('.gitignore').existsSync()) return false;
    final patterns = <String>[];
    for (final line in File('.gitignore').readAsLinesSync()) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      patterns.add(
        trimmed.endsWith('/')
            ? trimmed.substring(0, trimmed.length - 1)
            : trimmed,
      );
    }
    return patterns.contains(path) || patterns.contains('/$path');
  }

  static _Workspace load() {
    final rootPubspecPath = 'pubspec.yaml';
    if (!File(rootPubspecPath).existsSync()) {
      throw StateError(
        'the workspace contract test must run from the repository root: no $rootPubspecPath',
      );
    }
    final root = _Member('.', _readPubspec(rootPubspecPath));
    final globs = (root.pubspec['workspace']! as List<Object?>).cast<String>();

    final members = <String, _Member>{};
    for (final glob in globs) {
      for (final path in _packagesUnder(glob)) {
        members[path] = _Member(path, _readPubspec('$path/pubspec.yaml'));
      }
    }

    final reached = <String>{for (final glob in globs) ..._packagesUnder(glob)};
    final unreached = <String>[];
    final pubspecPaths = <String>[rootPubspecPath];
    for (final entity in Directory(
      '.',
    ).listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final path = _normalise(entity.path);
      if (!path.endsWith('/pubspec.yaml')) continue;
      if (path.contains('/.dart_tool/') || path.contains('/build/')) continue;
      pubspecPaths.add(path);
      final directory = path.substring(
        0,
        path.length - 'pubspec.yaml'.length - 1,
      );
      if (reached.contains(directory) ||
          _documentedNonMembers.contains(directory.split('/').first)) {
        continue;
      }
      unreached.add(path);
    }

    final legacy = <String>[];
    for (final name in const ['melos.yaml', 'pubspec.workspaces.yaml']) {
      for (final entity in Directory(
        '.',
      ).listSync(recursive: true, followLinks: false)) {
        if (entity is File && entity.path.endsWith(name))
          legacy.add(entity.path);
      }
    }

    return _Workspace(
      root: root,
      globs: globs,
      members: members,
      legacyConfig: legacy,
      unreachedPubspecs: unreached,
      pubspecPaths: pubspecPaths,
    );
  }
}

enum _Visit { open, done }

/// The imports, exports and parts of a Dart library, captured.
final _importPattern = RegExp(
  r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

Map<String, Object?> _readPubspec(String path) =>
    _plain(loadYaml(File(path).readAsStringSync(), sourceUrl: Uri.file(path)))!
        as Map<String, Object?>;

/// Converts a YamlMap or YamlList into plain Dart collections.
///
/// The conversion is explicit so that the test never makes a dynamic call: `strict-casts`
/// and `avoid_dynamic_calls` are on for the same reason the engine has no `dart:io`.
Object? _plain(Object? node) {
  if (node is YamlMap) {
    return <String, Object?>{
      for (final entry in node.nodes.entries)
        (entry.key as YamlScalar).value as String: _plain(entry.value),
    };
  }
  if (node is YamlList) {
    return <Object?>[for (final child in node) _plain(child)];
  }
  if (node is YamlScalar) return node.value;
  return node;
}

Set<String>? _stringKeys(Object? node) {
  if (node is! Map<String, Object?>) return null;
  return node.keys.whereType<String>().toSet();
}

int? _majorVersion(Object? constraint) {
  if (constraint is! String) return null;
  final match = RegExp(r'(\d+)\.').firstMatch(constraint);
  return match == null ? null : int.parse(match.group(1)!);
}

List<String> _packagesUnder(String glob) {
  final segments = glob.split('/');
  final prefix = segments.take(segments.length - 1).join('/');
  if (prefix.isEmpty) return const <String>[];
  final matcher = RegExp(
    '^${RegExp.escape(segments.last).replaceAll(r'\*', '.*')}\$',
  );
  final directory = Directory(prefix);
  if (!directory.existsSync()) return const <String>[];
  return directory
      .listSync(followLinks: false)
      .whereType<Directory>()
      .map((entry) => _normalise(entry.path))
      .where((path) => matcher.hasMatch(path.split('/').last))
      .where((path) => File('$path/pubspec.yaml').existsSync())
      .toList()
    ..sort();
}

/// Every file in a package directory, sorted, skipping the tool's own output.
List<File> _filesIn(Directory directory) {
  if (!directory.existsSync()) return const <File>[];
  final files = <File>[];
  for (final entity in directory.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File) continue;
    final path = entity.path.replaceAll(r'\', '/');
    if (path.contains('/.dart_tool/') || path.contains('/build/')) continue;
    files.add(entity);
  }
  return files..sort((a, b) => a.path.compareTo(b.path));
}

List<File> _dartFilesIn(Directory directory) =>
    _filesIn(directory).where((file) => file.path.endsWith('.dart')).toList();

/// Repository-relative, forward slashes, no `./` prefix — the same shape on every platform.
String _normalise(String path) =>
    path.replaceAll(r'\', '/').replaceFirst(RegExp(r'^\./'), '');
