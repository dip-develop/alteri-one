/// The native clock: `DateTime.now()` for records, a stopwatch for elapsed time.
///
/// The two come from different sources on purpose. See `src/clock.dart` for why one port cannot
/// answer both questions, and this file is where that separation is implemented rather than
/// documented: [PlatformClock.now] reads the wall clock, which may jump, and
/// [PlatformClock.monotonicNow] reads a [Stopwatch], which cannot.
library;

import 'dart:async';

import '../clock.dart';

/// The clock the product ships with.
///
/// A [Stopwatch] is the monotonic source because `dart:async` has no monotonic clock of its own and
/// `dart:io` does not export one either. [Stopwatch] reads the platform's monotonic counter —
/// `QueryPerformanceCounter` on Windows, `mach_absolute_time` on macOS, `CLOCK_MONOTONIC` on Linux —
/// so it is the right primitive, and the reason the answer is a [Duration] rather than an
/// instant.
///
/// The origin is this object's construction, so [monotonicNow] is only ever meaningful as a
/// difference and is never an absolute time.
final class PlatformClock implements AlteriOneClock {
  /// Creates the clock and starts its monotonic origin.
  PlatformClock();

  final Stopwatch _monotonic = Stopwatch()..start();

  @override
  DateTime now() => DateTime.now().toUtc();

  @override
  Duration monotonicNow() => _monotonic.elapsed;

  @override
  Future<void> delay(Duration duration) => Future<void>.delayed(duration);

  @override
  String toString() => 'PlatformClock(monotonic: ${_monotonic.elapsed})';
}
