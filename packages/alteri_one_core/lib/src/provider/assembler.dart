/// Chunk assembly: §3.2's rules, which is the whole reason this is a file.
///
/// [architecture/providers.md] §3.2 calls this "the most common source of streaming bugs" and
/// then says why:
///
/// > - Deltas for one call are concatenated **in `index` order**, not arrival order.
/// > - Accumulated argument bytes are a `String` buffer; they are parsed as JSON exactly once,
///   after the stream ends, into the typed DTO.
/// > - A call whose accumulated arguments do not parse is `-32602` naming the tool, never a
///   silent empty object.
/// > - A missing final `usage` block is `-32603` — usage is mandatory, see §4.
/// > - `finish_reason` terminates the stream: `tool_calls` continues the loop, `stop` finishes
///   the run, `length` is `-32030` because the turn was truncated by a limit.
///
/// Every one of those five is a *rule about order or about what happens at the end*, which is why
/// the whole class is written as a fold with a terminal step. An implementation that emitted
/// deltas as it read them and patched the result afterwards would have to be correct about the
/// same five things in five different places, and §3.2 is a list of things people get wrong.
///
/// ## Why the calls are keyed by `int` in a sorted map
///
/// An `index`, not the call's `id`. §3.2's own reason: a call's id arrives with its **first**
/// fragment, so a fragment that arrives second cannot be keyed by it — and the fragments are
/// exactly what has to be accumulated. An `int` is the only key every fragment of a call shares.
///
/// And a **sorted** map, not an insertion-ordered one, because "in `index` order, not arrival
/// order" is stated as a rule about the *result* and a linked list gives the wrong answer for the
/// exact case the rule names: an endpoint that emits call `1`'s fragment before call `0`'s first
/// fragment. That is not hypothetical — a model is free to emit its tool calls in any order, and
/// `parallelTools` exists precisely because a model may emit more than one.
///
/// ## Why a result is built once, at the end, and not incrementally
///
/// [AlteriOneChatResult.assembledText] is the whole reply, not the last delta. A caller showing
/// first tokens needs the deltas; a caller wanting the answer needs this. Recomputing it from the
/// deltas would make every consumer write the same concatenation, and one of them would get the
/// order wrong.
///
/// [architecture/providers.md]: ../../../../../docs/architecture/providers.md
/// [error-codes.md]: ../../../../../docs/reference/error-codes.md
library;

import 'dart:collection';
import 'dart:convert';

import 'package:alteri_one_protocol/alteri_one_protocol.dart';

import '../provider.dart';
import 'wire.dart';

/// A refusal raised while a turn's stream was being read.
///
/// Carries the **wire** code from [error-codes.md] §1 and not a diagnostic code, and the reason
/// is which vocabulary each half of the product speaks:
/// §3.2's rules name `-32602` and `-32603`, and those are the numbers a peer, a log and an exit
/// code agree on. A caller that has to catch one exception type to find out a turn failed is the
/// alternative this avoids — which is the same argument [HttpClientPort]'s `TransportFailure`
/// makes for carrying a `retryable` flag rather than three exception classes.
///
/// The message is written to be shown to a person and is guaranteed to name no credential:
/// §1 says the original status and body "survive only in redacted diagnostics", and the values
/// put on the wire by a refused tool call are model-produced content, not secrets.
final class ProviderRefusal implements Exception {
  /// Creates a refusal carrying [code] and a [message] that names no secret.
  ProviderRefusal(
    this.code,
    this.message, {
    this.data = const <String, Object?>{},
    this.cause,
  });

  /// The code, from one of the two declared enums.
  final ErrorCode code;

  /// What went wrong, in one sentence.
  final String message;

  /// Sanitised detail. Never a credential, never private data.
  final Map<String, Object?> data;

  /// The underlying failure, when there was one.
  ///
  /// Retained rather than only described, for [TransportFailure]'s reason: a diagnostic can then
  /// report the platform's own error. It is deliberately **not** in [toString], because a URL
  /// with a query string carrying a key is the most likely thing to reach a log through a
  /// message, and a message is what gets logged.
  final Object? cause;

  @override
  String toString() => 'ProviderRefusal(${code.code} $message)';
}

