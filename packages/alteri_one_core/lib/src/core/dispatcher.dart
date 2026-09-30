/// The dispatcher: route a namespaced method to its owner, with no core change per capability.
///
/// [docs/architecture/overview.md] §5 is the table, and this file is it:
///
/// | Prefix | Routed to |
/// |---|---|
/// | `core/*` | `AlteriOneCore` built-in methods |
/// | `$/` | Protocol control: `$/cancelRequest`, `$/progress` |
/// | `<namespace>.*` | The plugin registered under `<namespace>` |
///
/// The last row is the load-bearing one and it is what the whole design is for. **Adding a
/// plugin providing a new namespace requires no change to the core** — not a new `case`, not a
/// new import, not a new entry in a table here. The dispatcher resolves the leading segment of
/// the method to a [MethodNamespace] and looks it up in an [ExtensionRegistry]; a namespace that
/// was never heard of routes by exactly the same code path as one that was.
///
/// ## Why the lookup is a map and not a `switch`
///
/// A `switch` over namespace *values* is the thing `overview.md` §5 forbids by implication and
/// this file avoids on purpose: it would need a case per namespace, so a new one is a core edit
/// and the promise is false. A `switch` over the three *reserved* prefixes is a different thing
/// and is the right shape there, because those are built into the language of the protocol rather
/// than into this product — but even that is a lookup, because `core` and `$` are owners in the
/// same registry as everything else. There is no prefix branch at all; see
/// [MethodDispatcher.route] for why.
///
/// ## What the dispatcher does not do
///
/// It does not decode, does not authorise, does not measure, and does not hold state. A call
/// arrives, is routed, and the handler answers. `protocol.md` §1.2's typed decode is a generated
/// registry this does not own; `policy.md`'s capability check is a later call; and
/// `engine.md` §3's loop invariants belong to the engine. A dispatcher that also did any of
/// those would be a second place each of them is implemented.
library;

import 'package:alteri_one_protocol/alteri_one_protocol.dart';

import 'method_call.dart';
import 'namespace.dart';
import 'registry.dart';

/// The outcome of routing one call.
///
/// A value rather than a `AlteriOneResult` or a thrown error, and the reason is
/// [docs/reference/error-codes.md] §4.1: an unknown method is `-32601` and a handler that throws
/// is `-32603`, and **the dispatcher cannot tell those apart if it only returns results**. A
/// caller that got an `AlteriOneResult` back would have to inspect its body to discover a routing
/// failure, which is exactly the "a result that happened to be absent" confusion
/// `ResponseEnvelope` documents avoiding.
final class DispatchOutcome {
  /// A successful routing, carrying what the handler answered.
  const DispatchOutcome.delivered(this.result) : error = null;

  /// A refused routing, carrying the error to answer the peer with.
  const DispatchOutcome.refused(this.error) : result = null;

  /// What the handler answered, or null when the call was refused.
  final AlteriOneResult? result;

  /// Why the call was refused, or null when it was delivered.
  final AlteriOneError? error;

  /// Whether the call reached a handler.
  bool get isDelivered => result != null;

  /// The outcome as a protocol response body, so a transport can answer without a second
  /// `switch` on the same distinction.
  ResponseBody get body =>
      result != null ? ResultBody(result!.value) : ErrorBody(error!);

  @override
  String toString() => isDelivered
      ? 'DispatchOutcome(delivered $result)'
      : 'DispatchOutcome($error)';
}

/// Routes calls to the handler that owns their namespace.
final class MethodDispatcher {
  /// Creates a dispatcher over [registry].
  MethodDispatcher(this.registry);

  /// The bound units. Read-only for the dispatcher's whole life, which is what lets
  /// [MethodDispatcher] be a plain object with no invalidation.
  final ExtensionRegistry registry;

  /// Routes [call] and awaits its answer.
  ///
  /// **One lookup, no prefix branch.** `registry[call.namespace]` is the whole dispatch: `core`
  /// resolves because the registry was seeded with the engine, `$` because it was seeded with
  /// the control plane, and `web` because a plugin claimed it. A dispatcher that branched on
  /// `core` and `$/` first and only then consulted the registry would have two answers to "who
  /// owns `core`" and the second one would be the one that could be wrong.
  ///
  /// A handler that throws becomes `-32603`, because that is what a peer must be told about a
  /// failure inside the host: [docs/reference/error-codes.md] §1 lists `-32603` as "Internal
  /// error" with `possible for a transient cause` and `feedsToModel: true`, and a routed call
  /// that threw is exactly that. The exception's own message is **not** put in the error data —
  /// it may carry anything the handler put in it, and `data` is the sanitised channel.
  Future<DispatchOutcome> route(MethodCall call) async {
    final unit = registry[call.namespace];
    if (unit == null) {
      return DispatchOutcome.refused(_noOwner(call));
    }
    try {
      return DispatchOutcome.delivered(await unit.handler.handle(call));
    } on Object {
      return DispatchOutcome.refused(_internal(call));
    }
  }

