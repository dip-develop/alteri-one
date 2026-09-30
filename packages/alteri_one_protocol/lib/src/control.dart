/// The control plane: `$/cancelRequest`, `$/progress`, and what a receiver does with each.
///
/// [architecture/protocol.md] §3 states the frames; §3.1 and §3.2 are the decisions — the part
/// that says what a *receiver* does with a notification, rather than what one looks like. Both
/// signals here are notifications, so nothing in this file answers a peer: every member is
/// either a value a sender puts in a frame, or a table and a cascade a receiver keeps. That is
/// the shape of the whole file, and it is why a cancellation that refers to an unknown request is
/// a log line rather than an error frame.
///
/// Three things a peer gets wrong, each of which is a type or a method here rather than a note:
///
/// - **The cancelled request's id is `params.id`, and there is nowhere else to look.** §1 gives
///   a notification no frame-level `id` — [NotificationEnvelope] has no field for one and the
///   codec refuses one — so [CancelRequest.toParams] is the only place the correlation id can
///   live. A receiver that reaches for `frame.id` finds null, cancels nothing, and the symptom
///   is a run that ignores Ctrl-C. §3.1 calls this the single most likely bug in this area.
/// - **The first cancel wins, and a cascade fires once.** [CancelToken.cancel] returns whether
///   *this* call was the one that tripped the token, [CancelRegistry.cancel] maps that onto
///   [CancelOutcome.alreadyCancelled], and a repeat therefore does nothing. A cascade that runs
///   twice runs a tool's cleanup twice, which is how a cancelled Tier 2 process group becomes a
///   leaked one.
/// - **Monotonic progress is the receiver's property, not the sender's promise.** A peer whose
///   progress goes backwards has a cosmetic bug, and [ProgressLedger] ignores it rather than
///   failing a live run — a UI that has drawn 60% must not jump back to 20%, and progress
///   changes no policy decision, so there is nothing for a regression to invalidate.
///
/// ## What is not here, and where it goes
///
/// The `-32031` response to a cancelled request is **not** here. §3.1 makes it the `ErrorBody`
/// of a `response` frame to the cancelled request's id, which is [DomainErrorCode.cancelled] and
/// the dispatcher's assembly — this file has no id to answer, because a notification has none.
/// Neither is the method registry, so [asCancelRequest] returning null is a routing answer and
/// never a `-32601`; a frame under a method this version does not define is the registry's
/// finding (task `0.12`), and a reader that answered for a method it knows nothing about would
/// be answering on the peer's behalf.
///
/// ## The two readers, and what they are allowed to say
///
/// [CancelRequest.fromParams] and [ProgressEvent.fromParams] are strict: an unknown member, a
/// missing one, or one of the wrong type is a `-32602` naming `$.params.<member>`, per §1.2's
/// "a schema violation is `-32602` naming the JSON path". A [ProtocolViolation] is thrown rather
/// than returned, because a schema is not a value a caller branches on — it is a refusal, and a
/// caller that swallowed one would be accepting a frame it has already said it does not
/// understand. What a diagnostic may *not* do is quote the value it refused: `params` may carry a
/// credential, so a message names types and shapes, and quotes a string only as a JSON literal
/// that cannot claim control characters it does not have.
///
/// [architecture/protocol.md]: ../../../../docs/architecture/protocol.md
/// [architecture/overview.md]: ../../../../docs/architecture/overview.md
/// [concepts.md]: ../../../../docs/concepts.md
library;

import 'dart:async';

import 'envelope.dart';
import 'error.dart';
import 'json.dart';

/// The method of the cancellation notification, per [architecture/protocol.md] §3.
const String cancelRequestMethod = r'$/cancelRequest';

/// The method of the progress notification, per [architecture/protocol.md] §3.
const String progressMethod = r'$/progress';

/// The grammar [architecture/protocol.md] §3.1 gives a cancellation reason.
///
/// The identifier grammar of [concepts.md] §2 without the dot: a reason names a *cause*, not a
/// namespace, and a dotted spelling would invite a peer to smuggle a capability id into the one
/// member of this frame nobody validates.
const String _reasonGrammar = r'^[a-z][a-z0-9_]*$';

/// The longest reason §3.1 admits, in characters.
const int _maxReasonLength = 64;

/// The cause a request was cancelled for: a token, not a namespace.
///
/// §3.1 fixes the grammar and this is that grammar as a type, which is the only reason it can be
/// enforced on a peer's frame. A `String` parameter accepts `''`, a capitalised token and a
/// 4 KiB paragraph, none of which is a reason, and a `$/cancelRequest` carrying one is a frame
/// whose diagnostic nobody can act on.
///
/// A newtype over `String` for the same reason [FrameId] is one, and a final class rather than
/// an `extension type` for the reason [FrameId] documents: on the pinned SDK an extension type
/// has exactly one positional constructor and may not redeclare an `Object` member, so it can
/// neither validate the token nor print `user_interrupt` in a log.
///
/// ## Why [userInterrupt] is a constant and not an enum
///
/// It is the spelling §3's wire example uses, published as a convenience for the cause this
/// version's own host sends when a person interrupts a run. The **vocabulary** is not fixed by
/// this version — §3.1 says so in as many words, and says a receiver must not switch on it — so
/// an enum here would be a promise this protocol does not make, and the first peer to send
/// `timeout` would then be a peer this file calls wrong. A constant cannot be switched over and
/// cannot be extended into a closed set by accident; a receiver compares a reason for equality
/// when it wants to recognise one, and does nothing otherwise.
final class CancelReason {
  /// Creates a reason from its wire spelling.
  ///
  /// Throws [ArgumentError] naming [wire] when it does not match [grammar] or is longer than 64
  /// characters.
  factory CancelReason(String wire) {
    if (wire.length > _maxReasonLength) {
      throw ArgumentError.value(
        wire.length,
        'wire',
        'a cancellation reason is at most $_maxReasonLength characters',
      );
    }
    if (!_reasonPattern.hasMatch(wire)) {
      throw ArgumentError.value(
        wire,
        'wire',
        'a cancellation reason matches $_reasonGrammar',
      );
    }
    return CancelReason._(wire);
  }

