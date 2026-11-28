// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The `GET /v1/doctor` resource behind `alterione doctor`
/// (docs/spec/clients-cli.md, section 19; docs/plan/M4.md Step 14).
///
/// The CLI depends only on `contracts` and `client`, never on the core
/// (docs/spec/architecture.md, section 6), so the facts only the core knows —
/// configuration validity, the caller's scopes, extension signatures, provider
/// availability, the `llama-server` tools list, and the `distribution.yaml`
/// match — are surfaced through this read-only resource. The route enforces the
/// `read` scope; the daemon composition (Step 9) supplies an implementation
/// over the real configuration, extensions, and provider.
library;

import 'dart:convert';

import '../../domain/ports/extension_transport.dart';
import '../../domain/ports/manifest_verifier.dart';
import 'auth.dart';

/// The outcome of a single doctor check (docs/spec/clients-cli.md, section 19).
enum DoctorStatus {
  /// The check passed.
  ok('ok'),

  /// The check passed with a caveat the owner should know about.
  warn('warn'),

  /// The check failed; `alterione doctor` exits non-zero.
  fail('fail'),

  /// The check could not run (a fact is not available yet); it does not fail
  /// the command.
  skipped('skipped');

  const new(this.wire);

  /// The wire name used in the JSON report and the `--json` output.
  final String wire;

  /// Parses a wire [value], or returns `null` when it is not a known status.
  static DoctorStatus? fromWire(String value) {
    for (final status in values) {
      if (status.wire == value) return status;
    }
    return null;
  }
}

/// One doctor check result: a [name], a [status], and a human-readable [detail].
final class DoctorCheck {
  /// Creates a check result.
  const new({required this.name, required this.status, required this.detail});

  /// The check identifier, for example `daemon` or `llama_tools`.
  final String name;

  /// The outcome of the check.
  final DoctorStatus status;

  /// A human-readable explanation, secret-free.
  final String detail;

  /// The JSON object for this check; mirrors the `--json` shape.
  Map<String, Object?> toJson() => {
    'name': name,
    'status': status.wire,
    'detail': detail,
  };
}

/// The full doctor report: the ordered [checks] and the caller's [scopes].
final class DoctorReport {
  /// Creates a report.
  const new({required this.checks, required this.scopes});

  /// The checks, in the order the CLI renders them.
  final List<DoctorCheck> checks;

  /// The wire names of the scopes the caller's token grants.
  final List<String> scopes;

  /// The JSON object for this report.
  Map<String, Object?> toJson() => {
    'checks': checks.map((check) => check.toJson()).toList(),
    'scopes': scopes,
  };
}

/// Fetches [url] and returns its status and body.
///
/// The daemon's default implementation uses `dart:io`; a test injects a fake so
/// the `llama-server` tools check runs without a real server.
typedef ToolsFetcher = Future<({int status, String body})> Function(Uri url);

/// The `llama-server` built-in tools check (docs/spec/providers.md, section
/// 12.3; Q20, ADR-0018).
///
/// `GET {baseUrl}/tools` must return an empty list: a non-empty list means the
/// server's built-in tools (files, shell) are enabled, which is a hard failure
/// because they act outside `PolicyGate`. The endpoint is upstream-unstable, so
/// a `404` is a warning (Q20) and any transport error is a warning too — the
/// doctor cannot prove the tools are disabled, but it does not fail on an
/// endpoint it cannot reach. A missing [baseUrl] is `skipped`.
Future<DoctorCheck> checkLlamaServerTools({
  required String? baseUrl,
  required ToolsFetcher fetch,
}) async {
  const String name = 'llama_tools';
  if (baseUrl == null || baseUrl.isEmpty) {
    return const DoctorCheck(
      name: name,
      status: DoctorStatus.skipped,
      detail: 'provider base_url not available to the daemon',
    );
  }
  final Uri tools = Uri.parse(baseUrl).resolve('tools');
  final ({int status, String body}) response;
  try {
    response = await fetch(tools);
  } on Object catch (_) {
    return DoctorCheck(
      name: name,
      status: DoctorStatus.warn,
      detail: 'could not reach llama-server at $tools',
    );
  }
  if (response.status == 404) {
    return const DoctorCheck(
      name: name,
      status: DoctorStatus.warn,
      detail: 'GET /tools not available (404); tolerated per Q20',
    );
  }
  if (response.status < 200 || response.status >= 300) {
    return DoctorCheck(
      name: name,
      status: DoctorStatus.warn,
      detail: 'GET /tools returned ${response.status}',
    );
  }
  final List<Object?>? toolsList = _decodeList(response.body);
  if (toolsList == null) {
    return const DoctorCheck(
      name: name,
      status: DoctorStatus.warn,
      detail: 'GET /tools returned an unexpected body',
    );
  }
  if (toolsList.isEmpty) {
    return const DoctorCheck(
      name: name,
      status: DoctorStatus.ok,
      detail: 'llama-server exposes no built-in tools',
    );
  }
  return DoctorCheck(
    name: name,
    status: DoctorStatus.fail,
    detail: 'llama-server built-in tools are enabled (${toolsList.length})',
  );
}

