// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:bloc/bloc.dart';
import 'package:injectable/injectable.dart';

/// Status of one trigger.
final class TriggerStatus(
  /// Whether the trigger may fire.
  final bool enabled,

  /// When the trigger last fired; null if it never did.
  final DateTime? lastFired,
) {
  /// The disabled, never-fired status.
  factory initial() => TriggerStatus(false, null);

  /// Copies the status with replaced fields.
  TriggerStatus copyWith({bool? enabled, DateTime? lastFired}) =>
      TriggerStatus(enabled ?? this.enabled, lastFired ?? this.lastFired);
}

/// State of [TriggersCubit].
final class TriggersState(
  /// Trigger status by trigger id.
  final Map<String, TriggerStatus> triggers,
) {
  /// The state with no triggers.
  factory empty() => TriggersState(const {});

  /// Copies the state with a replaced map.
  TriggersState withTriggers(Map<String, TriggerStatus> value) =>
      TriggersState(value);
}

/// Enabled flags and last-firing times of triggers
/// (docs/spec/domain.md, section 8.10).
///
/// Skeleton: rate limiting (`max_per_hour`) and chain depth checks land in M2.
@lazySingleton
class TriggersCubit extends Cubit<TriggersState> {
  /// Creates the cubit with an empty registry.
  new() : super(TriggersState.empty());

  /// Registers a trigger; new triggers start disabled.
  void register(String id) {
    if (state.triggers.containsKey(id)) {
      return;
    }
    emit(state.withTriggers({...state.triggers, id: TriggerStatus.initial()}));
  }

  /// Enables or disables a registered trigger.
  void setEnabled(String id, bool enabled) {
    final status = state.triggers[id];
    if (status == null) {
      return;
    }
    emit(
      state.withTriggers({
        ...state.triggers,
        id: status.copyWith(enabled: enabled),
      }),
    );
  }

  /// Records that a trigger fired.
  void fired(String id, DateTime at) {
    final status = state.triggers[id];
    if (status == null || !status.enabled) {
      return;
    }
    emit(
      state.withTriggers({
        ...state.triggers,
        id: status.copyWith(lastFired: at),
      }),
    );
  }
}