  const CancelReason._(this._wire);

  /// The cause a host sends when a person interrupts a run: the §3 wire example's spelling.
  ///
  /// A convenience, not a vocabulary. See the class documentation.
  static const CancelReason userInterrupt = CancelReason._('user_interrupt');

  /// The compiled form of [_reasonGrammar].
  ///
  /// A `RegExp` and not a hand-rolled loop, because the house already has both answers and the
  /// regex is the one [framing.dart] uses for its header-name grammar: the pattern is the
  /// specification's own, so it is the thing a reviewer compares against §3.1 rather than a loop
  /// that has to be read and then believed.
  static final RegExp _reasonPattern = RegExp(_reasonGrammar);

  final String _wire;

  /// The reason as it appears on the wire.
  String get wire => _wire;

  /// The reason [wire] names, or null when it is not a token.
  ///
  /// Null rather than a throw, for the same reason [ProtoVersion.parseOrNull] is: a reader has
  /// a member it must refuse with a `-32602` naming `$.params.reason`, and a null it can turn
  /// into a diagnostic quoting the offending value beats an exception message it cannot. There is
  /// deliberately no throwing `parse` beside it — the one reader of a wire reason is
  /// [CancelRequest.fromParams], it wants the null, and a second entry point nothing calls is a
  /// second spelling of the same check.
  static CancelReason? parseOrNull(String wire) {
    if (wire.length > _maxReasonLength) return null;
    return _reasonPattern.hasMatch(wire) ? CancelReason._(wire) : null;
  }

  @override
  bool operator ==(Object other) =>
      other is CancelReason && other._wire == _wire;

  @override
  int get hashCode => _wire.hashCode;

  @override
  String toString() => _wire;
}

/// A cancellation signal that cascades: cancelling a parent cancels everything derived from it.
///
/// The specification's "cascades through `CancelToken` into subagents, tool calls and the Tier 2
/// process group" is one sentence, and the graph is the only reason this is not a bool. A token
/// exists so a host can hand a subagent something it can watch and something it can trip, and a
/// plain flag can do neither without the host also owning the bookkeeping for every token it ever
/// made — which is the bookkeeping, spelled out.
///
/// `dart:async` only, and no `dart:io`, because this package must keep working in a web build
/// (see [architecture/overview.md] §3). "Kill the Tier 2 process group" is therefore somebody
/// else's job: the group watches this token and reacts. A token that reached into a process
/// would put a trust boundary in the file that defines the signal, and this is not that file.
final class CancelToken {
  /// Creates a root token. A root is cancelled by cancelling it, and by nothing else.
  factory CancelToken() => CancelToken._(null);

  CancelToken._(this._parent) {
    final inherited = _parent?._reason;
    if (inherited != null) {
      // Born already cancelled. Joining the parent's child set would be pointless — the set was
      // cleared when it fired — and going through cancel() would report a cascade the parent
      // has already finished, for a cause this token did not choose.
      _trip(inherited);
    } else {
      _parent?._children.add(this);
    }
  }

  final CancelToken? _parent;
  final Set<CancelToken> _children = <CancelToken>{};
  final StreamController<CancelReason> _events =
      StreamController<CancelReason>.broadcast();
  final Completer<CancelReason> _cancellation = Completer<CancelReason>();

  CancelReason? _reason;

  /// Whether this token has been cancelled.
  bool get isCancelled => _reason != null;

  /// The cause, or null while this token is live.
  ///
  /// Null exactly when [isCancelled] is false. [cancel] takes a [CancelReason] and never null, a
  /// token is born either live or already cancelled, and [derived] is the only way in — so
  /// "cancelled" and "has a cause" are one state here rather than two that can disagree.
  CancelReason? get reason => _reason;

  /// A child cancelled whenever this one is, and born already cancelled if it already is.
  ///
  /// One per unit of work a person might want to stop: a subagent, a tool call, a sandboxed
  /// process group. Cancelling the root then reaches all of them without the host keeping the
  /// list itself, which is the whole of §3's cascade sentence.
  ///
  /// A child removes itself from its parent's set when it is cancelled directly, so a long-lived
  /// root does not accumulate dead children: a session that dispatches ten thousand tool calls
  /// holds one entry per call that is still running and nothing more. A child born already
  /// cancelled never joins a set at all.
  CancelToken derived() => CancelToken._(this);

