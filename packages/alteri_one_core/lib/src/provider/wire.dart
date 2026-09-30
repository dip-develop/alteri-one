/// The OpenAI-compatible wire: the request this product writes and the frames it reads.
///
/// [architecture/providers.md] §1 is the reason this file exists in the shape it has:
///
/// > `AlteriOneProvider` does not wrap a vendor SDK. The OpenAI-compatible implementation is
/// > built on `package:http` with its own typed DTOs: that preserves one wire format without
/// > inheriting an opinionated type set or a third party's invalid assumptions.
///
/// So there is one dictionary here and it is this product's, and the fact that it happens to be
/// the OpenAI Chat Completions shape is a fact about interoperability rather than about the
/// engine's vocabulary. Nothing in [provider.dart] — where the engine's own DTOs live — carries
/// a wire name, and nothing here carries an engine type. The two meet in exactly one place: the
/// provider this directory is named for.
///
/// ## Where the bytes go
///
/// Through [HttpClientPort] from `alteri_one_platform`, not through a `package:http` import.
/// The two are the same wire and a different layer, and the port is the layer this repository
/// chose: `architecture/install-and-update.md` §1's *"there is no analytics call, no crash report
/// and no version ping"* is proven by swapping that port for a deny-all client (task `0.21`), and
/// an inlined `package:http` call has nothing to swap. It would also make the core
/// browser-unbuildable, because `package:http`'s barrel reaches `dart:io` on the VM — and the
/// workspace contract test walks every product library's closure the way a web build resolves it,
/// precisely so that a dependency which quietly does that fails a test rather than a release.
///
/// The exchange is a **single** streaming request and a **single** response, and [ChatExchange]
/// is the only thing that opens one. §6's retry and idempotency rules are the caller's: `HttpResponse`
/// hands a non-2xx back as a response rather than a failure precisely so that a 429's
/// `Retry-After` and a 400's body survive to whoever decides what to do.
///
/// ## The two wire conventions worth naming
///
/// **Snake case, and it is not negotiable.** `max_tokens`, `tool_calls`, `finish_reason`,
/// `prompt_tokens_details`, `cached_tokens`. The engine's own names are camel case
/// (`maxOutputTokens`, `toolCallIds`, `finishReason`), and the two vocabularies meet only inside
/// the functions in this file. A `toJson` that leaked an engine name would be an endpoint that
/// silently ignores it, and the symptom would be a request that quietly loses a bound.
///
/// **Usage is a separate top-level member on the final frame, not a member of a choice.** On a
/// streaming response the last meaningful frame carries `choices: []` and a `usage` object,
/// because that is the only way an endpoint can report what a stream cost after the choices are
/// already finished. [ChatFrame.usage] is therefore nullable *on a frame* and non-null *on an
/// assembled turn*, and §3.2's rule — a missing one is `-32603` — is enforced in the assembler
/// rather than here.
///
/// [architecture/providers.md]: ../../../../../docs/architecture/providers.md
/// [architecture/install-and-update.md]: ../../../../../docs/architecture/install-and-update.md
/// [architecture/overview.md]: ../../../../../docs/architecture/overview.md
/// [provider.dart]: ../provider.dart
library;

import 'dart:convert';

import '../profile/profile.dart';
import '../provider.dart';

/// The terminator an OpenAI-compatible endpoint sends to close a stream.
///
/// Not a `finish_reason` and not an empty frame: it is a **sentinel on the transport**, and it is
/// the only value in a stream that is not JSON — which is why the reader recognises it by
/// comparison and never by decoding it.
///
/// **Its absence is not a failure, and the reader does not insist on it.** §3.2 makes
/// `finish_reason` the thing that terminates a turn, and [ChatAssembler] enforces the three rules
/// that follow from that: a turn with no `finish_reason` is `-32603`, a turn with no usage is
/// `-32603`, and a truncated one is `-32030`. A stream that closes its connection without a
/// sentinel but did report a `finish_reason` and a usage has said everything §3.2 requires of a
/// finished turn, and refusing it would be refusing a conformant-enough endpoint on a formality
/// the specification does not state. The sentinel's role is narrower: it ends the *reading*, so
/// that whatever a pooled connection sends next is not folded into this turn.
const String streamDoneSentinel = '[DONE]';

/// The `content-type` a streaming response carries, and the only signal that it streams.
///
/// Checked rather than assumed, because §3 requires the adapter in the other direction: *"A
/// non-streaming endpoint may implement the interface with an adapter that emits a single final
/// chunk."* So the reader must be able to discover which of the two it has, and the header is
/// what says so. A body that is neither — JSON or SSE — is `-32700`.
const String eventStreamContentType = 'text/event-stream';

