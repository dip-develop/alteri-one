/// A clock that a test moves by hand.
///
/// [process/testing-strategy.md] §3 makes a deterministic clock mandatory, and
/// [architecture/observability.md] §2.1 turns it into a hard requirement:
///
/// > A fake clock fixes all timestamps, so a re-run produces the same digest.
///
/// [AlteriOneClock] has three members and this answers all three, which is the only reason the
/// fake is a good citizen of the port rather than a wrapper around one. In particular it keeps
/// the port's split between [AlteriOneClock.now] (recording) and [AlteriOneClock.monotonicNow]
/// (elapsing): a fake with one value for both would let a call site use either, and the defect
/// that causes — a deadline compared against a wall clock — would then be invisible in every test
/// that uses the double.
///
/// ## A delay answers immediately **and advances the clock**
///
/// [AlteriOneClock.delay] does not wait on this clock; it moves it. That is the decision worth
/// knowing about, and it is what makes a backoff schedule testable at all:
/// [architecture/providers.md] §5 requires a provider retry to back off and §6 to honour
/// `Retry-After`. A fake that completed `delay(2s)` without moving anything would make every
/// such assertion read `0 ms`, which is a test that passes and proves nothing; a fake that waited
/// would make the suite take as long as the run it is standing in for.
///
/// The consequence is stated rather than hidden: **a test that awaits a delay has spent that
/// time on the fake clock.** A deadline assertion is therefore about
/// [AlteriOneClock.monotonicNow] and never about a stopwatch, and a caller that must stop waiting
/// races the delay against its own cancellation signal — [AlteriOneClock]'s documentation on why
/// there is no `cancellableDelay`, and task `0.14`'s `CancelToken`.
///
/// [AlteriOneClock]: ../clock.dart
/// [architecture/observability.md]: ../../../../../docs/architecture/observability.md
/// [architecture/providers.md]: ../../../../../docs/architecture/providers.md
/// [process/testing-strategy.md]: ../../../../../docs/process/testing-strategy.md
library;

import '../clock.dart';

/// A clock whose time only moves when a test moves it.
///
/// The two origins are independent and are moved together by [advance], which is the point: a
/// fake whose wall clock and monotonic clock were one number could not express a run in which
/// NTP stepped the wall clock — and [AlteriOneClock] exists as two members precisely so that a
/// deadline is never compared against a wall clock that moved.
///
/// Neither value is `DateTime.now` or a [Stopwatch], and the reason is [AlteriOneClock]'s: a real
/// clock is not a deterministic oracle. This class is therefore shipped rather than written per
/// test, so that `plugins/memory`, `injections/skill`, `apps/cli` and any extension outside this
/// repository all measure against the same double.
final class FakeClock implements AlteriOneClock {
  /// A clock at [now], whose monotonic origin is [monotonic].
  ///
  /// [now] is converted to UTC because [AlteriOneClock.now] is UTC, and a local [DateTime] in a
  /// test would put a zone offset into every transcript the run produces. A caller that means a
  /// local instant converts it explicitly, which is the rendering decision the port says belongs
  /// at the edge.
  FakeClock({DateTime? now, Duration monotonic = Duration.zero})
    : _now = (now ?? _defaultInstant).toUtc(),
      _monotonic = monotonic,
      assert(
        !monotonic.isNegative,
        'a monotonic clock cannot start before its own origin',
      );

  /// The instant a fake clock starts at when the caller names none.
  ///
  /// A fixed instant, not the current time, and the reason is that a default of "now" would make
  /// every test that forgot to pass one depend on the wall clock — the defect this package
  /// exists to prevent, introduced by the package that prevents it. The value is the Unix epoch
  /// in UTC: a round, obviously-synthetic value that a transcript shows as `1970-01-01T00:00:00Z`
  /// rather than something a reader could mistake for a real run.
  static final DateTime _defaultInstant = DateTime.utc(1970);

  DateTime _now;
  Duration _monotonic;

  @override
  DateTime now() => _now;

  @override
  Duration monotonicNow() => _monotonic;

  @override
  Future<void> delay(Duration duration) {
    _checkMovesForward(duration, 'delay');
    return _advance(duration);
  }

  /// Moves both origins by [duration].
  ///
  /// The one mutator, and both origins move together because that is the only change a fake
  /// clock can make that a real one would not: real time passes, and it passes for both readings
  /// at once. A test that needs the two to disagree — a wall-clock step during a run — has
  /// [setWallClock] for exactly that, and it is a separate member so that a reader can see the
  /// ordinary case needs neither.
  void advance(Duration duration) {
    _checkMovesForward(duration, 'advance');
    _advance(duration);
  }

  /// Sets the wall clock without touching the monotonic origin.
  ///
  /// The one way to make the two disagree, and it exists for the case [AlteriOneClock] is written
  /// for: a deadline must not move when the wall clock does. A test that steps the wall clock
  /// forwards and then checks that a deadline computed from [monotonicNow] has *not* expired is
  /// asserting the property the two-member port exists to provide, and it cannot be written
  /// without this member.
  void setWallClock(DateTime instant) => _now = instant.toUtc();

  /// The advance, shared so that [delay] and [advance] cannot drift apart.
  Future<void> _advance(Duration duration) {
    _now = _now.add(duration);
    _monotonic += duration;
    return Future<void>.value();
  }

  void _checkMovesForward(Duration duration, String member) {
    if (duration.isNegative) {
      throw ArgumentError.value(
        duration,
        'duration',
        '$member cannot move a clock backwards: [AlteriOneClock.monotonicNow] is required '
            'never to decrease, so a double that could move it backwards would let a test pass '
            'that the product forbids',
      );
    }
  }
}