  /// Trips this token and cascades to everything derived from it.
  ///
  /// Returns true when *this call* was the one that tripped the token, and false when it was
  /// already cancelled. §3.1's "the first reason wins", in the type: the cause a token was
  /// cancelled with is never overwritten, and a second call does not cascade a second time. A
  /// cascade that fires twice runs a tool's cleanup twice, and a cleanup that runs twice on a
  /// Tier 2 process group leaves one running.
  ///
  /// The bool is the whole contract. Without it a caller cannot tell an idempotent repeat from a
  /// first cancel, and a dispatcher that treated the second as a first would report a run as
  /// cancelled twice — so [CancelOutcome] is a reading of this return value rather than a
  /// parallel piece of state that could disagree with it.
  bool cancel(CancelReason reason) {
    if (_reason != null) return false;
    _trip(reason);
    // A directly cancelled child leaves its parent's set, so a root never grows a set of tokens
    // that can never fire again. A child cancelled *by* a cascade finds the set already cleared,
    // so the remove is a no-op there rather than an error.
    _parent?._children.remove(this);
    _cascade(reason);
    return true;
  }

  /// A broadcast stream of this token's cancellation, for fan-out to several consumers.
  ///
  /// Broadcast because a token has more than one consumer — a transport that stops reading, a
  /// tool that aborts, a process group that is killed — and a single-subscription stream would
  /// let the first of them take the event and starve the rest. "First subscriber wins" is not a
  /// property a cancellation signal may have.
  ///
  /// A listener that arrives *after* the cancel receives nothing: the event has gone to the
  /// listeners that were there, and a broadcast stream does not replay. That is not a defect and
  /// it is why the next member exists — [onCancel] is the fan-out, [whenCancelled] is the
  /// awaitable, and a caller that does not know whether it subscribed in time must use the
  /// second.
  Stream<CancelReason> get onCancel => _events.stream;

  /// Completes with the reason when this token is cancelled.
  ///
  /// The member that works for a listener that arrives late, including one that subscribes after
  /// the cancel did: the future is already complete, so the caller is released on the next
  /// microtask instead of waiting for an event that has been and gone. A token derived from an
  /// already-cancelled parent completes immediately, carrying the parent's cause rather than one
  /// of its own — which is the other half of "the first reason wins", inherited.
  Future<CancelReason> get whenCancelled => _cancellation.future;

  /// Publishes [reason] once, to the stream and to the future.
  ///
  /// Separate from [cancel] because [derived] needs to publish without cancelling *again*: the
  /// reason a child inherits is not a new cause, and treating it as one would report a cascade
  /// the parent has already run.
  void _trip(CancelReason reason) {
    _reason = reason;
    _events.add(reason);
    unawaited(_events.close());
    _cancellation.complete(reason);
  }

  /// Trips every child, once each.
  ///
  /// The snapshot is taken and the set cleared *before* the first child is cancelled, and that
  /// order is the entire re-entrancy guarantee. A listener that cancels a grandchild while the
  /// cascade is running then mutates a set this loop is not iterating, so it cannot throw a
  /// concurrent-modification error; and because [cancel] refuses a token that is already
  /// cancelled, a child reachable by two paths still fires exactly once. The loop's stack depth
  /// follows the depth of the token tree, not the number of tokens, so a root with a thousand
  /// children unwinds a thousand times shallow and no deeper.
  void _cascade(CancelReason reason) {
    if (_children.isEmpty) return;
    final children = _children.toList(growable: false);
    _children.clear();
    for (final child in children) {
      child.cancel(reason);
    }
  }
}

/// What a `$/cancelRequest` did — a log line, never a frame.
///
/// §3.1's four outcomes, and the reason they are an enum rather than a bool is that three of
/// them are *not* errors and the difference between two of those is the whole diagnostic. A
/// notification is never answered, so none of these reaches the peer: the receiver writes this
/// down and the peer learns nothing. The alternative — refusing a cancel for an id that is not in
/// flight — fails a healthy session over a duplicate message, which is a far worse cost than a
/// log line nobody reads.
enum CancelOutcome {
  /// This cancel tripped the token. The request answers `-32031` when it reaches that state.
  cancelled,

  /// The token was already cancelled: the idempotent repeat, which cascaded nothing.
  ///
  /// The first reason stands. This is §3.1's "a second `$/cancelRequest` for the same id does not
  /// overwrite the reason, and it does not fire a second cascade".
  alreadyCancelled,

  /// The response has already been sent, and the result stands.
  ///
  /// §3 resolves the race in favour of the completed result, and a cancel cannot un-send a
  /// response. The registry keeps the entry after `complete` for precisely long enough to say
  /// this rather than [unknownRequest] — both are harmless, but only one of them is true.
  alreadyCompleted,

  /// Nothing is in flight under that id, and this is **not** a frame error.
  ///
  /// A peer that cancels work which has already finished, or which the receiver never
  /// dispatched, is behaving correctly. `-32600` here would fail a session over a message the
  /// specification permits.
  unknownRequest,
}

