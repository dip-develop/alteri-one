/// The error taxonomy: which code means what, and the two properties every code carries.
///
/// The table in [reference/error-codes.md] §1 is the specification. This file *is* that table,
/// in types, and a contract test parses the markdown and compares — so the two cannot drift
/// without the gate going red. A hand-maintained constant and a hand-maintained table are two
/// documents that agree until the day somebody edits one of them.
///
/// Two enums, not one, because the ranges are not interchangeable:
///
/// - [JsonRpcErrorCode] holds the codes JSON-RPC reserves with their **standard** meaning.
///   Changing one of these changes the protocol itself: a peer that sends `-32601` expects
///   *method not found*, and a different meaning is a different protocol.
/// - [DomainErrorCode] holds the codes inside `-32768…-32000`, the block JSON-RPC reserves for
///   implementation-defined errors. These are AlteriOne's, and they live in one contiguous
///   range on purpose — see [reference/error-codes.md] §1.1 for why `-32041` and `-32042` are
///   separate codes rather than variants of `-32040`.
///
/// The [ErrorCode] interface is what a frame carries, so a caller that has to handle "any
/// error" writes one `switch` and the compiler proves it is exhaustive. A code that is not in
/// either enum cannot be constructed, which is the point: an undeclared code on the wire is
/// caught by the decoder, not discovered by an operator reading a log.
library;

import 'json.dart';

/// A JSON-RPC error code.
enum JsonRpcErrorCode implements ErrorCode {
  /// The payload is not valid JSON, or is not an object.
  parseError(
    -32700,
    'Parse error: invalid JSON or payload',
    retry: RetryPolicy.no,
  ),

  /// The envelope violates JSON-RPC: a bad `type`, a missing `id`, both `result` and `error`.
  ///
  /// This is the code a frame that breaks the rules gets, and it is what the codec raises
  /// rather than a crash. A peer sending a malformed frame is answered, not disconnected.
  invalidRequest(
    -32600,
    'Invalid request: envelope violates JSON-RPC',
    retry: RetryPolicy.no,
  ),

  /// No such method, or no such tool.
  methodNotFound(-32601, 'Method or tool not found', retry: RetryPolicy.no),

  /// The payload does not match the method's schema.
  ///
  /// The one standard code that may reach the model, and only with sanitised parameters.
  invalidParams(
    -32602,
    'Invalid params',
    retry: RetryPolicy.no,
    feedsToModel: true,
  ),

  /// An unclassified internal failure.
  internalError(
    -32603,
    'Internal error',
    retry: RetryPolicy.onTransientCause,
    feedsToModel: true,
  );

  const JsonRpcErrorCode(
    this.code,
    this.summary, {
    required this.retry,
    this.feedsToModel = false,
  });

  @override
  final int code;

  /// The meaning, as the table states it.
  final String summary;

  @override
  final RetryPolicy retry;

  @override
  final bool feedsToModel;

  @override
  String toString() => '$name($code)';
}

/// An AlteriOne domain error code, inside the implementation-defined `-32768…-32000` block.
enum DomainErrorCode implements ErrorCode {
  /// No provider answered, or none satisfied the profile.
  ///
  /// The one domain code that is retried, with backoff and never in a tight loop.
  providerUnavailable(
    -32001,
    'Provider unavailable',
    retry: RetryPolicy.withBackoff,
    feedsToModel: true,
  ),

  /// The provider refused on rate. `Retry-After` is the only acceptable delay.
  rateLimited(
    -32002,
    'Rate limited, honour `Retry-After`',
    retry: RetryPolicy.afterRetryAfter,
  ),

  /// The model refused, or a content filter fired.
  ///
  /// Feeds to the model, because a refusal is exactly the thing a model can sometimes work
  /// around and the operator needs to see either way.
  modelRefusal(
    -32003,
    'Model refusal or content filter',
    retry: RetryPolicy.no,
    feedsToModel: true,
  ),

  /// A tool failed.
  toolFailed(
    -32010,
    'Tool failed',
    retry: RetryPolicy.perCapability,
    feedsToModel: true,
  ),

