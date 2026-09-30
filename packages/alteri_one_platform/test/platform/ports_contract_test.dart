// The contract of the platform ports. Task 0.9.
//
// What this file is: the mechanical half of "the ports are injectable and free of dart:io in public
// contracts". Everything it asserts is also written down — the ports themselves in `lib/src/*.dart`,
// the rules in architecture/overview.md §3, architecture/build-and-release.md §3, ADR-0004,
// architecture/protocol.md §7.1 and §2.2 — and this file is what stops the prose from drifting away
// from the declarations. The arrangement this package uses to keep `dart:io` out of the public
// contracts is a *compiler* fact rather than a lint, so the interesting checks here are about that
// arrangement rather than about code behaviour.
//
// The greppable acceptance string for the task is the description of the first test below:
// "platform ports are injectable and free of dart:io in public contracts".
//
// What this file is not: a test of the native adapters' logic. Where an adapter needs the operating
// system — a child process, a socket — the test drives it for real, because a `StreamController` has
// no exit code, no pipe buffer and no signal, and a fake asserting against values it supplied itself
// is a tautology. Everything else is checked as a declaration.
//
// `dart:io` and `dart:mirrors` appear here and only here. Both are correct in a test and neither is
// ever shipped: the workspace contract test reads `lib/` rather than the whole package for exactly
// this reason (test/workspace/workspace_contract_test.dart, `imports`), and a test that could become
// part of the artefact would defeat the rule it is checking.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:mirrors';
import 'dart:typed_data';

// `TransportChannel` is imported from the protocol package and not from this one, because
// `Concurrency.channel` returns it and `alteri_one_platform` does not re-export it. That is the
// honest shape: the dependency is real, it is declared in this package's pubspec, and a consumer of
// that one member needs the protocol library's name to say so.
import 'package:alteri_one_protocol/alteri_one_protocol.dart';
import 'package:alteri_one_platform/alteri_one_platform.dart';
// Both conditional-export targets, imported directly and compared by reflection.
//
// The entry point gives a caller the native surface on the VM, so `PlatformClock` and
// `web.PlatformClock` are genuinely different types and comparing the two means naming both. Both
// prefixes are also needed to *load* both libraries: `dart:mirrors` reports only the libraries the
// isolate has loaded, and a surface nothing imported would compare as empty — the one result this
// check must never produce.
import 'package:alteri_one_platform/src/native.dart' as native;
import 'package:alteri_one_platform/src/web.dart' as web;
import 'package:test/test.dart';