/// The wire name of each [AlteriOneRole], and the only place the mapping is written down.
///
/// A `switch` over the enum rather than `role.name`, because `AlteriOneRole.assistant` is
/// `assistant` on the wire and the reason a `switch` is safe is that the enum is closed: a fourth
/// role is a compile error here rather than a `Bad state: no such role` on a request.
String wireRoleName(AlteriOneRole role) => switch (role) {
  AlteriOneRole.system => 'system',
  AlteriOneRole.user => 'user',
  AlteriOneRole.assistant => 'assistant',
  AlteriOneRole.tool => 'tool',
};

/// One message as the wire spells it.
///
/// A function rather than a class because the mapping is **total and mechanical**, and §3.1 says
/// so: a `toJson` on the engine's own [AlteriOneMessage] would put wire names in the port, and
/// the port is what a second wire format would have to be checked against. Three members, three
/// fields, one table — and the table is [wireRoleName] plus the branches below.
///
/// The three branches §3.1's table does *not* cover, because they are about correlation rather
/// than content:
///
/// - `role: tool` carries `tool_call_id`, and it is **required**. The engine's constructor
///   already refuses an uncorrelated tool message, so the value here is non-null by
///   construction and the fallback is unreachable rather than defensive.
/// - An assistant turn that called tools carries `tool_calls`, each with its `type`,
///   `function.name` and `function.arguments`. The argument text goes on the wire as the JSON
///   string the model produced, not as a nested object, because the endpoint re-parses it and a
///   re-serialisation here would be a second place for an escaping difference to appear.
/// - `content` is `null` for an assistant turn whose text is entirely tool calls, which is the
///   ordinary shape of such a turn and which [jsonEncode] cannot express for an empty string
///   without it being a *different* request.
Map<String, Object?> wireMessage(AlteriOneMessage message) {
  final wire = <String, Object?>{
    'role': wireRoleName(message.role),
    'content': message.content.isEmpty ? null : message.content,
  };
  final toolCallId = message.toolCallId;
  if (toolCallId != null) wire['tool_call_id'] = toolCallId;
  if (message.toolCalls.isNotEmpty) {
    wire['tool_calls'] = <Map<String, Object?>>[
      for (final call in message.toolCalls)
        <String, Object?>{
          'id': call.id,
          'type': 'function',
          'function': <String, Object?>{
            'name': call.name,
            'arguments': call.arguments,
          },
        },
    ];
  }
  return wire;
}

/// The body of one `POST {baseUrl}/chat/completions`.
///
/// [stream] is a parameter rather than a constant, and the reason is §3: streaming is in the
/// contract from the first version, and an endpoint that does not support it is answered by an
/// adapter emitting a single final chunk — never by a different interface. So the *request* is
/// the only thing that differs, and the difference is one boolean the probe already decided.
///
/// [maxTokensKey] is a parameter for the same reason one level up: a vendored endpoint that
/// renamed the output cap renames it in the request, and the *request* is the only place the name
/// appears. Which key a given endpoint wants is part of its capability matrix, not a constant of
/// the product.
Map<String, Object?> chatRequestBody({
  required String model,
  required List<Map<String, Object?>> messages,
  required bool stream,
  int? maxOutputTokens,
  String maxTokensKey = 'max_tokens',
  int? seed,
  double? temperature,
  bool jsonMode = false,
  List<Map<String, Object?>>? tools,
  bool? parallelToolCalls,
}) {
  final body = <String, Object?>{
    'model': model,
    'messages': messages,
    'stream': stream,
    if (maxOutputTokens != null) maxTokensKey: maxOutputTokens,
    if (seed != null) 'seed': seed,
    if (temperature != null) 'temperature': temperature,
    if (jsonMode) 'response_format': <String, Object?>{'type': 'json_object'},
    if (tools != null) 'tools': tools,
    if (parallelToolCalls != null) 'parallel_tool_calls': parallelToolCalls,
  };
  if (stream) {
    // **The reason usage is mandatory rather than usual.** Without this, a streaming endpoint
    // reports no usage at all, and §4's "usage is mandatory on every successfully completed model
    // turn" could not be checked — the absent block would be indistinguishable from an endpoint
    // that simply does not report it. Asking for it explicitly is what turns §3.2's `-32603` into
    // a real check: the endpoint was asked and did not answer.
    body['stream_options'] = <String, Object?>{'include_usage': true};
  }
  return body;
}