/// The receiver's table of in-flight requests, keyed by [FrameId].
///
/// The dispatcher [begin]s an entry when it dispatches a request, [complete]s it when it *sends*
/// the response, and [retire]s it afterwards. §3.1 fixes that middle step exactly: the receiver
/// marks a request complete when it *sends* the response, not when it starts building one — so a
/// cancel arriving while the response is being written is [CancelOutcome.cancelled] and the
/// request answers `-32031`, and a cancel arriving after the response is gone is
/// [CancelOutcome.alreadyCompleted] and changes nothing.
///
/// ## Why an entry survives [complete]
///
/// Because the four outcomes are not the same diagnostic. A request that has just answered and
/// one that never existed are both harmless to cancel, and the operator reading the log needs to
/// know which: a cancel for an id that was never dispatched points at a peer that lost track of
/// its own session, and a cancel for one that just answered is ordinary reordering. The entry
/// is cheap for the length of one response's send, and removing it early turns one of those into
/// the other.
///
/// ## Why there is a [retire]
///
/// The registry is not a log, and an entry that is never retired is a leak that grows with the
/// session rather than with the work in it. [complete] keeps an entry to make the late-cancel
/// answer precise; [retire] is what makes keeping it a decision rather than an accumulation. The
/// dispatcher is what pairs them, and a registry that retired on [complete] would give up the
/// `alreadyCompleted` case to save one map entry per request.
final class CancelRegistry {
  /// Creates a registry with nothing in flight.
  CancelRegistry();

  final Map<FrameId, _TrackedRequest> _requests = <FrameId, _TrackedRequest>{};

  /// Registers [id] as in flight and returns the token that cancels it.
  ///
  /// [parent], when given, is the token the request's work derives from — the session's, or a
  /// subagent's — so cancelling that parent reaches this request's tool calls and process group
  /// without the dispatcher wiring them up itself. Absent, the request gets a token that only a
  /// cancel naming [id] can trip, which is the right default: a request that nothing else
  /// watches is cancellable exactly once, by the frame meant to cancel it.
  ///
  /// Throws [StateError] when [id] is already registered. A duplicate request id in one session
  /// is a dispatcher bug and not a peer frame: two requests sharing an id are indistinguishable
  /// to every response and every cancel that follows, and a receiver that quietly replaced the
  /// entry would leave the first request running with nothing able to cancel it and no way to
  /// see that this is what happened. Throwing at the point of the bug is the only place the
  /// second request's own machinery is still intact enough to report it usefully.
  CancelToken begin(FrameId id, {CancelToken? parent}) {
    if (_requests.containsKey(id)) {
      throw StateError(
        'request $id is already in flight. Two requests sharing one id cannot be told apart by '
        'any response or any cancel afterwards, and a receiver that replaced the entry would '
        'leave the first one uncancellable',
      );
    }
    final request = _TrackedRequest(parent?.derived() ?? CancelToken());
    _requests[id] = request;
    return request.token;
  }

  /// Marks [id] finished, keeping the entry so a later cancel is [CancelOutcome.alreadyCompleted].
  ///
  /// Returns whether the request was in flight. Called when the response is *sent*; [retire] is
  /// called once the send has actually gone.
  bool complete(FrameId id) {
    final request = _requests[id];
    if (request == null || request.completed) return false;
    request.completed = true;
    return true;
  }

  /// Drops [id]'s entry, and is silent when there is none.
  ///
  /// Silent on purpose: a dispatcher retiring unconditionally on the path where a request failed
  /// before it was ever dispatched should not have to ask first, and an id that is not in the
  /// table has nothing to drop.
  void retire(FrameId id) {
    _requests.remove(id);
  }

  /// Cancels [id] and reports what happened.
  ///
  /// The four cases, in the order §3.1 states them, and each is decided by one fact: whether the
  /// table has the id, whether the entry is complete, and whether this call is the one that
  /// tripped the token. Note that a token cancelled *directly* — by a parent, or by a caller
  /// holding the token — is [CancelOutcome.alreadyCancelled] and not a fifth outcome, because
  /// from the peer's point of view it is exactly the idempotent repeat the rule describes.
  CancelOutcome cancel(FrameId id, CancelReason reason) {
    final request = _requests[id];
    if (request == null) return CancelOutcome.unknownRequest;
    if (request.completed) return CancelOutcome.alreadyCompleted;
    return request.token.cancel(reason)
        ? CancelOutcome.cancelled
        : CancelOutcome.alreadyCancelled;
  }

  /// The token for [id], or null when the table holds no entry for it.
  ///
  /// Present for a completed request as well as an in-flight one, because [complete] keeps the
  /// entry and a caller holding [id] is asking about correlation rather than about liveness. A
  /// caller that wants liveness asks [isInFlight].
  CancelToken? tokenFor(FrameId id) => _requests[id]?.token;

  /// Whether [id] is registered and has not been completed.
  bool isInFlight(FrameId id) {
    final request = _requests[id];
    return request != null && !request.completed;
  }

  /// How many requests are registered and not yet complete.
  ///
  /// The number §2's "concurrent in-flight requests, 32 per peer" bound applies to, and so the
  /// number a dispatcher counts. It is deliberately not the table's length: that includes
  /// requests already answered and not yet retired, and a dispatcher that counted those would
  /// refuse a new request because of responses it had already sent.
  int get inFlightCount {
    var count = 0;
    for (final request in _requests.values) {
      if (!request.completed) count++;
    }
    return count;
  }