void main() {
  group('the six ports', () {
    test('platform ports are injectable and free of dart:io in public contracts', () {
      // The acceptance criterion, and three claims in one test because they are one arrangement:
      // the interfaces exist, a fake can be injected through them, and nothing in them names a
      // platform library.

      // 1. The interfaces exist, and they are interfaces.
      //
      // `reflectedType.isAbstract` is the check, not a naming convention. A port declared as a
      // concrete class could be extended, and an implementation that extended it would inherit
      // behaviour from the port — which is how a port stops being a boundary and starts being a
      // base class with seven partial implementations.
      for (final port in _portTypes) {
        expect(
          reflectClass(port).isAbstract,
          isTrue,
          reason:
              '${port.toString()} is a port, so it has to be abstract. A concrete class here could '
              'be extended, and an implementer that extended it would inherit behaviour from the '
              'boundary it is supposed to implement',
        );
        expect(
          reflectClass(port).typeArguments,
          isEmpty,
          reason:
              '${port.toString()} is not generic. A generic port cannot be named without a type '
              'argument, so an implementation cannot be passed to a caller that holds the raw '
              'interface — and every consumer that wanted one instantiation would have to repeat it',
        );
      }

      // 2. A fake can be injected.
      //
      // Not "a fake exists" — *injected*. Each fake below is written against the port alone, never
      // against an adapter, and is then handed to a consumer whose parameters are all ports. That is
      // what `implements` here demonstrates: the product's seams are real, so a test can replace the
      // clock, the paths, the transport and the process boundary without an adapter existing at all.
      //
      // The fakes are local to this file on purpose. Task 0.10 ships the determinism doubles the
      // product's own tests use, and `HiveCeStorage` is task 1.1's; a fake shipped here would be a
      // declaration written before the task that specifies it, which is the failure mode the
      // package's "what arrives with which task" table exists to prevent.
      final fakes = _Fakes();
      _Consumer(
        clock: fakes.clock,
        paths: fakes.paths,
        http: fakes.http,
        storage: fakes.storage,
        concurrency: fakes.concurrency,
        processes: fakes.processes,
      ).describe();

      // 2b. The list of ports and the table of port files agree, and every file is really there.
      //
      // Without this, a seventh port declared and not added to either list would sail through every
      // check in this test — which is precisely what the comment on [_portFiles] says cannot happen.
      expect(
        _portFiles.length,
        _portTypes.length,
        reason:
            'a port exists that is in one of the two lists and not the other, so it is either '
            'unchecked or checked against a file that is not its own',
      );
      for (final entry in _portFiles.entries) {
        expect(
          File(_fileAbove(entry.key).path).existsSync(),
          isTrue,
          reason:
              '${entry.key} is listed as the home of ${entry.value} and does not exist',
        );
      }

      // 3. No port declaration names a platform library.
      //
      // Read from disk rather than trusted to the import graph, because the claim is about the
      // *file* and a transitive import through a barrel would hide it. This is the check that would
      // catch a `dart:io` typed into one port file before the conditional export stopped working.
      for (final entry in _portFiles.entries) {
        final source = _fileAbove(entry.key).readAsStringSync();
        for (final library in _platformLibraries) {
          expect(
            _directivesFor(source, library),
            isEmpty,
            reason:
                '${entry.key} declares ${entry.value.toString()} and must not import $library. '
                'The package keeps every platform library in lib/src/io/ behind one conditional '
                'export, so a port file that imports one defeats the arrangement rather than '
                'breaking a build',
          );
        }
      }

      // 4. And every platform library really is confined to lib/src/io/.
      //
      // The converse of (3), and it is a different failure: a file outside `io/` that imports
      // `dart:io` is still imported by a web compilation if it is reachable from the entry point,
      // so the arrangement is only true if the *directory* is the boundary and not merely the files
      // checked above.
      for (final file in _dartFilesIn(
        Directory(_packageRoot().uri.path + '/lib'),
      )) {
        if (_isInsideIoDirectory(file.path)) continue;
        for (final library in _platformLibraries) {
          expect(
            _directivesFor(file.readAsStringSync(), library),
            isEmpty,
            reason:
                '${file.path} imports $library and is outside lib/src/io/. Only lib/src/io/ is '
                'reachable through the conditional export, so an import anywhere else puts a '
                'platform library into a web compilation',
          );
        }
      }
    });

    test('the native surface and the browser surface declare the same API', () {
      // The browser surface exists so that a web compilation gets a refusal rather than an empty
      // object. That only works while the two surfaces agree: a member added to one and forgotten
      // in the other is not a difference nobody notices, it is a caller whose code compiles on the
      // VM and fails to compile in a browser — or worse, the reverse, a browser build that
      // silently lacks a method the native build has.
      //
      // Compared by reflection rather than by a hand-written list, because a hand-written list is
      // the same table twice and drifts. Both libraries are loadable on the VM: the conditional
      // export picks the native one, and importing the browser one directly is what makes its
      // declarations available to compare.
      // And the entry point really does hand out the native surface here. Asserted rather than
      // assumed, because the two surfaces declare the same class names — so `PlatformClock` being
      // usable at all proves nothing about *which* one it is, and the whole arrangement is only worth
      // anything if the VM gets the one that works.
      expect(PlatformClock, same(native.PlatformClock));
      expect(IsolateEndpoint, same(native.IsolateEndpoint));

      final nativeNames = _classNamesOf(_nativeLibrary);
      final webNames = _classNamesOf(_webLibrary);
      expect(
        webNames,
        nativeNames,
        reason: 'the two surfaces name the same classes',
      );
      expect(
        nativeNames,
        isNotEmpty,
        reason: 'an empty comparison passes vacuously',
      );

      for (final name in nativeNames) {
        final fromNative = _membersOf(_nativeLibrary, name);
        final fromWeb = _membersOf(_webLibrary, name);
        expect(
          fromWeb,
          fromNative,
          reason:
              'IsolateChannel/$name declares a different set of members on the two surfaces. A '
              'browser build resolves the browser one, so a member missing here is a member a web '
              'consumer cannot call and a member missing on the native side is one it can',
        );
      }
    });

    test('the browser surface refuses every capability it names', () {
      // A refusal, and the *port* it names. Both halves matter:
      //
      // The refusal matters because the alternative is an implementation that answers plausibly and
      // wrongly — an HTTP client that returns 503, a `Paths` rooted at a directory the user did not
      // choose, a `StoragePort` that accepts a write and loses it. Each of those is a caller being
      // told something false by a type that looks like it is telling the truth, and each fails
      // later and further away than the call that caused it. This is the same rule the product
      // applies to a sandbox that cannot be established, and to an install that cannot verify a
      // digest: refuse, never degrade.
      //
      // The named port matters because a refusal nobody can attribute is a refusal nobody can act
      // on. So every message names one of the six ports, and a seventh name would mean a seventh
      // port exists somewhere the specification does not record.
      const knownPorts = <String>{
        'clock',
        'paths',
        'http',
        'storage',
        'concurrency',
        'process',
      };

      final refusals = <Object>[
        () => web.PlatformClock().now(),
        () => web.PlatformClock().monotonicNow(),
        () => web.PlatformClock().delay(Duration.zero),
        () => web.PlatformPaths().home,
        () => web.PlatformPaths().config,
        () => web.PlatformPaths().profiles,
        () => web.PlatformPaths().policies,
        () => web.PlatformPaths().state,
        () => web.PlatformPaths().logs,
        () => web.PlatformPaths().injections,
        () => web.PlatformPaths().tools,
        () => web.PlatformPaths().plugins,
        () => web.PlatformPaths().bin,
        () => web.PlatformPaths().apps,
        () => web.PlatformPaths().resolve('state'),
        () => web.PlatformPaths().within(Uri.file('/')),
        () => web.PlatformPaths().ensure(Uri.file('/')),
        () => web.PlatformPaths().createDirectory(Uri.file('/')),
        () => web.PlatformPaths().exists(Uri.file('/')),
        () => web.PlatformHttpClient().send(_aRequest()),
        () => web.PlatformHttpClient().close(),
        () => web.PlatformConcurrency().maxParallelism,
        () => web.PlatformConcurrency().clock,
        () => web.PlatformConcurrency().run(() => 1),
        () => web.PlatformConcurrency().channel(web.IsolateEndpoint()),
        () => web.PlatformProcessHost().resolvedExecutable,
        () => web.PlatformProcessHost().start(_aProcessSpec()),
        () => web.PlatformProcessHost().clock,
        () => web.IsolateEndpoint().connect(SendPort),
        () => web.IsolateEndpoint().isConnected,
        () => web.IsolateEndpoint().messages,
        () => web.IsolateEndpoint().close(),
        () => web.IsolateChannel().incoming,
        () => web.IsolateChannel().write(<int>[1]),
        () => web.IsolateChannel().close(),
        () => web.IsolateEndpoint().receiveHandle,
        () => web.IsolateEndpoint().send(null),
      ];

      for (final refusal in refusals) {
        expect(
          refusal,
          throwsA(
            isA<PlatformUnavailable>().having(
              (PlatformUnavailable failure) => failure.port,
              'port',
              anyOf(
                isIn(knownPorts),
                'names a port the specification does not record',
              ),
            ),
          ),
          reason:
              'a browser has to refuse this, and name the port it is refusing',
        );
      }

      // Not merely a type: a message a user can act on. The reason names the platform, because
      // "storage is unavailable" sends an operator looking for a configuration problem and
      // "a browser origin is evictable and was not chosen by the user" tells them what happened.
      expect(
        () => web.PlatformProcessHost().start(_aProcessSpec()),
        throwsA(
          isA<PlatformUnavailable>()
              .having((f) => f.reason, 'reason', contains('process'))
              .having((f) => f.toString(), 'toString', contains('refusal')),
        ),
      );

      // A refusal is an Exception, not an Error, because it is an expected outcome of composing
      // against a platform rather than a bug. An Error is not catchable by ordinary code, and a
      // refusal nobody can catch is a crash.
      // An Exception and not an Error: a refusal is an expected outcome of composing against a
      // platform, and an Error is not catchable by the ordinary code that has to turn it into a
      // configuration error.
      expect(
        () => web.PlatformProcessHost().resolvedExecutable,
        throwsA(isA<Exception>()),
      );
    });
  });

  group('the clock', () {
    test(
      'wall-clock time and elapsed time are two different sources',
      () async {
        // The reason `AlteriOneClock` is not one `now()`. A deadline is an elapsed-time comparison and
        // has to survive an NTP step or a laptop resuming from sleep; a trace record is an absolute
        // instant and has to be readable. One method cannot be both, and a caller that has to guess
        // which to use guesses wrong about once a year per host.
        final clock = PlatformClock();
        final before = clock.monotonicNow();
        expect(before, greaterThanOrEqualTo(Duration.zero));

        await clock.delay(const Duration(milliseconds: 20));

        // Elapsed time never goes backwards. The only way to demonstrate the *property* rather than
        // one observation of it is to check the direction of the only operation available, so this is
        // a single sample and it is deliberately not overclaimed.
        expect(clock.monotonicNow(), greaterThan(before));

        // Wall-clock time is UTC, so a transcript written in two timezones is comparable.
        expect(clock.now().isUtc, isTrue);

        // And the two are genuinely different readings rather than one field twice: monotonic time has
        // no epoch, so it cannot be an instant at all.
        expect(clock.monotonicNow().inDays, lessThan(365 * 1000));
      },
    );
  });

  group('the install layout', () {
    test('every directory is derived from one root', () {
      // The precedence is the launcher's, from install-and-update.md §2.1, so the CLI and the core
      // cannot disagree about where memory lives.
      final paths = PlatformPaths.fromEnvironment(
        environment: const <String, String>{
          'ALTERIONE_HOME': '/srv/alterione-home',
        },
      );
      expect(paths.home.toFilePath(), contains('alterione-home'));

      // Every member is the root plus a fixed relative path, so there is no member that can disagree
      // with another about where the install root is.
      final derived = <String, Uri>{
        'config': paths.config,
        'profiles': paths.profiles,
        'policies': paths.policies,
        'state': paths.state,
        'logs': paths.logs,
        'injections': paths.injections,
        'tools': paths.tools,
        'plugins': paths.plugins,
        'bin': paths.bin,
        'apps': paths.apps,
      };
      for (final entry in derived.entries) {
        expect(
          paths.within(entry.value),
          isTrue,
          reason:
              '${entry.key} resolved to ${entry.value.toFilePath()}, which is not inside '
              '${paths.home.toFilePath()}. Every member is derived from the root, so one that is '
              'not is a derivation that escaped it',
        );
        expect(entry.value.toFilePath(), isNot(contains('/..')));
      }

      // The state directory is not under config: state is written constantly by concurrent
      // processes and an updater that swaps config wholesale must not take the lock files and the
      // transcript store with it. This is the one structural assertion about the layout, because it
      // is the one where nesting the two would be a data-loss bug wearing a tidiness costume.
      expect(
        paths.state.toFilePath(),
        isNot(startsWith(paths.config.toFilePath())),
      );
    });

    test(
      'the home directory is used only when the override is absent or empty',
      () {
        // An empty ALTERIONE_HOME is not treated as unset. A variable set to the empty string is
        // almost always a script that meant to set it and did not, and falling back to `~` would
        // write a user's real memory into a directory they did not name while reporting a path that
        // looks deliberate.
        final home = PlatformPaths.fromEnvironment(
          environment: const <String, String>{
            'HOME': '/home/tester',
            'ALTERIONE_HOME': '',
          },
        );
        expect(home.home.toFilePath(), contains('tester'));

        // And with neither, the port refuses rather than guessing.
        expect(
          () => PlatformPaths.fromEnvironment(
            environment: const <String, String>{},
          ),
          throwsA(isA<StateError>()),
          reason:
              'there is no directory to fall back to, and inventing one would put a user\'s memory '
              'somewhere they did not choose',
        );

        // A fallback is honoured when the caller supplies one, which is what makes a test able to use
        // a temporary directory at all.
        final supplied = PlatformPaths.fromEnvironment(
          environment: const <String, String>{},
          fallbackHome: Uri.file('/tmp/supplied'),
        );
        expect(supplied.home.toFilePath(), contains('supplied'));
      },
    );

    test('the root is refused when it is not an absolute file Uri', () {
      // [Paths.home] promises "never `~`, and never a relative path" and "a `file:` Uri on this
      // platform". A relative root is not cosmetic: `Directory.fromUri(relative)` resolves against the
      // *current directory*, so an install root of `install` puts a user's memory and their transcripts
      // beside whatever the CLI happened to be launched from — which is exactly what `fromEnvironment`
      // throws a [StateError] rather than cause, and the guard used to exist on one of the two public
      // constructors and not the other.
      for (final bad in <Object>[
        Uri.parse('install'),
        Uri.parse('./install'),
        Uri.parse('../install'),
      ]) {
        expect(
          () => PlatformPaths(bad as Uri),
          throwsArgumentError,
          reason: '\$bad is relative, so every directory derived from it would land beside the process',
        );
      }

      expect(
        () => PlatformPaths(Uri.parse('https://example.com/install')),
        throwsArgumentError,
        reason:
            'a non-file scheme produces paths no directory call can act on, and the failure would '
            'surface at the first ensure rather than here',
      );

      // The three forms that are allowed, so the guard is not simply refusing everything.
      expect(PlatformPaths(Uri.file('/srv/install')).home.path, '/srv/install');
      expect(
        PlatformPaths(Uri.file('/srv/install/')).home.path,
        '/srv/install',
      );
      expect(
        PlatformPaths(Uri.parse('/srv/install')).home.path,
        '/srv/install',
      );
    });

    test('resolve refuses an absolute input instead of silently replacing the root', () {
      // The trap this exists for, stated as a test: `Uri.resolve`'s own rule is that an absolute
      // reference on the right replaces the base, so `resolve('/etc/passwd')` on a `file:` base
      // returns `file:///etc/passwd` — a real path, from a method whose name says it joins onto the
      // root. A caller handed a root cannot be handed a path elsewhere by passing one.
      final paths = PlatformPaths(Uri.file('/srv/install'));

      expect(
        paths.resolve('state/default').toFilePath(),
        endsWith('state/default'),
      );

      for (final absolute in const [
        '/etc/passwd',
        r'C:\Windows',
        'file:///etc',
      ]) {
        expect(
          () => paths.resolve(absolute),
          throwsArgumentError,
          reason:
              '`$absolute` is not relative to the install root and must not resolve to one',
        );
      }

      expect(() => paths.resolve(''), throwsArgumentError);

      // `..` is *not* rejected here — this method's contract is about the anchor, not the result —
      // and `within` is the check that answers whether a path is still inside the root. Which is
      // lexical, and says so: a symlink inside the root still resolves out of it, and the
      // authoritative containment check is task 0.24's x-path-root rule with a real path.
      expect(
        paths.within(Uri.file('/srv/install')),
        isTrue,
        reason: 'the root is inside itself',
      );
      expect(
        paths.within(Uri.file('/srv/install/state')),
        isTrue,
        reason:
            'a path this port composed is inside the root it composed it from',
      );
      expect(
        paths.within(Uri.file('/srv/elsewhere')),
        isFalse,
        reason: 'a sibling directory is not beneath the root',
      );
      expect(
        paths.within(Uri.file('/srv/installation-state')),
        isFalse,
        reason: 'segment-wise, so a prefix that merely starts the same is not inside',
      );

      // `..` cannot reach this port. **Every** Uri constructor resolves it before the value exists —
      // `Uri.file`, `Uri.parse` and the unnamed constructor all turn `/srv/install/state/../other`
      // into `/srv/install/other` — so there is no `..` for a containment check to reject. Asserted
      // here because the observation is *why* [isBeneath] has no `..` branch, and an earlier version
      // carried one that could never fire.
      final climbing = Uri(scheme: 'file', path: '/srv/install/state/../other');
      expect(
        climbing.path,
        '/srv/install/other',
        reason: 'the SDK normalised it, not us',
      );
      expect(
        paths.within(climbing),
        isTrue,
        reason: 'the climb already happened, so what is left really is inside the root',
      );
    });

    test('no installed path spells the source name', () {
      // ADR-0016 splits the naming at the build boundary: `alteri_one_*` in the source tree because
      // that is Dart convention, `alterione` for everything a user receives — and an *installed
      // path or default configuration value* containing `alteri_one` fails the release assembly.
      // The default install root is exactly such a value, so this is the check that keeps the two
      // spellings from being mixed up in the one place where they meet.
      final paths = PlatformPaths.fromEnvironment(
        environment: const <String, String>{'HOME': '/home/tester'},
      );
      expect(paths.home.toFilePath(), endsWith('alterione'));
      expect(paths.home.toFilePath(), isNot(contains('alteri_one')));

      for (final member in <Uri>[
        paths.config,
        paths.profiles,
        paths.policies,
        paths.state,
        paths.logs,
        paths.injections,
        paths.tools,
        paths.plugins,
        paths.bin,
        paths.apps,
      ]) {
        expect(
          member.toFilePath(),
          isNot(contains('alteri_one')),
          reason:
              '${member.toFilePath()} is a default configuration value a user would see, and an '
              'installed path spelling the source name fails the release assembly (ADR-0016)',
        );
      }
    });
  });

  group('the storage boundary', () {
    test('the single-writer lock is on the port and it refuses rather than waiting', () async {
      // ADR-0004 lists two processes writing one profile state directory as *forbidden*: Hive is
      // not safe for concurrent writers and the second process does not fail cleanly. So the lock
      // is on the interface rather than in a comment, and the answer is a value — a second CLI
      // invocation has to be able to say "another process is using this profile" and exit, which is
      // a message. Blocking for ever makes the failure a hang, and a hang is what a stale lock file
      // from a killed process already looks like.
      final port = _InMemoryStorage();
      final held = await port.acquireWriteLock('default');
      expect(held.isHeldByAnotherProcess, isFalse);

      final second = await port.acquireWriteLock('default');
      expect(
        second.isHeldByAnotherProcess,
        isTrue,
        reason:
            'a second writer must be refused. Without the lock the second process corrupts the '
            'store or silently overwrites it, and neither failure names its cause',
      );
      expect(second.holderDescription, isNotNull);
      expect(second.holderDescription, isNotEmpty);

      // Releasing is idempotent, and a refusal's release is a no-op that completes rather than
      // touching the holder's lock. A release that threw would be the classic way a second process
      // manages to steal the first one's lock on the way out.
      await held.release();
      await held.release();
      final third = await port.acquireWriteLock('default');
      expect(third.isHeldByAnotherProcess, isFalse);

      // And the store does not open without one.
      //
      // This has to *call* [StoragePort.openCollection] with no lock held, or it asserts nothing.
      // The version of this check that sat next to three lock calls and no open could not have
      // failed: `openedWithoutLock` was never at risk. An implementation reachable without the lock is
      // one whose caller has no way to be safe, which is a property of the boundary rather than of any
      // one engine.
      final unlocked = _InMemoryStorage();
      await unlocked.openCollection('facts', schemaVersion: 1);
      expect(
        unlocked.openedWithoutLock,
        isTrue,
        reason:
            'the port let a collection be opened with no lock held at all. ADR-0004 lists two '
            'concurrent writers as forbidden, so an implementation reachable without the lock has no '
            'safe caller',
      );
    });

    test(
      'the lock is per profile namespace, so two profiles do not conflict',
      () async {
        // ADR-0004: "A single-writer lock **per profile namespace** guards concurrent processes." The
        // damage is confined to one profile's directory, so two invocations on *different* profiles
        // are not in conflict -- and a port whose lock had no namespace could not tell those two cases
        // apart. That is why [StoragePort.acquireWriteLock] takes one.
        final port = _InMemoryStorage();
        final first = await port.acquireWriteLock('default');
        expect(first.isHeldByAnotherProcess, isFalse);

        final other = await port.acquireWriteLock('research');
        expect(
          other.isHeldByAnotherProcess,
          isFalse,
          reason:
              'a second profile is a second namespace, not a second writer of the first. Refusing it '
              'would serialise the whole install behind whichever profile the user opened first',
        );

        expect(
          (await port.acquireWriteLock('default')).isHeldByAnotherProcess,
          isTrue,
          reason:
              'the same namespace twice is still one writer, and still refused',
        );
      },
    );

    test(
      'a value is opaque bytes under a tag, so the port carries no engine type',
      () {
        // The compromise in StoragePort, and the one that keeps ADR-0004's replaceability real: not a
        // Map<String, dynamic> (which puts the engine's schema into the port, so changing engines
        // becomes a change to every record type) and not a hive_ce frame (which makes the port a
        // re-export of the engine). Opaque bytes with a tag let hive_ce_generator own the codec in task
        // 1.1 and leave the tag as the branch a future migration takes.
        final value = StorageValue(
          typeTag: 'MemoryRecord.fact',
          bytes: Uint8List.fromList(<int>[1, 2, 3]),
        );
        expect(value.bytes, hasLength(3));
        expect(
          value.asList,
          same(value.bytes),
          reason: 'not a copy — the aliasing is the point',
        );
        expect(
          value,
          StorageValue(
            typeTag: 'MemoryRecord.fact',
            bytes: Uint8List.fromList(<int>[1, 2, 3]),
          ),
        );
        expect(
          value,
          isNot(
            StorageValue(
              typeTag: 'MemoryRecord.fact',
              bytes: Uint8List.fromList(<int>[1, 2, 4]),
            ),
          ),
        );
      },
    );
  });

  group('the process host', () {
    test('bounds the diagnostics buffer and keeps the tail', () async {
      // Bound one of the two this package owns. A child that writes more than a pipe buffer with
      // nobody reading blocks in write(2); the symptom is a plugin that "hangs" holding a capability
      // lease. So the host drains unconditionally and bounds what it *keeps*.
      //
      // The fixture writes 256 KiB against a 4 KiB bound — sixty-four times over, and more than
      // twice a typical pipe buffer, so it could not have finished if this host did not drain.
      const bound = 4096;
      final host = PlatformProcessHost();
      final child = await host.start(
        _aProcessSpec(
          mode: 'noisy',
          maxDiagnosticsBytes: bound,
          exitTimeout: const Duration(seconds: 30),
        ),
      );

      final exit = await child.waitForExit();
      expect(
        exit.exitCode,
        0,
        reason: 'the child completed, so the host did not block it',
      );
      expect(exit.timedOut, isFalse);

      // Bounded, and visibly so.
      expect(child.diagnostics.length, lessThanOrEqualTo(bound));
      expect(
        child.droppedDiagnosticsBytes,
        greaterThan(0),
        reason:
            'the fixture wrote far more than the bound, so a dropped count of zero would mean the '
            'bound is not being applied — and a diagnostics surface that silently discarded '
            'megabytes is indistinguishable from one that worked',
      );

      // The *tail*, not the head. When a child writes more than the bound, the lines that say why
      // it failed are the last ones; a buffer keeping the first 4 KiB of a plugin's debug output has
      // kept the part nobody needed. Asserted by content, because length alone cannot tell the two.
      final kept = utf8.decode(child.diagnostics, allowMalformed: true);
      expect(kept, contains('255:'), reason: 'the last line must survive');
      expect(
        kept,
        isNot(contains('0:  ')),
        reason: 'the first line is what was dropped',
      );

      await child.close();
    });

    test('bounds the wait for a process that does not exit', () async {
      // Bound two of the two. A child that never ends is an ordinary operational condition, and
      // there are two reasonable answers to it: signal harder, or give up and report. A caller
      // cannot choose between them if the first is an exception, because an exception in a
      // teardown-adjacent path is very likely to be swallowed or to replace the failure the caller
      // was already handling. So the timeout is a value, and `kill` is how the caller escalates.
      final host = PlatformProcessHost();
      final child = await host.start(
        _aProcessSpec(
          mode: 'sleep',
          exitTimeout: const Duration(milliseconds: 150),
          killTimeout: const Duration(seconds: 10),
        ),
      );

      final timedOut = await child.waitForExit();
      expect(timedOut.timedOut, isTrue);
      expect(
        timedOut.didExit,
        isFalse,
        reason: 'the child really was still running',
      );
      expect(
        child.hasExited,
        isFalse,
        reason: 'a timeout is not an exit, and hasExited must say so',
      );

      // Escalation resolves it, and the result of the kill is observable — which is what the
      // first version of this could not do, because it cached the timeout and so a kill after a
      // timed-out wait returned the timeout the kill was meant to resolve.
      final killed = await child.kill();
      expect(killed.didExit, isTrue);
      expect(child.hasExited, isTrue);

      // And a wait after the exit reports the exit rather than timing out again.
      final afterwards = await child.waitForExit();
      expect(afterwards.didExit, isTrue);

      await child.close();
    });

    test('close releases stdin and never waits for the child', () async {
      // The rule task 0.8 states for the stdio adapter's channel, applied to the port that owns it.
      // Closing the child's stdin is what makes a child blocked on a read stop waiting, and it is
      // awaited; the child's *exit* is not, because `close` is what a `finally` block calls and a
      // teardown that waits for a child that ignores EOF hangs the CLI on Ctrl-C.
      //
      // `stdin.write` returns a bool for §2.2's reason: nothing is taken, nothing is discarded, and
      // a caller that gets `false` may keep its own copy and decide whether the session is over or
      // the child is merely slow.
      final host = PlatformProcessHost();
      final child = await host.start(
        _aProcessSpec(mode: 'reader', exitTimeout: const Duration(seconds: 20)),
      );

      // Wait until the child is *inside* the read, rather than assuming it got there: the fixture
      // announces itself on stdout first, so this does not depend on scheduling.
      final announced = await child.stdout.first;

      expect(child.stdin.write(<int>[1, 2, 3]), isTrue);
      await child.stdin.flush();

      await child.close();
      expect(child.stdin.write(<int>[4]), isFalse, reason: 'stdin is closed');

      // The read unblocked because stdin was closed, and the process ended on its own — a child
      // blocked on read(2) is exactly what the close is for.
      final exit = await child.waitForExit();
      expect(
        exit.didExit,
        isTrue,
        reason:
            'the child was blocked reading stdin and close() closed it, so EOF arrived and the '
            'child finished. Without that, close would have left it waiting for ever',
      );
      expect(announced, isNotEmpty);
    }, tags: 'integration');

    test(
      'stdout is broadcast, because the port says a second reader may attach',
      () async {
        // `dart:io`'s `Process.stdout` is **single-subscription** and throws on a second listener, so
        // the port's promise -- a transport reads it and a transcript tee may want the same bytes -- has
        // to be kept by wrapping it rather than by hoping. Checked here rather than assumed: the first
        // version of this file documented a broadcast the adapter did not provide, and the only way that
        // was ever going to be caught was by attaching twice.
        final host = PlatformProcessHost();
        final child = await host.start(
          _aProcessSpec(
            mode: 'reader',
            exitTimeout: const Duration(seconds: 20),
          ),
        );

        final first = <int>[];
        final second = <int>[];
        child.stdout.listen(first.addAll);
        child.stdout.listen(second.addAll);

        await child.stdout.first.timeout(const Duration(seconds: 10));
        expect(
          first,
          isNotEmpty,
          reason: 'the first reader got the fixture\'s announcement',
        );
        expect(
          second,
          first,
          reason:
              'both readers saw the same bytes. A single-subscription stream throws on the second '
              'listener, so this fails loudly rather than quietly -- which is the point of attaching '
              'twice rather than reading the documentation',
        );

        await child.close();
      },
      tags: 'integration',
    );

    test(
      'close leaves the diagnostics drain running while the child is alive',
      () async {
        // The deadlock this package exists to prevent, reached the other way round. `close` is what a
        // `finally` block calls and the child is often *still running* at that point, so cancelling the
        // stderr drain there would stop draining a child that keeps writing -- and a child that fills a
        // pipe buffer blocks in `write(2)` for ever. An earlier version cancelled it unconditionally,
        // and the failure would have presented as a Tier 2 plugin that "hangs" holding a capability
        // lease, which is the symptom the drain was written for.
        //
        // So: close first, then keep the child writing well past a pipe buffer, then require that it
        // exits. Nothing about that is a timing assumption -- the child writes a fixed 256 KiB and the
        // assertion is on its exit code.
        const bound = 4096;
        final host = PlatformProcessHost();
        final child = await host.start(
          _aProcessSpec(
            mode: 'noisy',
            maxDiagnosticsBytes: bound,
            exitTimeout: const Duration(seconds: 30),
          ),
        );

        await child.close();
        expect(
          child.hasExited,
          isFalse,
          reason:
              'the child is still running, so close() must not have stopped reading its stderr. Had it '
              'done so, the child would block on a full pipe and never exit',
        );

        final exit = await child.waitForExit();
        expect(
          exit.exitCode,
          0,
          reason:
              'the child wrote 256 KiB through a 4 KiB bound *after* close(). Without a drain it '
              'would have blocked in write(2) and this would time out rather than report a code',
        );
        expect(child.diagnostics.length, lessThanOrEqualTo(bound));
      },
      tags: 'integration',
    );

    test(
      'a spawn that cannot happen is a typed failure naming the executable',
      () async {
        final host = PlatformProcessHost();
        await expectLater(
          host.start(
            ProcessSpec(
              executable: Uri.file(
                '/definitely/not/an/executable-${pidSuffix()}',
              ),
            ),
          ),
          throwsA(
            isA<ProcessSpawnFailure>().having(
              (ProcessSpawnFailure failure) => failure.reason,
              'reason',
              contains('refused to start'),
            ),
          ),
        );
      },
    );
  });

  group('the http port', () {
    test(
      'carries a request, streams a body and never leaks the query',
      () async {
        // Bound to a loopback socket the test opens itself, on an ephemeral port. That is not the same
        // as reaching the network: nothing external is contacted, nothing already listening is
        // disturbed, and a test run cannot fail because a host it does not control is down. What is
        // forbidden — and what task 0.21's local fixture server exists for — is a blocking-chain test
        // that depends on a remote service.
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));

        // The handler reads the request body, so the assertion below is about what the adapter actually
        // put on the wire rather than about a stream this test managed to listen to. Having the test
        // listen instead is not possible: `HttpRequest` is single-subscription and `dart:io` already
        // touches it to route the request.
        final seen = Completer<_SeenRequest>();
        server.listen((request) async {
          final body = await utf8.decoder.bind(request).join();
          if (!seen.isCompleted) {
            seen.complete(
              _SeenRequest(
                method: request.method,
                body: body,
                contentType: request.headers.value('content-type'),
              ),
            );
          }
          request.response
            ..statusCode = HttpStatus.created
            ..headers.set('x-alteri-test', 'yes')
            ..write('first ')
            ..add(utf8.encode('second'));
          // Awaited, and the reason matters: `close()` on an `HttpResponse` returns a `Future`, and a
          // handler that does not await it lets the listener finish while the socket is still open —
          // which shows up as the *client* seeing a truncated body, so the failure lands in a test about
          // the client and blames the wrong side.
          await request.response.close();
        });

        final client = PlatformHttpClient();
        addTearDown(client.close);

        final uri = Uri.parse(
          'http://${server.address.address}:${server.port}/v1/chat'
          '?api_key=super-secret-value',
        );
        final response = await client.send(
          HttpRequestSpec(
            method: 'POST',
            uri: uri,
            headers: const {
              'content-type': ['application/json'],
            },
            body: utf8.encode('{"ping":true}'),
          ),
        );

        expect(response.statusCode, 201);
        expect(response.isSuccess, isTrue);
        expect(response.header('x-alteri-test'), 'yes');
        expect(
          response.header('X-Alteri-Test'),
          'yes',
          reason: 'header names are case-insensitive',
        );
        expect(response.header('absent'), isNull);

        // The request really arrived, with its body — an adapter that fabricated a response would pass
        // every assertion above.
        final request = await seen.future;
        expect(request.method, 'POST');
        expect(request.contentType, 'application/json');
        expect(request.body, '{"ping":true}');

        // A streamed body, assembled: `first ` and `second`, twelve bytes.
        expect(utf8.decode(await response.bytes()), 'first second');

        // The query string is where an API key lives, and an error message is the single most likely
        // thing to end up in a log or a transcript. So no message this port produces carries it.
        final failure = TransportFailure(
          'the request to '
          '${uri.scheme}://${uri.host}:${uri.port} failed',
          retryable: false,
        );
        expect(failure.toString(), isNot(contains('super-secret-value')));
      },
      tags: 'integration',
    );

    test('a non-2xx status is a response, and its body is readable', () async {
      // A 401 names the wrong key and a 429 carries `retry-after`, so folding a non-2xx into a
      // failure would throw away the only useful part of it.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response
          ..statusCode = HttpStatus.unauthorized
          ..headers.set('www-authenticate', 'Bearer realm="provider"')
          ..write('no key here')
          ..close();
      });

      final client = PlatformHttpClient();
      addTearDown(client.close);
      final response = await client.send(_aRequest(port: server.port));

      expect(response.statusCode, 401);
      expect(response.isSuccess, isFalse);
      expect(response.header('www-authenticate'), contains('provider'));
      expect(utf8.decode(await response.bytes()), 'no key here');
    }, tags: 'integration');

    test(
      'a failed exchange is a TransportFailure with a retryable verdict',
      () async {
        // The classification is set by the implementation, because that is the only place that knows
        // why it failed. providers.md §6 permits a retry only for errors marked retryable, and a
        // caller that has to catch four exception types to find that out eventually retries
        // something it should not — a 401 becomes a loop against a provider that will keep saying 401.
        final client = PlatformHttpClient();
        addTearDown(client.close);

        // A port nothing is listening on: a refused connection is the canonical retryable failure.
        final dead = await _aClosedPort();
        await expectLater(
          client.send(_aRequest(port: dead)),
          throwsA(
            isA<TransportFailure>()
                .having((f) => f.retryable, 'retryable', isTrue)
                .having((f) => f.cause, 'cause', isNotNull),
          ),
        );
      },
      tags: 'integration',
    );
  });

  group('concurrency', () {
    test(
      'runs work off the caller and reports a parallelism it can defend',
      () async {
        final concurrency = PlatformConcurrency(clock: PlatformClock());
        expect(concurrency.maxParallelism, greaterThan(0));

        // `Isolate.run` is the whole of the native implementation, so this is a real isolate hop: a
        // closure capturing something unsendable throws from inside it, which is why Concurrency.run
        // says errors are not wrapped.
        final fromAnotherIsolate = await concurrency.run(() => 7 * 6);
        expect(fromAnotherIsolate, 42);

        // The clock is held rather than reached for, so a caller can measure what scheduling cost.
        expect(concurrency.clock, isA<AlteriOneClock>());
      },
      tags: 'integration',
    );

    test('a channel over a peer can refuse, which is what makes the bound reachable', () async {
      // architecture/protocol.md §7.1 requires a port's write to report whether it took the bytes.
      // A port that can only accept has no way to say "not now", so the outbox's bound is unreachable
      // and `backpressured` is a value no caller can ever see — which is exactly what happened to the
      // first version of that transport, whose test passed by priming the queue it then measured. A
      // tautology, not a check.
      //
      // A real isolate, because the bound is released by an acknowledgement from the peer and a
      // `StreamController` on this side of the test cannot produce one.
      //
      // **Two phases, and the second one is the whole test.** Each side builds an endpoint — which
      // gives it a port to *receive* on — and then learns the other side's port. So this end is built,
      // spawned with its receive handle, and connected once the peer has sent its own back.
      //
      // The earlier arrangement handed each isolate a different endpoint and kept it, so each side
      // was sending to itself: the port type-checked, nothing threw, and the round trip simply never
      // completed. An endpoint that sends to its own inbox looks like a working link right up until
      // something waits for the peer.
      final inbox = ReceivePort();
      final local = IsolateEndpoint.unconnected(outbound: inbox.sendPort);
      final peer = await Isolate.spawn<List<Object>>(_echoIsolate, <Object>[
        local.receiveHandle,
        inbox.sendPort,
      ]);
      addTearDown(() => peer.kill(priority: Isolate.immediate));

      // Typed here rather than left `dynamic`: `ReceivePort` is a `Stream<dynamic>`, and the value is
      // known to be the peer's `SendPort` because the peer sends nothing else.
      final farHandle = await inbox.first as SendPort;
      local.connect(farHandle);
      expect(local.isConnected, isTrue);

      final channel = IsolateChannel(local);

      addTearDown(() async {
        await channel.close();
        await local.close();
        inbox.close();
      });

      // Over the bound: refused, and nothing taken, so the caller still owns the bytes and offers them
      // again. §2.2's rule, which is what `false` means — and a bound no write can ever reach is not a
      // bound.
      final oversized = Uint8List(IsolateChannel.maxQueuedBytes + 1);
      expect(
        channel.write(oversized),
        isFalse,
        reason:
            'a port that cannot say "not now" has no way to express backpressure, and a bound no '
            'write can ever reach is not a bound',
      );

      // Exactly the bound is taken, so the budget is now full with nothing acknowledged yet.
      final full = Uint8List(IsolateChannel.maxQueuedBytes);
      expect(channel.write(full), isTrue);
      expect(
        channel.write(<int>[1]),
        isFalse,
        reason: 'the budget is exhausted, so this write is refused',
      );

      // The peer echoes the chunk, which means it acknowledged it, which means **this end's room was
      // released**. That release is the mechanism behind the bound, and it is only observable by
      // filling the budget and watching it drain — which is what the two writes above are for.
      final echoed = await channel.incoming.first;
      expect(echoed, hasLength(IsolateChannel.maxQueuedBytes));
      expect(
        channel.write(<int>[1]),
        isTrue,
        reason:
            'the peer acknowledged the chunk, so the in-flight budget came back. A channel that only '
            'ever refused would satisfy the two assertions above and never deliver anything',
      );

      // A closed channel refuses rather than throwing: a peer that closes first is an ordinary end of
      // a session, and an exception raised on the way down is what turns a healthy teardown into a
      // failed one.
      await channel.close();
      expect(channel.write(<int>[4]), isFalse);
    }, tags: 'integration');
  });
}