/// One decoded frame of a streaming response, or the whole body of a batch one.
///
/// A `final class` over [Map] rather than a generated DTO, and the reason is §1's: the wire's
/// type set is not the product's, and a DTO per vendor field would be a second description of the
/// wire that has to be kept in step with the first. What is decoded eagerly is exactly what §3.2
/// names — the choice's [delta], its [finishReason], and the frame's [usage] — and the rest stays
/// a map a caller can read without this file having enumerated a vendor's whole schema.
///
/// Every field is nullable for one reason: **an OpenAI-compatible endpoint is not obliged to
/// agree with itself.** A frame with no `choices` is how the usage frame arrives; a choice with
/// no `delta` is how a heartbeat arrives; a `delta` with neither `content` nor `tool_calls` is
/// how a `finish_reason` arrives. Modelling those as separate frame types would be a fiction about
/// the wire, and the falsity would be paid for in a crash on a real endpoint.
final class ChatFrame {
  /// Wraps a decoded frame body.
  const ChatFrame(this.json);

  /// The whole decoded frame, unmodifiable.
  final Map<String, Object?> json;

  /// The first choice, or null when the frame carries none.
  ///
  /// `choices[0]` and not a search: the engine's own port has exactly one conversation per turn
  /// ([AlteriOneRequest] carries one [AlteriOneConversation]), and a request for `n > 1` is not
  /// one this product makes. A frame with several choices is read as its first, and [choiceCount]
  /// exists so a caller can see that is what happened.
  Map<String, Object?>? get choice {
    final choices = json['choices'];
    if (choices is! List<Object?>) return null;
    for (final entry in choices) {
      if (entry is Map<String, Object?>) return entry;
    }
    return null;
  }

  /// How many choices the frame carries.
  int get choiceCount {
    final choices = json['choices'];
    return choices is List<Object?> ? choices.length : 0;
  }

  /// The delta the first choice carries, or null.
  Map<String, Object?>? get delta {
    final choice = this.choice;
    if (choice == null) return null;
    final delta = choice['delta'];
    return delta is Map<String, Object?> ? delta : null;
  }

  /// The `finish_reason` of the first choice, or null.
  ///
  /// Null on every frame of a turn that has not finished **and** on a frame whose `choices` is
  /// empty, which is the usage frame. The two are the same value here and the assembler keeps them
  /// apart by remembering that a turn has finished.
  String? get finishReason {
    final choice = this.choice;
    if (choice == null) return null;
    final reason = choice['finish_reason'];
    return reason is String ? reason : null;
  }

  /// The frame's usage, or null.
  ///
  /// Nullable on a frame and mandatory on a turn — see this file's documentation.
  AlteriOneUsage? get usage {
    final raw = json['usage'];
    if (raw is! Map<String, Object?>) return null;
    return tryReadUsage(raw);
  }

  /// The text the first choice's delta added, or null.
  String? get textDelta {
    final delta = this.delta;
    if (delta == null) return null;
    final content = delta['content'];
    return content is String ? content : null;
  }

  /// The tool-call deltas the first choice carried, in the order the wire listed them.
  ///
  /// Raw maps rather than [AlteriOneToolCallDelta]s, because the assembler is the one thing that
  /// knows an `index` is the assembly key and it must not be able to receive a fragment that has
  /// already been re-keyed by something that did not.
  List<Map<String, Object?>> get toolCallDeltas {
    final delta = this.delta;
    if (delta == null) return const <Map<String, Object?>>[];
    final calls = delta['tool_calls'];
    if (calls is! List<Object?>) return const <Map<String, Object?>>[];
    return <Map<String, Object?>>[
      for (final entry in calls)
        if (entry is Map<String, Object?>) entry,
    ];
  }

  @override
  String toString() => 'ChatFrame(${json['object'] ?? 'object'})';
}

/// Reads a wire `usage` object, or null when it is absent or unreadable.
///
/// **Null rather than a throw, deliberately.** A frame with no `usage` is the ordinary usage
/// frame's companion on a stream where the endpoint reports usage only at the end, and every
/// earlier frame of that turn has no `usage` either. The rule §3.2 states — *a missing final
/// `usage` block is `-32603`* — is about the *turn*, and it is enforced where the turn is
/// assembled. A reader that threw per frame would make every non-final frame a failure.
AlteriOneUsage? tryReadUsage(Map<String, Object?> raw) {
  final input = _intOrNull(raw['prompt_tokens']);
  final output = _intOrNull(raw['completion_tokens']);
  if (input == null || output == null) return null;
  var cached = 0;
  final details = raw['prompt_tokens_details'];
  if (details is Map<String, Object?>) {
    cached = _intOrNull(details['cached_tokens']) ?? 0;
  }
  // A cached count larger than the input it is a subset of is a report this product cannot
  // account with, and §4 builds the budget on the normalised record — so it is clamped rather
  // than trusted, and the check is here where the shape is known. `AlteriOneUsage` documents
  // that `cachedInputTokens` is a subset of `inputTokens`; this is what makes that true of a
  // wire that did not.
  if (cached < 0) cached = 0;
  if (cached > input) cached = input;
  return AlteriOneUsage(
    inputTokens: input,
    outputTokens: output,
    cachedInputTokens: cached,
  );
}