  /// Every registered id, unmodifiable.
  ///
  /// Includes completed-but-not-retired requests, because this is a view of the table rather
  /// than of the work. The order is [Map]'s own and is not part of the contract: nothing in the
  /// protocol depends on it, and a caller that does is depending on an implementation detail of
  /// the default map rather than on this class.
  Iterable<FrameId> get tracked => List<FrameId>.unmodifiable(_requests.keys);

  /// Forgets every entry, and cancels nothing.
  ///
  /// Deliberately not a cancellation. [clear] is what a dispatcher calls when a transport has
  /// died and every pending request is about to fail on its own, and having it also trip the
  /// tokens would run a tool's cleanup path on the way down — a cascade whose purpose has already
  /// happened, aimed at work that is already over. A caller that *does* want the cascade cancels
  /// its root token first and then clears.
  void clear() {
    _requests.clear();
  }
}

/// One row of the table: a token, and whether its response has gone.
///
/// Library-private, and not a record: a `bool` field is part of the row's *state* rather than
/// part of its identity, and a record with a mutable-looking member invites a caller to think it
/// can be copied and then changed independently of the table it came from.
final class _TrackedRequest {
  _TrackedRequest(this.token);

  final CancelToken token;
  bool completed = false;
}

/// A `$/cancelRequest`: stop the request whose id is named in here.
final class CancelRequest {
  /// Creates a cancel for [requestId], for [reason].
  factory CancelRequest({
    required FrameId requestId,
    required CancelReason reason,
  }) => CancelRequest._(requestId, reason);

  const CancelRequest._(this._requestId, this._reason);

  /// Reads a `$/cancelRequest`'s `params`, strictly.
  ///
  /// Throws a [ProtocolViolation] of `-32602` naming `$.params.<member>` for an unknown member, a
  /// missing, non-string or empty `id`, and a missing or non-token `reason`. An unknown member is
  /// refused for the reason the codec refuses one on a frame: a member this version does not
  /// define would be dropped, and a silently dropped member is how two peers come to disagree
  /// about what was sent.
  factory CancelRequest.fromParams(JsonMap params) {
    _rejectUnknownMembers(params, const <String>{'id', 'reason'});

    final id = params['id'];
    if (id is! String || id.isEmpty) {
      throw _badParams(
        r'$.params.id',
        'is ${_quoted(id)}, expected a non-empty string. A notification has no frame-level id, '
            'so this member is the only place the request being cancelled can be named',
      );
    }

    final wire = params['reason'];
    if (wire is! String) {
      throw _badParams(
        r'$.params.reason',
        'is ${_quoted(wire)}, expected a cancellation reason',
      );
    }
    final reason = CancelReason.parseOrNull(wire);
    if (reason == null) {
      // The value, quoted, and not the reason it was refused. `params` may carry a credential,
      // so this message names the grammar the peer can check its own sender against — which is
      // actionable — rather than embedding the string that failed, which is not.
      throw _badParams(
        r'$.params.reason',
        'is ${jsonString(wire)}, which is not a cancellation reason. A reason matches '
            '$_reasonGrammar and is at most $_maxReasonLength characters',
      );
    }

    return CancelRequest._(FrameId(id), reason);
  }

  final FrameId _requestId;
  final CancelReason _reason;

  /// The request to stop.
  FrameId get requestId => _requestId;

  /// Why it is being stopped.
  ///
  /// This frame is a *request* to cancel, not the cancellation itself, so §3.1's "the first
  /// reason wins" is [CancelToken]'s rule and not this value's. What a receiver does with a
  /// second frame for the same id is [CancelRegistry]'s answer, and it is the same answer
  /// whichever of the two reasons it carries.
  CancelReason get reason => _reason;

  /// The `params` of the notification.
  ///
  /// The member is `id` **inside `params`**, and that is all of §3.1's first rule. A notification
  /// has no frame-level `id` — [NotificationEnvelope] has no field for one and the codec refuses
  /// one — so this is the only place a cancelled request's id can appear. A receiver that looks
  /// for `frame.id` finds null, cancels nothing, and the symptom is a run that ignores Ctrl-C.
  JsonMap toParams() =>
      JsonMap({'id': _requestId.wire, 'reason': _reason.wire});

  /// The notification frame for this cancel.
  ///
  /// [module] and [meta] are required with no defaults: every frame carries both, and this file
  /// does not get to invent them. A caller reaching for a convenient default would be guessing a
  /// namespace or a protocol major, and either guess is a session running on a version nobody
  /// agreed to.
  NotificationEnvelope toEnvelope({
    required String module,
    required EnvelopeMeta meta,
  }) => NotificationEnvelope(
    module: module,
    meta: meta,
    method: cancelRequestMethod,
    params: toParams(),
  );

  @override
  bool operator ==(Object other) =>
      other is CancelRequest &&
      other._requestId == _requestId &&
      other._reason == _reason;

  @override
  int get hashCode => Object.hash(_requestId, _reason);

  @override
  String toString() =>
      'CancelRequest(requestId: $_requestId, reason: $_reason)';
}