/// A loaded extension the signature check re-verifies: its [id] and the
/// [uri] of the module it was spawned from.
final class ExtensionModuleRef {
  /// Creates a reference to the module at [uri] registered under [id].
  const new({required this.id, required this.uri});

  /// The extension identifier from its manifest.
  final String id;

  /// The module the extension was spawned from.
  final Uri uri;
}

/// The extension-signature check (docs/spec/extensions.md, sections 11.2 and
/// 11.4; docs/spec/clients-cli.md, section 19).
///
/// Re-verifies every loaded extension's module through [verifier] (the
/// signing-backed `ManifestVerifier` the composition root wires) and reports
/// `ok` only when every module verifies, `fail` when any is rejected, and
/// `skipped` — never a faked `ok` — when there is nothing to verify or no
/// verifier is wired. The [modules] are the loaded extensions in registration
/// order; the detail names each one's outcome.
Future<DoctorCheck> checkExtensionSignatures({
  required List<ExtensionModuleRef> modules,
  required ManifestVerifier? verifier,
}) async {
  const String name = 'extension_signatures';
  if (modules.isEmpty) {
    return const DoctorCheck(
      name: name,
      status: DoctorStatus.skipped,
      detail: 'no loaded extensions to verify',
    );
  }
  if (verifier == null) {
    return const DoctorCheck(
      name: name,
      status: DoctorStatus.skipped,
      detail: 'no manifest verifier wired in the composition root',
    );
  }
  final results = <String>[];
  var failed = false;
  for (final module in modules) {
    try {
      await verifier.verify(module.uri);
      results.add('${module.id}: ok');
    } on ExtensionRejected catch (error) {
      failed = true;
      results.add('${module.id}: rejected (${error.reason})');
    } on Object catch (error) {
      failed = true;
      results.add('${module.id}: error ($error)');
    }
  }
  return DoctorCheck(
    name: name,
    status: failed ? DoctorStatus.fail : DoctorStatus.ok,
    detail: results.join('; '),
  );
}

/// The contents of a personal build: its [name] and the package names of the
/// extensions it ships (docs/spec/extensions.md, section 11.7).
final class DistributionContents {
  /// Creates the contents of the build named [name] shipping [extensions].
  const new({required this.name, required this.extensions});

  /// The build name from `distribution.yaml`.
  final String name;

  /// The package names of the shipped extensions.
  final List<String> extensions;
}

/// The `distribution.yaml`-match check (docs/spec/extensions.md, section 11.7;
/// docs/spec/clients-cli.md, section 19).
///
/// Compares the running binary's contents [running] with its declared
/// [declared] `distribution.yaml`: `ok` when the extension sets are equal,
/// `fail` when they differ, and `skipped` — never a faked match — when either
/// side is not available to the running daemon (the declared file is a
/// build-time artifact the binary does not carry yet).
Future<DoctorCheck> checkDistribution({
  required DistributionContents? running,
  required DistributionContents? declared,
}) async {
  const String name = 'distribution';
  if (running == null || declared == null) {
    return const DoctorCheck(
      name: name,
      status: DoctorStatus.skipped,
      detail:
          'distribution.yaml is a build-time artifact not available to the '
          'running daemon',
    );
  }
  final runningSet = running.extensions.toSet();
  final declaredSet = declared.extensions.toSet();
  if (runningSet.length == declaredSet.length &&
      runningSet.containsAll(declaredSet)) {
    return DoctorCheck(
      name: name,
      status: DoctorStatus.ok,
      detail: 'binary matches distribution.yaml (${declared.name})',
    );
  }
  final missing = declaredSet.difference(runningSet).toList()..sort();
  final extra = runningSet.difference(declaredSet).toList()..sort();
  return DoctorCheck(
    name: name,
    status: DoctorStatus.fail,
    detail:
        'binary does not match distribution.yaml; missing: $missing, '
        'extra: $extra',
  );
}

/// Decodes [body] as a JSON list, or returns `null` when it is not one.
List<Object?>? _decodeList(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return null;
  }
  return decoded is List<Object?> ? decoded : null;
}

/// The resource seam behind `GET /v1/doctor` (docs/spec/api.md, section 16.3).
///
/// The daemon (Step 9) implements this over the real configuration, the
/// extension registry, and the provider; tests implement it as a fake. The route
/// resolves the bearer token and enforces the `read` scope before calling in.
abstract interface class DoctorResourcePort {
  /// Builds the doctor report for the device behind [token].
  Future<DoctorReport> report(DeviceToken token);
}