/// The integer at [key], or null.
///
/// `num` and not `int` on purpose: `jsonDecode` produces `int` for a JSON integer and `double`
/// for a JSON number written with a fraction, and an endpoint that writes `10.0` is still
/// reporting ten tokens. Rejecting that would make a usage block unreadable for a formatting
/// difference.
int? _intOrNull(Object? value) {
  if (value is int) return value;
  if (value is double) {
    if (value.isNaN || value.isInfinite) return null;
    return value.round();
  }
  return null;
}

/// The request URL for [baseUrl], built by appending and never by resolving.
///
/// `Uri.resolve` **replaces the base's last segment**, so
/// `Uri.parse('http://127.0.0.1:11434/v1').resolve('chat/completions')` is
/// `http://127.0.0.1:11434/chat/completions` — outside the `/v1` the profile named, produced by
/// a method whose purpose is to produce a path inside it, and looking like a successful join.
/// `resolveBeneath` in `alteri_one_platform`'s `src/paths.dart` exists for the same reason, and
/// this is a second instance of the same trap on a URL rather than a path, so the join is written
/// out: a trailing slash is added when absent, and the segment is appended.
///
/// Throws [ArgumentError] for a base that is not absolute http or https. A `file:` or a bare
/// host is refused **here** rather than becoming a confusing transport failure, and the check is
/// a precondition of the whole file: `install-and-update.md` §1's egress rules are evaluated
/// against this URI, and a scheme they cannot classify is a request the policy has no verdict on.
Uri chatCompletionsUri(String baseUrl) {
  final Uri base;
  try {
    base = Uri.parse(baseUrl);
  } on FormatException catch (error) {
    // **`Uri.parse` raises, and the raise is not an `ArgumentError`.** `127.0.0.1:11434/v1` has
    // no scheme, so the parser reads `127` as one and rejects it — and a bare host is the most
    // likely mistake in a hand-written profile, so it must arrive as the configuration
    // diagnostic the caller expects rather than as a `FormatException` from a URI builder.
    throw ArgumentError.value(
      baseUrl,
      'baseUrl',
      'not a URL: ${error.message}',
    );
  }
  if (!base.hasScheme || base.host.isEmpty) {
    throw ArgumentError.value(
      baseUrl,
      'baseUrl',
      'a provider base URL must be an absolute http or https URL; the egress rules in '
          'install-and-update.md §1 are evaluated against this URI and a scheme they cannot '
          'classify has no verdict',
    );
  }
  if (base.scheme != 'http' && base.scheme != 'https') {
    throw ArgumentError.value(
      baseUrl,
      'baseUrl',
      'the provider wire is https or http; "${base.scheme}" is neither and is not something the '
          'egress policy can rule on',
    );
  }
  final basePath = base.path.endsWith('/') ? base.path : '${base.path}/';
  return base.replace(path: '${basePath}chat/completions');
}

/// Encodes [body] as the bytes of a request, and names the content type that goes with it.
///
/// One function rather than a constant next to a call site, because the pair *is* one fact: a
/// body encoded as UTF-8 with a `content-type` that says something else is a request an endpoint
/// either refuses or, worse, parses under the wrong rules. §3.2's tool arguments can contain
/// any Unicode the model produced, so the encoding is not ASCII.
({List<int> body, Map<String, List<String>> headers}) encodeJsonRequest(
  Map<String, Object?> body,
) {
  final encoded = utf8.encode(jsonEncode(body));
  return (
    body: encoded,
    headers: <String, List<String>>{
      'content-type': <String>['application/json; charset=utf-8'],
    },
  );
}

/// The name of a [ModelFeature] as the wire and the profile both spell it.
///
/// **A one-line function on purpose.** It looks like indirection and is the opposite: a reader
/// arriving from the wire name `jsonMode` needs to find out that the Dart enum member is *not*
/// `jsonMode` — that it is spelled `json_object` or `JSONMode` in the codebase — and this is the
/// one place that says so in a way a `grep` for `wireName` cannot. The body is
/// `feature.wireName` because there is exactly one table, in `profile.dart`, and duplicating the
/// mapping here would be a second spelling to keep in step with the first.
String modelFeatureWireName(ModelFeature feature) => feature.wireName;
