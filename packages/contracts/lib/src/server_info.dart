// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:schemantic/schemantic.dart';

part 'server_info.g.dart';

/// What the daemon reports about itself on `GET /v1/info`
/// (docs/spec/api.md, section 16.3).
///
/// A client reads this on connect and checks the major [protocolVersion]
/// against its own; an unknown major version is a hard error
/// (docs/spec/api.md, section 16.5). New fields may be added; removing one or
/// changing its meaning is a breaking change.
@Schema()
abstract class $ServerInfo {
  /// Major protocol version this server speaks. A client refuses a different
  /// major version (section 16.5).
  @IntegerField(
    name: 'protocol_version',
    description: 'Major protocol version the daemon speaks.',
    defaultValue: 1,
  )
  int? get protocolVersion;

  /// The Dart SDK version the daemon was built with, for example `3.14.0`.
  @Field(
    name: 'sdk',
    description: 'Dart SDK version the daemon was built with.',
  )
  String get sdk;

  /// Advertised feature tokens, for example `sse`. A client treats an
  /// unknown capability as absent.
  @Field(
    name: 'capabilities',
    description: 'Feature tokens the daemon supports.',
  )
  List<String> get capabilities;
}
