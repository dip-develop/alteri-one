/// The one bus every event flows on.
///
/// [docs/architecture/overview.md] §6 is one sentence and it is the whole contract:
///
/// > All events flow on one bus carrying `traceId`.
///
/// [docs/architecture/engine.md] §4 says what the bus is for, and it is worth quoting because it
/// is a prohibition as much as a description:
///
/// > The event stream is the single public contract for the CLI and UI, notification observers,
/// > tracing and tests. The UI does not read internal state, hooks do not substitute for
/// > policy, and provider-specific chunks never become a second observability channel.
///
/// That last clause is why this is a synchronous in-process fan-out and nothing more. There is
/// no second channel to leak into: no provider chunks, no hook callbacks, no per-extension queue
/// that a plugin could read its own state through. A subscriber sees an [AlteriOneEvent] or it
/// sees nothing.
///
/// ## Why a list and a loop, and not a `StreamController` per subscriber
///
/// A `Stream` between the bus and a subscriber adds a **microtask boundary**. `publish` would
/// return before any subscriber had seen the event, the order a transcript's lines were written
/// in would be a function of the event loop rather than of the call order, and two runs of the
/// same script could produce the same events in a different file order.
///
/// [docs/architecture/observability.md] §2 is what makes that disqualifying: "Transcripts are
/// content-addressed and compared **byte-for-byte** in tests and across operating systems."
/// Byte-for-byte is not a property a scheduler can be asked for. The same argument appears in
/// `alteri_one_platform`'s clock documentation against a periodic timer, and it is the reason
/// this file does not import `dart:async` at all.
///
/// ## Delivery order is subscription order
///
/// Subscribers are appended to a list and walked front to back, in the order they called
/// [subscribe] or [subscribeTo]. Everything else was rejected:
///
/// - **Not the event's own id.** `IdGenerator`'s counters are **per kind**
///   (`concepts.md` §2.1 gives six kinds and `AGENTS.md` records that the per-kind counter is
///   what makes ids stable under concurrency), so there is no total order over events to sort
///   by. A bus that ordered by id would have had to invent the missing global sequence, and it
///   would be a sequence whose only justification was the bus.
///
/// - **Not the topic.** Delivery would then depend on the eight event names, and a run that
///   published `step_completed` before `task_done` — which it can, because a plugin's tool call
///   completes before the run that started it does — would have its transcript reordered by
///   something the reader did not do.
///
/// - **Not a hash order.** Not even `LinkedHashMap` iteration by key, because a set of event
///   types is not the delivery order and using one would make the transcript's order a function
///   of the alphabet.
///
/// Registration order is the only order a reader can predict by reading the `subscribe` calls,
/// and it is a function of the program rather than of the run. Two runs of the same script
/// subscribe in the same places and therefore write in the same order — which is the property
/// `observability.md` §2.1 wants when it says "a fake clock fixes all timestamps, so a re-run
/// produces the same digest".
///
/// ## A subscriber that throws is isolated, recorded, and never fatal
///
/// [docs/architecture/engine.md] §2 sets the precedent for a throwing component inside a running
/// pipeline, and it is the only one in the specification:
///
/// > An injection that throws is isolated to its own contribution: the transform is skipped, the
/// > original fragments are kept, and `injection.failed` is recorded with the reason. **A failed
/// > transform never ends a run and never grants anything**.
///
/// So [publish] does three things: it delivers to every remaining subscriber, it records the
/// failure in [failures], and it returns normally. It does not rethrow, and it does not swallow
/// silently.
///
/// **Not rethrowing** is the `engine.md` §2 rule. A transcript writer that throws is an
/// *observer* failing, and rethrowing would turn a broken log line into a run that dies — and
/// worse, would do it from inside whatever published the event, which for `task_done` is the
/// engine's own terminal path. The repository's fail-closed rule is about **enforcement**:
/// `AGENTS.md` states it as "a sandbox that cannot be established causes a refusal", and a
/// diagnostic subscription is not enforcement, a policy check, a sandbox or a signature. There is
/// nothing here to refuse *about*.
///
/// **Not swallowing** is the other half, and it is the part that is easy to get wrong. A loop
/// that let a throw escape would starve every subscriber after it, silently: the second
/// observer in the list would stop seeing events and nothing would turn red, which is a worse
/// failure than a crash. So the exception is caught at the callback boundary, the loop
/// continues, and the failure is **recorded** rather than discarded — bounded, inspectable, and
/// carrying the event and the stack trace so a reader can find the observer.
///
/// The failure record deliberately renders the event through [AlteriOneEvent.toString], which
/// prints the type and the id and not the payload. That is not incidental: a failure report is
/// written to a log, and a payload printed into one is a payload in a transcript.
///
/// [docs/architecture/engine.md]: ../../../../docs/architecture/engine.md
/// [docs/architecture/overview.md]: ../../../../docs/architecture/overview.md
/// [docs/architecture/observability.md]: ../../../../docs/architecture/observability.md
/// [ConfigDiagnostic]: ../profile/diagnostic.dart
/// [SourceSpan]: ../profile/diagnostic.dart
library;

