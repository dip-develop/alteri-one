/// Runtime identifiers, and the two sources they come from.
///
/// [architecture/observability.md] §1: *"The root run creates a `traceId` from an injectable
/// generator."* [concepts.md] §2 gives the grammar, §2.1 reserves the six prefixes, and
/// [architecture/observability.md] §4 is the reason this is a port:
///
/// > A deterministic seeded mode draws from a counter mixed with the seed, so id assignment is
/// > reproducible **and** stable under concurrency — a per-call random source would not be,
/// > which is why the seeded mode is specified as counter-based rather than as a PRNG stream.
///
/// The sentence has two halves and they are the whole design. *Reproducible* is the counter;
/// *stable under concurrency* is what rules out a shared PRNG, and it is also the reason the
/// counter is **per kind**. Both are below, with the property each one buys, because a
/// transcript is content-addressed: two records that should have differed and did not are a
/// digest that matches a run that never happened.
///
/// ## The shape of an id, and why the counter is in the clear
///
/// ```text
/// <prefix>_<8 hex of CRC-32(seed, kind)><8 hex of the counter for that kind>
/// trace_9f2c41ab00000007
/// ```
///
/// Sixteen hex characters, which is inside [concepts.md] §2's `^[0-9a-f]{8,32}$`, in two blocks
/// that are deliberately *not* one hash. **There is no separator between the blocks**, and that
/// is forced rather than chosen: the grammar is `_(hex)+` with nothing else in it, so an id that
/// read `trace_9f2c41ab_00000007` would be a record id the grammar rejects — and a record id that
/// the grammar rejects is one a validating profile or an exported transcript cannot carry. The
/// cost is that a reader cannot see where the identity ends, which is why the block widths are
/// documented here and asserted in the contract test rather than left to be inferred:
///
/// - The **counter block is the uniqueness that matters.** Within one generator, two ids of one
///   kind can never be equal, because the counter is a counter and not a digest of anything. That
///   is a structural property, not a probability, and it holds however many ids a run draws.
/// - The **identity block is the separation between runs.** It is a checksum of the seed and the
///   kind, so two runs with different seeds do not collide in the transcript of a test that
///   compares them.
///
/// A single 64-bit hash of `(seed, kind, counter)` would have been shorter to write and would
/// have replaced a guarantee with a probability — roughly one collision in 2.7 × 10⁻⁸ at a
/// million ids in a run. The extra eight characters buy certainty where a transcript needs it
/// and a probability only where a human-readable difference is enough.
///
/// ## CRC-32, chosen for its arithmetic
///
/// The identity block is CRC-32 — the reflected IEEE 802.3 variant, `0xEDB88320` — and the
/// reason is not that it is a good hash. It is that its step is a shift and an exclusive-or:
///
/// ```text
/// crc = (crc >> 8) ^ table[(crc ^ byte) & 0xFF]
/// ```
///
/// Every value in that line is below 2³², so it is exact in a Dart integer *and* in a JavaScript
/// number. FNV-1a, the obvious alternative, computes `(hash ^ byte) * 0x01000193`, whose
/// intermediate reaches about 7.2 × 10¹⁶ — above 2⁵³, the point at which an integer compiled to
/// JavaScript stops being exact. A web build of that formula computes a *different* identity
/// block from the same seed, and the only symptom is a transcript digest that matches on the VM
/// and not in a browser, which is the one thing
/// [architecture/observability.md] §2.1 says must not happen.
///
/// The port therefore has a browser target, and the identity block had to be picked by its
/// arithmetic rather than by its reputation. The same argument rules out anything 64-bit:
/// a Dart `int` is a signed 64-bit value on the VM and a double everywhere else, so a 64-bit
/// accumulator is exact on one target and not on the others. 32 bits is the widest width that is
/// exact on all of them.
///
/// The table is computed once, in a `final`, because building it needs the same shift-and-xor
/// step — no multiply is involved in CRC-32 at run time or at table-build time.
///
/// [architecture/observability.md]: ../../../../docs/architecture/observability.md
/// [concepts.md]: ../../../../docs/concepts.md
library;

import 'dart:convert';
import 'dart:math';

/// The six reserved identifier prefixes.
///
/// [concepts.md] §2.1 reserves `trace_`, `req_`, `span_`, `evt_`, `mem_` and `art_` for runtime
/// identifiers and names `IdGenerator` as the thing that registers them. The set is an enum
/// rather than a string parameter because a string is a typo waiting to become a seventh prefix,
/// and a seventh prefix is a reserved-namespace conflict (concepts.md §2.1) that no compiler
/// would catch.
///
/// The declaration order is the product's own order and is never load-bearing, with one
/// exception that is worth stating: the identity block is derived from each kind's
/// [Enum.index], so **reordering this enum changes every seeded id in a golden test**. That is a
/// loud failure rather than a silent one, and it is a reason to append rather than to reorder.
/// The index is never persisted: it is part of how an id is computed, not part of what it means.
enum IdKind {
  /// The root run. One per run, and the id every span hangs from.
  trace('trace'),

  /// One model turn or one JSON-RPC request.
  request('req'),