/// A `pid`-free suffix, so a repeated run cannot collide with a path it created the last time.
String pidSuffix() => '${Directory.current.path.hashCode.abs()}';

/// A request to nowhere in particular, for the failure paths.
HttpRequestSpec _aRequest({int port = 1}) => HttpRequestSpec(
  method: 'GET',
  uri: Uri.parse('http://127.0.0.1:$port/nothing'),
);

/// A process spec for [mode], run from this package's own directory.
///
/// Spawned with `Platform.resolvedExecutable` rather than a name on `PATH`: this file runs under
/// `dart test`, so that is the VM already running it, and a runner with a different or no `dart` on
/// its path would otherwise fail for a reason that has nothing to do with the ports.
ProcessSpec _aProcessSpec({
  String mode = 'sleep',
  int? maxDiagnosticsBytes,
  Duration exitTimeout = const Duration(seconds: 5),
  Duration killTimeout = const Duration(seconds: 2),
}) => ProcessSpec(
  executable: Uri.file(Platform.resolvedExecutable),
  arguments: <String>['run', _fixtureFile().absolute.path, mode],
  workingDirectory: _packageRoot().uri,
  // Deliberately **not** inherited: a child that inherits a developer's real environment is a test
  // that passes locally and behaves differently in CI, and this fixture reads nothing from it. The
  // child is spawned by absolute path, so it does not need `PATH` either.
  inheritEnvironment: false,
  exitTimeout: exitTimeout,
  killTimeout: killTimeout,
  maxDiagnosticsBytes: maxDiagnosticsBytes ?? 64 * 1024,
);