/// The `$/cancelRequest` [frame] carries, or null when it is not one.
///
/// Null rather than a throw, for the same reason [EnvelopeType.fromWireName] is null rather than
/// a throw: a dispatcher switches on the method *first*, so a null here means "you routed this
/// frame here by mistake", and a throw would turn a routing mistake in our own code into an
/// exception raised on somebody else's frame.
///
/// A **wrong method** is not `-32601` here, and the distinction is worth being precise about. The
/// frame is a perfectly valid notification of some other method; it is this reader that cannot
/// use it. `-32601` means "no such method" *to the peer*, and a frame sent in good faith under a
/// method this version does not define is genuinely that — but deciding it is the method
/// registry's job, and a reader that answered `-32601` for a frame it merely failed to recognise
/// would be speaking for a method it knows nothing about. The rejected alternative is a check
/// here that raised, which would make "this is not for me" and "this is broken" the same event.
CancelRequest? asCancelRequest(AlteriOneEnvelope frame) {
  if (frame is! NotificationEnvelope) return null;
  if (frame.method != cancelRequestMethod) return null;
  return CancelRequest.fromParams(frame.params);
}

/// A `$/progress`: the request named here is this far along.
///
/// Advisory in both directions, and §3.2 says why in one sentence: progress carries no secrets
/// and changes no policy decision. So nothing in this class is load-bearing except the
/// correlation — the `requestId` is what routes the frame, and [ProgressLedger] is what that
/// routing finds. A value here never satisfies a check, relaxes a deadline or stands in for a
/// result, and a receiver that renders [message] must treat it as untrusted text: the
/// redaction obligation is the sender's, not this type's.
final class ProgressEvent {
  /// Creates a progress event for [requestId].
  ///
  /// Throws [ArgumentError] naming the parameter when [progress] is not a finite number in
  /// `0.0..1.0` inclusive, when [total] is present and negative, or when [message] is present and
  /// empty.
  ///
  /// `double.nan` and `double.infinity` are refused by name because every comparison against them
  /// is false: `nan < 0.0` and `nan > 1.0` are both false, so the range check written as two
  /// comparisons admits a `nan` silently, and admits an infinity on the side it is testing.
  /// [JsonMap] admits any `num` and a Dart caller can hand one straight in, which is why this is
  /// checked here as well as in [ProgressEvent.fromParams] — the constructor is the other way a
  /// value enters the type, and a check that holds on only one of the two doors is a check that
  /// holds on whichever door the peer did not use.
  factory ProgressEvent({
    required FrameId requestId,
    required double progress,
    int? total,
    String? message,
  }) {
    if (progress.isNaN ||
        progress.isInfinite ||
        progress < 0.0 ||
        progress > 1.0) {
      throw ArgumentError.value(
        progress,
        'progress',
        'a progress value is a finite fraction in 0.0..1.0, inclusive',
      );
    }
    if (total != null && total < 0) {
      throw ArgumentError.value(
        total,
        'total',
        'a count of steps is not negative',
      );
    }
    if (message != null && message.isEmpty) {
      throw ArgumentError.value(
        message,
        'message',
        'a progress message is not empty',
      );
    }
    return ProgressEvent._(requestId, progress, total, message);
  }

  const ProgressEvent._(
    this._requestId,
    this._progress,
    this._total,
    this._message,
  );

  /// Reads a `$/progress`'s `params`, strictly.
  ///
  /// Throws a [ProtocolViolation] of `-32602` naming `$.params.<member>` for an unknown member, a
  /// missing, non-finite or out-of-range `progress`, a negative or non-integer `total`, and an
  /// empty or non-string `message`. Absent `total` and `message` are legitimate and are
  /// distinguished from present-and-null by [JsonMap.containsKey] — a peer that sends
  /// `message: null` has sent a message, and it is not a string.
  ///
  /// `progress` is read as a [num] and narrowed, because JSON has one number type: a peer that
  /// has computed `1` has sent an `int`, and refusing that would break a sender which did
  /// nothing wrong. A `String` is refused outright — `"0.5"` is a peer stringifying its
  /// diagnostics into a protocol field, and admitting it would give every fraction two spellings
  /// and every receiver a coercion to invent.
  factory ProgressEvent.fromParams(JsonMap params) {
    _rejectUnknownMembers(params, const <String>{
      'requestId',
      'progress',
      'total',
      'message',
    });

    final requestId = params['requestId'];
    if (requestId is! String || requestId.isEmpty) {
      throw _badParams(
        r'$.params.requestId',
        'is ${_quoted(requestId)}, expected a non-empty string',
      );
    }

    final raw = params['progress'];
    if (raw is! num || raw.isNaN || raw.isInfinite || raw < 0 || raw > 1) {
      throw _badParams(
        r'$.params.progress',
        'is ${_quoted(raw)}, expected a finite number in 0.0..1.0 inclusive. JSON has one '
            'number type, so an integer here is ordinary and is refused only when it is out of '
            'range',
      );
    }

    return ProgressEvent._(
      FrameId(requestId),
      raw.toDouble(),
      _readOptionalCount(params, 'total'),
      _readOptionalMessage(params, 'message'),
    );
  }

  final FrameId _requestId;
  final double _progress;
  final int? _total;
  final String? _message;

  /// The request this progress is about, and the member that routes the frame.
  FrameId get requestId => _requestId;

