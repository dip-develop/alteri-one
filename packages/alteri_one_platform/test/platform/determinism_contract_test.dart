// The contract of the determinism doubles: the id generator and the fake clock. Task 0.10.
//
// What this file is: the mechanical half of "identical ids, time and usage on a replayed script".
// The rules it asserts are written down — `IdGenerator` and the seeded mode in
// architecture/observability.md §4, the grammar and the reserved prefixes in concepts.md §2 and
// §2.1, the two-member clock in lib/src/clock.dart, and the requirement that a fake clock fixes
// every timestamp in observability.md §2.1 — and this file is what stops the prose from drifting
// away from the declarations.
//
// The greppable acceptance string for the task is the description of the first test in the
// `FakeProvider` contract test in `alteri_one_core`, which is the task's named acceptance
// command. The tests here are the platform half of the same claim: a run's ids and a run's clock
// are the two things a replayed script reproduces before the provider is even asked.
//
// What this file is not: a test of the OpenAI-compatible provider, and not a test of the loop.
// `identityBlock` is exported so that a test can pin the algorithm against the published CRC-32
// test vector; that is the only reason it is public, and the reason is written down at its
// declaration in lib/src/ids.dart.
//
// `dart:io` appears once, to name the operating system in a failure message for the one test
// whose subject is cross-platform reproducibility. A test is not shipped and is allowed to read
// the host (test/workspace/workspace_contract_test.dart, `imports`), so the `dart:io` rule of
// architecture/overview.md §3 is untouched by anything here.

import 'dart:convert' show utf8;
import 'dart:io' show Platform;
import 'dart:math' show Random;

import 'package:alteri_one_platform/alteri_one_platform.dart';
import 'package:test/test.dart';

/// concepts.md §2's record-id grammar, transcribed.
///
/// Written out here rather than read out of the library, because a gate that takes the rule from
/// the code it checks asserts only that the code agrees with itself. concepts.md §2 is the
/// authority; this is a copy, and a change to either has to change the other. That is the same
/// relationship `IdKind` has to a string parameter, for the same reason.
final RegExp _recordId = RegExp(
  r'^(trace|req|span|evt|mem|art)_[0-9a-f]{8,32}$',
);

/// The two blocks of a generated id: prefix, then eight hex of identity, then the counter.
///
/// The counter block is `[0-9a-f]{8,}` rather than `{8}` because a counter past 2³² widens the
/// block rather than truncating it, which lib/src/ids.dart says is deliberate.
final RegExp _idShape = RegExp(r'^([a-z]+)_([0-9a-f]{8})([0-9a-f]{8,})$');