  /// A tool exceeded its deadline. One retry, and only with an `idempotencyKey`.
  toolTimeout(
    -32011,
    'Tool timeout',
    retry: RetryPolicy.once,
    feedsToModel: true,
  ),

  /// Policy denied the action.
  policyDenied(
    -32020,
    'Policy denied',
    retry: RetryPolicy.no,
    feedsToModel: true,
  ),

  /// A human declined the approval.
  approvalDeclined(
    -32021,
    'Approval declined',
    retry: RetryPolicy.no,
    feedsToModel: true,
  ),

  /// Approval is required, or a prior approval no longer holds.
  consentRequired(
    -32022,
    'Consent required, or a prior approval was invalidated',
    retry: RetryPolicy.no,
    feedsToModel: true,
  ),

  /// The run exceeded its deadline.
  deadlineExceeded(-32030, 'Deadline exceeded', retry: RetryPolicy.no),

  /// The run was cancelled.
  ///
  /// `-32031`, not LSP's `-32800`. The deviation is deliberate and an LSP-aware peer must
  /// translate; see [reference/error-codes.md] §2.
  cancelled(-32031, 'Cancelled', retry: RetryPolicy.no),

  /// The run exhausted its budget.
  budgetExhausted(-32032, 'Budget exhausted', retry: RetryPolicy.no),

  /// The loop stopped making progress.
  stagnationDetected(
    -32033,
    'Stagnation detected',
    retry: RetryPolicy.no,
    feedsToModel: true,
  ),

  /// A sandbox violation, or a plugin process that was killed.
  ///
  /// Not actionable by an operator: the plugin is untrusted, full stop. That is exactly why
  /// `-32041` and `-32042` are separate codes — merging them would bury two failures an
  /// operator *can* act on inside one they cannot.
  sandboxViolation(
    -32040,
    'Sandbox violation, or the plugin process was killed',
    retry: RetryPolicy.no,
  ),

  /// A digest or signature mismatch on a plugin artefact.
  ///
  /// Actionable: a corrupt or tampered distribution.
  pluginIntegrityFailure(
    -32041,
    'Plugin integrity failure: digest or signature mismatch',
    retry: RetryPolicy.no,
  ),

  /// A capability the tool asked for that policy did not grant.
  ///
  /// Actionable: a misconfiguration. Also the code that a *missing* capability produces, which
  /// is not a vulnerability — a user who never granted `shell.run` has not been attacked.
  capabilityNotGranted(
    -32042,
    'Capability not granted by policy',
    retry: RetryPolicy.no,
    feedsToModel: true,
  ),

  /// A peer exceeded a frame size or a queue depth.
  ///
  /// A protocol-level limit, deliberately distinct from a sandbox violation: it is the right
  /// signal for a peer that ignores framing limits, and it is the one the framing code raises.
  peerLimitExceeded(
    -32043,
    'Peer limit exceeded: frame size or queue depth',
    retry: RetryPolicy.no,
  ),

  /// Two versions disagree.
  ///
  /// One code for every version disagreement on the extension surface — a manifest and a
  /// lockfile, a host and an extension, a bind-time `apiVersion` and a runtime negotiation.
  /// Splitting it would produce two codes with one remedy, and an operator reading a code needs
  /// to know what to do. The specific disagreement is named in the diagnostic, not the number.
  versionIncompatible(-32050, 'Version incompatibility', retry: RetryPolicy.no);

  const DomainErrorCode(
    this.code,
    this.summary, {
    required this.retry,
    this.feedsToModel = false,
  });

  @override
  final int code;

  /// The meaning, as the table states it.
  final String summary;

  @override
  final RetryPolicy retry;

  @override
  final bool feedsToModel;

  @override
  String toString() => '$name($code)';
}

/// Any error code the protocol can carry.
///
/// A `sealed class` rather than a `sealed interface`, and that is not a style choice. An enum
/// can only `implement` its supertype, never extend it, so an *interface* is the shape a reader
/// would expect here — and on the pinned SDK 3.13.4 `sealed interface` does not parse at all.
/// The cost is that each enum restates the four members; the benefit is that `sealed` survives,
/// so a `switch` over an [ErrorCode] is exhaustive and a third enum is a compile error in every
/// handler rather than a silently unhandled case.
sealed class ErrorCode {
  const ErrorCode();