import '../profile/diagnostic.dart';
import 'event.dart';

/// What a subscriber is handed: the event, synchronously, and nothing to await.
///
/// A `void` return and not a `Future`, for the reason this file's documentation gives about
/// `dart:async`: an `async` callback would put a microtask between the bus and the observer, so
/// the order records are written in would be the event loop's rather than the call order's, and
/// `observability.md` §2 compares transcripts byte for byte.
///
/// A caller that needs to do slow work takes it off the bus: it hands the event to something it
/// owns, which is the difference between an observer and a second, undrained pipeline inside the
/// engine.
typedef EventListener = void Function(AlteriOneEvent event);

/// A registration on an [EventBus], and the only way to take one back.
///
/// A value rather than the bare callback the caller passed in, and the reason is the ordinary
/// shape of a teardown: a component subscribes, and then unsubscribes on one path explicitly and
/// on another from a `finally`. A bare `void Function()` has no way to express "stop calling
/// me", so the second of those would have to be a flag the caller remembers to check — inside
/// the callback, which is the place a reader does not look.
///
/// [unsubscribe] is therefore **idempotent**, and that is the property the `finally` path needs:
/// a second call is a no-op rather than a throw. A non-idempotent release would make the
/// careful shape — unsubscribe explicitly, and again in a `finally` for the early-return path —
/// the shape that crashes.
final class EventSubscription {
  EventSubscription._(this.id, this.types, this._onEvent, this._release);

  /// This subscription's registration number on its bus, counting from zero.
  ///
  /// The delivery order, stated as a value rather than inferred from a list: two subscribers
  /// taking the same set of types are otherwise indistinguishable in a [SubscriberFailure]. The
  /// number is the position at **registration**, and the ids are **not** contiguous after a
  /// removal — they are assigned once and never reused, so an id is a stable name for a
  /// registration rather than an index into a list that shifts under the reader.
  final int id;

  /// The event types this subscriber asked for, unmodifiable.
  ///
  /// A set and not a predicate, and that is the *whole* matching rule. `config-schema.md` §2
  /// configures notifications as `- event: task_done` / `- event: subagent_done` with no
  /// pattern, no glob and no `core/` prefix, and a filter language here would be a second
  /// matching vocabulary that a configuration author would have to learn and that nothing in the
  /// specification describes. Eight event types do not need one.
  final Set<EventType> types;

  final EventListener _onEvent;

  /// Tells the bus to drop this registration. The bus's own method, passed in so the handle stays
  /// a handle and the bus's list stays private.
  final void Function(EventSubscription subscription) _release;

  bool _released = false;

  /// Whether this subscription can still be delivered to.
  ///
  /// Cleared by [unsubscribe] and by [EventBus.close], and **cleared rather than merely
  /// cancelled**: the bus walks its list during a delivery, so a handle left looking active for
  /// the turn in which it was released would be an observable that is briefly wrong. An
  /// observable that is briefly wrong is worse than one that is absent.
  bool get isActive => !_released;

  /// Stops delivery to this subscriber. Idempotent.
  ///
  /// Takes effect immediately, including for an event currently being delivered: if an earlier
  /// subscriber in the same [EventBus.publish] released this one, it does not receive the event
  /// it was released during. A release is a statement about now, not about the next publish.
  void unsubscribe() {
    if (_released) return;
    _released = true;
    _release(this);
  }

  @override
  String toString() =>
      'EventSubscription($id, ${types.map((type) => type.wireName).toList()}, '
      'active: $isActive)';
}

