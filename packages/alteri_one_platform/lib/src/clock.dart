/// The clock the engine reads, and the two kinds of time it needs.
///
/// [process/testing-strategy.md] §3 names `AlteriOneClock` as a mandatory determinism double, and
/// lists what it has to provide: **time, deadline expiry and retry timing**. Those are two
/// different clocks, and the reason this port is not one `now()` method is that conflating them is
/// a defect that only appears on a machine whose clock is adjusted mid-run.
///
/// ## Why two sources of time
///
/// [monotonicNow] is for **elapsing** and [now] is for **recording**, and they must not be
/// interchanged:
///
/// - A deadline is an elapsed-time comparison. [core.CostBudget] and `Deadline` of task `0.14` ask
///   "has this run out of time yet?", and the answer must not move backwards when NTP steps the
///   system clock, or when the user changes the timezone, or when a laptop resumes from sleep.
///   `DateTime.now()` answers that question wrongly roughly once a year per host, and always on
///   the machines most likely to be running an agent: laptops.
/// - A trace record is an absolute instant. "The provider replied at 14:03:22Z" is only meaningful
///   against wall time, and a transcript that recorded *monotonic* offsets would not be comparable
///   across two runs, let alone across two machines — which is exactly what
///   [ADR-0013]'s transcript-first tracing is for.
///
/// A port with only `now()` forces callers to pick: use it for a deadline and the loop can stall
/// across a clock step; use it for a record and two runs of the same script produce transcripts
/// that differ in every timestamp and cannot be compared. A port with both makes the choice a
/// name instead of an inference.
///
/// ## What the port deliberately does not have
///
/// - **No timer, no `Stream<DateTime>` ticks.** Nothing in v1 needs a periodic source, and a port
///   that offers one invites `Stream.periodic` in production code — which is a scheduling
///   dependency in an engine whose [architecture/protocol.md] §7.1 in-process transport is
///   specified as having no scheduler at all. The engine waits with [delay] and gets scheduled by
///   whoever holds the token.
/// - **No cancellation.** [delay] is a plain future and a caller that needs to stop waiting
///   races it against its own cancellation signal, which is task `0.14`'s `CancelToken` and
///   belongs to the engine rather than to a platform. A `cancellableDelay` here would be the
///   second cancellation mechanism in the product, and the one that is hardest to test.
/// - **No time zone.** [now] is UTC. A local time is a rendering decision, made once at the edge
///   with `intl` (task `0.11`), and a clock that could answer either produces transcripts whose
///   timestamps depend on the machine that wrote them.
///
/// [process/testing-strategy.md]: ../../../../docs/process/testing-strategy.md
/// [architecture/protocol.md]: ../../../../docs/architecture/protocol.md
/// [core.CostBudget]: ../../../../docs/architecture/engine.md
/// [ADR-0013]: ../../../../docs/decisions/0013-transcript-first-tracing.md
library;

/// The source of every time value in the product.
///
/// Injected into every trace and every deadline ([observability.md](../observability.md) §2): no
/// production code calls [DateTime.now] directly, because a real clock is not a deterministic
/// oracle and an engine that cannot be replayed cannot be tested at its own boundary.
///
/// Implemented by `PlatformClock` on every platform the product ships, and by a fake from task
/// `0.10`, which is where the shipped doubles arrive.
abstract interface class AlteriOneClock {
  /// The current wall-clock instant, in UTC, for **recording** when something happened.
  ///
  /// UTC and not the host's local zone, so a transcript written on a machine in one zone is
  /// comparable with one written in another. Use this for a timestamp that goes into a trace or a
  /// transcript; use [monotonicNow] to ask how long something took.
  ///
  /// May jump in either direction — an NTP correction is a legitimate thing for a wall clock to do
  /// — which is precisely why it is the wrong answer for a deadline.
  DateTime now();

  /// Time elapsed since this clock's own origin, for **measuring** and **expiring**.
  ///
  /// Never decreases within one process, whatever the host's wall clock does, which is the
  /// property a deadline comparison needs and [now] does not have. It is relative to an arbitrary
  /// origin chosen by the implementation, so it is meaningful only as a difference and must never
  /// be written into a transcript as a timestamp.
  ///
  /// A fake clock of task `0.10` advances this explicitly; the seeded mode moves it in whole
  /// milliseconds so a replayed script reproduces every expiry decision it made.
  Duration monotonicNow();

  /// Completes after [duration] has elapsed on this clock.
  ///
  /// The only place in the product that waits on wall time, which is what makes it the one member
  /// a test has to be able to answer immediately. It does not complete early and it never throws:
  /// a fake answers on demand, and a real clock's [Timer] cannot fail.
  ///
  /// **Not cancellable**, and that is a decision rather than an omission. A caller that must stop
  /// waiting — a cancelled request, a deadline that has already expired — races this future
  /// against its own cancellation signal (task `0.14`'s `CancelToken`) and abandons the loser. A
  /// cancellable delay here would be the second cancellation mechanism in the product, would have
  /// to be composable with the first, and would be the harder of the two to test: the difference
  /// between "the caller stopped waiting" and "the timer fired" is invisible in the result, and
  /// every caller would have to be written to tell them apart.
  Future<void> delay(Duration duration);
}