/// One assembled tool call, or the `-32602` that says its arguments are not a JSON object.
///
/// §3.2's second and third bullets, and they are the two easiest to get wrong in the *helpful*
/// direction: a parse failure that yields an empty object produces a run that looks like it
/// worked, with a tool that received nothing and said so. So this either returns a whole call or
/// throws, and there is no path through it that returns something incomplete.
///
/// The id and the name are checked **before** the parse, and that order is chosen: a `-32602`
/// has to name the tool it is about (`error-codes.md` §1), so the fields that *are* the name are
/// validated first, and a call with no name is named by its index instead.
AlteriOneToolCall assembledCall(
  String? id,
  String? name,
  String arguments,
  int index,
) {
  final where = (name == null || name.isEmpty)
      ? 'the call at index $index'
      : name;
  if (id == null || id.isEmpty) {
    throw ProviderRefusal(
      JsonRpcErrorCode.invalidParams,
      'a tool call arrived with no id, so its outcome could not be attributed: $where',
      data: <String, Object?>{'index': index, 'tool': name},
    );
  }
  if (name == null || name.isEmpty) {
    throw ProviderRefusal(
      JsonRpcErrorCode.invalidParams,
      'a tool call named $id arrived with no tool name, so it dispatches nowhere',
      data: <String, Object?>{'id': id, 'index': index},
    );
  }
  // **The one parse, here, and nowhere else.** §3.2: "parsed as JSON exactly once, after the
  // stream ends". The failure is `-32602` *naming the tool*, and the raw text goes in the
  // message because a `-32602` feeds to the model and a model cannot correct a parse error it
  // cannot see.
  final Object? decoded;
  try {
    decoded = jsonDecode(arguments);
  } on FormatException catch (error) {
    throw ProviderRefusal(
      JsonRpcErrorCode.invalidParams,
      'the arguments for $name do not parse as JSON: ${error.message}. §3.2 makes this -32602 '
      'rather than an empty object, because an empty object is a call the model believes it '
      'made and the tool never received',
      data: <String, Object?>{'tool': name, 'id': id},
    );
  }
  if (decoded is! Map<String, Object?>) {
    throw ProviderRefusal(
      JsonRpcErrorCode.invalidParams,
      'the arguments for $name are a ${decoded.runtimeType} rather than a JSON object. §3.1 maps '
      'arguments onto tools[].function.parameters, which is an object, so a scalar cannot be '
      'validated against any schema',
      data: <String, Object?>{'tool': name, 'id': id},
    );
  }
  return AlteriOneToolCall(id: id, name: name, arguments: arguments);
}

/// Folds a turn's frames into the engine's own chunks, per §3.2.
///
/// Not a `Stream` transformer, and the reason is that §3.2's rules are not all *per frame*: the
/// argument parse happens once when the stream ends, and the `-32602` it raises is about the
/// accumulated text rather than about any frame. A `StreamTransformer` that could only fail on
/// the frame in hand could not express the fourth and fifth rules at all, and the natural
/// implementation — a transformer plus a post-hoc check — is the shape that produces a
/// half-assembled turn with no result.
class ChatAssembler {
  final StringBuffer _text = StringBuffer();
  final SplayTreeMap<int, _CallBuilder> _calls =
      SplayTreeMap<int, _CallBuilder>();

  /// The frame's `finish_reason`, once one has been seen.
  ///
  /// Remembered rather than read off the last frame, because the usage frame that follows it
  /// carries `choices: []` and therefore no `finish_reason` at all. A reader that took the value
  /// from the final frame would conclude no turn had finished.
  String? _finishReason;

  /// The usage reported by any frame seen so far.
  ///
  /// Last-wins rather than first-wins because a non-streaming endpoint reports it once in the
  /// body and a streaming one reports it in the final frame, and both are "the usage of this
  /// turn". §4's rule that a retry's usage *sums* into the original operation's is a rule about
  /// the caller, not about two reports of one turn.
  AlteriOneUsage? _usage;

  /// Whether a text or tool delta has been emitted.
  ///
  /// Tracked so the result can say whether the turn produced anything, which is what separates
  /// `stop` with an answer from `stop` with nothing — and the second is not an error the
  /// assembler invents, it is reported as such by the caller reading [wasEmpty].
  bool _emitted = false;