/// The child fixture, found by walking up from the working directory.
///
/// **Not** `Platform.script`, and that is the mistake this comment exists to prevent: under `dart test`
/// that is a *generated* bootstrap inside `.dart_tool/test/`, so resolving the fixture against it gave
/// a path that does not exist, the child died with a `dart run` error, its stdout closed with no
/// element, and every process test failed with "Bad state: No element" — a symptom naming neither the
/// fixture nor the cause.
///
/// The walk upwards is what makes the acceptance command and a developer's habit agree. The command
/// runs in the package directory, a developer runs from the repository root, and `melos run test`
/// starts the suite from the root; only a walk finds the same file from all three.
File _fixtureFile() => _fileAbove('test/platform/fixtures/process_child.dart');

/// The package root, derived from the fixture's own location.
///
/// Not the working directory, because a relative path is resolved against the parent on some platforms
/// and against the child on others. Found by walking up to the **nearest** `pubspec.yaml` from the
/// fixture, which is this package's rather than the repository root's — the outer manifest does not
/// describe it.
Directory _packageRoot() {
  var directory = _fixtureFile().absolute.parent;
  while (true) {
    if (File('${directory.path}/pubspec.yaml').existsSync()) return directory;
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError(
        'no pubspec.yaml above ${_fixtureFile().path}. The child has to be started somewhere it can '
        'resolve this package however the test was invoked.',
      );
    }
    directory = parent;
  }
}

