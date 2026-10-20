// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:bloc/bloc.dart';
import 'package:injectable/injectable.dart';

/// Availability of a channel.
enum ChannelStatus {
  /// Connected: `askApproval` can reach the owner.
  connected,

  /// Unavailable: `ask` decisions degrade to `deny` (fail closed).
  unavailable,
}

/// State of [ChannelsCubit].
final class ChannelsState(
  /// Channel status by channel id (for example `cli` or `app`).
  final Map<String, ChannelStatus> channels,
) {
  /// The state with no channels.
  factory empty() => ChannelsState(const {});

  /// Copies the state with a replaced map.
  ChannelsState withChannels(Map<String, ChannelStatus> value) =>
      ChannelsState(value);

  /// Whether at least one channel can reach the owner; feeds
  /// `PolicyGate.hasInteractiveChannel`.
  bool get hasInteractive => channels.values.contains(ChannelStatus.connected);
}

/// Channel status: connected or unavailable (docs/spec/domain.md, 8.10).
///
/// Skeleton: pairing and SSE transport land in M4.
@lazySingleton
class ChannelsCubit extends Cubit<ChannelsState> {
  /// Creates the cubit with no channels.
  new() : super(ChannelsState.empty());

  /// Registers a channel in its initial status.
  void register(String id, ChannelStatus status) {
    if (state.channels.containsKey(id)) {
      return;
    }
    emit(state.withChannels({...state.channels, id: status}));
  }

  /// Updates the status of a registered channel.
  void setStatus(String id, ChannelStatus status) {
    if (!state.channels.containsKey(id)) {
      return;
    }
    emit(state.withChannels({...state.channels, id: status}));
  }
}