/// A subscriber that threw, recorded rather than discarded.
///
/// A value, and the reason is the same as [EventSubscription]: the bus has to be able to hand a
/// reader the evidence, and a callback that printed its own message would put it wherever that
/// callback's logging happened to point. The stack trace is carried because "an observer threw"
/// without a location cannot be acted on — the same rule [ConfigDiagnostic] follows by never
/// being permitted to have an empty [SourceSpan].
///
/// [event] is held so a reader can find the record in a transcript, and rendering it in
/// [toString] goes through [AlteriOneEvent.toString] on purpose: that is the type and the id,
/// never the payload, so a failure report written to a log cannot carry a record's contents into
/// a transcript.
final class SubscriberFailure {
  /// Records a failure of subscription [subscriptionId] while delivering [event].
  const SubscriberFailure({
    required this.subscriptionId,
    required this.event,
    required this.error,
    required this.stackTrace,
  });

  /// The [EventSubscription.id] of the subscriber that threw.
  final int subscriptionId;

  /// The event that was being delivered.
  final AlteriOneEvent event;

  /// The stable code for this condition, so a log line carrying it is greppable.
  ///
  /// [docs/reference/error-codes.md] §3 promises that diagnostic codes "appear in `--json`
  /// output and in logs" and are "greppable and localisable by key". A record held only in an
  /// in-memory list keeps **none** of that: an operator reading a log has nothing to search for,
  /// and the list is read by code that has to know the bus exists. The code is a getter rather
  /// than a constructor parameter because there is exactly one — a parameter would let a caller
  /// record a subscriber failure under some other code, which is the mistake a code is supposed
  /// to prevent.
  ///
  /// It is [EngineDiagnosticCode.engineObserverFailed] and never a refusal: the event reached
  /// every other subscriber and the run continued, because an observer is not enforcement.
  DiagnosticCode get code => EngineDiagnosticCode.engineObserverFailed;

  /// A diagnostic for this failure, localised, with the event's type as the one value.
  ///
  /// The failure's own [error] and [stackTrace] are **not** in the diagnostic: `error` is
  /// whatever the subscriber put in it, and §1's `data` channel is the sanitised one. A
  /// subscriber that throws `StateError('key sk-… not found')` would otherwise put a credential
  /// fragment into a message an operator reads.
  ConfigDiagnostic toDiagnostic(String locale) => ConfigDiagnostic(
    code: code,
    path: 'eventBus.subscriptions[$subscriptionId]',
    span: const SourceSpan.unknownPosition('event bus'),
    values: <String, Object?>{
      'field': event.eventType.wireName,
      'expected': 'a subscriber that does not throw',
    },
  );

  /// What it threw. An [Object] and not an [Exception], because a callback may throw an [Error]
  /// and narrowing the type here would make the most common case — a `RangeError` or a
  /// `StateError` from a subscriber's own logic — unrecordable.
  final Object error;

  /// Where it was thrown from.
  final StackTrace stackTrace;

  @override
  String toString() =>
      '${code.code} subscription $subscriptionId threw '
      '${error.runtimeType} on ${event.eventType.wireName} ${event.eventId}';
}

/// One bus, carrying every event of the canonical stream.
///
/// Synchronous, in-process, ordered, and closed exactly once.
/// [docs/architecture/overview.md] §6's "All events flow on one bus carrying `traceId`" is
/// implemented by there being exactly one of this class per core, and by
/// [AlteriOneEvent.traceId] being non-nullable, so the publish path has no shape in which the
/// trace id could be left out. There is deliberately **no** convenience `publish` that takes a
/// payload and a type: a builder that assembled an event would be a second way to publish, and a
/// second way is a second place the trace id could be forgotten.
final class EventBus {
  /// Creates an open bus with no subscribers.
  ///
  /// No arguments, and that is worth stating: there is no clock, no id generator, no logger and
  /// no configuration. The bus moves values that already exist — an [AlteriOneEvent] was stamped
  /// by the engine's injected clock and carries ids from its injected generator, per this
  /// library's documentation — so a bus that took a clock would be a second source of the
  /// timestamps a record already has.
  EventBus();

