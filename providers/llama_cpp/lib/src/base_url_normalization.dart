// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Base-URL normalization for the llama.cpp provider (docs/spec/providers.md,
/// section 12.3).
library;

/// Ensures [raw] has a trailing slash so `Uri.resolve` keeps the `/v1` prefix.
///
/// `Uri.parse('http://host/v1').resolve('chat/completions')` drops the `v1`
/// segment because the last segment is treated as a file; appending the slash
/// makes it a directory, so the join keeps the path. A base URL that already
/// ends in `/` is returned unchanged. Any query and fragment are discarded,
/// because they would otherwise corrupt the join; the LlamaPulse base URL is
/// always scheme, authority and path.
///
/// The returned value always ends with `/`.
String normalizeBaseUrl(String raw) {
  final base = Uri.parse(raw);
  final path = base.path.isEmpty
      ? '/'
      : (base.path.endsWith('/') ? base.path : '${base.path}/');
  // Rebuild without query or fragment: `replace(query: '', fragment: '')`
  // would leave a bare `?#`, so the fields are dropped explicitly.
  return Uri(
    scheme: base.scheme,
    userInfo: base.userInfo,
    host: base.host,
    port: base.hasPort ? base.port : null,
    path: path,
  ).toString();
}