void main() {
  group('the id grammar', () {
    test('a generated id is a record id in the shape concepts.md §2 gives', () {
      // The platform half of the task's acceptance claim, in three parts: every kind produces an
      // id, the id is inside the documented grammar, and the counter is the second block and
      // starts at zero in the clear.
      for (final kind in IdKind.values) {
        final generator = SeededIdGenerator(seed: 'contract');
        final ids = <String>[
          for (var turn = 0; turn < 4; turn++) generator.next(kind),
        ];

        for (final id in ids) {
          expect(id, matches(_recordId), reason: '$kind produced $id');
        }
        expect(ids.map((id) => _idShape.firstMatch(id)!.group(1)).toSet(), {
          kind.prefix,
        }, reason: 'every id of one kind carries that kind\'s reserved prefix');
        expect(ids.map((id) => _idShape.firstMatch(id)!.group(3)), [
          '00000000',
          '00000001',
          '00000002',
          '00000003',
        ], reason: '$kind must number its own counter from zero, in the clear');
      }
    });

    test(
      'the six reserved prefixes are exactly the six of concepts.md §2.1',
      () {
        // A seventh prefix is a reserved-namespace conflict that no compiler would catch, so the
        // enum's membership is a contract rather than a convenience.
        expect(IdKind.values.map((kind) => '${kind.prefix}_').toSet(), {
          'trace_',
          'req_',
          'span_',
          'evt_',
          'mem_',
          'art_',
        });
      },
    );

    test('the grammar rejects what the generator would never produce', () {
      // The other direction, and the reason the grammar is worth transcribing twice. A gate that
      // only inspects generated ids cannot notice a seventh prefix being reserved, a prefix
      // spelled with a capital, or the hex block being shortened by a future change to
      // lib/src/ids.dart.
      for (final rejected in <String>[
        'call_00000000', // not one of the six
        'TRACE_00000000', // the prefix is lowercase
        'trace_0000', // fewer than eight hex characters
        'trace_0000000g', // not hex
        'trace', // no block at all
        'req_00000000_extra', // a suffix after the counter is not part of the grammar
      ]) {
        expect(rejected, isNot(matches(_recordId)), reason: rejected);
      }
    });
  });

  group('the seeded mode', () {
    test(
      'the same seed produces the same ids, and a different seed does not',
      () {
        // Reproducibility, which is the first half of observability.md §4's sentence.
        List<String> draw(IdGenerator generator) => <String>[
          for (final kind in IdKind.values) generator.next(kind),
        ];

        expect(
          draw(SeededIdGenerator(seed: 'trace-one')),
          draw(SeededIdGenerator(seed: 'trace-one')),
        );
        expect(
          draw(SeededIdGenerator(seed: 'trace-one')),
          isNot(draw(SeededIdGenerator(seed: 'trace-two'))),
        );
      },
    );

    test(
      'the counter is per kind, so an unrelated kind cannot move this one',
      () {
        // Why the counters are not one counter. A run that draws a hundred spans and three requests
        // has to number its requests 0, 1, 2; a shared counter would make every request id depend
        // on how much instrumentation the run happened to do, so two runs differing only in that
        // would produce different ids for the same logical event, and the transcript digest would
        // differ for a reason that has nothing to do with the run.
        final busy = SeededIdGenerator(seed: 'per-kind');
        for (var turn = 0; turn < 100; turn++) {
          busy.next(IdKind.span);
          busy.next(IdKind.event);
          busy.next(IdKind.artifact);
        }
        final requests = <String>[
          busy.next(IdKind.request),
          busy.next(IdKind.request),
        ];

        final quiet = SeededIdGenerator(seed: 'per-kind');
        expect(
          requests,
          <String>[quiet.next(IdKind.request), quiet.next(IdKind.request)],
          reason: 'a request id must not depend on how many other ids were drawn first',
        );
      },
    );

    test('ids never repeat within a kind', () {
      // Structural, not probabilistic: the counter is a counter. It is worth a test because the
      // alternative — hashing the counter too — would satisfy every other test in this file and
      // would make a long run's ids collide eventually.
      final generator = SeededIdGenerator(seed: 'unique');
      final ids = <String>{};
      for (var turn = 0; turn < 5000; turn++) {
        expect(
          ids.add(generator.next(IdKind.request)),
          isTrue,
          reason: 'turn $turn',
        );
      }
      expect(ids, hasLength(5000));
    });

    test('a seeded run is the same value on every operating system', () {
      // The claim is about the *value*, and the value is a function of the seed and a documented
      // algorithm. What this guards is a regression to something machine-dependent — a
      // `String.hashCode`, a pointer, a timestamp — which would make every golden transcript in
      // the repository pass on the machine that wrote it and fail on every other. So the expected
      // values are written out here rather than compared against a second generator: comparing
      // two runs of the same code would be green for any deterministic code, including a
      // deterministic one that is not reproducible across machines.
      final generator = SeededIdGenerator(seed: 'cross-platform');
      expect(
        <String>[for (final kind in IdKind.values) generator.next(kind)],
        // A regression here is a regression to something machine-dependent, and the symptom is
        // that every transcript in the repository would be wrong on every machine but the one
        // that produced it. The reason names the host so that report is legible on a runner.
        const <String>[
          'trace_102109a300000000',
          'req_6726393500000000',
          'span_fe2f688f00000000',
          'evt_8928581900000000',
          'mem_174ccdba00000000',
          'art_604bfd2c00000000',
        ],
        reason:
            'a seeded id changed on ${Platform.operatingSystem}: every transcript in the '
            'repository would now be wrong on every machine but the one that produced it, '
            'where the change is invisible',
      );

      // And the same ids one kind at a time, with the counter advancing, so the pinned block
      // above is tied to the per-kind counter rather than to an ordering of the enum.
      final second = SeededIdGenerator(seed: 'cross-platform');
      expect(
        <String>[
          second.next(IdKind.trace),
          second.next(IdKind.trace),
          second.next(IdKind.memory),
        ],
        const <String>[
          'trace_102109a300000000',
          'trace_102109a300000001',
          'mem_174ccdba00000000',
        ],
      );
    });

    test('a generator is an actor, and two actors interleave without either seeing the other', () async {
      // The second half of observability.md §4's sentence — *stable under concurrency* — and the
      // arrangement it forces. A counter advances in draw order, and draw order is a scheduling
      // artefact, so a generator shared by interleaved callers numbers their ids by whoever ran
      // first. Two actors are therefore two generators, and each one's own sequence is then
      // independent of the other's: the interleaving below is real (`Future.wait` on two
      // concurrent draws) and both sequences still equal what each actor produces alone.
      Future<List<String>> actor(String seed, int turns) async {
        final generator = SeededIdGenerator(seed: seed);
        final ids = <String>[];
        for (var turn = 0; turn < turns; turn++) {
          ids.add(generator.next(IdKind.request));
          // A real await between draws, so the two actors' continuations really are interleaved
          // rather than run to completion one after the other.
          await Future<void>.delayed(Duration.zero);
        }
        return ids;
      }

      List<String> solo(String seed, int turns) {
        final generator = SeededIdGenerator(seed: seed);
        return <String>[
          for (var turn = 0; turn < turns; turn++)
            generator.next(IdKind.request),
        ];
      }

      final interleaved = await Future.wait(<Future<List<String>>>[
        actor('left', 8),
        actor('right', 8),
      ]);

      expect(
        interleaved[0],
        solo('left', 8),
        reason: 'the left actor saw the right one',
      );
      expect(
        interleaved[1],
        solo('right', 8),
        reason: 'the right actor saw the left one',
      );
      expect(
        interleaved[0],
        isNot(interleaved[1]),
        reason: 'two seeds must not collide',
      );
    });

    test(
      'one generator shared by concurrent callers still never repeats an id',
      () async {
        // The other half of the same property, and the reason the arrangement above is advice
        // rather than a rule the type system enforces: shared or not, the uniqueness inside a run
        // is structural. A caller that shares one gets ids numbered in draw order, which is
        // reproducible when the draw order is, and never a duplicate.
        final generator = SeededIdGenerator(seed: 'shared');
        final batches = await Future.wait(<Future<List<String>>>[
          for (var actor = 0; actor < 8; actor++)
            Future<List<String>>(() async {
              final ids = <String>[];
              for (var turn = 0; turn < 25; turn++) {
                ids.add(generator.next(IdKind.request));
                await Future<void>.delayed(Duration.zero);
              }
              return ids;
            }),
        ]);

        final ids = batches.expand((batch) => batch).toList();
        expect(ids, hasLength(200));
        expect(
          ids.toSet(),
          hasLength(200),
          reason: 'a shared generator repeated an id',
        );
        // Whatever order they arrived in, the set of counters handed out is 0..199 and no gaps.
        expect(
          ids
              .map(
                (id) =>
                    int.parse(_idShape.firstMatch(id)!.group(3)!, radix: 16),
              )
              .toSet(),
          <int>{for (var counter = 0; counter < 200; counter++) counter},
        );
      },
    );
  });

  group('the identity block', () {
    test('it is the standard CRC-32 of the seed and the kind', () {
      // The published test vector from the CRC catalogue: CRC-32 of "123456789" is 0xCBF43926.
      // Nothing else here compares against an outside authority, so a deterministic-but-wrong
      // block — a different polynomial, an unreflected form, a missing final inversion — would
      // pass every other test in this file.
      expect(_crc32Bitwise(utf8.encode('123456789')), 0xcbf43926);

      // And the block is a CRC-32 of the seed followed by the kind's index, which means a caller
      // in another language can reproduce an id rather than compare opaque strings.
      for (final kind in IdKind.values) {
        expect(
          identityBlock('seed', kind),
          _crc32Bitwise(<int>[...utf8.encode('seed'), kind.index & 0xFF]),
          reason: '${kind.name} must be seeded by its own index',
        );
      }
    });

    test('a different seed and a different kind give different blocks', () {
      final blocks = <int>{
        for (final kind in IdKind.values) ...<int>[
          identityBlock('a', kind),
          identityBlock('b', kind),
        ],
      };
      expect(blocks, hasLength(IdKind.values.length * 2));
    });

    test('an empty seed is a seed, and a distinct one', () {
      // "required String seed" invites the reading that an empty string is somehow an absent
      // seed. It is not: two generators built from it produce the same ids, which is occasionally
      // what a test wants and must not be an accident of a default.
      expect(
        SeededIdGenerator(seed: '').next(IdKind.trace),
        SeededIdGenerator(seed: '').next(IdKind.trace),
      );
      expect(
        SeededIdGenerator(seed: '').next(IdKind.trace),
        isNot(SeededIdGenerator(seed: 'x').next(IdKind.trace)),
      );
    });
  });

  group('the random source', () {
    test('a production id has the same shape and is unique within its run', () {
      // Same shape, not merely a valid one. `alterione why` and the replay harness read a
      // transcript without knowing which generator wrote it, so a production id that did not
      // parse the same way as a golden one would be a transcript only one of the two could read.
      final generator = RandomIdGenerator();
      final ids = <String>[
        for (var turn = 0; turn < 32; turn++) generator.next(IdKind.span),
      ];
      for (final id in ids) {
        expect(id, matches(_recordId));
        expect(_idShape.firstMatch(id)!.group(1), 'span');
      }
      expect(ids.toSet(), hasLength(32));
    });

    test('two runs differ, and an injected Random makes them agree', () {
      expect(
        RandomIdGenerator().next(IdKind.trace),
        isNot(RandomIdGenerator().next(IdKind.trace)),
      );
      // Injectable so a test can be reproducible without pretending to be a seeded run. The
      // distinction is stated at `RandomIdGenerator`: a fixed Random repeats across runs, which
      // is *worse* for a production transcript than ids that differ, which is why the seeded
      // generator is a separate type rather than a flag.
      expect(
        RandomIdGenerator(random: Random(7)).next(IdKind.trace),
        RandomIdGenerator(random: Random(7)).next(IdKind.trace),
      );
    });
  });

  group('the fake clock', () {
    test('a fake clock starts where it is told and only moves when moved', () {
      final clock = FakeClock(now: DateTime.utc(2026, 3, 4, 5, 6, 7));
      final start = DateTime.utc(2026, 3, 4, 5, 6, 7);
      expect(clock.now(), start);
      expect(clock.monotonicNow(), Duration.zero);

      // Time does not pass on its own between two reads. A fake that advanced on its own would
      // make every timestamp assertion a race, and these two reads are separated by a full
      // statement.
      expect(clock.now(), start);
      expect(clock.monotonicNow(), Duration.zero);

      clock.advance(const Duration(milliseconds: 1500));
      expect(clock.monotonicNow(), const Duration(milliseconds: 1500));
      expect(clock.now().difference(start), const Duration(milliseconds: 1500));
    });

    test(
      'the two origins move together and can be made to disagree on purpose',
      () {
        // [AlteriOneClock] is two members and not one because a deadline is an elapsed-time
        // comparison that must not move when the wall clock does. This assertion is only
        // expressible with a two-member port: step the wall clock forward an hour and the 30-second
        // deadline is still not expired, which is exactly the property lib/src/clock.dart exists to
        // make checkable — and the NTP step is the case its documentation says happens "roughly
        // once a year per host, and always on the machines most likely to be running an agent".
        final clock = FakeClock(now: DateTime.utc(2026));
        final deadline = clock.monotonicNow() + const Duration(seconds: 30);

        clock.setWallClock(DateTime.utc(2030));
        expect(
          clock.now(),
          DateTime.utc(2030),
          reason: 'the recording clock moved',
        );
        expect(
          clock.monotonicNow(),
          Duration.zero,
          reason: 'the elapsed clock did not',
        );
        expect(
          clock.monotonicNow() < deadline,
          isTrue,
          reason: 'an hour of wall clock must not expire a 30 s deadline',
        );
      },
    );

    test(
      'a delay answers immediately and moves the clock by exactly its duration',
      () async {
        // The property that makes a backoff schedule testable, and it cuts both ways: the future
        // completes without real time passing, and the elapsed time is visible afterwards. A fake
        // that completed `delay(2s)` without moving anything would make a retry assertion read
        // `0 ms` — a test that passes and proves nothing. A fake that really waited would make the
        // suite take as long as the run it stands in for.
        final clock = FakeClock();
        final started = clock.monotonicNow();

        await clock.delay(const Duration(seconds: 2));

        expect(
          clock.monotonicNow() - started,
          const Duration(seconds: 2),
          reason:
              'a retry backoff is invisible unless the delay moved the clock',
        );
      },
    );

    test('a clock cannot be moved backwards', () {
      // [AlteriOneClock.monotonicNow] is required never to decrease. A double that could move it
      // backwards would let a test pass on behaviour the product forbids, which is the one thing a
      // determinism double must not do. The two members are checked separately because `delay` and
      // `advance` are separate members and either could have been left out.
      final clock = FakeClock();
      clock.advance(const Duration(seconds: 5));

      expect(
        () => clock.advance(const Duration(seconds: -1)),
        throwsArgumentError,
      );
      expect(
        () => clock.delay(const Duration(milliseconds: -1)),
        throwsArgumentError,
      );
      expect(clock.monotonicNow(), const Duration(seconds: 5));
    });

    test('a fake clock is UTC, whatever it was given', () {
      // A local DateTime reaching a test would put a zone offset into every timestamp the run
      // produces, and a transcript written on a machine in one zone would not compare with one
      // written in another. The port says [AlteriOneClock.now] is UTC; a double that ignored it
      // would be a double a caller could not rely on.
      final local = DateTime(2026, 3, 4, 5, 6, 7);
      expect(FakeClock(now: local).now().isUtc, isTrue);
      expect(FakeClock(now: local).now(), local.toUtc());
    });

    test('a clock built from nothing starts at the epoch rather than at the present', () {
      // A default of "now" would make every test that forgot to pass an instant depend on the
      // wall clock: the defect this package exists to prevent, introduced by the package that
      // prevents it. The value is round and obviously synthetic, so a transcript containing it
      // reads as a fake's and not as a real run.
      expect(FakeClock().now(), DateTime.utc(1970));
    });

    test('a fake clock is a clock, and so is the real one', () {
      // [AlteriOneClock] is an interface and the double is checked against it as one, not as a
      // `FakeClock` that merely has the same members. A double that is a plain class and a port
      // that is an interface are unrelated types in Dart's type system, so a caller who takes the
      // port and is handed the double gets a compile error rather than a silent pass — which is
      // the whole value of the port being an interface.
      expect(FakeClock(), isA<AlteriOneClock>());
      expect(PlatformClock(), isA<AlteriOneClock>());
    });
  });
}

/// CRC-32 over [bytes], written here independently of the library's implementation.
///
/// Two implementations in one test file is the point rather than a duplication. The library's is
/// table-driven; the published test vector says a table-driven CRC-32 agrees with a bit-at-a-time
/// one. A single implementation cannot check itself, and a wrong-but-deterministic identity block
/// would pass every other test here.
int _crc32Bitwise(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