  /// How many recorded failures [failures] keeps before it drops the oldest.
  ///
  /// A cap rather than a policy. The alternative is a list that grows for the whole run, and a
  /// broken observer in a long run is exactly when the list is growing; 64 is enough to see that
  /// something is wrong and small enough that a full bus's memory is measured in kilobytes. The
  /// count of what was dropped is [droppedFailures], so the cap cannot hide the scale of a
  /// failure by being invisible.
  static const int maxRecordedFailures = 64;

  final List<EventSubscription> _subscriptions = <EventSubscription>[];
  final List<SubscriberFailure> _failures = <SubscriberFailure>[];

  int _nextSubscriptionId = 0;
  int _droppedFailures = 0;
  bool _closed = false;

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  /// How many live subscriptions there are, in delivery order.
  ///
  /// Released ones are not counted. It is a snapshot: a subscriber that releases another during
  /// a delivery is reflected from the next call, not from inside the current one.
  int get subscriberCount => _subscriptions.length;

  /// The recorded failures, oldest first, bounded by [maxRecordedFailures].
  ///
  /// A copy, so a caller reading it cannot clear it — a bus whose failure history a reader can
  /// mutate is not the record this class documents. Empty in the normal case, which is the point:
  /// its being non-empty is a finding.
  List<SubscriberFailure> get failures =>
      List<SubscriberFailure>.unmodifiable(_failures);

  /// How many failures were dropped because [failures] was full.
  ///
  /// Separate from `failures.length` so that "there were 65 failures" and "there were 65 and I
  /// can see one" cannot be confused. A cap that silently discarded records would let a
  /// permanently broken observer look like an intermittently broken one.
  int get droppedFailures => _droppedFailures;

  /// Subscribes to one [type], and returns the handle that takes it back.
  ///
  /// A named wrapper over [subscribeTo] rather than a default parameter, for the reason
  /// `FakeProvider`'s two constructors are two constructors: the common case is one type, and
  /// making every call site write a singleton set would bury the actual subscription in syntax.
  EventSubscription subscribe(EventType type, EventListener onEvent) =>
      subscribeTo(<EventType>{type}, onEvent);

  /// Subscribes to every type in [types], and returns the handle that takes it back.
  ///
  /// A **set of [EventType]**, which is the only matching rule this bus has. Throws
  /// [ArgumentError] on an empty set: a subscription that can never be called is a wiring
  /// mistake, and it would otherwise be indistinguishable from a subscription whose type is
  /// misspelled — except that the misspelling is a compile error here, which is the whole
  /// benefit of taking the enum.
  ///
  /// There is no wildcard and no predicate. `config-schema.md` §2's `notifications:` block names
  /// events exactly (`- event: task_done`), eight of them is a set a caller can write in full,
  /// and a filter expression would be a second vocabulary with no specification behind it.
  ///
  /// A subscription added during a [publish] does **not** receive the event in flight. The bus
  /// walks a snapshot, so the in-flight event is delivered to the subscribers that existed when
  /// it was published and to nobody else — which is the only way "publish delivers to everyone
  /// who was listening" is a statement a reader can check.
  EventSubscription subscribeTo(Set<EventType> types, EventListener onEvent) {
    if (_closed) {
      throw StateError(
        'cannot subscribe to a closed EventBus. close() is a teardown, and a subscription taken '
        'after it would look active and never be delivered to. An observable that is '
        'briefly wrong is worse than one that is absent',
      );
    }
    if (types.isEmpty) {
      throw ArgumentError.value(
        types,
        'types',
        'is empty. A subscription to no event type can never be called, and it would be '
            'indistinguishable from a subscription that was wired to the wrong one. A set of all '
            'eight EventType values is the explicit way to say "every event"',
      );
    }
    final subscription = EventSubscription._(
      _nextSubscriptionId,
      Set<EventType>.unmodifiable(types),
      onEvent,
      _release,
    );
    _nextSubscriptionId++;
    _subscriptions.add(subscription);
    return subscription;
  }