  /// One step inside a trace: a provider turn, a tool, a memory operation, a platform adapter.
  span('span'),

  /// One published event on the bus.
  event('evt'),

  /// One memory record.
  memory('mem'),

  /// One artefact produced by a run.
  artifact('art');

  const IdKind(this.prefix);

  /// The reserved prefix, without the underscore.
  ///
  /// Part of the wire-visible id, so it is a `const` string rather than something derived per
  /// call: it is read once per id and it appears in every transcript.
  final String prefix;
}

/// The source of every runtime identifier.
///
/// Injected beside [AlteriOneClock] and for the same reason: a trace is only replayable if every
/// id in it is a function of the run rather than of the machine.
/// [architecture/observability.md] §1 makes the `traceId` injectable and §4 names this port as
/// mandatory in Phase 0, and [apps/sdk.md] §3 lists it next to the clock in an embedder's
/// configuration — an embedder supplies its own id source, exactly as it supplies its own clock.
///
/// The port has one member. It is deliberately **not** a `sealed class` over "seeded" and
/// "random" modes: a caller that has to switch on the id's source to ask for an id is a caller
/// whose determinism depends on the mode, and the two implementations differ in exactly nothing
/// an id's consumer can observe — both produce the same shape from the same draw order.
///
/// [AlteriOneClock]: clock.dart
/// [architecture/observability.md]: ../../../../docs/architecture/observability.md
/// [apps/sdk.md]: ../../../../docs/apps/sdk.md
abstract interface class IdGenerator {
  /// The next unused id for [kind].
  ///
  /// Never returns the same value twice for one kind on one instance, and never returns a value
  /// outside [concepts.md] §2's `^(trace|req|span|evt|mem|art)_[0-9a-f]{8,32}$`. Both are
  /// guarantees of the implementations rather than a rule a caller is trusted to keep, because
  /// the consequence of breaking the first is two records sharing an id in a content-addressed
  /// transcript.
  ///
  /// [concepts.md]: ../../../../docs/concepts.md
  String next(IdKind kind);
}

/// A counter-based generator whose ids are a function of a seed.
///
/// The deterministic mode of [architecture/observability.md] §4, and the reason a golden test
/// exists: two runs of the same script with the same [seed] produce the same ids, on every
/// platform, in any order the machine happens to schedule the work in.
///
/// [seed] is mixed into the identity block and never appears in an id in the clear, so a
/// transcript does not carry the seed of the run that wrote it. A seed is a test input, and a
/// transcript is committed and published; an id that spelled it would put it in the clear in
/// every record.
///
/// A generator is **owned by one logical actor** — a run, a trace, a subagent — and that actor
/// draws its ids in its own logical order. This file's documentation is about why: the counter
/// advances in draw order, and draw order is a scheduling artefact, so a generator shared by
/// interleaved callers numbers their ids by whoever ran first. Two actors that genuinely
/// interleave are two generators, each seeded, and each one's own sequence is then independent of
/// the other — the property task `0.10`'s contract test demonstrates by interleaving two actors
/// and comparing each against the sequence it produces alone.
final class SeededIdGenerator implements IdGenerator {
  /// A generator whose ids are a function of [seed] and of the draw order.
  ///
  /// [seed] is checksummed once, here, so the cost is per generator rather than per id. An empty
  /// seed is allowed and is **not** the same as no seed: two generators built from the empty
  /// string still produce the same ids, which is occasionally what a test wants.
  SeededIdGenerator({required String seed})
    : _identities = <int>[
        for (final kind in IdKind.values) identityBlock(seed, kind),
      ];

  /// The per-kind identity blocks: `_identities[kind.index]` is the first eight hex characters
  /// every id of that kind carries.
  ///
  /// Built once and indexed by [IdKind] declaration order, because the enum is the only thing
  /// that may turn a kind into an index and a parallel list would be a second copy of that order.
  final List<int> _identities;

  /// One counter per kind, which is the property this file's documentation is about.
  final List<int> _counters = List<int>.filled(IdKind.values.length, 0);

  @override
  String next(IdKind kind) {
    final counter = _counters[kind.index]++;
    return '${kind.prefix}_${_hex(_identities[kind.index])}${_hex(counter)}';
  }
}

/// A generator for a run that is not being reproduced.
///
/// The production default, and the only implementation here that consults a source of entropy.
/// It is still counter-based in the second block, so the guarantee that matters inside a run —
/// two ids of one kind are never equal — is structural here too, and an id from a production
/// transcript has the same shape as an id from a golden one. `alterione why` and the replay
/// harness parse a transcript without knowing which generator wrote it.
///
/// [random] is injectable because a test that wants two production runs to differ still wants
/// each of them to be reproducible in its own terms. It is **not** a route to determinism for a
/// run that must be reproducible: [SeededIdGenerator] is that, and a fixed-seed [Random] produces
/// ids that repeat across runs, which is worse than ids that differ.
final class RandomIdGenerator implements IdGenerator {
  /// A generator that draws its identity block from [random].
  ///
  /// Defaults to [Random.secure], which is the platform's cryptographic source and is available
  /// on every target including a browser. It is read six times here and never again, because a
  /// run has one identity and every id in it says so.
  RandomIdGenerator({Random? random}) : _random = random ?? Random.secure() {
    for (var index = 0; index < IdKind.values.length; index++) {
      _identities[index] = _random.nextInt(_identitySpace);
    }
  }

