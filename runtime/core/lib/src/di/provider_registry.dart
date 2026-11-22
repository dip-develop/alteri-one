// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_provider_api/alteri_one_provider_api.dart';

/// The provider plugins available to a process (docs/spec/providers.md, §12).
///
/// A provider is a compile-time package, never an AOT module: it receives the
/// full model context and the API keys. Two providers with the same [kind]
/// are a build error, so the registry rejects a duplicate `kind` and is
/// all-or-nothing: a rejected registration stores nothing.
///
/// The registry only looks providers up. The composition root decides when to
/// call [ModelProvider.probe] and [ModelProvider.create].
final class ProviderRegistry {
  /// Creates an empty registry.
  new();

  final Map<String, ModelProvider> _byKind = <String, ModelProvider>{};

  /// The `kind` of every registered provider, in registration order.
  Iterable<String> get kinds => _byKind.keys;

  /// Whether a provider with [kind] is registered.
  bool isRegistered(String kind) => _byKind.containsKey(kind);

  /// The provider registered under [kind].
  ///
  /// Throws a [StateError] when no provider is registered under [kind].
  ModelProvider operator [](String kind) {
    final provider = _byKind[kind];
    if (provider == null) {
      throw StateError('No model provider registered under "$kind"');
    }
    return provider;
  }

  /// Registers [providers], rejecting a duplicate [ModelProvider.kind].
  ///
  /// All-or-nothing: every provider is validated before any is stored, so a
  /// rejected call leaves the registry exactly as it was. Throws a
  /// [StateError] when two of the new providers share a `kind`, or when a new
  /// `kind` is already registered.
  void registerAll(Iterable<ModelProvider> providers) {
    final incoming = <ModelProvider>[];
    final seen = <String>{};
    for (final provider in providers) {
      final kind = provider.kind;
      if (!seen.add(kind)) {
        throw StateError('Duplicate model provider kind "$kind"');
      }
      if (_byKind.containsKey(kind)) {
        throw StateError('Model provider kind "$kind" is already registered');
      }
      incoming.add(provider);
    }
    for (final provider in incoming) {
      _byKind[provider.kind] = provider;
    }
  }
}