  /// Routes a one-way [frame] and reports whether an owner took it.
  ///
  /// **Present because the §5 table is not only about requests.** `$/cancelRequest` and
  /// `$/progress` are notifications — they have no `id` and expect no response — and they are
  /// two of the three rows in the dispatch table. A dispatcher that only routed [MethodCall]
  /// would leave the control plane unreachable, and the two ways to fix that are both worse than
  /// this: routing notifications as if they were requests would synthesise a response nobody
  /// reads, and leaving them out would push the special case into `apps/cli`, which is the one
  /// place that is not allowed to know how frames are routed.
  ///
  /// There is deliberately **no result**. A notification is one-way and a handler that produces
  /// one has been asked the wrong question; the answer to "did an owner take it" is a bool and
  /// nothing more, which is also the whole of what the caller can act on.
  ///
  /// A notification with no owner is **not** an error to be reported upward. It is logged by the
  /// caller's own means, and the refusal is a bool rather than an [AlteriOneError] for the same
  /// reason `error-codes.md` §3.1's control-plane rules make an unknown `$/cancelRequest` and an
  /// unknown `$/progress` non-events: a frame nobody owns is a frame nobody sent on purpose, and
  /// turning it into a protocol error would fail a healthy session over it.
  Future<bool> routeNotification(NotificationEnvelope frame) async {
    // The nullable namespace is handled here rather than through a sentinel value. An earlier
    // version carried a private "unparseable" namespace whose `value` was the empty string, so a
    // malformed method would flow through the ordinary "no owner" path — and that is a fake
    // value in a type whose whole job is to be a parsed one. A malformed notification is simply
    // a notification nobody owns.
    final namespace = MethodNamespace.of(frame.method);
    final unit = namespace == null ? null : registry[namespace];
    if (unit == null) return false;
    try {
      await unit.handler.handle(MethodCall(frame.method, params: frame.params));
      return true;
    } on Object {
      // A handler that threw on a one-way frame has no one to answer. Swallowing it here would
      // lose the failure entirely, and rethrowing would fail a session over a notification that
      // was never owed a response — so the outcome is reported as "not taken" and the caller
      // decides what to do. The bool alone cannot carry the cause, which is why this returns
      // false rather than true-with-a-caveat: a caller that must distinguish the two cases needs
      // the log, and a bool that pretends to carry a cause is worse than one that does not.
      return false;
    }
  }

  /// Whether [call] has an owner, without routing it.
  ///
  /// Separate from [route] because a caller that only wants to know whether a tool is exposed —
  /// [docs/extensibility/tools.md] §1.2's step 2, filtering by namespace scope — must not have
  /// to build a call and trigger a handler to ask.
  bool canRoute(MethodCall call) => registry.owns(call.namespace);

  /// The `-32601` for a call with no owner.
  ///
  /// `error-codes.md` §1 gives "Method or tool not found" as `-32601`, and
  /// [docs/architecture/protocol.md] §1.2 says "an unknown method is `-32601`, not a best-effort
  /// cast". The data carries the known namespaces so the reader can see what *was* available:
  /// a bare "not found" on a typo'd namespace is a message that sends the reader to the
  /// dispatcher rather than to their own `register` call.
  AlteriOneError _noOwner(MethodCall call) => AlteriOneError(
    code: JsonRpcErrorCode.methodNotFound,
    message: 'no owner is registered for ${call.namespace}',
    data: JsonMap({
      'method': call.method,
      'namespace': call.namespace.value,
      'known': registry.summary,
    }),
  );

  /// The `-32603` for a handler that threw.
  ///
  /// The `data` names the namespace and the method and **nothing about the exception**. The
  /// exception's own message is whatever the handler put in it, and `error-codes.md` §1's
  /// `data` channel is the sanitised one — a handler that throws `StateError('key sk-… not
  /// found')` would otherwise put a credential fragment into a frame a peer reads.
  AlteriOneError _internal(MethodCall call) => AlteriOneError(
    code: JsonRpcErrorCode.internalError,
    message: 'the handler for ${call.namespace} failed',
    data: JsonMap({'namespace': call.namespace.value, 'method': call.method}),
  );
}