  /// The fraction complete, in `0.0..1.0` inclusive.
  double get progress => _progress;

  /// An optional count of steps. Informational: nothing derives [progress] from it.
  int? get total => _total;

  /// An optional human-readable note. Untrusted text, and unbounded on purpose — see below.
  ///
  /// §3.2 declines to cap this, and the reasoning is the point rather than the omission: the
  /// frame cap already bounds it at 8 MiB, a per-field limit would be a second number to
  /// negotiate, and a diagnostic string is not the place to spend one. [CancelReason] is bounded
  /// because it has a grammar with limits, not because it is a short field.
  String? get message => _message;

  /// The `params` of the notification, with absent optionals **omitted**.
  ///
  /// The rule [AlteriOneEnvelope.metaToJson] follows, for the reason it follows it: a peer
  /// holding `total: null` has to decide whether that means "no total" or "the sender did not
  /// know", and the protocol does not make it say. An absent member is unambiguous, and a
  /// `null` is a second spelling of it that every receiver has to interpret for itself.
  JsonMap toParams() => JsonMap({
    'requestId': _requestId.wire,
    'progress': _progress,
    if (_total != null) 'total': _total,
    if (_message != null) 'message': _message,
  });

  /// The notification frame for this event.
  ///
  /// [module] and [meta] are required for the same reason they are on [CancelRequest.toEnvelope]:
  /// they are members of every frame, and a default here would be a guessed namespace or a
  /// guessed protocol major.
  NotificationEnvelope toEnvelope({
    required String module,
    required EnvelopeMeta meta,
  }) => NotificationEnvelope(
    module: module,
    meta: meta,
    method: progressMethod,
    params: toParams(),
  );

  @override
  bool operator ==(Object other) =>
      other is ProgressEvent &&
      other._requestId == _requestId &&
      other._progress == _progress &&
      other._total == _total &&
      other._message == _message;

  @override
  int get hashCode => Object.hash(_requestId, _progress, _total, _message);

  @override
  String toString() =>
      'ProgressEvent(requestId: $_requestId, progress: $_progress'
      '${_total == null ? '' : ', total: $_total'}'
      '${_message == null ? '' : ', message: $_message'})';
}

/// The `$/progress` [frame] carries, or null when it is not one.
///
/// Null rather than a throw, for the reason [asCancelRequest] is null rather than a throw: a
/// dispatcher routes on the method first, so a null says "this was not for me" and says it in the
/// only way that does not turn our own routing bug into an exception on a peer's frame. And a
/// wrong method is still not `-32601` — that frame is valid, this reader simply cannot use it,
/// and the method registry is what answers a peer about a method it does not know.
ProgressEvent? asProgressEvent(AlteriOneEnvelope frame) {
  if (frame is! NotificationEnvelope) return null;
  if (frame.method != progressMethod) return null;
  return ProgressEvent.fromParams(frame.params);
}

/// What a `$/progress` did to a [ProgressLedger] — a decision, not a frame.
///
/// Three cases rather than a bool, because "applied" and "did not move" are three different
/// things: §3.2 draws the line between a repeat and a regression, and a caller asking "did the
/// peer send something that went backwards" is asking a different question from one asking
/// whether the bar moved.
enum ProgressVerdict {
  /// Greater than the high-water mark: applied, and [ProgressLedger.recorded] is incremented.
  accepted,

  /// Exactly the high-water mark. A repeat, accepted silently, and the mark does not move.
  ///
  /// Progress is at-least-once in practice, so the same value twice is ordinary. Refusing it
  /// would turn a retried notification into an error — and a notification cannot be answered, so
  /// there would be nothing to answer with but a log line and a peer's continued retries.
  duplicate,

  /// Lower than the high-water mark. Ignored, and the mark does not move.
  ///
  /// Not an error and not a session failure, for the two reasons §3.2 gives together: a UI that
  /// has drawn 60% must not jump back to 20% because a late frame arrived, and progress changes no
  /// policy decision, so a peer's cosmetic bug must not take a live run down. Ignoring is the
  /// only action that satisfies both halves at once.
  regressionIgnored,
}

/// The high-water mark for **one** request's progress.
///
/// §3.2: "Monotonic is the receiver's property, not the sender's promise." A peer that sends
/// `0.5` and then `0.2` has not broken the protocol — it has a bug — and the receiver's
/// obligation is to keep reporting the maximum value it has ever seen. So this is a value, not a
/// check on the sender: [record] returns a verdict and never throws about a peer's arithmetic.
///
/// One ledger per request, found by the dispatcher's own lookup. §3.2's "a `$/progress` for an id
/// that is not in flight is ignored" is that lookup's answer — a dispatcher with no entry has no
/// ledger, so there is nothing to record into, for the same reason an unknown cancel is not an
/// error. What this file contributes is the part a lookup cannot express: the mark, and the three
/// verdicts a frame can earn against it.
final class ProgressLedger {
  /// Creates a ledger for [requestId], with nothing recorded yet.
  factory ProgressLedger(FrameId requestId) => ProgressLedger._(requestId);

  ProgressLedger._(this._requestId);

  final FrameId _requestId;
  double _progress = 0.0;
  int _recorded = 0;

