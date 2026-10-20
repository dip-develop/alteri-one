// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:bloc/bloc.dart';
import 'package:injectable/injectable.dart';

/// Lifecycle states of an extension (docs/spec/domain.md, section 8.10).
enum ExtensionLifecycle {
  /// Registered and serving calls.
  loaded,

  /// Stopping: in-flight calls finish, new calls are refused.
  draining,

  /// Died unexpectedly.
  crashed,

  /// Stopped cleanly.
  stopped,
}

/// State of [ExtensionsBloc]: the extension registry.
final class ExtensionsState(
  /// Extension lifecycle by extension id.
  final Map<String, ExtensionLifecycle> registry,
) {
  /// The state with no extensions.
  factory empty() => ExtensionsState(const {});

  /// Copies the state with a replaced map.
  ExtensionsState withRegistry(Map<String, ExtensionLifecycle> value) =>
      ExtensionsState(value);
}

/// Events of [ExtensionsBloc].
sealed class ExtensionsEvent {
  const new();
}

/// An extension entered the registry.
final class ExtensionRegisteredEvent extends ExtensionsEvent {
  /// Creates the event.
  const new(this.extensionId, this.lifecycle);

  /// The extension identifier from its manifest.
  final String extensionId;

  /// Its current lifecycle state.
  final ExtensionLifecycle lifecycle;
}

/// An extension changed its lifecycle state.
final class ExtensionLifecycleChangedEvent extends ExtensionsEvent {
  /// Creates the event.
  const new(this.extensionId, this.lifecycle);

  /// The extension identifier from its manifest.
  final String extensionId;

  /// The new lifecycle state.
  final ExtensionLifecycle lifecycle;
}

/// The extension registry: loaded, draining, crashed, stopped
/// (docs/spec/domain.md, section 8.10).
///
/// Skeleton: loading and draining effects land in M5. Like [RunBloc], all
/// events share one handler so registry changes stay ordered.
@lazySingleton
class ExtensionsBloc extends Bloc<ExtensionsEvent, ExtensionsState> {
  /// Creates the bloc with an empty registry.
  new() : super(ExtensionsState.empty()) {
    on<ExtensionsEvent>(_onEvent);
  }

  void _onEvent(ExtensionsEvent event, Emitter<ExtensionsState> emit) {
    switch (event) {
      case ExtensionRegisteredEvent(:final extensionId, :final lifecycle):
        emit(state.withRegistry({...state.registry, extensionId: lifecycle}));
      case ExtensionLifecycleChangedEvent(:final extensionId, :final lifecycle):
        if (!state.registry.containsKey(extensionId)) {
          return;
        }
        emit(state.withRegistry({...state.registry, extensionId: lifecycle}));
    }
  }
}