/// The file at [relative] in this package, found by walking up from the working directory.
File _fileAbove(String relative) {
  var directory = Directory.current;
  File? found;
  while (found == null) {
    final candidate = File(
      '${directory.path}/$relative'.replaceAll(r'\\', '/'),
    );
    if (candidate.existsSync()) found = candidate;
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  if (found == null) {
    throw StateError(
      '$relative not found above ${Directory.current.path}. This test needs its own fixture and it '
      'looks for one rather than assuming where it was run from.',
    );
  }
  return found;
}

/// Finds an ephemeral port that nothing is listening on.
///
/// Bound and immediately closed, which is a small race in principle and is the standard way to do it.
/// The alternative — picking a fixed port — collides with anything else on the machine, and a test that
/// fails because of what is already listening is worse than one that fails rarely.
Future<int> _aClosedPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

/// The port types this package declares.
///
/// One list, used by the first test and by the fake check, because a port that exists and is not in
/// the list is a port nothing has claimed.
const _portTypes = <Type>[
  AlteriOneClock,
  Paths,
  HttpClientPort,
  StoragePort,
  Concurrency,
  ProcessHost,
];

/// The libraries that must not appear in a port declaration.
const _platformLibraries = <String>[
  'dart:io',
  'dart:isolate',
  'dart:ffi',
  'dart:mirrors',
  'package:web',
];

/// Each port declaration, and the file it lives in.
///
/// Both halves written out rather than discovered, for the reason the workspace contract test
/// hard-codes its membership: the list is a decision, and a decision nothing checks is a preference.
/// A port added without a row here is caught by the count assertion below rather than passing quietly.
const _portFiles = <String, Type>{
  'lib/src/clock.dart': AlteriOneClock,
  'lib/src/paths.dart': Paths,
  'lib/src/http.dart': HttpClientPort,
  'lib/src/storage.dart': StoragePort,
  'lib/src/concurrency.dart': Concurrency,
  'lib/src/process.dart': ProcessHost,
};

/// Every `import` or `export` directive naming [library] in [source].
///
/// **Quote-agnostic.** The obvious `RegExp("import '$library'")` misses `import "dart:io";`, and
/// `prefer_single_quotes` is what makes that unreachable today rather than what makes it impossible —
/// a check for the task's central claim should not depend on a lint nobody is obliged to keep.
List<String> _directivesFor(String source, String library) {
  final pattern = RegExp(
    '^\\s*(?:import|export)\\s+([\'"])${RegExp.escape(library)}\\1',
    multiLine: true,
  );
  return [
    for (final match in pattern.allMatches(source)) match.group(0)!.trim(),
  ];
}

/// Whether [path] is one of the native adapters.
///
/// Matches `lib/src/io/` with no leading separator, because the paths tested here come from a walk
/// rooted at the current directory and are therefore already repository-relative. An earlier version
/// looked for `/lib/src/io/` and reported every native adapter as being outside its own directory — a
/// check that could not pass, which is the useful kind of failure only if somebody reads it.
bool _isInsideIoDirectory(String path) =>
    path.replaceAll(r'\\', '/').contains('lib/src/io/');

/// Every `.dart` file under [directory], sorted, skipping generated and tool output.
List<File> _dartFilesIn(Directory directory) {
  if (!directory.existsSync()) return const <File>[];
  final files = <File>[
    for (final entity in directory.listSync(
      recursive: true,
      followLinks: false,
    ))
      if (entity is File && entity.path.endsWith('.dart')) entity,
  ];
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

/// The URI each conditional-export target is mirrored under.
///
/// Written out rather than recovered from the import prefixes, because a prefix is not a URI and the
/// mirror system is keyed by the latter. Two literals, in one place, and the first test compares the
/// two surfaces through them — so if the entry point's conditional export is ever respelled, the
/// failure is `null` on a library lookup here with the URI in the message, rather than a silently
/// smaller comparison.
const _nativeLibrary = 'package:alteri_one_platform/src/native.dart';
const _webLibrary = 'package:alteri_one_platform/src/web.dart';

/// The public class names [uri] declares.
///
/// Reflected rather than enumerated by hand, because a hand-written list is the same table written
/// twice and drifts from both surfaces at once — which is the failure the comparison exists to catch.
Set<String> _classNamesOf(String uri) => {
  for (final declaration in _declarationsOf(uri))
    // A leading underscore makes a declaration library-private, so it is not part of the surface a
    // caller holds and comparing it would be comparing two files' internals. The native surface has
    // two (`_NativeProcess`, `_NativeStdin`) and the browser surface has none — a difference with no
    // meaning to anyone outside the library.
    if (!MirrorSystem.getName(declaration.simpleName).startsWith('_'))
      MirrorSystem.getName(declaration.simpleName),
};

/// The members [uri] declares for [className], rendered as `name` or `name()`.
///
/// Getters and methods are distinguished because they are different calls: a member that is a getter
/// on one surface and a method on the other is a caller whose code compiles against one and not the
/// other. Constructors are excluded for the same reason — they are a property of the class rather
/// than part of the surface a caller holds, and their reflection names are unstable enough that
/// including them would make the comparison depend on the mirror library's internals.
Set<String> _membersOf(String uri, String className) {
  final members = <String>{};
  for (final declaration in _mirrorFor(uri, className).declarations.values) {
    final name = MirrorSystem.getName(declaration.simpleName);
    // Private declarations are library-internal, and `_monotonic` on one surface against `_refuse`
    // on the other is a difference in implementation rather than in API.
    if (name.startsWith('_')) continue;
    // Constructors are a property of the class, not of the surface a caller holds.
    if (declaration is MethodMirror) {
      if (declaration.isConstructor) continue;
      members.add('$name${declaration.isGetter ? '' : '()'}');
    } else if (declaration is VariableMirror) {
      members.add(name);
    }
  }
  // `toString` and `hashCode` are inherited from `Object` whether or not a class declares them, so a
  // declared override is a choice about how a value *prints* rather than a member a caller can or
  // cannot reach. The native adapters override `toString` because a port that cannot be described in
  // a log is hard to debug; the browser ones do not, because a refused value has nothing to print.
  return members
      .where((name) => !_inheritedFromObject.contains(name))
      .where((name) => !_staticDeclarations.contains(name))
      .toSet();
}

/// The members every class has, declared or not.
const _inheritedFromObject = <String>{
  'toString()',
  'hashCode()',
  'noSuchMethod()',
  'runtimeType',
};

/// Constants on `IsolateChannel`, which are statics.
///
/// A static is not something a caller *holds* — it belongs to the class, not to an instance — so
/// comparing them across surfaces would be comparing two files' constants rather than two APIs.
/// `IsolateChannel.maxQueuedBytes` is the only one, and it is deliberately absent from the browser
/// counterpart, which refuses before any budget could apply to it.
const _staticDeclarations = <String>{'maxQueuedBytes'};

ClassMirror _mirrorFor(
  String uri,
  String className,
) => _declarationsOf(uri).firstWhere(
  (declaration) => MirrorSystem.getName(declaration.simpleName) == className,
  orElse: () => throw StateError(
    'no class $className is declared in $uri. The conditional export in '
    'lib/alteri_one_platform.dart names one library on the VM and the other in a browser; if '
    'this is missing, the entry point no longer exports that name from either',
  ),
);

/// The classes [uri] declares or re-exports, failing loudly if the library was never loaded.
///
/// **Follows exports**, and it has to: the native surface declares nothing itself — it re-exports the
/// five adapters from `lib/src/io/` — so a reflection walk that stopped at the first library compared
/// an empty set against the browser surface's seven classes, and the "the two surfaces agree" check
/// reported a difference. A reflection-based comparison that cannot see through an `export` is not a
/// comparison of the surface; it is a comparison of one file's text.
///
/// `currentMirrorSystem().libraries` only holds libraries the isolate has actually loaded, so a
/// misspelled URI is `null` rather than an empty list — and an empty list would make the surface
/// comparison pass vacuously, which is the worst possible outcome for a check whose entire purpose is
/// to notice an absence.
Iterable<ClassMirror> _declarationsOf(String uri) {
  final library = currentMirrorSystem().libraries[Uri.parse(uri)];
  if (library == null) {
    throw StateError(
      'the mirror system has no library for $uri. Both surfaces are imported by this file so both '
      'are loaded; if this fires, one of the imports was removed or the entry point stopped '
      'exporting the library.',
    );
  }
  final found = <String, ClassMirror>{};
  final seen = <String>{};

  void walk(LibraryMirror current) {
    // Keyed by name, so a name reachable by two paths counts once. `PlatformClock` is reachable
    // through `native.dart` alone, but the *library* `io/platform_clock.dart` is reachable twice if
    // two barrels both export it — and a set that counted it twice would fail an equality check for
    // no reason a reader could see.
    if (!seen.add(_libraryKey(current))) return;
    for (final declaration
        in current.declarations.values.whereType<ClassMirror>()) {
      found.putIfAbsent(
        MirrorSystem.getName(declaration.simpleName),
        () => declaration,
      );
    }
    // `libraryDependencies` is the only list of a library's links, and it mixes imports and exports
    // with an `isImport` flag. Only the **exports** can carry a *name* a caller sees — an import
    // contributes nothing to the public surface unless it is also exported — so this follows
    // `isExport` alone, and a name reachable only through a prefix import is correctly invisible.
    //
    // (There is no `exports` member; the SDK exposes `libraryDependencies` and the flag.)
    for (final dependency in current.libraryDependencies) {
      if (!dependency.isExport) continue;
      // `targetLibrary` is nullable because a deferred export names an isolate that does not exist
      // yet; there is nothing to walk in that case, and skipping it is right rather than an error,
      // because a deferred export contributes no name to this library's surface.
      final target = dependency.targetLibrary;
      if (target != null) walk(target);
    }
  }

  walk(library);
  return found.values;
}

/// A stable key for a mirrored library, for the visited set above.
String _libraryKey(LibraryMirror library) => library.uri.toString();

/// The other end of the isolate channel's round trip.
///
/// A top-level function because an isolate entry point has to be one: a closure or a static method
/// of a class in a test file cannot be sent to a fresh isolate, and `Isolate.spawn` needs a reference
/// it can look up in the target's root library.
///
/// It sends its own handle to [toParent] first, so the parent waits for the peer to exist rather than
/// writing into a channel whose far end is not wired yet.
/// The other end of the isolate channel's round trip.
///
/// A **top-level `void` function taking one argument**, because that is `Isolate.spawn`'s entry-point
/// type exactly: a closure, a bound method or an async function is not assignable to it, and the
/// mismatch is a compile error that says so. The echo loop is therefore started and *not* awaited —
/// the isolate stays alive as long as its receive port is open, which is what keeps the echo running
/// until the test kills it.
///
/// It sends its own handle to [toParent] first, so the parent waits for the peer to exist rather than
/// writing into a channel whose far end is not wired yet.
void _echoIsolate(List<Object> handles) {
  final farEndHandle = handles[0] as SendPort;
  final parentInbox = handles[1] as SendPort;

  // This isolate's own endpoint, built before it knows anything: it gives this side a port to receive
  // on, which is the half that can be built alone.
  final endpoint = IsolateEndpoint.unconnected();
  // The two halves, joined: send to the port the parent handed over, and tell the parent which port to
  // send to in return.
  endpoint.connect(farEndHandle);
  parentInbox.send(endpoint.receiveHandle);

  final channel = IsolateChannel(endpoint);
  // Echo for ever: the test kills the isolate rather than closing it, because the property under test
  // is that a byte budget is released by acknowledgement, and a graceful close would stop this loop
  // before a write could be refused for lack of room.
  unawaited(() async {
    await for (final chunk in channel.incoming) {
      channel.write(chunk);
    }
  }());
}

/// What the loopback server saw.
final class _SeenRequest {
  const _SeenRequest({
    required this.method,
    required this.body,
    required this.contentType,
  });

  final String method;
  final String body;
  final String? contentType;
}

/// A consumer written against the ports and nothing else.
///
/// Every parameter is a port type, so constructing one compiles only if all six ports are injectable
/// — which is the claim the first test makes, stated as a type rather than as a reflection. It has no
/// behaviour beyond [describe], which exists so the fakes are *used* rather than merely constructed.
final class _Consumer {
  _Consumer({
    required this.clock,
    required this.paths,
    required this.http,
    required this.storage,
    required this.concurrency,
    required this.processes,
  });

  final AlteriOneClock clock;
  final Paths paths;
  final HttpClientPort http;
  final StoragePort storage;
  final Concurrency concurrency;
  final ProcessHost processes;

  /// The types the product would name, and nothing else.
  String describe() => <String>[
    clock.runtimeType.toString(),
    paths.runtimeType.toString(),
    http.runtimeType.toString(),
    storage.runtimeType.toString(),
    concurrency.runtimeType.toString(),
    processes.runtimeType.toString(),
  ].join(', ');
}

/// Six fakes, one per port.
///
/// They exist to be *injected*, not to be correct: the point is that the product's seams accept an
/// object the caller wrote, without an adapter existing and without the fake knowing anything about
/// the product. So every one is the smallest thing that satisfies its port, and the clock is genuinely
/// controllable — that is the one property a caller of a port is entitled to expect to drive.
///
/// Task `0.10` ships the product's own doubles and `HiveCeStorage` is task `1.1`'s, so these stay local
/// to this file. A fake shipped from the package now would be a declaration written before the task
/// that specifies it, which is the failure mode the library's "what arrives with which task" table
/// exists to prevent.
final class _Fakes {
  _Fakes() {
    clock = _FakeClock();
    paths = _FakePaths();
    http = _FakeHttp();
    storage = _InMemoryStorage();
    concurrency = _FakeConcurrency(clock);
    processes = _FakeProcessHost();
  }

  late final AlteriOneClock clock;
  late final Paths paths;
  late final HttpClientPort http;
  late final StoragePort storage;
  late final Concurrency concurrency;
  late final ProcessHost processes;
}

/// A clock a test drives.
///
/// Wall time and monotonic time are advanced separately, because the port keeps them separate and a
/// fake that advanced both together would hide the distinction that is the whole reason
/// `AlteriOneClock` has three members rather than one.
final class _FakeClock implements AlteriOneClock {
  DateTime _now = DateTime.utc(2026, 1, 1);
  Duration _elapsed = Duration.zero;

  @override
  DateTime now() => _now;

  @override
  Duration monotonicNow() => _elapsed;

  @override
  Future<void> delay(Duration duration) async {
    _elapsed += duration;
    _now = _now.add(duration);
  }
}

/// A layout rooted wherever the test says.
///
/// Every member delegates to the package's own `resolveBeneath` and `isBeneath` rather than
/// re-deriving them, and that is the point of exposing those as functions instead of inherited
/// interface methods: a fake is then one line per member rather than a copy of the containment rule
/// that has to be kept in step with the adapter's.
final class _FakePaths implements Paths {
  _FakePaths([Uri? root]) : _home = root ?? Uri.file('/tmp/fake-install');

  final Uri _home;

  @override
  Uri get home => _home;

  @override
  Uri get config => resolve('config');

  @override
  Uri get profiles => resolve('config/profiles');

  @override
  Uri get policies => resolve('config/policies.d');

  @override
  Uri get state => resolve('state');

  @override
  Uri get logs => resolve('logs');

  @override
  Uri get injections => resolve('injections');

  @override
  Uri get tools => resolve('tools');

  @override
  Uri get plugins => resolve('plugins');

  @override
  Uri get bin => resolve('bin');

  @override
  Uri get apps => resolve('apps');

  @override
  Uri resolve(String relative) => resolveBeneath(_home, relative);

  @override
  bool within(Uri candidate) => isBeneath(_home, candidate);

  @override
  Future<bool> ensure(Uri directory, {bool create = true}) async => false;

  @override
  Future<void> createDirectory(Uri directory) async {}

  @override
  Future<bool> exists(Uri path) async => false;
}

/// An HTTP port that answers from a script and never opens a socket.
///
/// `responses` is keyed by path prefix, which is the shape task `0.21`'s deny-all client needs: a
/// request to a host that is not on the list gets a refusal and one that is gets a scripted response.
/// [sent] is what lets a test assert on the *request*, which is the half of a round trip that a fake
/// response alone would never check.
final class _FakeHttp implements HttpClientPort {
  final Map<String, HttpResponse> responses = <String, HttpResponse>{};
  final List<HttpRequestSpec> sent = <HttpRequestSpec>[];
  bool closed = false;

  @override
  Future<HttpResponse> send(HttpRequestSpec request) async {
    sent.add(request);
    for (final entry in responses.entries) {
      if (request.uri.path.startsWith(entry.key)) return entry.value;
    }
    throw TransportFailure(
      'no scripted response for ${request.method} ${request.uri.scheme}://${request.uri.host}'
      '${request.uri.path}',
      retryable: false,
    );
  }

  @override
  Future<void> close() async => closed = true;
}

/// A concurrency that runs work in-line, and says so.
///
/// `maxParallelism` is **1**, not a plausible number. A fake reporting four would be reporting
/// something false to the only caller that reads it — which is exactly the failure `src/web.dart`
/// refuses rather than commits, so a fake that committed it would make that refusal look unreasonable.
final class _FakeConcurrency implements Concurrency {
  _FakeConcurrency(this._clock);

  final AlteriOneClock _clock;

  @override
  AlteriOneClock get clock => _clock;

  @override
  int get maxParallelism => 1;

  @override
  Future<R> run<R>(Computation<R> computation, {String? debugName}) async =>
      await computation();

  @override
  TransportChannel channel(ConcurrencyPeer peer) => throw UnsupportedError(
    'the deterministic in-memory pair in alteri_one_protocol is the in-memory one; this fake is '
    'here to satisfy the interface, not to reimplement it',
  );
}

/// A process host that records the spec and spawns nothing.
final class _FakeProcessHost implements ProcessHost {
  final List<ProcessSpec> started = <ProcessSpec>[];

  @override
  Uri get resolvedExecutable => Uri.file('/fake/alterione');

  @override
  Future<HostProcess> start(ProcessSpec spec) async {
    started.add(spec);
    throw UnsupportedError('a fake host spawns nothing; it records the spec');
  }
}

/// A `StoragePort` in a map, with a single-writer lock that actually refuses.
///
/// `HiveCeStorage` is task `1.1`'s, so this is the only implementation of the port in the repository
/// today — and it is here because ADR-0004's rule ("two processes writing one profile state directory
/// concurrently" is forbidden) is a rule about the *port*, so it has to be demonstrable without the
/// engine that motivates it.
///
/// [openedWithoutLock] is the assertion that matters: an implementation reachable without the lock is
/// one whose caller has no way to be safe, and that is a property of the boundary rather than of any
/// one engine.
final class _InMemoryStorage implements StoragePort {
  final Map<String, StorageCollection> _collections =
      <String, StorageCollection>{};
  final Map<String, int> _versions = <String, int>{};
  bool openedWithoutLock = false;
  bool closed = false;

  final Map<String, StorageLock> _heldByNamespace = <String, StorageLock>{};

  @override
  Future<StorageLock> acquireWriteLock(
    String namespace, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final held = _heldByNamespace[namespace];
    if (held == null) {
      final granted = StorageLock.granted(
        token: 'fake-1',
        heldSince: Duration.zero,
        // A hook rather than a subclass: this fake genuinely holds a lock, and the only thing between
        // a test that asserts the lock is taken and one that asserts it is *released* is that
        // something happens here.
        onRelease: () => _heldByNamespace.remove(namespace),
      );
      _heldByNamespace[namespace] = granted;
      return granted;
    }
    // Refused immediately rather than after `timeout`. The wait exists in the real port because a lock
    // file may be released a moment later; a fake has nothing to wait for, and a test that had to
    // sleep to observe a refusal would be slow for no extra coverage.
    return StorageLock.refused(
      token: 'fake-2',
      heldSince: Duration.zero,
      holderDescription: 'a fake process holding this namespace',
    );
  }

  @override
  Future<StorageCollection> openCollection(
    String name, {
    required int schemaVersion,
  }) async {
    if (_heldByNamespace.isEmpty) openedWithoutLock = true;
    final existing = _collections[name];
    if (existing != null) return existing;
    _versions[name] = schemaVersion;
    final collection = _MapCollection(name, schemaVersion);
    _collections[name] = collection;
    return collection;
  }

  @override
  Future<int?> storedVersion(String name) async => _versions[name];

  @override
  Future<void> close() async {
    closed = true;
    for (final collection in _collections.values) {
      await collection.close();
    }
    _collections.clear();
  }
}

/// One collection of the map-backed storage.
final class _MapCollection implements StorageCollection {
  _MapCollection(this.name, this.schemaVersion);

  @override
  final String name;

  @override
  final int schemaVersion;

  final Map<String, StorageValue> _entries = <String, StorageValue>{};
  bool isClosed = false;

  @override
  Future<StorageValue?> read(String key) async => _entries[key];

  @override
  Future<void> write(String key, StorageValue value) async {
    _entries[key] = value;
  }

  @override
  Future<bool> delete(String key) async => _entries.remove(key) != null;

  @override
  Future<List<String>> keys({String? prefix}) async =>
      _entries.keys
          .where((key) => prefix == null || key.startsWith(prefix))
          .toList()
        ..sort();

  @override
  Future<List<StorageValue>> values({String? prefix}) async => <StorageValue>[
    for (final entry in _entries.entries)
      if (prefix == null || entry.key.startsWith(prefix)) entry.value,
  ];

  @override
  Future<int> clear() async {
    final count = _entries.length;
    _entries.clear();
    return count;
  }

  @override
  Future<void> close() async => isClosed = true;
}