  /// Whether a reported usage has ever carried a non-zero cached count.
  ///
  /// §2's probe cannot establish [AlteriOneModelCapabilities.promptCaching] — nothing in a
  /// *request* can make an endpoint report cached tokens — so the only evidence in the whole
  /// product is a real turn whose `usage.prompt_tokens_details.cached_tokens` is non-zero. That
  /// makes this the single place the observation is made, and the provider folds it into the flag
  /// so a later probe reports what has been seen rather than asking again.
  bool get observedCachedTokens =>
      _usage != null && _usage!.cachedInputTokens > 0;

  /// The reply text accumulated so far.
  String get assembledText => _text.toString();

  /// Whether any content was emitted.
  bool get wasEmpty => !_emitted;

  /// Folds one [frame] in and returns the chunks it completed.
  ///
  /// Returns a `List` because a single frame can complete several chunks: a `delta` carrying two
  /// `tool_calls` entries is two [AlteriOneToolCallDelta]s, and a `delta` carrying both `content`
  /// and a tool call is three. An `async*` that yielded them would be the same list, one
  /// `yield` at a time, and this avoids making the caller a stream for no gain — the provider
  /// above assembles the list into one.
  List<AlteriOneChatChunk> add(ChatFrame frame) {
    final out = <AlteriOneChatChunk>[];

    final text = frame.textDelta;
    if (text != null && text.isNotEmpty) {
      // **Empty text is dropped, and that is not cosmetic.** §3.1's note on the field says an
      // empty delta "must not be dropped by a consumer that treats empty as end-of-stream" — which
      // is a statement about *consumers*, and this is the producer's decision: an endpoint sends
      // `content: ""` on the frame that opens a tool call, and a consumer that counted empty
      // deltas as content would report a turn that produced nothing as one that produced a
      // character. The field's contract is kept by the *result* carrying the assembled text.
      _text.write(text);
      _emitted = true;
      out.add(AlteriOneTextDelta(text));
    }

    final deltas = frame.toolCallDeltas;
    if (deltas.isNotEmpty) {
      // **Sorted by `index` within the frame, not just across frames.** §3.2's rule is about the
      // order the calls are *presented* in, and a frame listing them out of order would otherwise
      // emit them out of order even though the assembled result is right. The engine's own
      // `AlteriOneChatResult.toolCallIds` doc says a caller that assembled from deltas in arrival
      // order "would be assembled in arrival order rather than in `index` order — which is the
      // exact mistake §3.2 warns about", and this is the place that mistake is prevented.
      final ordered = deltas.toList()
        ..sort((a, b) => _indexOf(a).compareTo(_indexOf(b)));
      for (final delta in ordered) {
        final index = _indexOf(delta);
        final builder = _calls.putIfAbsent(index, _CallBuilder.new);
        final id = _stringOrNull(delta['id']);
        final function = delta['function'];
        final name = function is Map<String, Object?>
            ? _stringOrNull(function['name'])
            : null;
        final arguments = function is Map<String, Object?>
            ? _stringOrNull(function['arguments'])
            : null;
        if (id != null) builder.id = id;
        if (name != null) builder.name = name;
        final fragment = arguments ?? '';
        if (fragment.isNotEmpty) builder.arguments.write(fragment);
        _emitted = true;
        out.add(
          AlteriOneToolCallDelta(
            index: index,
            id: id,
            name: name,
            // Emitted verbatim, including an empty fragment, because a delta *is* a fragment and
            // the assembler is the only thing that may join them. Emitting nothing for an empty
            // one would make "the model sent a zero-length fragment" indistinguishable from "the
            // model sent no fragment", and only the second is a fact worth reporting.
            arguments: fragment,
          ),
        );
      }
    }

    final reason = frame.finishReason;
    if (reason != null) _finishReason = reason;
    final usage = frame.usage;
    if (usage != null) _usage = usage;

    return out;
  }

