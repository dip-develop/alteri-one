// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:bloc/bloc.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:injectable/injectable.dart';

/// State of [SchedulerBloc].
final class SchedulerState(
  /// When the last processed tick fired; null before the first one.
  final DateTime? lastTick,
) {
  /// The state before any tick.
  factory initial() => SchedulerState(null);

  /// Copies the state with a replaced `lastTick`.
  SchedulerState withLastTick(DateTime value) => SchedulerState(value);
}

/// A schedule tick fired (docs/spec/domain.md, section 8.10).
final class SchedulerTickEvent {
  /// Creates the event.
  const new(this.at);

  /// When the tick fired.
  final DateTime at;
}

/// Schedule ticks. The `droppable` transformer skips a tick while the
/// previous one is still being processed (docs/spec/domain.md, 8.10).
///
/// Skeleton: starting scheduled runs lands in M2; the handler currently only
/// records the tick.
@lazySingleton
class SchedulerBloc extends Bloc<SchedulerTickEvent, SchedulerState> {
  /// Creates the bloc.
  new() : super(SchedulerState.initial()) {
    on<SchedulerTickEvent>(_onTick, transformer: droppable());
  }

  // TODO(m2): evaluate schedules and start due runs inside the handler.
  void _onTick(SchedulerTickEvent event, Emitter<SchedulerState> emit) {
    emit(state.withLastTick(event.at));
  }
}
