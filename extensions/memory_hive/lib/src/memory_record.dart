// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:schemantic/schemantic.dart';

part 'memory_record.g.dart';

/// The stored form of one personal memory entry
/// (docs/spec/storage.md, section 15.1: the `memory` `LazyBox<String>`).
///
/// The box holds JSON strings, not type adapters; the format is controlled by
/// the project and every object carries a version field `v`. [createdAt] is an
/// ISO-8601 string and [source] is `user` or `agent` (docs/spec/domain.md,
/// section 8.6).
@Schema()
abstract class $MemoryRecord {
  /// The format version, always `1` for now.
  @IntegerField(name: 'v', defaultValue: 1)
  int? get v;

  /// Stable identifier, without the `mem:` box-key prefix.
  @Field(name: 'id')
  String get id;

  /// The fact: short text, not a transcript.
  @Field(name: 'text')
  String get text;

  /// Who wrote it: `user` or `agent`.
  @Field(name: 'source')
  String get source;

  /// When it was stored, as an ISO-8601 string.
  @Field(name: 'created_at')
  String get createdAt;

  /// The run that produced it, if any.
  @Field(name: 'run_id')
  String? get runId;

  /// Search tags.
  @Field(name: 'tags')
  List<String> get tags;

  /// Whether the run that produced it had read untrusted content.
  @Field(name: 'untrusted')
  bool get untrusted;
}