  /// Finishes the turn and returns the mandatory [AlteriOneChatResult].
  ///
  /// **Every failure mode of a turn is raised here rather than at a frame**, and that ordering is
  /// the point of the class: the rules that can fail are "the turn did not finish", "the turn did
  /// not report usage" and "a call's arguments did not parse", and all three are statements about
  /// the whole. Checking them per frame would report a turn as missing its usage on its first
  /// frame, which is every turn on every streaming endpoint.
  ///
  /// The order the three are checked in is itself a choice, and it is the order §3.2 lists them:
  /// the tool calls first, because a `-32602` naming a tool is a message **the model can be
  /// shown** (`error-codes.md` §1: `-32602` feeds to the model) and a `-32603` is not; then the
  /// `finish_reason`, because a turn that never finished has nothing to be long; then the usage,
  /// because by then everything the turn produced is known and only its cost is missing.
  AlteriOneChatResult finish() {
    final calls = _assembleCalls();

    if (_finishReason == null) {
      throw ProviderRefusal(
        JsonRpcErrorCode.internalError,
        'the stream ended without a finish_reason. §3.2 makes finish_reason the thing that '
        'terminates a turn, so a stream that ends without one is a turn that did not happen '
        'rather than a turn that produced nothing',
      );
    }

    final reason = switch (_finishReason) {
      'tool_calls' => AlteriOneFinishReason.toolCalls,
      'stop' => AlteriOneFinishReason.stop,
      // §3.2: "`length` is `-32030` because the turn was truncated by a limit". Not a finish and
      // not a short answer — the loop must not present a truncated reply as a complete one, and
      // `-32030` is the taxonomy's "a limit cut this short".
      'length' => throw ProviderRefusal(
        DomainErrorCode.deadlineExceeded,
        'the model stopped at a length limit, so the turn was truncated rather than answered. '
        '§3.2 makes this -32030 and not a finish reason: a truncated reply is a failure to '
        'produce an answer',
      ),
      'content_filter' => throw ProviderRefusal(
        DomainErrorCode.modelRefusal,
        'the endpoint stopped the turn on a content filter, so there is no answer to use',
      ),
      final other => throw ProviderRefusal(
        JsonRpcErrorCode.internalError,
        'the endpoint reported a finish_reason this build does not know: "$other". §3.2 names '
        'tool_calls, stop and length; treating an unknown one as "stop" would present a turn '
        'the endpoint declined to finish as a finished one',
      ),
    };

    final usage = _usage;
    if (usage == null) {
      throw ProviderRefusal(
        JsonRpcErrorCode.internalError,
        'the turn finished without a usage block. §3.2 makes this -32603 and §4 makes usage '
        'mandatory, because a run that cannot be billed cannot be given a cost ceiling. The '
        'request asked for it with stream_options.include_usage, so the endpoint declined '
        'rather than defaulted',
      );
    }

    return AlteriOneChatResult(
      finishReason: reason,
      usage: usage,
      assembledText: _text.toString(),
      toolCallIds: <String>[for (final call in calls) call.id],
    );
  }

  /// The assembled calls, in `index` order, with the argument JSON parsed exactly once.
  ///
  /// Delegating each call to [assembledCall] rather than inlining the rules is what makes the
  /// rules testable on their own: §3.2's second and third bullets are about one call, and a
  /// function that takes `(id, name, arguments, index)` can be driven with a two-character
  /// argument fragment without a stream around it. The order is [SplayTreeMap]'s iteration
  /// order, which is `index` order and nothing else.
  List<AlteriOneToolCall> _assembleCalls() => <AlteriOneToolCall>[
    for (final entry in _calls.entries)
      assembledCall(
        entry.value.id,
        entry.value.name,
        entry.value.arguments.toString(),
        entry.key,
      ),
  ];

  /// The `index` of a wire tool-call delta, or 0 when it carries none.
  ///
  /// **0 rather than a refusal, and the reason is §3.2.** The `index` is what makes a fragment
  /// addressable and an OpenAI-compatible endpoint is expected to send it; a fragment without one
  /// is an endpoint being non-conformant in a way that has an unambiguous reading — the only call
  /// in the delta. Refusing here would turn a sloppy endpoint into a run that cannot use tools at
  /// all, over a field the engine can reconstruct. The case is documented at [AlteriOneToolCallDelta]
  /// as well because a reader who finds it by grepping for `index` should not have to come here
  /// to find out what happens when it is absent.
  static int _indexOf(Map<String, Object?> delta) {
    final raw = delta['index'];
    if (raw is int) return raw;
    if (raw is double && raw.isFinite) return raw.round();
    return 0;
  }

  /// The string at [key], or null.
  static String? _stringOrNull(Object? value) => value is String ? value : null;
}

/// The accumulated fragments of one call, keyed by its `index`.
class _CallBuilder {
  /// The call's id, from the fragment that opened it.
  String? id;

  /// The tool being called, from the fragment that opened it.
  String? name;

  /// The argument JSON, accumulated as a `String` buffer per §3.2.
  final StringBuffer arguments = StringBuffer();
}
