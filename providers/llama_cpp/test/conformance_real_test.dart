// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Real `llama-server` conformance (docs/spec/providers.md, section 12.4).
///
/// The test is tagged `llamapulse` and is skipped unless `ALTERIONE_LLAMA_URL`
/// points at a running server, so the normal `dart test` run never contacts a
/// model. The procedure and the evidence to record are in
/// `docs/spikes/m3-llamapulse-conformance.md`.
@Tags(<String>['llamapulse'])
library;

import 'dart:io';

import 'package:alteri_one_provider_llama_cpp/alteri_one_provider_llama_cpp.dart';
import 'package:alteri_one_testkit/alteri_one_testkit.dart';
import 'package:test/test.dart';

Future<void> main() async {
  final url = Platform.environment['ALTERIONE_LLAMA_URL'];
  if (url == null || url.isEmpty) {
    test(
      'real LlamaPulse conformance',
      () {},
      skip: 'set ALTERIONE_LLAMA_URL to run against a real llama-server',
    );
    return;
  }

  final port = LlamaCppLlm(options: LlamaCppOptions(baseUrl: url));
  runProviderConformance(port: port, tools: ConformanceTools());
}