  /// Delivers [event] to every live subscription whose [EventSubscription.types] contain
  /// [AlteriOneEvent.eventType], in subscription order, and returns.
  ///
  /// Synchronous: when this method returns, every subscriber that is still subscribed has run.
  /// That is the property the transcript depends on, and it is why there is no `await` on the
  /// signature.
  ///
  /// Throws [StateError] after [close]. The choice is the repository's, not the
  /// specification's — nothing in `engine.md` or `overview.md` says what publishing to a closed
  /// bus does — and it is made against a silent no-op for two reasons. `engine.md` §4 says
  /// "`task_done` always terminates the root task, including on failure", so a publish that lands
  /// after teardown is the terminal event of a run, and dropping it produces a transcript that
  /// stops with no terminal record while the process exits `0`. And `StdioTransport`-style
  /// teardown calls `close` from a `finally`, so the publish that is racing it is usually
  /// *itself* cleanup — and a cleanup that dies quietly is how a run loses its last line.
  ///
  /// A subscriber that throws does not stop the loop and does not propagate; see this file's
  /// documentation and [failures]. The bus records it and carries on to the next subscriber,
  /// because an observer starving the observers behind it is a defect nothing else would report.
  void publish(AlteriOneEvent event) {
    if (_closed) {
      throw StateError(
        'cannot publish ${event.eventType.wireName} ${event.eventId} on a closed EventBus. '
        'engine.md §4 makes the terminal event of a run the one that must never be dropped, '
        'and a silent no-op here would end a transcript with no terminal record and an exit '
        'code of 0. If the run really is over, close the bus after its last publish',
      );
    }

    // A snapshot, walked in order. Two things depend on it. A callback that unsubscribes — itself
    // or a later subscriber — does not mutate the list being walked; and a callback that
    // subscribes does not receive the event in flight, so "publish reached every subscriber that
    // existed when it was called" is a statement with no exceptions to remember.
    for (final subscription in List<EventSubscription>.of(_subscriptions)) {
      if (!subscription.isActive) continue;
      if (!subscription.types.contains(event.eventType)) continue;
      try {
        subscription._onEvent(event);
      } catch (error, stackTrace) {
        _record(
          SubscriberFailure(
            subscriptionId: subscription.id,
            event: event,
            error: error,
            stackTrace: stackTrace,
          ),
        );
      }
    }
    _prune();
  }

  /// Closes the bus: releases every subscription and refuses any further publish or subscribe.
  ///
  /// **Idempotent**, for the same reason [EventSubscription.unsubscribe] is: `close` is what a
  /// `finally` block calls, and a teardown that throws on its second call is a teardown that
  /// replaces the error it was cleaning up after.
  ///
  /// Releasing the subscriptions rather than leaving them attached is a deliberate choice, and it
  /// is the one from `AGENTS.md` about the stdio adapter: "A released reader means the
  /// subscription field is cleared, not merely cancelled… an observable that is briefly wrong is
  /// worse than none." A handle held past `close` reports [EventSubscription.isActive] as false,
  /// which is the truth; leaving it true would have it promise deliveries that cannot happen.
  ///
  /// The recorded [failures] survive the close, deliberately. They are about observers that
  /// already failed, and a teardown that erased the evidence would be the last thing to go.
  void close() {
    if (_closed) return;
    _closed = true;
    for (final subscription in _subscriptions) {
      // The private field, and not unsubscribe(): a release from inside the walk would call back
      // into _release and mutate the list being walked. This is the same reason the field is
      // `_released` rather than a bus-maintained set — the handle owns its own state.
      subscription._released = true;
    }
    _subscriptions.clear();
  }

  /// Drops a released subscription from the list.
  ///
  /// Not done during delivery and not done by [EventSubscription.unsubscribe] beyond its own
  /// removal. Pruning after the loop keeps a long run's list the size of its *live* subscribers
  /// rather than the total number ever taken — a bus that accumulated dead handles would make
  /// every publish walk them, and a transcript writer that re-subscribes per step would make
  /// that quadratic.
  void _prune() {
    if (!_subscriptions.any((subscription) => !subscription.isActive)) return;
    _subscriptions.removeWhere((subscription) => !subscription.isActive);
  }

  /// The callback a subscription hands to [EventSubscription] to remove itself.
  void _release(EventSubscription subscription) =>
      _subscriptions.remove(subscription);

  /// Records a failure, dropping the oldest once [maxRecordedFailures] is reached.
  void _record(SubscriberFailure failure) {
    if (_failures.length >= maxRecordedFailures) {
      _failures.removeAt(0);
      _droppedFailures++;
    }
    _failures.add(failure);
  }
}