  final Random _random;

  /// The per-kind identity blocks, drawn once in the constructor.
  final List<int> _identities = List<int>.filled(IdKind.values.length, 0);

  final List<int> _counters = List<int>.filled(IdKind.values.length, 0);

  @override
  String next(IdKind kind) {
    final counter = _counters[kind.index]++;
    return '${kind.prefix}_${_hex(_identities[kind.index])}${_hex(counter)}';
  }
}

/// The number of distinct identity blocks, and the width of one.
///
/// The identity block is eight hex characters, which is 32 bits, and this is the exclusive bound
/// on a drawn value — `Random.nextInt` takes 2³² as its maximum argument, so the identity block
/// spans its whole space.
const int _identitySpace = 1 << 32;

/// Eight lowercase hex characters, left-padded with zeros.
///
/// Fixed width rather than "as many as the number needs", because the id's *shape* is part of the
/// contract: a transcript that padded differently after a counter crossed 2³² would not
/// byte-compare equal to a golden one, and 4.3 billion ids in one run is not the case worth
/// optimising for. A counter that large simply widens the block, which stays inside
/// [concepts.md] §2's 32-hex limit.
///
/// [concepts.md]: ../../../../docs/concepts.md
String _hex(int value) => value.toRadixString(16).padLeft(8, '0');

/// The identity block for [seed] and [kind].
///
/// CRC-32 over the seed's UTF-8 bytes followed by the kind's index. **Public, and that is
/// deliberate**: it is part of the id *algorithm* rather than an internal detail, so the
/// contract test can pin it against the published CRC-32 test vector and a caller writing a
/// replay harness in another language can reproduce an id instead of comparing opaque strings.
///
/// A checksum is the right tool and a cryptographic digest would be the wrong one: this value
/// separates two runs of a test, and it is not a trust boundary, a capability token or anything
/// a caller could gain from predicting.
int identityBlock(String seed, IdKind kind) {
  var crc = _crcInitial;
  for (final byte in utf8.encode(seed)) {
    crc = _crc32Step(crc, byte);
  }
  // One final step per kind rather than appending the index as a byte: `Enum.index` is a Dart
  // ordinal, not a character, and a variable-width encoding of it would make the block depend on
  // how many kinds the enum had. Two kinds with adjacent indices get adjacent checksums, which is
  // the price, and the counter block in the clear is what keeps the full id unique anyway.
  crc = _crc32Step(crc, kind.index & 0xFF);
  // The final inversion, and it is not optional: CRC-32 as published ends with it, and omitting it
  // yields a value that is still perfectly deterministic and still not CRC-32. The first version
  // of this function omitted it, and the only symptom was that `identityBlock` disagreed with the
  // published test vector while agreeing with itself — which is what a test written against a
  // second copy of the same mistake would have said too. A checksum nobody can check against an
  // outside authority is a magic number, and the vector is the authority.
  return (crc ^ _crcFinalInversion) & 0xFFFFFFFF;
}

/// CRC-32's initial register value.
const int _crcInitial = 0xFFFFFFFF;

/// CRC-32's final inversion, all ones — see [identityBlock], which is where it is applied and why
/// it is the kind of step that gets dropped without anything turning red.
const int _crcFinalInversion = 0xFFFFFFFF;

/// One CRC-32 step over [byte], in the reflected IEEE form.
///
/// The shift and the exclusive-or are the whole algorithm. Nothing here widens: `crc >> 8` is
/// below 2²⁴ and the table entry is below 2³², so the result is exact in a Dart integer on the
/// VM and in a JavaScript number in a web build alike. This file's documentation says why that
/// matters, and it is the reason the identity block is not FNV-1a.
int _crc32Step(int crc, int byte) =>
    (crc >> 8) ^ _crcTable[(crc ^ byte) & 0xFF];

/// The CRC-32 byte table, computed once.
///
/// Built rather than written out, because the construction is the same shift-and-xor step and
/// therefore has the same exactness property: a 256-entry literal of hex constants is 256
/// opportunities to transcribe a digit wrongly, and a typo there is a checksum that is still
/// perfectly deterministic and perfectly wrong.
final List<int> _crcTable = _buildCrcTable();

List<int> _buildCrcTable() {
  final table = List<int>.filled(256, 0);
  for (var index = 0; index < 256; index++) {
    var value = index;
    for (var bit = 0; bit < 8; bit++) {
      value = (value & 1) != 0 ? _crcPolynomial ^ (value >> 1) : value >> 1;
    }
    table[index] = value;
  }
  return table;
}

/// The reversed CRC-32 polynomial, `0xEDB88320`.
///
/// Written as its decimal twin as well, because a hexadecimal constant with no name attached is
/// how an implementation ends up being a *different* CRC-32 than the one its test vector is from.
const int _crcPolynomial = 0xEDB88320;