  /// The request this ledger is for.
  FrameId get requestId => _requestId;

  /// The highest value ever recorded, and `0.0` before anything has been.
  ///
  /// Read after every [record] rather than from the event: a caller that draws a bar wants the
  /// mark, and an ignored regression is visible as a number that did not move — which is exactly
  /// what "ignored" should look like from outside this class.
  double get progress => _progress;

  /// How many frames were actually applied.
  ///
  /// Only [ProgressVerdict.accepted] counts. A duplicate carries the value the mark already
  /// holds, so applying it would be counting a frame that changed nothing, and a regression is by
  /// definition not applied. A ledger whose only event was `0.0` therefore reports `0` here, and
  /// that is the honest number: the mark has not moved.
  int get recorded => _recorded;

  /// Applies [event] if it moves the mark, and reports what it did.
  ///
  /// Greater applies and moves the mark; equal is a [ProgressVerdict.duplicate] and is accepted
  /// silently; lower is a [ProgressVerdict.regressionIgnored] and leaves the mark exactly where
  /// it was. None of the three throws, because none of the three is a fault in the frame.
  ///
  /// Throws [ArgumentError] when the event is not for this ledger's id. That is a dispatcher
  /// routing bug and not a peer frame — a peer cannot miscorrelate, because the event's
  /// `requestId` is the very thing that routed it here — and a ledger that accepted another
  /// request's progress would draw one run's bar with another run's number and report the
  /// result as evidence about neither.
  ProgressVerdict record(ProgressEvent event) {
    if (event.requestId != _requestId) {
      throw ArgumentError.value(
        event.requestId,
        'event.requestId',
        'this ledger tracks $_requestId, and an event for another request was routed to it',
      );
    }
    final value = event.progress;
    if (value > _progress) {
      _progress = value;
      _recorded++;
      return ProgressVerdict.accepted;
    }
    if (value == _progress) return ProgressVerdict.duplicate;
    return ProgressVerdict.regressionIgnored;
  }

  @override
  String toString() =>
      'ProgressLedger(requestId: $_requestId, progress: $_progress, recorded: $_recorded)';
}

/// Reads an optional step count, distinguishing absent from present-and-null.
///
/// [JsonMap.containsKey] is what tells the two apart; `params['total']` alone cannot, and a
/// `total` of `null` is a peer that sent a number field as null rather than a peer with no
/// total — which is a mistake worth reporting rather than a value to absorb.
int? _readOptionalCount(JsonMap params, String key) {
  if (!params.containsKey(key)) return null;
  final value = params[key];
  if (value is! int || value < 0) {
    throw _badParams(
      '\$.params.$key',
      'is ${_quoted(value)}, expected a non-negative integer count of steps',
    );
  }
  return value;
}

/// Reads an optional non-empty string, on the same absent-versus-null rule.
String? _readOptionalMessage(JsonMap params, String key) {
  if (!params.containsKey(key)) return null;
  final value = params[key];
  if (value is! String || value.isEmpty) {
    throw _badParams(
      '\$.params.$key',
      'is ${_quoted(value)}, expected a non-empty string',
    );
  }
  return value;
}

/// Refuses a `params` member this version of the protocol does not define.
///
/// The same choice `codec.dart` makes on a frame, and the same reason: a member that is dropped
/// is how two peers come to disagree about what was sent. It is `-32602` rather than `-32600`
/// because the frame decoded — the fault is in the payload, and §1.2 puts a payload that does not
/// match the method's schema at `-32602` with the JSON path named.
void _rejectUnknownMembers(JsonMap params, Set<String> known) {
  for (final key in params.toMap().keys) {
    if (known.contains(key)) continue;
    throw _badParams(
      '\$.params.$key',
      'is not a member of these `params` in this version of the protocol. A member this version '
          'does not define is dropped, and a silently dropped one is how two peers disagree '
          'about what was sent',
    );
  }
}

/// A `-32602` at [path], in the shape `codec.dart` uses for a `-32600`.
///
/// [JsonRpcErrorCode.invalidParams] and not [JsonRpcErrorCode.invalidRequest], and the difference
/// is §1.2's: the frame decoded and it is the payload that does not match the method's schema.
/// The codec cannot raise it, because the codec does not know the method — these two readers are
/// the method registry's knowledge of two methods, and `-32602` is the number the specification
/// names for that.
ProtocolViolation _badParams(String path, String what) => ProtocolViolation(
  code: JsonRpcErrorCode.invalidParams,
  message: '`$path` $what',
  path: path,
);

/// Names a member's value for a diagnostic, by shape rather than by content.
///
/// The house pattern from `codec.dart`, restated rather than shared: that one is library-private,
/// and lifting a ten-line "describe a JSON value" function into a shared internal would give
/// every reader in the package a third file to keep in step with the other two.
///
/// A type name, never the value, because `params` may carry a credential — "expected a string,
/// got a boolean" finds it, while quoting the value puts it in a log. A [String] is the one
/// exception, and it is quoted through [jsonString] so the message cannot claim control
/// characters the value does not have.
String _quoted(Object? value) {
  if (value == null) return 'absent';
  if (value is String) return jsonString(value);
  if (value is JsonMap) return 'an object';
  if (value is JsonList) return 'an array';
  return value.toString();
}