  /// The number as it appears on the wire. Negative, per JSON-RPC.
  int get code;

  /// The meaning, as the table states it.
  String get summary;

  /// Whether retrying the operation is legitimate, and on what terms.
  ///
  /// Not a bool, because the table's "Retry" column is not a bool: "with backoff", "after
  /// `Retry-After`", "one retry" and "per capability" are four different obligations and a
  /// bool would lose three of them.
  RetryPolicy get retry;

  /// Whether sanitised detail about this error may appear in model-visible data.
  ///
  /// Never means the error's own contents. "Feed to the model" in the table means a sanitised
  /// reason and parameters may, and never a credential or private data — which is a
  /// redaction obligation, not a property of the code.
  bool get feedsToModel;
}

/// Whether retrying is legitimate, and on what terms.
///
/// The other half of the specification's rule is deliberately not on this enum: "a request with
/// a side effect may be retried only when it carries an `idempotencyKey`" is a property of the
/// **request** — it is [EnvelopeMeta.idempotencyKey] — not of the code that came back. Putting it
/// here would let a caller read a code, see that a retry is allowed, and conclude the retry is
/// *safe*, which is the mistake the rule exists to prevent. A policy says whether to try again;
/// only the request says whether trying again twice is the same as trying once.
enum RetryPolicy {
  /// Never.
  no,

  /// Once, for a cause that may be transient.
  ///
  /// A single retry: an internal error that recurs on a second attempt is not transient.
  onTransientCause,

  /// Once, and only with an `idempotencyKey`.
  once,

  /// After the delay the peer asked for, and honouring it is the whole point of `-32002`.
  afterRetryAfter,

  /// With exponential backoff, at the caller's discretion.
  withBackoff,

  /// As the capability's own contract allows.
  perCapability;

  /// Whether this policy permits a retry at all.
  bool get allowsRetry => this != RetryPolicy.no;
}

/// Every code the protocol defines, standard and domain.
///
/// The whole taxonomy as one list, for the places that need to answer "is this number one of
/// ours?" — a decoder, a log formatter, the contract test that compares against the table.
Iterable<ErrorCode> get allErrorCodes => <ErrorCode>[
  ...JsonRpcErrorCode.values,
  ...DomainErrorCode.values,
];

/// The code with [code], or null when no declared code has that number.
///
/// A decoder's entry point. Null is the answer for a number outside both ranges *and* for one
/// inside the implementation-defined block that AlteriOne does not define — a peer is allowed
/// its own codes there, so an unknown one is a `-32600` on the frame rather than a crash. What
/// is not allowed is a peer choosing a number from *our* block for something else, and there
/// is no way to detect that from the number alone: the meaning is agreed by the method, which
/// is what the method registry is for.
ErrorCode? errorCodeFor(int code) {
  for (final candidate in allErrorCodes) {
    if (candidate.code == code) return candidate;
  }
  return null;
}

/// The error carried in a response.
///
/// A `data` member is allowed and is where sanitised detail goes; it is never the only
/// information, because `-32602` "names the JSON path" and an error with no path is not
/// actionable. `data` is a [JsonMap] for the same reason `params` is: it crosses the boundary
/// as JSON and is validated as such.
final class AlteriOneError {
  /// Creates an error carrying [code] with a human-readable [message].
  const AlteriOneError({
    required this.code,
    required this.message,
    this.data = JsonMap.empty,
  });

  /// The code, from one of the two declared enums.
  final ErrorCode code;

  /// What went wrong, in one sentence. Shown to an operator and, when [ErrorCode.feedsToModel]
  /// is set, to the model.
  final String message;

  /// Optional sanitised detail. Never a credential, never private data.
  final JsonMap data;

  /// The number as it appears on the wire.
  int get wireCode => code.code;

  @override
  bool operator ==(Object other) =>
      other is AlteriOneError &&
      other.code == code &&
      other.message == message &&
      other.data == data;

  @override
  int get hashCode => Object.hash(code, message, data);

  @override
  String toString() => 'AlteriOneError(${code.code} $message)';
}
