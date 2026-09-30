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

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
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

        // Runtime *and* development, on purpose. A dev dependency on a sibling package is
        // still a link in the graph: it puts two packages in one compilation unit, it can
        // create a cycle that `dart pub` would resolve and a reader would not expect, and it
        // lets a package reach a sibling's internals from its tests. A *toolchain* dependency
        // is outside this list entirely, which is what task 0.4 exposed: `alteri_one_protocol`
        // needs `test` to run its own acceptance command, and the table correctly says it may
        // depend on nothing.
        expect(
          member.value.workspaceDependencies.toSet().difference(allowed),
          isEmpty,
          reason:
              '${member.key} depends on a package the table does not allow it to '
              'depend on',
        );
      }
    });

    test('a development dependency is a build or test tool, and nothing else', () {
      // The gap task 0.4 opened, and it is worth closing explicitly rather than by making the
      // table bigger. A `dev_dependencies` entry on a package outside this workspace cannot
      // reach the shipped artefact, so the §3 table has nothing to say about it — but an
      // unlisted one is still a third-party package entering the resolution, and the only
      // reason it is acceptable is that it is a tool. `_toolchain` is that list, and it is
      // short on purpose: adding to it is how a real dependency would get in through the back
      // door, so each entry has to be a build or test runner that nothing links against.
      for (final member in workspace.members.values) {
        expect(
          member.externalDevDependencies.where(
            (name) => !_toolchain.contains(name),
          ),
          isEmpty,
          reason:
              '${member.path} has a development dependency that is not a build or test '
              'tool. The §3 table governs in-repository dependencies; a third-party one is '
              'governed by this list, and adding a name to it should be reviewed as '
              'deciding that a package enters the resolution',
        );
      }
    });

    test('a runtime dependency outside this workspace is on the allowlist', () {
      // The gap ADR-0022 opened, and it was open before this test noticed it. Neither list above
      // can see a third-party *runtime* dependency: `_allowedDependencies` is a table of
      // workspace members, and `_toolchain` only inspects `dev_dependencies`. So before task
      // `0.11` a real runtime dependency on a package from pub.dev would have entered the
      // resolution, into the AOT snapshot and into the browser bundle, with nothing to stop it —
      // `architecture/overview.md` §3's rule is a table a human reads.
      //
      // `_runtimeThirdParty` is that table. It is separate from `_toolchain` on purpose even
      // though `yaml` is in both: a package can be a build tool for one package and a shipped
      // dependency of another, and collapsing the two lists would make the *less* dangerous use
      // the one that authorises the more dangerous one.
      for (final member in workspace.members.values) {
        expect(
          member.externalRuntimeDependencies.where(
            (name) =>
                !_runtimeThirdParty.containsKey(member.name) ||
                !_runtimeThirdParty[member.name]!.contains(name),
          ),
          isEmpty,
          reason:
              '${member.path} depends at runtime on a third-party package the allowlist does '
              'not name. Every entry here is a package that reaches the shipped artefact, so '
              'adding one is a decision: add it to this list, to architecture/overview.md §3 '
              'and to docs/decisions/ in the same change',
        );
      }
    });

    test('the runtime allowlist names only packages that are actually used', () {
      // The other direction, and the one that stops the list becoming a place where names go to
      // be forgotten. A list that is only ever added to is a list that ends up naming a package
      // no longer in the resolution, at which point it authorises a re-introduction nobody
      // notices. The allowlist has to be a *description* of the tree, not a wish list.
      for (final entry in _runtimeThirdParty.entries) {
        final member = workspace.memberNamed(entry.key);
        if (member == null)
          continue; // the package is not in the workspace for this phase
        expect(
          member.externalRuntimeDependencies,
          containsAll(entry.value),
          reason:
              '${entry.key} is allowed these third-party runtime dependencies: '
              '${entry.value.join(', ')}. At least one is not among the ones it declares, so '
              'the allowlist is stale — remove it or add the dependency back',
        );
      }
    });

    test('every product library resolves for a web build', () {
      // The closure check, and the reason ADR-0022 is not satisfied by `intl` *not importing*
      // `dart:io` on its own. `intl` has two libraries that do — `intl_standalone.dart`, which
      // discovers the system locale, and `date_symbol_data_file.dart`, which loads symbols from a
      // file — and neither is reachable from `intl.dart`. That is the property that keeps
      // `architecture/overview.md` §3's "no `dart:io` in protocol or core" a property of a
      // **build**: `dart compile js` resolves the same imports this walk resolves, so a browser
      // build fails if anything in the closure reaches one.
      //
      // Two things this has to get right, and both have bitten this repository before:
      //
      // - **Conditional exports are resolved, not ignored.** `alteri_one_platform` puts every
      //   `dart:io` adapter behind `if (dart.library.js_interop)`, so a walk that followed both
      //   branches would report a web build that works. Following only the branch the web build
      //   takes is what makes the one package that *may* import `dart:io` checkable at all
      //   without an exemption — and the platform's own contract test already pins the
      //   native-first ordering, so this is the same property asserted from the other end.
      // - **A third-party package is walked, not trusted.** The check above it reads only a
      //   package's *own* imports, so a dependency that never writes `dart:io` itself can still
      //   make its caller uncompilable for the web, and the only way to know is to walk.
      final offenders = <String>[];
      for (final member in workspace.members.values) {
        if (member.isExtension)
          continue; // Tier 0/1 extensions are not the browser surface
        final reached = webClosureOf(member);
        if (reached == null) {
          offenders.add('${member.path} → (unresolvable)');
          continue;
        }
        if (reached.dartUris.contains('dart:io')) {
          offenders.add('${member.path} → ${reached.via.join(', ')}');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'a product library reaches dart:io when resolved for a web build, so '
            '`dart compile js` of it would not compile. architecture/overview.md §3 makes the '
            'absence of dart:io a property of a build and this is the check that keeps it one: '
            'a conditional export, a smaller dependency, or an ADR',
      );
    });

    test('the web-closure walk actually walked something', () {
      // The guard on the guard. A closure check that resolved no libraries would report "no
      // offenders" for the same reason a workspace glob matching nothing does — which
      // `dart pub get` refuses for, and which this repository treats as a defect rather than an
      // empty result. So the premise is asserted: the member under test must resolve to a real
      // library and reach a real package, or the check above is vacuously green on a machine
      // where `.dart_tool/package_config.json` is missing or stale.
      final core = workspace.memberNamed('alteri_one_core')!;
      final reached = webClosureOf(core);
      expect(
        reached,
        isNotNull,
        reason:
            'alteri_one_core did not resolve for a web build. The walk reads '
            '.dart_tool/package_config.json, so run `dart pub get` first — a check that walked '
            'nothing cannot fail',
      );
      expect(
        reached!.dartUris,
        isNotEmpty,
        reason:
            'alteri_one_core resolved to no dart: library at all, which means the walk '
            'found no import to start from',
      );
      expect(
        reached.via,
        isNotEmpty,
        reason:
            'alteri_one_core reached no package outside this workspace. It declares intl, '
            'source_span and yaml, so an empty list means the closure did not follow them',
      );
    });

    test('a package with tests declares the runner', () {
      // `dart test` in a package without `test` on `dev_dependencies` fails to resolve rather
      // than failing a test, and the failure is a toolchain error in CI with no indication of
      // which package caused it. The acceptance commands in the task breakdown are run with
      // `melos exec --scope=<package>`, so this is the difference between a task's acceptance
      // criterion running and not running.
      for (final member in workspace.members.values) {
        if (!Directory('${member.path}/test').existsSync()) continue;
        expect(
          member.declaredDevDependencies,
          contains('test'),
          reason:
              '${member.path} has a test/ directory and does not declare `test` on '
              'dev_dependencies, so its tests cannot resolve',
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
      //
      // **The check is for an identifier, and it is checked as one.** It used to be
      // `file.contains('alterione')` over the whole file, which is a proxy for "an identifier
      // spells it" and is wrong in both directions: it fails a file whose only occurrence is prose
      // explaining ADR-0016, and it fails a file whose only occurrence is the *value* `~/.alterione`.
      //
      // That second one is not avoidable, and the reason is the ADR itself. `alteri_one_platform`
      // resolves the install root, install-and-update.md §2 makes that root `~/.alterione`, and
      // ADR-0016 requires an installed path and a default configuration value to carry the product
      // spelling. So the product spelling **must** appear in that package, as a string — and the
      // rule has to be about identifiers, which is what it says it is about, or the rule and the
      // specification contradict each other.
      //
      // Narrowing it this way does not weaken the gate. An identifier still fails, and the narrowing
      // is *only* about comments and string literals; the stripper is exercised by its own test below,
      // because a governance gate that silently stopped checking anything would be worse than the
      // false positive it replaced.
      for (final member in workspace.members.values) {
        if (member.path == 'apps/bootstrap') continue;
        final offenders = <String>[
          for (final file in _filesIn(Directory(member.path)))
            if (!file.path.endsWith('.g.dart') &&
                _spellsTheProductNameInCode(file))
              _normalise(file.path),
        ];
        expect(
          offenders,
          isEmpty,
          reason:
              '${member.path} spells the product name in a source identifier; the product '
              'spelling belongs to the release (ADR-0016). A comment or a string value may carry '
              'it — the default install root is `~/.alterione` and has to — but a name may not',
        );
      }
    });

    test('the product-spelling check looks at code and not at prose', () {
      // The stripper behind the check above, tested on its own. A governance gate whose own
      // machinery is untested is a gate that can stop working without anything turning red, which is
      // the failure mode the rest of this file exists to prevent.
      //
      // Every case is written as a **raw** string, because each one is Dart source being fed to the
      // scanner and an escaped one would be harder to read than the thing it is about.
      expect(_codeOnly(r'class alterione {}'), contains('alterione'));
      expect(
        _codeOnly(r"final x = '~/.alterione';"),
        isNot(contains('alterione')),
      );
      expect(
        _codeOnly(r'final x = "~/.alterione";'),
        isNot(contains('alterione')),
      );
      expect(
        _codeOnly(r"final x = r'~/.alterione';"),
        isNot(contains('alterione')),
      );
      expect(
        _codeOnly(r'// alterione in a line comment'),
        isNot(contains('alterione')),
      );
      expect(
        _codeOnly(r'/// alterione in a doc comment'),
        isNot(contains('alterione')),
      );
      expect(
        _codeOnly(r'/* alterione in a block */'),
        isNot(contains('alterione')),
      );
      expect(
        _codeOnly(r'/* outer /* nested */ still a comment */'),
        isNot(contains('alterione')),
        reason: 'Dart block comments nest, so the inner */ does not end the outer one',
      );
      expect(
        _codeOnly(r"final url = 'https://alteri.one'; // alterione"),
        isNot(contains('alterione')),
        reason: 'a // inside a string is part of the string, not the start of a comment',
      );
      expect(
        _codeOnly(r"final s = 'it\'s alterione';"),
        isNot(contains('alterione')),
        reason: 'an escaped quote does not end the string',
      );
      expect(
        _codeOnly(r'final s = "a\"b alterione";'),
        isNot(contains('alterione')),
      );
      expect(
        _codeOnly(r"// it's a comment with an apostrophe"),
        isNot(contains('alterione')),
        reason:
            'an apostrophe in a comment does not open a string. Scanning for strings before comments '
            'would treat the rest of this line as a string and hide whatever came after it',
      );
      // **Triple quotes**, where the first version of this scanner had its silent false negative.
      // Each case is the shape that hid an identifier: a triple-quoted body containing the *other*
      // kind of quote, followed by real code. The literals are raw or double-quoted so the Dart
      // source of this test is itself unambiguous -- an escaping mistake here would look like a
      // scanner failure.
      expect(
        _codeOnly(r"final s = '''it's plain''';"),
        isNot(contains('alterione')),
        reason: 'a triple-quoted string is a string',
      );
      expect(
        _codeOnly(
          r"final s = '''it's plain''';"
          '\nfinal alterione = 1;',
        ),
        contains('alterione'),
        reason:
            'a triple-quoted string containing a quote must end at the closing triple, not at '
            'the first quote inside its body -- otherwise everything after it reads as code '
            'that has been blanked, and the identifier is invisible to the gate',
      );
      expect(
        _codeOnly(
          'final s = """it\'s plain""";'
          '\nfinal alterione = 1;',
        ),
        contains('alterione'),
        reason: 'and the same for a double-quoted one',
      );
      expect(
        _codeOnly(
          r"final s = r'''it's raw''';"
          '\nfinal alterione = 1;',
        ),
        contains('alterione'),
        reason: 'and for a raw one, which has no escapes at all',
      );
      expect(
        _codeOnly("final s = '''\nalterione\n''';"),
        isNot(contains('alterione')),
        reason: 'a multi-line triple-quoted body is still a string',
      );

      // Length-preserving, so a finding can still be located in the original.
      expect(_codeOnly('final x = 1;').length, 'final x = 1;'.length);
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
    test('the boundary rules are checked against a lib/ that exists', () {
      // The guard on the guard. The rules below read `lib/` rather than the whole package,
      // because a test is not shipped and is allowed to read a file off disk. A package whose
      // `lib/` were empty or renamed would make them all vacuously true — the same shape of
      // defect as a workspace glob that matches nothing, which `dart pub get` refuses for
      // exactly this reason. So the premise is asserted rather than assumed.
      for (final member in workspace.members.values) {
        final lib = Directory('${member.path}/lib');
        expect(
          lib.existsSync(),
          isTrue,
          reason:
              '${member.path} has no lib/ directory, so its import rules would pass without '
              'reading anything',
        );
        expect(
          _dartFilesIn(lib),
          isNotEmpty,
          reason: '${member.path}/lib contains no Dart source',
        );
        expect(
          File('${member.path}/lib/${member.name}.dart').existsSync(),
          isTrue,
          reason:
              '${member.path} has no lib/${member.name}.dart. A package is imported by its '
              'own name, so the file named after the package is its entry point, and it is '
              'what makes the import rules reachable at all',
        );
      }
    });

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
/// The names of every workspace member, for a manifest that is being read on its own.
///
/// A top-level value rather than a lookup through [_Workspace], because a [_Member] is
/// constructed while the workspace is still being discovered and cannot reach the map it is
/// being added to.
final workspaceNames = <String>{};

/// The workspace members, keyed by package name rather than by path.
///
/// The closure walk needs to go from an import to a member's `lib/`, and the discovered map is
/// keyed by path. Kept as a second index rather than by searching [workspaceNames] and
/// re-reading every manifest, because the walk runs once per import and a linear scan per scan
/// is the kind of thing that makes a "fast" gate slow on a large tree.
final workspaceNamesByPath = <String, _Member>{};

/// Development dependencies that are build or test tools rather than something a package links
/// against.
///
/// Deliberately small. A name here is a package the §3 dependency table stops seeing, so each
/// entry has to be something that cannot end up in a shipped artefact: a test runner, a build
/// runner, or a codegen tool. `yaml` is here because the contract tests parse manifests with
/// it — a test may not use a transitive dependency, and promoting it to an explicit
/// dev_dependency is how that is done without it entering any runtime graph.
///
/// It is **not** the same list as [_runtimeThirdParty], even though `yaml` appears in both.
/// A package can be a build tool for one package and a shipped dependency of another, and one
/// list would make the harmless use authorise the load-bearing one.
const _toolchain = <String>{
  'test',
  'test_api',
  'build',
  'build_runner',
  'yaml',
};

/// Third-party **runtime** dependencies, per package, from ADR-0022.
///
/// A separate table from [_allowedDependencies] because that one is a table of *workspace
/// members* and this one is of everything else. Before task `0.11` no product library had a
/// third-party runtime dependency at all, so neither the §3 table nor [_toolchain] had anything
/// to say about one: a real dependency on a package from pub.dev would have reached the AOT
/// snapshot and the browser bundle with no gate in its way.
///
/// A package absent as a key is a package that may have **no** third-party runtime dependency,
/// which is the state every package but `alteri_one_core` is in and is the state worth
/// protecting. Adding an entry is a decision and belongs with an ADR, because every name here
/// ships.
const _runtimeThirdParty = <String, Set<String>>{
  'alteri_one_core': <String>{
    // The profile parser. Pure Dart, so it does not make a web build impossible.
    'yaml',
    // `yaml`'s span type, named directly rather than reached through `yaml`'s internals.
    'source_span',
    // The l10n catalogue and locale-aware number formatting.
    'intl',
  },
};

/// The `dart:` libraries [member] reaches when it is resolved the way a **web build** resolves
/// it, and the non-workspace packages walked to get there.
///
/// Returns null when the member's own entry point does not resolve, which the caller reports as
/// a finding rather than as "nothing reached" — a member whose `lib/<name>.dart` is missing is a
/// member the check above it would otherwise pass silently, and the premise test turns the same
/// condition red when it is the member under test.
///
/// Every workspace sibling is resolved from its own `lib/` through the same package config, so
/// `alteri_one_core` is checked with `alteri_one_platform`'s real conditional export applied
/// rather than assumed away.
_WebClosure? webClosureOf(_Member member) {
  final config = _packageConfig;
  if (config == null) return null;
  final entry = File('${member.path}/lib/${member.name}.dart');
  if (!entry.existsSync()) return null;

  final closure = _WebClosure(<String>{}, <String>{});
  _resolveForWeb(entry, config, closure, <String>{});
  return closure;
}

/// One web-resolution: the `dart:` libraries reached and the out-of-workspace packages walked.
///
/// Mutated in place through a walk because the walk is recursive and a result object per frame
/// would allocate one set per library; a file read is the expensive part, not the set.
final class _WebClosure {
  _WebClosure(this.dartUris, this.via);

  /// Every `dart:` URI resolved. `dart:io` appearing here is the finding.
  final Set<String> dartUris;

  /// Every package outside this workspace that was walked, for the failure message.
  ///
  /// A message saying "alteri_one_core → intl → dart:io" is one a reader can act on; one
  /// saying only "alteri_one_core → dart:io" sends them looking in the wrong package.
  final Set<String> via;
}

/// Records what [file] reaches, following [dartUris] and `package:` URIs for the **web** target.
///
/// **The conditional resolution is the point, and it is why this is not a grep.** A directive
/// guarded by `if (dart.library.io)` is not resolved by `dart compile js`, so a library behind
/// one contributes nothing — which is exactly how `alteri_one_platform` is allowed to ship
/// `dart:io` adapters at all. Ignoring the guard would report a web build that works; treating
/// every branch as reachable would forbid the arrangement the whole browser surface depends on.
///
/// The condition grammar understood is the one this repository uses and the one the Dart
/// specification defines for `import`/`export`: `if (<boolean-value>) '<uri>'`, where a
/// boolean value is a dotted identifier, optionally `== "true"` or `== "false"`. A condition
/// mentioning `dart.library.io` is **not** satisfiable on the web unless it explicitly asks for
/// it to be false. A condition the walker does not understand is treated as satisfied, which is
/// the conservative direction: it can only produce a false positive, and a false positive is
/// reviewable while a false negative is a browser build that does not compile.
void _resolveForWeb(
  File file,
  _PackageConfig config,
  _WebClosure closure,
  Set<String> visited,
) {
  // **Canonicalised before the visited check, and that is load-bearing.** A relative import may
  // legally carry `..`: `package:clock`'s own barrel does `export 'src/../clock.dart'`, so a
  // naive walk reaches `clock.dart`, then `src/../clock.dart`, then `src/../src/../clock.dart`,
  // each a different *string* naming the same file. The visited set never matches and the walk
  // recurses until the stack gives out — which is exactly what happened the first time this
  // ran, and it is why a governance gate that walks a graph must not compare paths as written.
  //
  // `canonicalize` rather than `normalize` because the second reason is symlinks: on macOS
  // `/tmp` is a link to `/private/tmp`, and a set keyed on the un-canonical spelling reports two
  // files where there is one, which is the same class of bug in a different place.
  final path = p.canonicalize(file.path);
  if (!visited.add(path))
    return; // a cycle, or a second route to a library already walked
  if (!File(path).existsSync()) return;

  for (final directive in _directivesIn(File(path).readAsStringSync())) {
    final chosen = _branchForWeb(directive);
    if (chosen == null) continue;
    final uri = chosen;
    if (uri.startsWith('dart:')) {
      closure.dartUris.add(uri);
      continue;
    }
    if (uri.startsWith('package:')) {
      final resolved = config.fileFor(uri);
      if (resolved == null) continue;
      final name = uri.substring('package:'.length).split('/').first;
      if (!workspaceNames.contains(name)) closure.via.add(name);
      _resolveForWeb(resolved, config, closure, visited);
      continue;
    }
    _resolveForWeb(
      File(p.join(p.dirname(path), uri)),
      config,
      closure,
      visited,
    );
  }
}

/// The URI a web build resolves [directive] to.
///
/// **A conditional directive is a choice, and the default is the *fallback*.**
/// `export 'a.dart' if (C) 'b.dart';` means a build that satisfies `C` uses `b.dart` and every
/// other build uses `a.dart` — never both, and `a.dart` is not a branch in its own right. Two
/// readings of that line are both wrong in a way this repository has already paid for:
///
/// - Following the default unconditionally makes `alteri_one_platform`'s `src/native.dart` look
///   reachable from a web build, and the platform package may ship `dart:io` adapters *only*
///   because a web build does not resolve that file.
/// - Following every branch reaches both files and reports the same false failure.
///
/// So the whole line is parsed into one default plus its ordered `if` clauses, and the first
/// clause the web satisfies wins. The order matters and is the order they appear in, which is
/// the resolution order the Dart specification defines. With no clause satisfied, the default is
/// the answer — and with no clauses at all, the default is the only candidate, so one shape
/// covers an unconditional directive too.
String? _branchForWeb(_Directive directive) {
  for (final branch in directive.branches) {
    if (_satisfiableOnWeb(branch.condition)) return branch.uri;
  }
  return directive.fallback;
}

/// Whether [condition] can hold on the web.
///
/// Only `dart.library.io` is treated as VM-only, because it is the one this repository's
/// conditional exports are written against and the one that decides whether a `dart:io` import
/// is reachable. `dart.library.js_interop` is the *web* condition and is therefore always
/// satisfiable — treating it as VM-only would select the wrong branch and hide the refusal
/// surface `alteri_one_platform` exists to provide.
///
/// A condition naming neither is treated as satisfiable, which is the conservative direction: it
/// can only produce a false positive, and a false positive is reviewable while a false negative
/// is a browser build that does not compile.
bool _satisfiableOnWeb(String condition) {
  final wantsIo = RegExp(r'dart\.library\.io\s*(?:==\s*"true")?')
      .hasMatch(condition);
  final explicitlyFalse = condition.contains('== "false"');
  return !wantsIo || explicitlyFalse;
}

/// One `if (condition) 'uri'` clause of a directive.
final class _Branch {
  const _Branch(this.condition, this.uri);

  final String condition;
  final String uri;
}

/// One `import`, `export` or `part` directive: its default URI and its ordered `if` clauses.
final class _Directive {
  const _Directive(this.fallback, this.branches);

  /// The URI a build that satisfies none of [branches] resolves to.
  final String fallback;

  /// The `if` clauses, in the order they appear.
  final List<_Branch> branches;
}

/// The `import`, `export` and `part` directives in [source], in order.
///
/// A single pass over the lines rather than a global regular expression, because the default
/// branch and its `if` clauses are on the **same line** and the pairing is the whole job: a
/// global match finds both and loses which condition belongs to which. `part of` is excluded
/// because it declares membership rather than naming a URI to follow, and `part 'x.dart'` is
/// followed — the same rule [Member.imports] uses, and deliberately the same one so the two
/// checks cannot disagree about what an import is.
Iterable<_Directive> _directivesIn(String source) sync* {
  for (final line in const LineSplitter().convert(source)) {
    if (line.trimLeft().startsWith('part of')) continue;
    final fallback = _defaultBranch.firstMatch(line);
    if (fallback == null) continue;
    final branches = <_Branch>[
      for (final branch in _conditionalBranch.allMatches(line))
        _Branch(branch.group(1)!.trim(), branch.group(2)!),
    ];
    yield _Directive(fallback.group(1)!, branches);
  }
}

/// The default URI of a directive: a quoted string straight after the verb.
final _defaultBranch = RegExp(
  r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''',
);

/// One `if (<condition>) '<uri>';` clause, wherever it sits on the line.
final _conditionalBranch = RegExp(r'''if\s*\(([^)]*)\)\s*['"]([^'"]+)['"]''');

/// The resolved package graph, read from `.dart_tool/package_config.json`.
///
/// A top-level final so the file is read once and every walk reuses it; Dart initialises it
/// lazily, so a run that never reaches the closure test does not pay for the read.
final _packageConfig = _readPackageConfig();

/// The `package_config.json` at the repository root, or null when it is not there.
_PackageConfig? _readPackageConfig() {
  final file = File('.dart_tool/package_config.json');
  if (!file.existsSync()) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(file.readAsStringSync());
  } on FormatException {
    return null; // half-written by an interrupted `pub get`
  }
  if (decoded is! Map<String, Object?>) return null;
  final packages = decoded['packages'];
  if (packages is! List<Object?>) return null;
  return _PackageConfig(packages);
}

/// The resolved packages, and how to turn a `package:` URI into a file.
final class _PackageConfig {
  _PackageConfig(List<Object?> entries) {
    for (final entry in entries) {
      if (entry is! Map<String, Object?>) continue;
      final name = entry['name'];
      final rootUri = entry['rootUri'];
      if (name is! String || rootUri is! String) continue;
      final packageUri = entry['packageUri'];
      _roots[name] = (
        root: _resolveRootUri(rootUri),
        lib: packageUri is String ? packageUri : 'lib/',
      );
    }
  }

  final Map<String, ({String root, String lib})> _roots = {};

  /// The file a `package:` [uri] names, or null when it does not resolve.
  ///
  /// Split on the **first** colon only. `Uri.parse` would be the general answer and is wrong
  /// here: a `package:` URI's path may itself contain a colon, and `split(':')` would then
  /// produce three parts and look up a package that does not exist. The prefix is a known,
  /// fixed-length scheme, so a substring is both correct and cheaper.
  File? fileFor(String uri) {
    const scheme = 'package:';
    if (!uri.startsWith(scheme)) return null;
    final rest = uri.substring(scheme.length);
    final slash = rest.indexOf('/');
    if (slash <= 0) return null;
    final entry = _roots[rest.substring(0, slash)];
    if (entry == null) return null;
    final base = entry.root.endsWith('/') ? entry.root : '${entry.root}/';
    final file = File('$base${entry.lib}${rest.substring(slash + 1)}');
    return file.existsSync() ? file : null;
  }

  /// Resolves a `package_config.json` `rootUri` to a path relative to the repository root.
  ///
  /// The two forms are both present in the file and both are documented to be relative to the
  /// configuration file's own directory, which is `.dart_tool/`. A `file:` URI is absolute and a
  /// bare path is relative, and getting this wrong resolves every package to a path one
  /// directory too high — which produces a walk that reads nothing and reports no offenders.
  static String _resolveRootUri(String rootUri) {
    if (rootUri.startsWith('file:')) return Uri.parse(rootUri).toFilePath();
    return rootUri.startsWith('../') ? rootUri : '../$rootUri';
  }
}

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

  /// Direct dependencies on packages *of* this workspace, sorted.
  ///
  /// Runtime and development together. Both are links in the graph a reader reasons about: a
  /// dev dependency on a sibling puts two packages in one compilation unit and can create a
  /// cycle, so the §3 table governs this list and not only the runtime half of it.
  List<String> get workspaceDependencies {
    final dependencies = <String>{
      ...?_stringKeys(pubspec['dependencies']),
      ...?_stringKeys(pubspec['dev_dependencies']),
    };
    return dependencies
        .where((name) => name != this.name && workspaceNames.contains(name))
        .toList()
      ..sort();
  }

  /// Direct dependencies on packages *outside* this workspace, sorted.
  ///
  /// Split by whether the target is a workspace member, because the two answer different
  /// questions. A workspace dependency is part of the product's graph and the §3 table decides
  /// it. An external one is third-party code; as a dev dependency it is a build or test tool
  /// that cannot end up in a shipped artefact, which is what [_toolchain] lists.
  List<String> get externalDependencies {
    final declared = <String>{
      ...?_stringKeys(pubspec['dependencies']),
      ...?_stringKeys(pubspec['dev_dependencies']),
    };
    return declared
        .where((name) => name != this.name && !workspaceNames.contains(name))
        .toList()
      ..sort();
  }

  /// Third-party dependencies on the **runtime** path, sorted.
  ///
  /// The half of [externalDependencies] that reaches a shipped artefact, and the reason
  /// [_runtimeThirdParty] exists: a `dev_dependency` on a package from pub.dev cannot end up in
  /// the AOT snapshot and a runtime one always does, so the two need different tables even when
  /// they name the same package. A package with no `dependencies:` section has none, which is
  /// the common case and the one the allowlist's absent keys are asserting.
  List<String> get externalRuntimeDependencies {
    final declared = _stringKeys(pubspec['dependencies']);
    if (declared == null) return const [];
    return declared
        .where((name) => name != this.name && !workspaceNames.contains(name))
        .toList()
      ..sort();
  }

  /// Declared development dependencies that are not packages of this workspace, sorted.
  List<String> get externalDevDependencies {
    final declared = _stringKeys(pubspec['dev_dependencies']);
    if (declared == null) return const [];
    return declared
        .where((name) => name != this.name && !workspaceNames.contains(name))
        .toList()
      ..sort();
  }

  /// Every declared development dependency, toolchain or not, sorted.
  List<String> get declaredDevDependencies =>
      [...?_stringKeys(pubspec['dev_dependencies'])]..sort();

  /// Every library URI imported or exported by this package's `lib/` sources.
  ///
  /// `lib/` and not the whole package, and the distinction is the point of the rule rather
  /// than a loophole in it. What the boundary protects is the *shipped* surface: a library that
  /// imports `dart:io` cannot be compiled for the web, which is the whole reason
  /// `alteri_one_platform` has a web implementation. A test is not shipped, is never linked
  /// into the product, and is allowed to read a file off disk — a contract test that
  /// cross-checks a library against a table in `docs/` has to, and forbidding it would mean
  /// either shipping a second copy of that table or giving up the check.
  ///
  /// A `dart:io` import in `lib/` is still caught, so nothing about the property is weakened:
  /// a test cannot become part of the artefact.
  Set<String> get imports {
    final found = <String>{};
    final lib = Directory('$path/lib');
    if (!lib.existsSync()) return found;
    for (final file in _dartFilesIn(lib)) {
      for (final match in _importPattern.allMatches(file.readAsStringSync())) {
        found.add(match.group(1)!);
      }
    }
    return found;
  }

  /// Every library URI imported or exported anywhere in the package, tests included.
  ///
  /// For the checks that are about the *repository* rather than the artefact — which
  /// subproject a file belongs to, for instance. The dependency rules use [imports].
  Set<String> get importsIncludingTests {
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
        final member = _Member(path, _readPubspec('$path/pubspec.yaml'));
        members[path] = member;
        // Recorded as it is found, so a manifest read later can tell a workspace sibling from
        // a third-party package without going through the map that is still being built.
        workspaceNames.add(member.name);
        // The second index, by name rather than by path: the closure walk starts from an import
        // and needs the member's `lib/`, and the map being built here is keyed by path.
        workspaceNamesByPath[member.name] = member;
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

/// Whether [file] spells the product name **in code** rather than in a comment or a string.
///
/// The rule is about identifiers, so this strips the two things an identifier is not and asks again.
/// A single-pass scanner rather than a regular expression, because the three cases interact: a `//`
/// inside a string is part of the string, an apostrophe inside a comment is not a quote, and Dart's
/// block comments nest. Getting any of those wrong produces either a false positive on a correctly
/// spelled package or — worse — a false negative that hides the identifier the rule exists to find.
///
/// Two documented limits, both harmless for this rule and both stated rather than left to a reader:
///
/// - An interpolated expression inside a string is treated as part of the string, so
///   `'$someIdentifier'` is not inspected. A product-spelled identifier would have to be interpolated
///   to get past this, which is not a mistake anyone makes by accident.
/// - Raw strings (`r'…'`) have no escapes, so a quote ends them; that is correct for raw strings and
///   the reason they need no escape handling. Triple quotes are handled, and that is not a
///   detail: without them this function had a silent false negative on an identifier after a
///   triple-quoted block containing an apostrophe -- strictly worse than the false positive it
///   replaced.
String _codeOnly(String source) {
  final out = StringBuffer();
  var index = 0;

  void blank(int count) {
    for (var offset = 0; offset < count; offset++) {
      final character = source[index + offset];
      // Newlines survive so that a finding's line number still means something in the original.
      out.write(character == '\n' ? '\n' : ' ');
    }
  }

  while (index < source.length) {
    final character = source[index];

    if (character == '/' && index + 1 < source.length) {
      if (source[index + 1] == '/') {
        while (index < source.length && source[index] != '\n') {
          blank(1);
          index++;
        }
        continue;
      }
      if (source[index + 1] == '*') {
        // Nesting matters: `/* a /* b */ c */` is one comment in Dart, and treating the inner `*/`
        // as the end would leave `c */` as code — where an identifier could hide.
        var depth = 0;
        while (index < source.length) {
          if (source.startsWith('/*', index)) {
            depth++;
            blank(2);
            index += 2;
          } else if (source.startsWith('*/', index)) {
            depth--;
            blank(2);
            index += 2;
            if (depth == 0) break;
          } else {
            blank(1);
            index++;
          }
        }
        continue;
      }
    }

    final isQuote = character == "'" || character == '"';
    final rawPrefix =
        character == 'r' &&
        index + 1 < source.length &&
        (source[index + 1] == "'" || source[index + 1] == '"');
    if (isQuote || rawPrefix) {
      final raw = rawPrefix;
      // The quote starts one past the `r` of a raw prefix and at the character itself otherwise, so
      // the triple-quote run is measured **from the quote** in both cases. Measuring it from `index`
      // while guarding on `!raw` looks equivalent and is not: `r'''...` was then read as a
      // single-quoted raw string that ended at the second quote of the run, which blanked almost
      // nothing and left the rest of the literal to be scanned as code.
      final quoteIndex = raw ? index + 1 : index;
      final quote = source[quoteIndex];
      // A run of three is a triple-quoted string. **This case is not optional**: reading ''' as
      // an empty string plus a string starting at the third quote ends it at the *first* apostrophe
      // in the body, so everything after it is read as code that has been correctly blanked -- and an
      // identifier after such a block is then invisible to the gate. A longer run is a syntax error
      // rather than a case worth handling, and taking the first three as the delimiter is the right
      // approximation of it.
      final quoteLength =
          quoteIndex + 2 < source.length &&
              source[quoteIndex + 1] == quote &&
              source[quoteIndex + 2] == quote
          ? 3
          : 1;
      final opener = quoteLength + (raw ? 1 : 0);
      blank(opener);
      index += opener;

      while (index < source.length) {
        if (!raw && source[index] == r'\') {
          // The backslash and whatever follows it, consumed together: an escape has to be
          // consumed or a quote would end the string early and the rest is read as code. A
          // backslash-newline is one unit, so its newline is blanked too -- the only case where
          // the length-preserving property does not hold, and it is a line continuation.
          final escapeLength = index + 1 < source.length ? 2 : 1;
          blank(escapeLength);
          index += escapeLength;
          continue;
        }
        if (source.startsWith(quote * quoteLength, index)) {
          blank(quoteLength);
          index += quoteLength;
          break;
        }
        blank(1);
        index += 1;
      }
      continue;
    }

    out.write(character);
    index += 1;
  }
  return out.toString();
}

/// Whether [file] carries the product spelling outside a comment and outside a string.
bool _spellsTheProductNameInCode(File file) =>
    _codeOnly(file.readAsStringSync()).contains('alterione');

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
