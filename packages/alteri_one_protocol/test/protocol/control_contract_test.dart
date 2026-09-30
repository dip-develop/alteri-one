// The control-plane contract. Task 0.6.
//
// Three frames share one file and one bug shape: `$/cancelRequest`, `$/progress` and
// `core.initialize`. In each of them the identity of the thing the frame is *about* lives inside
// `params` and nowhere else — `params.id`, `params.requestId`, `params.moduleVersion` — and a
// receiver that reaches for the obvious field cancels nothing, records nothing and negotiates
// nothing. The symptom is identical for all three: a session that looks like it is working. So
// the first test below puts all three through the real wire path and asserts that each lands on
// the one thing it names.
//
// The properties worth pinning, and the case each is easiest to get wrong:
//
// - **Four `CancelOutcome`s.** Three of them are not errors and the difference between two of
//   those is the whole diagnostic, so they cannot be a bool. §3.1's list is enumerated.
// - **The first reason wins.** A cascade that fires twice runs a tool's cleanup twice, which is
//   how a cancelled Tier 2 process group becomes a leaked one.
// - **`whenCancelled` is not `onCancel`.** The stream is a broadcast fan-out and does not replay;
//   the future completes for a caller that arrived after the cancel. That asymmetry is what makes
//   a subagent started *after* the interrupt see it.
// - **The `$/progress` range is enforced at both doors.** The constructor refuses a `nan` and an
//   infinity, and the reader refuses the same on the wire. A check that holds on one door is a
//   check that holds on whichever door the peer did not use.
// - **A regression is ignored, not refused.** A UI that has drawn 60% must not jump back to 20%
//   because a late frame arrived, and progress changes no policy decision.
// - **A refusal is an `error` response, never a result carrying `accepted: false`.** §1 makes
//   `result` and `error` mutually exclusive, so one frame cannot hold both.
// - **Only `capability_mismatch` ever degrades**, and that is a property of the cause rather than
//   of configuration. A `warn+degrade` host that degraded a version disagreement would be a
//   downgrade path, which §4.3 forbids.
// - **The range grammar is one form.** `^`, `~`, `||`, `*` and hyphen ranges are refused with a
//   `FormatException`, because a parser that accepts a second form has two answers to "is 1.5.0
//   inside this range" and two answers is one more than a protocol can carry.
//
// No process, no socket, no network, no `dart:mirrors`, no clock and no id generator. `dart:io`
// appears once, in this file, to read three markdown documents — the package under test never
// imports it and this file must not weaken that. The only waiting anywhere below is `await` on a
// future the library itself completes, and `dart_test.yaml` allows an async test 30 s.
//
// The greppable acceptance string for the task is the description of the first test below:
// "cancel progress and initialize negotiation are correlated".

import 'dart:convert';
import 'dart:io';

import 'package:alteri_one_protocol/alteri_one_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('the correlation', () {
    test('cancel progress and initialize negotiation are correlated', () {
      // One test for three frames, because the mistake they share is the same one. Every frame
      // below is encoded to framed bytes and read back through `FrameDecoder` and
      // `decodeEnvelope`, so the correlation is proved over the wire rather than over an object
      // graph — a test that skipped the transport would pass on a `params` the framing layer had
      // mangled, and would never notice that a notification carries its correlation id in
      // `params` at all.
      final registry = CancelRegistry();
      final runId = FrameId('req_01f4a9c2');
      final otherId = FrameId('req_00beef11');
      final runToken = registry.begin(runId);
      final otherToken = registry.begin(otherId);
      expect(registry.inFlightCount, 2);

      // The request that put the work in flight.
      final request = _throughTheWire(
        RequestEnvelope(
          module: 'core',
          meta: sessionMeta,
          id: runId,
          method: 'core/run',
          params: JsonMap({'goal': 'Prepare a short report'}),
        ),
      );
      expect((request as RequestEnvelope).id, runId);

      // The cancel. §3.1's first rule: the correlation id is `params.id`, and a notification has
      // no frame-level `id` for a receiver to find instead.
      final cancelFrame = _throughTheWire(
        CancelRequest(
          requestId: runId,
          reason: CancelReason.userInterrupt,
        ).toEnvelope(module: 'core', meta: sessionMeta),
      );
      expect(cancelFrame, isA<NotificationEnvelope>());
      final notification = cancelFrame as NotificationEnvelope;
      expect(notification.method, cancelRequestMethod);
      expect(
        notification.id,
        isNull,
        reason:
            'a notification has no frame-level id and the codec refuses one. A receiver reading '
            '`frame.id` here finds nothing, cancels nothing, and the run ignores Ctrl-C',
      );
      expect(notification.toJson().toMap().containsKey('id'), isFalse);
      expect(
        notification.params['id'],
        runId.wire,
        reason: 'the only place a cancelled request can be named',
      );

      final cancel = asCancelRequest(notification);
      expect(cancel, isNotNull);
      expect(
        registry.cancel(cancel!.requestId, cancel.reason),
        CancelOutcome.cancelled,
      );
      expect(runToken.isCancelled, isTrue);
      expect(runToken.reason, CancelReason.userInterrupt);
      expect(
        otherToken.isCancelled,
        isFalse,
        reason: 'the cancel names one request and must cancel exactly that one',
      );
      expect(otherToken.reason, isNull);
      // An id the registry never saw — *not* `otherId`, which is registered and in flight and so
      // is correctly cancellable. §3.1 refuses a healthy session over a cancel it cannot act on,
      // and the outcome is a log line rather than a frame error.
      expect(
        registry.cancel(FrameId('req_never_seen'), CancelReason.userInterrupt),
        CancelOutcome.unknownRequest,
        reason:
            'nothing is in flight under an id the table never received, so a cancel for it is a '
            'log line rather than a frame error — §3.1 refuses a healthy session over a '
            'duplicate message',
      );

      // Progress for the same request, over the same wire, into its own ledger.
      final ledger = ProgressLedger(runId);
      final otherLedger = ProgressLedger(otherId);
      expect(
        ledger.record(asProgressEvent(_progressFrame(runId, 0.25))!),
        ProgressVerdict.accepted,
      );
      expect(
        ledger.record(asProgressEvent(_progressFrame(runId, 0.5))!),
        ProgressVerdict.accepted,
      );
      expect(
        ledger.record(asProgressEvent(_progressFrame(runId, 0.5))!),
        ProgressVerdict.duplicate,
      );
      expect(
        ledger.record(asProgressEvent(_progressFrame(runId, 0.2))!),
        ProgressVerdict.regressionIgnored,
      );
      expect(ledger.progress, 0.5, reason: 'the mark only ever moves forward');
      expect(ledger.recorded, 2, reason: 'only an applied frame is counted');

      // The other request's progress, its own ledger. One ledger per `requestId`.
      expect(
        otherLedger.record(asProgressEvent(_progressFrame(otherId, 0.9))!),
        ProgressVerdict.accepted,
      );
      expect(otherLedger.progress, 0.9);
      expect(ledger.progress, 0.5);

      // The handshake, over the same wire. §1.1's invariant, which task 0.4 left unconstructed
      // until there was a handshake to construct it from.
      final initId = FrameId('init_01');
      final initFrame = _throughTheWire(
        _paramsFixture().toEnvelope(
          id: initId,
          module: 'core',
          meta: sessionMeta,
        ),
      );
      expect((initFrame as RequestEnvelope).method, initializeMethod);

      final read = InitializeParams.asInitializeRequest(initFrame);
      expect(read, isNotNull);
      final outcome = negotiateHandshake(
        params: read!,
        meta: initFrame.meta,
        host: _hostFixture(),
      );
      expect(outcome, isA<HandshakeAccepted>());
      final accepted = outcome as HandshakeAccepted;
      expect(accepted.warnings, isEmpty);
      expect(accepted.result.negotiatedProtoVersion, ProtoVersion.current);

      // `meta.proto == negotiatedProtoVersion.major` for every frame in the session — including
      // the three written above, all of which declared it.
      expect(
        () => accepted.invariant.require(initFrame.meta.proto),
        returnsNormally,
        reason:
            'the frame that carried the handshake declares the major the handshake agreed on, '
            'so it is in session',
      );
      expect(
        accepted.invariant.requiredProto.value,
        ProtoVersion.current.major,
      );
      expect(accepted.invariant.accepts(sessionMeta.proto), isTrue);
      expect(
        () => accepted.invariant.require(
          ProtoMajor(ProtoVersion.current.major + 1),
        ),
        throwsA(
          isA<ProtocolViolation>().having(
            (violation) => violation.code,
            'code',
            DomainErrorCode.versionIncompatible,
          ),
        ),
        reason: 'a session running on a version nobody agreed to is worse than a closed one',
      );
    });
  });

  group('cancellation', () {
    test('a cancel names its request in params, and nowhere else', () {
      // §3.1's first bullet, and the first thing this file asserts. §3's wire example is pinned
      // member for member, so a renamed member cannot pass unnoticed.
      final cancel = CancelRequest(
        requestId: FrameId('req_01f4a9c2'),
        reason: CancelReason.userInterrupt,
      );
      // §3's wire example, member for member: a renamed member cannot pass unnoticed.
      expect(
        cancel.toParams().toMap().length,
        2,
        reason: 'and no third member',
      );
      expect(cancel.toParams()['id'], 'req_01f4a9c2');
      expect(cancel.toParams()['reason'], 'user_interrupt');

      final frame = _throughTheWire(
        cancel.toEnvelope(module: 'core', meta: sessionMeta),
      );
      final notification = frame as NotificationEnvelope;
      expect(notification.method, cancelRequestMethod);
      expect(notification.id, isNull);
      expect(notification.toJson().toMap().containsKey('id'), isFalse);
      expect(notification.params['id'], 'req_01f4a9c2');

      final read = asCancelRequest(notification);
      expect(
        read,
        cancel,
        reason: 'the frame round-trips to the value that built it',
      );
      expect(read!.reason, CancelReason.userInterrupt);
      expect(CancelReason.userInterrupt.wire, 'user_interrupt');
      expect(
        read.toParams().toMap(),
        cancel.toParams().toMap(),
        reason: 'a re-read cancel re-encodes to the same members',
      );
    });

    test('the registry cancels the request params named, and no other', () {
      // The control matters: a cancel that tripped every token in the table would pass a test
      // that only checked the intended one.
      final registry = CancelRegistry();
      final target = FrameId('req_target');
      final bystander = FrameId('req_bystander');
      final targetToken = registry.begin(target);
      final bystanderToken = registry.begin(bystander);

      final frame = _throughTheWire(
        CancelRequest(
          requestId: target,
          reason: CancelReason.userInterrupt,
        ).toEnvelope(module: 'core', meta: sessionMeta),
      );
      final read = asCancelRequest(frame)!;

      expect(
        registry.cancel(read.requestId, read.reason),
        CancelOutcome.cancelled,
      );
      expect(targetToken.isCancelled, isTrue);
      expect(targetToken.reason, CancelReason.userInterrupt);
      expect(bystanderToken.isCancelled, isFalse);
      expect(registry.isInFlight(bystander), isTrue);
      expect(
        registry.inFlightCount,
        2,
        reason:
            'tripping a token does not mark the request complete. The dispatcher does that when '
            'it *sends* the response, and until it does the entry is still there',
      );

      // And the unrelated one is still cancellable by a frame that names it.
      expect(
        registry.cancel(bystander, CancelReason('timeout')),
        CancelOutcome.cancelled,
      );
      expect(bystanderToken.isCancelled, isTrue);
      expect(bystanderToken.reason, CancelReason('timeout'));
    });

    test('the four outcomes are four readings of one table', () {
      // §3.1's list, in the order the section states it. Enumerated rather than sampled: a fifth
      // member added to the enum is a decision somebody has to make deliberately, and the count
      // here is what makes the addition visible.
      expect(CancelOutcome.values.map((outcome) => outcome.name), <String>[
        'cancelled',
        'alreadyCancelled',
        'alreadyCompleted',
        'unknownRequest',
      ]);

      final registry = CancelRegistry();
      final cancelled = FrameId('req_cancelled');
      final completed = FrameId('req_completed');
      final cancelledToken = registry.begin(cancelled);
      final completedToken = registry.begin(completed);
      expect(registry.inFlightCount, 2);

      // 1. The first cancel trips the token.
      expect(
        registry.cancel(cancelled, CancelReason.userInterrupt),
        CancelOutcome.cancelled,
      );
      expect(cancelledToken.reason, CancelReason.userInterrupt);

      // 2. The repeat is idempotent, and the *first* reason stands.
      expect(
        registry.cancel(cancelled, CancelReason('timeout')),
        CancelOutcome.alreadyCancelled,
      );
      expect(
        cancelledToken.reason,
        CancelReason.userInterrupt,
        reason:
            '§3.1: a second cancel does not overwrite the reason, and it does not fire a second '
            'cascade',
      );

      // 3. A cancel after the response went is `alreadyCompleted`, and the result stands: the
      //    token is *not* tripped, because a cancel cannot un-send a response.
      expect(registry.complete(completed), isTrue);
      expect(
        registry.cancel(completed, CancelReason.userInterrupt),
        CancelOutcome.alreadyCompleted,
      );
      expect(
        completedToken.isCancelled,
        isFalse,
        reason: 'the response has gone and §3 resolves the race in favour of the result',
      );
      expect(registry.isInFlight(completed), isFalse);
      expect(
        registry.inFlightCount,
        1,
        reason: 'completed-but-not-retired is still tracked but is no longer in flight',
      );

      // 4. An id the registry never saw is `unknownRequest`, and is not a frame error.
      CancelOutcome? unknown;
      expect(
        () => unknown = registry.cancel(
          FrameId('req_never_dispatched'),
          CancelReason.userInterrupt,
        ),
        returnsNormally,
        reason:
            'a cancel for an id this peer never sent must not fail the session',
      );
      expect(unknown, CancelOutcome.unknownRequest);

      // `retire` drops the entry, and afterwards the same id is indistinguishable from one that
      // never existed — which is why a dispatcher pairs `complete` with `retire`.
      registry.retire(completed);
      expect(registry.tokenFor(completed), isNull);
      expect(
        registry.cancel(completed, CancelReason.userInterrupt),
        CancelOutcome.unknownRequest,
      );
      expect(
        registry.complete(completed),
        isFalse,
        reason: 'and a retired request cannot be completed a second time',
      );
    });

    test('an unknown request is a log line, never a ProtocolViolation', () {
      // Separated from the table above because it is the one that would be reported wrongly: a
      // notification cannot be answered, so there is nothing to answer with but a code nobody
      // should be sent.
      final registry = CancelRegistry();
      CancelOutcome? outcome;
      expect(
        () => outcome = registry.cancel(
          FrameId('req_nope'),
          CancelReason.userInterrupt,
        ),
        returnsNormally,
      );
      expect(outcome, CancelOutcome.unknownRequest);
      expect(outcome, isNot(CancelOutcome.cancelled));
      expect(
        registry.tracked,
        isEmpty,
        reason: 'a cancel does not create an entry',
      );
      expect(registry.inFlightCount, 0);
    });

    test(
      'two requests sharing one id is a dispatcher bug, not a peer frame',
      () {
        // A peer cannot miscorrelate — it would have to send the same id twice — but a dispatcher
        // can, and a receiver that quietly replaced the entry would leave the first request running
        // with nothing able to cancel it.
        final registry = CancelRegistry();
        registry.begin(FrameId('req_1'));
        expect(
          () => registry.begin(FrameId('req_1')),
          throwsA(isA<StateError>()),
          reason: 'two requests sharing one id cannot be told apart by any later response',
        );
      },
    );

    test('a frame this reader cannot use is a routing answer, not -32601', () {
      // `-32601` means "no such method" *to the peer*, and deciding that is the method
      // registry's job (task 0.12). A reader that answered for a method it knows nothing about
      // would be speaking for it.
      final notification = NotificationEnvelope(
        module: 'core',
        meta: sessionMeta,
        method: progressMethod,
        params: JsonMap({'requestId': 'req_1', 'progress': 0.5}),
      );
      expect(
        asCancelRequest(notification),
        isNull,
        reason: 'a valid frame of another method',
      );
      expect(asProgressEvent(notification), isNotNull);

      final request = RequestEnvelope(
        module: 'core',
        meta: sessionMeta,
        id: FrameId('req_1'),
        method: 'core/run',
      );
      expect(
        asCancelRequest(request),
        isNull,
        reason: 'a notification reader handed a request has been routed a frame by mistake',
      );
      expect(asProgressEvent(request), isNull);

      final event = EventEnvelope(
        module: 'core',
        meta: sessionMeta,
        topic: 'core/step_completed',
        data: JsonMap({'step': 1}),
        traceId: 'trace_01f4a9c2',
      );
      expect(asCancelRequest(event), isNull);
      expect(asProgressEvent(event), isNull);

      // And the wire half: a notification *carrying* an id is refused by the codec before either
      // reader sees it, so there is no version of this frame that both agree on.
      final corrupted = jsonDecode(
        encodeFrame(
          CancelRequest(
            requestId: FrameId('req_1'),
            reason: CancelReason.userInterrupt,
          ).toEnvelope(module: 'core', meta: sessionMeta),
        ),
      ) as Map<String, Object?>;
      corrupted['id'] = 'req_1';
      final violation = _refuse(() => decodeEnvelope(jsonEncode(corrupted)));
      expect(
        violation.code,
        JsonRpcErrorCode.invalidRequest,
        reason:
            'an id on a notification is an invalid envelope, not a parse error',
      );
      expect(violation.path, r'$.id');
    });

    test('a cancel params is read strictly', () {
      // §1.2: a schema violation is `-32602` naming the JSON path. An unknown member is refused
      // rather than dropped, because a silently dropped member is how two peers come to disagree
      // about what was sent.
      final unknown = _refuse(
        () => CancelRequest.fromParams(
          JsonMap({'id': 'req_1', 'reason': 'user_interrupt', 'force': true}),
        ),
      );
      expect(unknown.code, JsonRpcErrorCode.invalidParams);
      expect(unknown.path, r'$.params.force');
      expect(unknown.message, contains('not a member'));

      // A **list of records, not a map keyed by the expected path.** A map would be the obvious
      // shape here and it is the wrong one: five of these seven share two paths, so the later
      // entries would silently overwrite the earlier ones and five assertions would never run.
      // The analyzer flags duplicate keys; the test is written so that the question cannot arise.
      final cases = <(String, JsonMap)>[
        (r'$.params.id', JsonMap({'reason': 'user_interrupt'})),
        (r'$.params.id', JsonMap({'id': '', 'reason': 'user_interrupt'})),
        (r'$.params.id', JsonMap({'id': 42, 'reason': 'user_interrupt'})),
        (r'$.params.reason', JsonMap({'id': 'req_1'})),
        (
          r'$.params.reason',
          JsonMap({'id': 'req_1', 'reason': 'User_Interrupt'}),
        ),
        (r'$.params.reason', JsonMap({'id': 'req_1', 'reason': 'core.run'})),
        (r'$.params.reason', JsonMap({'id': 'req_1', 'reason': 'x' * 65})),
      ];
      for (final (expectedPath, params) in cases) {
        final violation = _refuse(() => CancelRequest.fromParams(params));
        expect(
          violation.code,
          JsonRpcErrorCode.invalidParams,
          reason: '$params',
        );
        expect(violation.path, expectedPath, reason: '$params');
      }

      // A reason is a token, and the vocabulary is *not* fixed by this version — so the reader
      // checks the grammar rather than a list, and a peer that sends `tool_timeout` is right.
      expect(CancelReason.parseOrNull('tool_timeout'), isNotNull);
      expect(CancelReason.parseOrNull('timeout'), isNotNull);
      expect(
        CancelReason.parseOrNull('tool.timeout'),
        isNull,
        reason: 'no dot: not a namespace',
      );
      expect(CancelReason.parseOrNull('2fast'), isNull);
      expect(CancelReason.parseOrNull('x' * 64), isNotNull);
      expect(CancelReason.parseOrNull('x' * 65), isNull);
      expect(CancelReason.userInterrupt, CancelReason('user_interrupt'));
      expect(
        () => CancelReason('User_Interrupt'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('forgetting the table is not a cancellation', () {
      // `clear` is what a dispatcher calls when the transport has died, and having it trip the
      // tokens as well would run a tool's cleanup path on the way down — a cascade whose purpose
      // has already happened, aimed at work that is already over.
      final registry = CancelRegistry();
      final token = registry.begin(FrameId('req_1'));
      registry.clear();

      expect(registry.tracked, isEmpty);
      expect(
        token.isCancelled,
        isFalse,
        reason: 'the cascade must not run on the way down',
      );
      expect(
        registry.cancel(FrameId('req_1'), CancelReason.userInterrupt),
        CancelOutcome.unknownRequest,
      );
    });
  });

  group('the cancellation token', () {
    test('the first cancel wins and a repeat does not re-notify', () async {
      final root = CancelToken();
      // Subscribed before anything happens, and `toList` completes when the stream is done —
      // which is what makes "exactly one event" an assertion rather than a race with a timer.
      final seen = root.onCancel.toList();
      final first = CancelReason.userInterrupt;
      final second = CancelReason('timeout');

      expect(root.cancel(first), isTrue, reason: 'this call tripped the token');
      expect(root.cancel(second), isFalse, reason: 'and this one did not');
      expect(root.reason, first);
      expect(root.isCancelled, isTrue);

      expect(
        await seen,
        <CancelReason>[first],
        reason:
            'the broadcast stream fired exactly once. A second notification would run a '
            "listener's cleanup twice, which is how a cancelled process group becomes a leaked "
            'one',
      );
      expect(
        await root.whenCancelled,
        first,
        reason: 'and it is an already-completed future rather than a replayed event',
      );
    });

    test(
      'a derived token is born cancelled, or is cancelled by its parent',
      () async {
        final root = CancelToken();
        final early = root.derived();
        expect(
          early.isCancelled,
          isFalse,
          reason: 'a live parent gives a live child',
        );

        root.cancel(CancelReason.userInterrupt);
        expect(
          early.isCancelled,
          isTrue,
          reason: '§3: cancellation cascades into subagents, tool calls and the process group',
        );
        expect(
          early.reason,
          CancelReason.userInterrupt,
          reason: 'inherited rather than chosen — the cascade does not restate the cause',
        );

        // The property that matters for a late subagent: derived after the cancel, it is already
        // cancelled and completes immediately rather than waiting for an event that has been and
        // gone.
        final late = root.derived();
        expect(
          late.isCancelled,
          isTrue,
          reason: 'a unit of work started after the interrupt',
        );
        expect(late.reason, CancelReason.userInterrupt);
        expect(await late.whenCancelled, CancelReason.userInterrupt);
      },
    );

    test(
      'whenCancelled releases a late listener, and onCancel does not replay',
      () async {
        final token = CancelToken();
        token.cancel(CancelReason.userInterrupt);

        expect(
          await token.onCancel.isEmpty,
          isTrue,
          reason:
              'onCancel is a broadcast fan-out for the listeners that were there. The event has '
              'gone to them and a stream does not replay',
        );
        expect(
          await token.whenCancelled,
          CancelReason.userInterrupt,
          reason:
              'which is why a caller that cannot know whether it subscribed in time uses the '
              'future instead',
        );
      },
    );

    test('a deep chain cascades once per token', () async {
      // The cascade snapshots and clears its children *before* cancelling the first, so a
      // listener that mutates the set cannot throw a concurrent-modification error and a token
      // reachable by two paths still fires exactly once.
      final root = CancelToken();
      final chain = <CancelToken>[root];
      final pending = <int, Future<List<CancelReason>>>{};
      for (var i = 0; i < 64; i++) {
        final token = chain.last.derived();
        final observed = token.onCancel.toList();
        pending[i] = observed;
        chain.add(token);
      }
      expect(chain.any((token) => token.isCancelled), isFalse);

      root.cancel(CancelReason.userInterrupt);
      for (final entry in pending.entries) {
        expect(
          await entry.value,
          hasLength(1),
          reason: 'token ${entry.key} must be notified exactly once',
        );
      }
      for (final token in chain) {
        expect(token.isCancelled, isTrue);
        expect(token.reason, CancelReason.userInterrupt);
      }
    });

    test('a token cancelled directly takes neither its parent nor its siblings', () async {
      final root = CancelToken();
      final first = root.derived();
      final second = root.derived();

      expect(first.cancel(CancelReason.userInterrupt), isTrue);
      expect(second.cancel(CancelReason('timeout')), isTrue);
      expect(
        root.isCancelled,
        isFalse,
        reason:
            'a child is cancellable on its own without cancelling the session',
      );

      // A child of the root created after both siblings died is live, so the root's set is not
      // poisoned by the two that are gone.
      final third = root.derived();
      expect(third.isCancelled, isFalse);
      expect(root.cancel(CancelReason.userInterrupt), isTrue);
      expect(third.isCancelled, isTrue);
      expect(
        await third.whenCancelled,
        CancelReason.userInterrupt,
        reason: 'and it was reached by the cascade, exactly once',
      );
    });
  });

  group('the -32031 answer', () {
    test('an unfinished cancelled request answers -32031 on its own id', () async {
      final registry = CancelRegistry();
      final id = FrameId('req_01f4a9c2');
      final token = registry.begin(id);
      expect(
        registry.cancel(id, CancelReason.userInterrupt),
        CancelOutcome.cancelled,
      );

      // The dispatcher waits for its work to notice the token, and then answers. Ordered here
      // the way it happens, because §3.1 puts the whole race in that order.
      final reason = await token.whenCancelled;
      expect(reason, CancelReason.userInterrupt);
      expect(
        registry.complete(id),
        isTrue,
        reason:
            'marked when the response is sent, not when it starts being built',
      );

      final response = _throughTheWire(
        ResponseEnvelope(
          module: 'core',
          meta: sessionMeta,
          id: id,
          body: ErrorBody(
            AlteriOneError(
              code: DomainErrorCode.cancelled,
              message: 'the request was cancelled (${reason.wire})',
            ),
          ),
        ),
      );

      expect(
        response,
        isA<ResponseEnvelope>(),
        reason: '§3.1: a response, never a notification',
      );
      final answered = response as ResponseEnvelope;
      expect(
        answered.id,
        id,
        reason:
            "the cancelled request's own id, so the peer's pending request is answered exactly "
            'once whichever way it was cancelled',
      );
      expect(answered.errorOrNull!.code, DomainErrorCode.cancelled);
      expect(
        answered.errorOrNull!.code.code,
        -32031,
        reason: "protocol.md §6, deliberately not LSP's −32800",
      );
      expect(answered.resultOrNull, isNull);
      expect(answered.toJson().toMap().containsKey('result'), isFalse);
      expect(
        asCancelRequest(answered),
        isNull,
        reason: r'the answer is a response, not a second $/cancelRequest',
      );
    });

    test('the cancel that tripped it is still never answered', () {
      // The two frames are different objects with different correlations: one is addressed to a
      // request by id, the other is addressed to nobody at all. A receiver that answered the
      // notification would have nowhere to put the answer.
      final cancel = _throughTheWire(
        CancelRequest(
          requestId: FrameId('req_01f4a9c2'),
          reason: CancelReason.userInterrupt,
        ).toEnvelope(module: 'core', meta: sessionMeta),
      );
      expect((cancel as NotificationEnvelope).id, isNull);
      expect(cancel.toJson().toMap().containsKey('error'), isFalse);
      expect(cancel.toJson().toMap().containsKey('result'), isFalse);
    });
  });

  group('progress', () {
    test('a progress notification round-trips with its optionals', () {
      final event = ProgressEvent(
        requestId: FrameId('req_01f4a9c2'),
        progress: 0.5,
        total: 4,
        message: 'Half the steps done',
      );
      final frame = _throughTheWire(
        event.toEnvelope(module: 'core', meta: sessionMeta),
      );
      expect(frame, isA<NotificationEnvelope>());
      final notification = frame as NotificationEnvelope;
      expect(notification.method, progressMethod);
      expect(notification.id, isNull);
      expect(notification.params['total'], 4);
      expect(notification.params['message'], 'Half the steps done');

      final read = asProgressEvent(notification);
      expect(read, event);
      expect(read!.progress, 0.5);
      expect(
        read.total,
        4,
        reason: '§3.2: informational, and nothing derives from it',
      );
      expect(read.message, 'Half the steps done');
      expect(read.requestId, FrameId('req_01f4a9c2'));
    });

    test('the constructor refuses a fraction it could not draw', () {
      // Both doors are checked, because both are ways a value enters the type. `nan` and an
      // infinity are named rather than left to the two comparisons: `nan < 0.0` and `nan > 1.0`
      // are both false, so a range check written as comparisons admits a `nan` silently.
      for (final bad in <double>[
        -0.0001,
        1.0001,
        -1.0,
        2.0,
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(
          () => ProgressEvent(requestId: FrameId('req_1'), progress: bad),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.name,
              'name',
              'progress',
            ),
          ),
          reason: '$bad is not a fraction',
        );
      }

      // The boundaries are inclusive, and the difference is a peer that can report 100%.
      expect(
        ProgressEvent(requestId: FrameId('req_1'), progress: 0.0).progress,
        0.0,
      );
      expect(
        ProgressEvent(requestId: FrameId('req_1'), progress: 1.0).progress,
        1.0,
      );
      expect(
        () => ProgressEvent(
          requestId: FrameId('req_1'),
          progress: 0.5,
          total: -1,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => ProgressEvent(
          requestId: FrameId('req_1'),
          progress: 0.5,
          message: '',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('the wire reader refuses the same range, naming the JSON path', () {
      for (final bad in <Object?>[
        1.5,
        -0.5,
        2,
        -1,
        '0.5',
        true,
        <String>['0.5'],
        JsonMap.empty,
        null,
      ]) {
        final violation = _refuse(
          () => ProgressEvent.fromParams(
            JsonMap({'requestId': 'req_1', 'progress': bad}),
          ),
        );
        expect(
          violation.code,
          JsonRpcErrorCode.invalidParams,
          reason: '`$bad`',
        );
        expect(violation.path, r'$.params.progress', reason: '`$bad`');
      }

      final missing = _refuse(
        () => ProgressEvent.fromParams(JsonMap({'requestId': 'req_1'})),
      );
      expect(missing.code, JsonRpcErrorCode.invalidParams);
      expect(missing.path, r'$.params.progress');

      final unknown = _refuse(
        () => ProgressEvent.fromParams(
          JsonMap({'requestId': 'req_1', 'progress': 0.5, 'percent': 50}),
        ),
      );
      expect(unknown.path, r'$.params.percent');
    });

    test('an integer progress is a number, not a type error', () {
      // The case a strict `double`-only reader gets wrong and a peer gets right. JSON has one
      // number type, so a sender that computed exactly 1 has sent an `int`; refusing it would
      // break a peer that did nothing wrong.
      final wireFrame = NotificationEnvelope(
        module: 'core',
        meta: sessionMeta,
        method: progressMethod,
        params: JsonMap({'requestId': 'req_01f4a9c2', 'progress': 1}),
      );
      expect(
        encodeFrame(wireFrame),
        contains('"progress":1'),
        reason:
            'the sender wrote an integer and the payload must carry an integer',
      );

      final read = asProgressEvent(_throughTheWire(wireFrame));
      expect(read, isNotNull);
      expect(
        read!.progress,
        1.0,
        reason: 'narrowed on the way in, not refused',
      );
      expect(read.total, isNull);
      expect(read.message, isNull);
    });

    test('absent optionals are omitted, and a null is not an absent', () {
      final bare = ProgressEvent(requestId: FrameId('req_1'), progress: 0.25);
      final params = bare.toParams().toMap();
      expect(params.containsKey('total'), isFalse);
      expect(params.containsKey('message'), isFalse);
      expect(
        params.keys,
        unorderedEquals(<String>['requestId', 'progress']),
        reason:
            'a peer receiving `total: null` has to decide whether it means "no total" or "the '
            'sender did not know", and §3.2 does not make it say',
      );
      expect(
        encodeFrame(bare.toEnvelope(module: 'core', meta: sessionMeta)),
        isNot(contains('null')),
        reason: 'the writer omits rather than writing null',
      );

      // And a reader that absorbed `message: null` would be hiding a mistake rather than
      // reporting it: `containsKey` is the only thing that tells the two apart.
      // Records, not a map: `message` and `total` each appear three and four times, and a map
      // literal would keep only the last of each — four of these seven cases silently never
      // running, which is the exact shape of bug this test exists to catch.
      for (final (member, value) in <(String, Object?)>[
        ('message', null),
        ('total', null),
        ('message', ''),
        ('total', -1),
        ('total', 2.5),
        ('total', '4'),
        ('total', true),
      ]) {
        final violation = _refuse(
          () => ProgressEvent.fromParams(
            JsonMap({'requestId': 'req_1', 'progress': 0.5, member: value}),
          ),
        );
        expect(
          violation.code,
          JsonRpcErrorCode.invalidParams,
          reason: '$member: $value',
        );
        expect(
          violation.path,
          r'$.params.'
          '$member',
          reason: '$member: $value',
        );
      }
    });

    test('the ledger is monotonic and counts only what it applied', () {
      // §3.2: monotonic is the receiver's property. A peer whose progress goes backwards has a
      // cosmetic bug, and a live run must not be taken down by it.
      final id = FrameId('req_01f4a9c2');
      final ledger = ProgressLedger(id);
      expect(ledger.requestId, id);
      expect(ledger.progress, 0.0);
      expect(ledger.recorded, 0);

      ProgressVerdict feed(double value) =>
          ledger.record(asProgressEvent(_progressFrame(id, value))!);

      // 0.0 against an initial mark of 0.0 is a duplicate, not an application: the mark has not
      // moved, and counting it would report progress nobody saw.
      expect(feed(0.0), ProgressVerdict.duplicate);
      expect(ledger.recorded, 0, reason: 'the mark has not moved');

      expect(feed(0.2), ProgressVerdict.accepted);
      expect(ledger.progress, 0.2);
      expect(ledger.recorded, 1);

      // An equal value is a duplicate and is accepted silently. Progress is at-least-once in
      // practice, and a notification cannot be answered anyway.
      expect(feed(0.2), ProgressVerdict.duplicate);
      expect(ledger.progress, 0.2);
      expect(ledger.recorded, 1, reason: 'a duplicate changed nothing');

      // A lower value is ignored, not refused, and the mark does not move: a UI that has drawn
      // 60% must not jump back to 20% because a late frame arrived.
      expect(feed(0.1), ProgressVerdict.regressionIgnored);
      expect(ledger.progress, 0.2);
      expect(ledger.recorded, 1);

      expect(feed(1.0), ProgressVerdict.accepted);
      expect(ledger.progress, 1.0);
      expect(ledger.recorded, 2);
      expect(ProgressVerdict.values.map((verdict) => verdict.name), <String>[
        'accepted',
        'duplicate',
        'regressionIgnored',
      ]);
    });

    test('an event for another request is a dispatcher bug, not a value', () {
      final ledger = ProgressLedger(FrameId('req_1'));
      final foreign = ProgressEvent(requestId: FrameId('req_2'), progress: 0.5);

      expect(
        () => ledger.record(foreign),
        throwsA(isA<ArgumentError>()),
        reason:
            "a peer cannot miscorrelate — the event's requestId is what routed it here — so "
            'this is our own bug',
      );
      expect(
        ledger.progress,
        0.0,
        reason: 'and the ledger must not have taken the value',
      );
      expect(ledger.recorded, 0);
    });
  });

  group('the accepted handshake', () {
    test('core.initialize is agreed, and the answer carries the agreement', () {
      // The whole round trip: a request built from §4's example, over the wire, read back, and
      // answered with a result that names what was agreed.
      final initId = FrameId('init_01');
      final request = _throughTheWire(
        _paramsFixture().toEnvelope(
          id: initId,
          module: 'core',
          meta: sessionMeta,
        ),
      );
      expect((request as RequestEnvelope).method, initializeMethod);

      final read = InitializeParams.asInitializeRequest(request);
      expect(
        read,
        _paramsFixture(),
        reason: 'the offer survives the wire unchanged',
      );
      expect(read!.protoVersionRange.wire, '>=1.0.0 <2.0.0');

      final outcome = negotiateHandshake(
        params: read,
        meta: request.meta,
        host: _hostFixture(),
      );
      expect(outcome, isA<HandshakeAccepted>());
      final accepted = outcome as HandshakeAccepted;
      expect(accepted.warnings, isEmpty, reason: 'nothing disagreed');

      final response = _throughTheWire(
        accepted.toResponse(id: initId, module: 'core', meta: sessionMeta),
      );
      final answered = response as ResponseEnvelope;
      expect(answered.id, initId);
      expect(answered.errorOrNull, isNull);
      expect(answered.resultOrNull, isNotNull);
      final result = answered.resultOrNull!;
      expect(
        result['accepted'],
        isTrue,
        reason: '`accepted` appears in a result only as true',
      );

      final readBack = InitializeResult.fromResult(result);
      expect(readBack.negotiatedProtoVersion, ProtoVersion.current);
      expect(
        readBack.negotiatedProtoVersion,
        ProtoVersion.current,
        reason:
            "§4.3: the negotiated version is the host's own, never one picked out of the peer's "
            'range by preference',
      );
      expect(
        readBack.degradePolicy,
        DegradePolicy.refuse,
        reason: "the host's chosen policy",
      );
      expect(readBack.limits, SessionLimits.defaults);
      expect(readBack.api.protocol, ProtoVersionRange.v1);
      expect(
        readBack.api.ports.keys,
        unorderedEquals(<String>['storage', 'memory']),
      );
      expect(readBack, accepted.result);
      expect(
        readBack.toResult(),
        result,
        reason: 'the answer round-trips unchanged',
      );
    });

    test(
      'the invariant is the agreement, and every frame must declare its major',
      () {
        // §1.1 and §4.3's last bullet: after the handshake, `meta.proto ==
        // negotiatedProtoVersion.major` for every frame in the session. This is the loop closing
        // from task 0.4, which deliberately left the invariant unconstructed.
        final accepted = _agree(_paramsFixture());
        final invariant = accepted.invariant;

        expect(invariant.negotiated, accepted.result.negotiatedProtoVersion);
        expect(
          invariant.requiredProto,
          ProtoMajor.of(accepted.result.negotiatedProtoVersion),
        );
        expect(
          invariant.requiredProto.value,
          ProtoVersion.current.major,
          reason:
              'the invariant is a major, not a version and not the other field',
        );

        expect(invariant.accepts(sessionMeta.proto), isTrue);
        expect(() => invariant.require(sessionMeta.proto), returnsNormally);
        for (final major in <int>[0, ProtoVersion.current.major + 1, 99]) {
          expect(
            () => invariant.require(ProtoMajor(major)),
            throwsA(
              isA<ProtocolViolation>()
                  .having(
                    (violation) => violation.code,
                    'code',
                    DomainErrorCode.versionIncompatible,
                  )
                  .having(
                    (violation) => violation.code.code,
                    'code number',
                    -32050,
                  )
                  .having(
                    (violation) => violation.path,
                    'path',
                    r'$.meta.proto',
                  ),
            ),
            reason:
                'a frame declaring major $major is not part of this session',
          );
        }

        // A caller that knows more than this package does names the frame, so the diagnostic points
        // at a queue entry rather than at the root of a stream.
        expect(
          () => invariant.require(ProtoMajor(0), path: r'$.frames[3]'),
          throwsA(
            isA<ProtocolViolation>().having(
              (violation) => violation.path,
              'path',
              r'$.frames[3].meta.proto',
            ),
          ),
        );
      },
    );

    test('the accepted outcome is what builds the invariant', () {
      // Asserted by behaviour rather than by reflection. What §4.3 promises is that "an accepted
      // handshake is the only thing that constructs a `SessionVersionInvariant`", and the
      // observable consequence is that the invariant belongs to the *outcome*: one value per
      // accepted handshake, `late final` so that two reads are the same object, and it tracks the
      // result's negotiated version rather than anything the result could be asked for.
      final first = _agree(_paramsFixture());
      final second = _agree(_paramsFixture());

      expect(
        first.invariant,
        same(first.invariant),
        reason:
            'one agreement is one value. A getter building a fresh one per read would make two '
            'references to the same session unequal, and `SessionVersionInvariant` has no `==`',
      );
      expect(
        second.invariant,
        isNot(same(first.invariant)),
        reason:
            'two handshakes are two agreements even from equal inputs — so the invariant is the '
            "outcome's, and a bare result cannot answer for one",
      );
      expect(second.invariant.requiredProto, first.invariant.requiredProto);
      expect(second.invariant.negotiated, second.result.negotiatedProtoVersion);

      // And a result is only a value: it can be built for a version nothing agreed on, and
      // nothing on it pins a session to that version.
      final unagreed = InitializeResult(
        negotiatedProtoVersion: ProtoVersion(major: 9, minor: 0, patch: 0),
        degradePolicy: DegradePolicy.refuse,
        limits: SessionLimits.defaults,
        api: HostApiVersions(
          protocol: ProtoVersionRange.parse('>=9.0.0 <10.0.0'),
          extension: ProtoVersionRange.parse('1.0.0'),
          runtime: ProtoVersionRange.parse('1.0.0'),
        ),
      );
      expect(unagreed.toResult()['negotiatedProtoVersion'], '9.0.0');
      expect(
        first.invariant.accepts(ProtoMajor(9)),
        isFalse,
        reason: 'the agreement this file holds is major 1, whatever a result can be built for',
      );
    });
  });

  group('the refused handshake', () {
    test(
      'an incompatible version is refused with -32050 and names the cause',
      () {
        // The acceptance case, named in §4.2: a peer whose `protoVersionRange` does not admit the
        // version the host speaks. The code and the `data.reason` are both load-bearing — `-32050`
        // alone sends an operator looking for the wrong half of the system.
        final initId = FrameId('init_01');
        final request = _throughTheWire(
          _paramsFixture(
            protoVersionRange: ProtoVersionRange.parse('>=2.0.0 <3.0.0'),
          ).toEnvelope(id: initId, module: 'core', meta: sessionMeta),
        );
        final read = InitializeParams.asInitializeRequest(request)!;
        final outcome = negotiateHandshake(
          params: read,
          meta: request.meta,
          host: _hostFixture(),
        );

        expect(outcome, isA<HandshakeRefused>());
        final refused = outcome as HandshakeRefused;
        expect(refused.cause, HandshakeCause.protoRangeUnsatisfied);
        expect(refused.cause.wireName, 'proto_range_unsatisfied');

        final error = refused.toError();
        expect(error.code, DomainErrorCode.versionIncompatible);
        expect(error.code.code, -32050, reason: 'protocol.md §6');
        expect(error.data['reason'], 'proto_range_unsatisfied');
        expect(error.data['detail'], refused.detail);
        expect(error.data['hostVersion'], ProtoVersion.current.toString());
        expect(error.message, contains(initializeMethod));

        // §4.2's first bullet, and §1's exclusivity: a refusal is the error response, and
        // `accepted: false` is what the *negotiator* concludes — never a member of the frame.
        final response = _throughTheWire(
          refused.toResponse(id: initId, module: 'core', meta: sessionMeta),
        );
        final answered = response as ResponseEnvelope;
        expect(answered.id, initId);
        expect(answered.resultOrNull, isNull);
        expect(answered.errorOrNull!.code, DomainErrorCode.versionIncompatible);
        expect(answered.errorOrNull!.data['reason'], 'proto_range_unsatisfied');
        final wire = answered.toJson().toMap();
        expect(wire.containsKey('result'), isFalse);
        expect(wire.containsKey('error'), isTrue);
        expect(
          () => InitializeResult.fromResult(
            JsonMap(<String, Object?>{...refused.toError().data.toMap()}),
          ),
          throwsA(
            isA<ProtocolViolation>().having(
              (violation) => violation.path,
              'path',
              r'$.result.reason',
            ),
          ),
          reason:
              'the refusal carries `reason` and `detail` and never `accepted`, so a peer cannot '
              'read it as a result it declined',
        );
      },
    );

    test('every cause is -32050, including a capability mismatch', () {
      // §4.2: the handshake negotiates and does not grant, so nothing has been published that
      // could be denied. A capability asked for *after* the handshake is `-32042`, and answering
      // `-32042` here would tell an operator a policy denied something when nothing has been
      // granted to deny.
      final causes = <HandshakeCause, InitializeParams>{
        HandshakeCause.protoRangeUnsatisfied: _paramsFixture(
          protoVersionRange: ProtoVersionRange.parse('>=2.0.0 <3.0.0'),
        ),
        HandshakeCause.moduleVersionMismatch: _paramsFixture(
          moduleVersion: ProtoVersion(major: 1, minor: 2, patch: 0),
        ),
        HandshakeCause.extensionApiOutOfRange: _paramsFixture(
          extensionApi: ProtoVersion(major: 2, minor: 0, patch: 0),
        ),
        HandshakeCause.portVersionOutOfRange: _paramsFixture(
          ports: <String, ProtoVersion>{
            'storage': ProtoVersion(major: 2, minor: 0, patch: 0),
          },
        ),
        HandshakeCause.undeclaredPort: _paramsFixture(
          ports: <String, ProtoVersion>{'telemetry': _v1_0_0},
        ),
        HandshakeCause.capabilityMismatch: _paramsFixture(
          capabilities: const <String>['shell.run'],
        ),
      };
      expect(
        causes.keys.toSet(),
        HandshakeCause.values.toSet(),
        reason: 'every cause §4.2 names, and no others',
      );

      for (final entry in causes.entries) {
        final outcome = _negotiate(entry.value);
        expect(outcome, isA<HandshakeRefused>(), reason: '${entry.key}');
        final refused = outcome as HandshakeRefused;
        expect(refused.cause, entry.key);
        final error = refused.toError();
        expect(
          error.code,
          DomainErrorCode.versionIncompatible,
          reason: '${entry.key}',
        );
        expect(error.code.code, -32050, reason: '${entry.key}');
        expect(
          error.data['reason'],
          entry.key.wireName,
          reason: '${entry.key}',
        );
        expect(
          refused.detail,
          isNotEmpty,
          reason: 'an unreadable -32050 names nothing',
        );
      }
      expect(
        HandshakeCause.values.map((cause) => cause.wireName).toSet(),
        <String>{
          'proto_range_unsatisfied',
          'module_version_mismatch',
          'extension_api_out_of_range',
          'port_version_out_of_range',
          'undeclared_port',
          'capability_mismatch',
        },
      );
    });

    test('the host refuses its own misconfiguration', () {
      // §4.3's second range is a self-check, not a redundancy: a host whose own version falls
      // outside the `api.protocol` it publishes is misconfigured, and the handshake is where a
      // peer would otherwise find out by not working.
      final outcome = _negotiate(
        _paramsFixture(),
        host: _hostFixture(protocol: ProtoVersionRange.parse('2.0.0')),
      );
      expect(outcome, isA<HandshakeRefused>());
      final refused = outcome as HandshakeRefused;
      expect(
        refused.cause,
        HandshakeCause.protoRangeUnsatisfied,
        reason:
            'to the peer it *is* an unsatisfiable range, and a sixth cause would give -32050 two '
            'spellings',
      );
      expect(refused.detail, contains('api.protocol'));
      expect(refused.hostVersion, ProtoVersion.current);

      // The peer's own range is checked first, so a peer that also excluded this host reports
      // the peer's problem rather than the host's.
      expect(
        _refusalCause(
          _paramsFixture(
            protoVersionRange: ProtoVersionRange.parse('>=2.0.0 <3.0.0'),
          ),
          host: _hostFixture(protocol: ProtoVersionRange.parse('2.0.0')),
        ),
        HandshakeCause.protoRangeUnsatisfied,
      );
    });

    test(
      'a peer that sends two module versions has not said which one it is',
      () {
        // Checked before the range, because it is the more specific fact: telling a peer whose
        // `meta` and `params` disagree that its range did not match sends it looking at a
        // constraint it may well satisfy.
        final disagreeing = EnvelopeMeta(
          proto: ProtoMajor.of(ProtoVersion.current),
          moduleVersion: ProtoVersion(major: 1, minor: 2, patch: 0),
        );
        expect(
          _refusalCause(_paramsFixture(), meta: disagreeing),
          HandshakeCause.moduleVersionMismatch,
        );
        expect(
          _refusalCause(
            _paramsFixture(
              moduleVersion: ProtoVersion(major: 1, minor: 2, patch: 0),
            ),
            meta: disagreeing,
          ),
          isNull,
          reason: 'two members that agree on 1.2.0 are not a disagreement',
        );
      },
    );

    test('the extension and the ports are checked, and an unpublished port is fatal', () {
      // §4.1's mandatory check, and §4.3's spelling of it: a port the host does not declare is
      // as fatal as one declared at the wrong version, because both mean the peer was built
      // against a contract this host does not have.
      expect(
        _refusalCause(
          _paramsFixture(
            extensionApi: ProtoVersion(major: 2, minor: 0, patch: 0),
          ),
        ),
        HandshakeCause.extensionApiOutOfRange,
      );
      expect(
        _refusalCause(
          _paramsFixture(
            ports: <String, ProtoVersion>{
              'storage': ProtoVersion(major: 2, minor: 0, patch: 0),
            },
          ),
        ),
        HandshakeCause.portVersionOutOfRange,
      );
      expect(
        _refusalCause(
          _paramsFixture(ports: <String, ProtoVersion>{'telemetry': _v1_0_0}),
        ),
        HandshakeCause.undeclaredPort,
        reason: 'a port the host does not publish at all',
      );
      expect(
        _refusalCause(
          _paramsFixture(
            ports: <String, ProtoVersion>{
              'storage': _v1_0_0,
              'memory': _v1_0_0,
            },
          ),
        ),
        isNull,
        reason: 'every published port, at an admitted version',
      );
      expect(
        _refusalCause(
          _paramsFixture(capabilities: const <String>['web.search']),
        ),
        isNull,
      );
    });

    test('a host publishing a date range refuses a semver for that port', () {
      // §4's own example: `mcp: "2026-07-28"` is a date-shaped exact version rather than a
      // semver. No `ProtoVersion` spells a date, so the range admits nothing — said rather than
      // hidden, and refused rather than coerced into `2026.7.28`.
      final outcome = _negotiate(
        _paramsFixture(ports: <String, ProtoVersion>{'mcp': _v1_0_0}),
        host: _hostFixture(
          ports: <String, ProtoVersionRange>{
            'mcp': ProtoVersionRange.parse('2026-07-28'),
          },
        ),
      );
      final refused = outcome as HandshakeRefused;
      expect(refused.cause, HandshakeCause.portVersionOutOfRange);
      expect(refused.detail, contains('mcp'));
    });
  });

  group('the degrade policy', () {
    test('a capability mismatch degrades only when the host chose it to', () {
      // §4.3: the *policy* decides whether a capability mismatch degrades, and the decision is
      // recorded in the outcome as a warning rather than discarded.
      final asking = _paramsFixture(capabilities: const <String>['shell.run']);

      expect(
        _refusalCause(asking, host: _hostFixture(policy: DegradePolicy.refuse)),
        HandshakeCause.capabilityMismatch,
        reason: 'the default reading of §4.3 is fail-closed',
      );

      final degraded = _negotiate(
        asking,
        host: _hostFixture(policy: DegradePolicy.warnAndDegrade),
      );
      expect(degraded, isA<HandshakeAccepted>());
      final accepted = degraded as HandshakeAccepted;
      expect(accepted.warnings, hasLength(1));
      expect(accepted.warnings.single.cause, HandshakeCause.capabilityMismatch);
      expect(accepted.warnings.single.detail, contains('shell.run'));
      expect(
        accepted.result.degradePolicy,
        DegradePolicy.warnAndDegrade,
        reason: 'echoed so the peer knows what it is being held to',
      );
      expect(
        accepted.result.toResult()['degradePolicy'],
        'warn+degrade',
        reason: 'and on the wire, spelled the way §4 writes it',
      );
      expect(
        accepted.invariant.accepts(sessionMeta.proto),
        isTrue,
        reason: 'a degraded handshake is still an agreed one, and it pins the session too',
      );
    });

    test('a warn+degrade host still refuses a version disagreement', () {
      // The load-bearing half of §4.3: degradability is a property of the *cause*, not of the
      // configuration. A host that cannot speak the peer's version cannot usefully pretend to,
      // and continuing would be a session running on a version nobody agreed to.
      expect(
        HandshakeCause.values
            .where((cause) => cause != HandshakeCause.capabilityMismatch)
            .every((cause) => !cause.degradable),
        isTrue,
        reason:
            'the four version causes and `undeclared_port` are fail-closed whatever a host '
            'configures',
      );
      expect(HandshakeCause.capabilityMismatch.degradable, isTrue);

      final host = _hostFixture(policy: DegradePolicy.warnAndDegrade);
      expect(
        _refusalCause(
          _paramsFixture(
            protoVersionRange: ProtoVersionRange.parse('>=2.0.0 <3.0.0'),
          ),
          host: host,
        ),
        HandshakeCause.protoRangeUnsatisfied,
      );
      expect(
        _refusalCause(
          _paramsFixture(
            moduleVersion: ProtoVersion(major: 1, minor: 2, patch: 0),
          ),
          host: host,
        ),
        HandshakeCause.moduleVersionMismatch,
      );
      expect(
        _refusalCause(
          _paramsFixture(
            extensionApi: ProtoVersion(major: 2, minor: 0, patch: 0),
          ),
          host: host,
        ),
        HandshakeCause.extensionApiOutOfRange,
      );
      expect(
        _refusalCause(
          _paramsFixture(
            ports: <String, ProtoVersion>{
              'storage': ProtoVersion(major: 2, minor: 0, patch: 0),
            },
          ),
          host: host,
        ),
        HandshakeCause.portVersionOutOfRange,
      );
      expect(
        _refusalCause(
          _paramsFixture(ports: <String, ProtoVersion>{'telemetry': _v1_0_0}),
          host: host,
        ),
        HandshakeCause.undeclaredPort,
      );
      expect(
        _refusalCause(_paramsFixture(), host: host),
        isNull,
        reason: 'a peer asking only for what the host publishes is not a degradation at all',
      );
      expect(
        _refusalCause(
          _paramsFixture(capabilities: const <String>['shell.run']),
          host: host,
        ),
        isNull,
        reason: 'and the one cause the policy covers is the only one it covers',
      );
    });

    test('the policy is chosen, never inferred', () {
      // §4.3's last bullet: defaulting to `refuse` would be the safe answer and the wrong one —
      // it silently accepts a peer that forgot to choose, and the operator never learns the
      // policy was never set.
      final agreed = _agree(_paramsFixture());
      final result = Map<String, Object?>.of(agreed.result.toResult().toMap());
      expect(result.containsKey('degradePolicy'), isTrue);

      final missing = Map<String, Object?>.of(result)..remove('degradePolicy');
      final absent = _refuse(
        () => InitializeResult.fromResult(JsonMap(missing)),
      );
      expect(absent.code, JsonRpcErrorCode.invalidParams);
      expect(absent.path, r'$.result.degradePolicy');
      expect(absent.message, contains('absent'));

      for (final bad in <Object?>[
        'warn-and-degrade',
        'warn_degrade',
        'WARN+DEGRADE',
        'degrade',
        true,
        null,
        1,
      ]) {
        final violation = _refuse(
          () => InitializeResult.fromResult(
            JsonMap(<String, Object?>{...result, 'degradePolicy': bad}),
          ),
        );
        expect(
          violation.code,
          JsonRpcErrorCode.invalidParams,
          reason: '`$bad` is not a policy this version defines',
        );
        expect(violation.path, r'$.result.degradePolicy', reason: '`$bad`');
      }

      expect(DegradePolicy.values.map((policy) => policy.wireName), <String>[
        'refuse',
        'warn+degrade',
      ]);
      expect(DegradePolicy.fromWireName('refuse'), DegradePolicy.refuse);
      expect(
        DegradePolicy.fromWireName('warn+degrade'),
        DegradePolicy.warnAndDegrade,
      );
      expect(DegradePolicy.fromWireName('anything else'), isNull);
      expect(DegradePolicy.fromWireName(1), isNull);
    });

    test('a result carrying accepted: false is -32600, not -32602', () {
      // §4.2: such a peer "has neither agreed nor refused", and a session started from it is a
      // session nobody agreed to. `-32602` would report a schema problem with a payload that is
      // perfectly well formed.
      final agreed = _agree(_paramsFixture());
      final result = Map<String, Object?>.of(agreed.result.toResult().toMap());

      final refused = _refuse(
        () => InitializeResult.fromResult(
          JsonMap(<String, Object?>{...result, 'accepted': false}),
        ),
      );
      expect(refused.code, JsonRpcErrorCode.invalidRequest);
      expect(refused.code.code, -32600);
      expect(refused.path, r'$.result.accepted');

      // Absent is a different mistake and gets a different code: the frame decoded, so the
      // payload is what is being read.
      final missing = Map<String, Object?>.of(result)..remove('accepted');
      final absent = _refuse(
        () => InitializeResult.fromResult(JsonMap(missing)),
      );
      expect(absent.code, JsonRpcErrorCode.invalidParams);
      expect(absent.path, r'$.result.accepted');

      // And an unknown member is refused, so a peer cannot end up believing a limit was agreed
      // that was not.
      final unknown = _refuse(
        () => InitializeResult.fromResult(
          JsonMap(<String, Object?>{...result, 'negotiatedProto': '1.0.0'}),
        ),
      );
      expect(unknown.path, r'$.result.negotiatedProto');
    });
  });

  group('the negotiated limits', () {
    test('a peer asking for 16 MiB is granted 8 MiB and told 8 MiB', () {
      // §4.3: "may negotiate lower, never higher" is arithmetic, not a request to both sides'
      // good behaviour. The answer is the clamp rather than a rejection, because a peer asking
      // for too much is asking for a conversation, not committing a breach.
      final accepted = _agree(
        _paramsFixture(
          limits: const SessionLimits(maxFrameBytes: 16 * 1024 * 1024),
        ),
      );
      expect(accepted.result.limits.maxFrameBytes, hardMaxFrameBytes);
      expect(accepted.result.limits.maxFrameBytes, 8388608);
      expect(accepted.result.limits, SessionLimits.defaults);
      expect(
        (accepted.result.toResult()['limits']! as JsonMap)['maxFrameBytes'],
        hardMaxFrameBytes,
        reason: 'and the peer is told the number it is held to',
      );

      // Reading a proposal clamps it in every build, and so does holding one: the assert in
      // `SessionLimits` is debug-only, so `capped` is the check that holds either way.
      expect(
        SessionLimits.fromJson(
          const JsonMap.trusted(<String, Object?>{'maxFrameBytes': 16777216}),
        ).maxFrameBytes,
        hardMaxFrameBytes,
      );
      expect(
        const SessionLimits(maxFrameBytes: 1 << 30).capped.maxFrameBytes,
        hardMaxFrameBytes,
        reason: 'a limit that configuration can raise is not a limit',
      );
    });

    test('a peer asking for less gets its number', () {
      final accepted = _agree(
        _paramsFixture(
          limits: const SessionLimits(
            maxFrameBytes: 65536,
            maxHeaderBytes: 1024,
            maxJsonDepth: 8,
            maxConcurrentRequests: 4,
          ),
        ),
      );
      expect(accepted.result.limits.maxFrameBytes, 65536);
      expect(accepted.result.limits.maxHeaderBytes, 1024);
      expect(accepted.result.limits.maxJsonDepth, 8);
      expect(accepted.result.limits.maxConcurrentRequests, 4);

      // The two framing numbers are also available as the type the codec and the transport
      // take, so a caller does not rebuild one from a negotiated value.
      final frames = accepted.result.limits.frames;
      expect(frames.maxFrameBytes, 65536);
      expect(frames.maxHeaderBytes, 1024);
    });

    test("an absent params.limits yields the host's own clamped limits", () {
      // §4.2: an absent `limits` means "no request to lower anything", which is exactly the
      // default — so the peer gets the host's own numbers back rather than a refusal.
      final host = _hostFixture(
        limits: const SessionLimits(
          maxFrameBytes: 1024 * 1024,
          maxJsonDepth: 8,
        ),
      );
      expect(host.limits.maxFrameBytes, 1024 * 1024);

      final accepted = _agree(_paramsFixture(), host: host);
      expect(accepted.result.limits.maxFrameBytes, 1024 * 1024);
      expect(accepted.result.limits.maxJsonDepth, 8);
      expect(
        accepted.result.limits.maxHeaderBytes,
        SessionLimits.defaults.maxHeaderBytes,
        reason: "a member the peer did not lower keeps the host's own",
      );
      expect(
        _paramsFixture().limits,
        isNull,
        reason: 'and it is omitted from `params` rather than written as null',
      );
      expect(
        encodeFrame(
          _paramsFixture().toEnvelope(
            id: FrameId('init_01'),
            module: 'core',
            meta: sessionMeta,
          ),
        ),
        isNot(contains('"limits"')),
      );

      // A host that configured above the cap is clamped at construction, so a caller reading
      // `host.limits` is reading the effective value and cannot negotiate against a number that
      // was never in force.
      expect(
        _hostFixture(limits: const SessionLimits(maxFrameBytes: 1 << 30))
            .limits
            .maxFrameBytes,
        hardMaxFrameBytes,
      );
    });

    test(
      'the four limits are one value, and the fifth row is not among them',
      () {
        // §2's table has five rows. Four are negotiated together and one — 256 queued pending
        // responses — is a transport's own local policy, because the depth of one queue is not a
        // fact two peers can agree about.
        expect(SessionLimits.defaults.maxFrameBytes, hardMaxFrameBytes);
        expect(SessionLimits.defaults.maxHeaderBytes, hardMaxHeaderBytes);
        expect(SessionLimits.defaults.maxJsonDepth, hardMaxJsonDepth);
        expect(
          SessionLimits.defaults.maxConcurrentRequests,
          hardMaxConcurrentRequests,
        );
        expect(
          SessionLimits.defaults.toJson().toMap().keys,
          unorderedEquals(<String>[
            'maxFrameBytes',
            'maxHeaderBytes',
            'maxJsonDepth',
            'maxConcurrentRequests',
          ]),
          reason: 'one negotiated object, all four members, always',
        );
        expect(defaultMaxQueuedFrames, 256);
        expect(
          defaultMaxQueuedFrames,
          isNot(SessionLimits.defaults.maxConcurrentRequests),
          reason:
              'the queue depth is not the in-flight bound, and confusing the two would refuse '
              'work for the wrong reason',
        );
        final frames = SessionLimits.defaults.frames;
        expect(frames.maxFrameBytes, FrameLimits.defaults.maxFrameBytes);
        expect(frames.maxHeaderBytes, FrameLimits.defaults.maxHeaderBytes);

        // `minimum` is the agreement between two peers and deliberately does *not* fold in the
        // hard cap, so a caller cannot clamp twice and cannot agree to 32 MiB because both sides
        // happened to configure it.
        final generous = const SessionLimits(maxFrameBytes: 1 << 30);
        expect(
          SessionLimits.minimum(generous, generous).maxFrameBytes,
          1 << 30,
        );
        expect(
          SessionLimits.minimum(generous, generous).capped.maxFrameBytes,
          hardMaxFrameBytes,
        );
      },
    );

    test('a limits block is read strictly', () {
      final unknown = _refuse(
        () => SessionLimits.fromJson(
          const JsonMap.trusted(<String, Object?>{'maxQueuedFrames': 256}),
        ),
      );
      expect(unknown.code, JsonRpcErrorCode.invalidParams);
      expect(unknown.path, r'$.params.limits.maxQueuedFrames');

      for (final bad in <Object?>[0, -1, 8388608.0, '8388608', true]) {
        final violation = _refuse(
          () => SessionLimits.fromJson(
            JsonMap(<String, Object?>{'maxFrameBytes': bad}),
          ),
        );
        expect(
          violation.code,
          JsonRpcErrorCode.invalidParams,
          reason: '`$bad` is not a positive count',
        );
        expect(
          violation.path,
          r'$.params.limits.maxFrameBytes',
          reason: '`$bad`',
        );
      }

      // A caller knows more about where a block came from than this package does.
      final elsewhere = _refuse(
        () => SessionLimits.fromJson(
          const JsonMap.trusted(<String, Object?>{'maxFrameBytes': 0}),
          path: r'$.result.limits',
        ),
      );
      expect(elsewhere.path, r'$.result.limits.maxFrameBytes');
    });
  });

  group('the range grammar', () {
    test('the grammar is the conjunction form and nothing else', () {
      // §4.4: one spelling, everywhere. A parser that accepts a second form has two answers to
      // "is 1.5.0 inside this range", and two answers is one more than a protocol can carry
      // without the peers disagreeing about what was agreed.
      for (final text in <String>[
        r'^1.0.0',
        r'~1.0.0',
        '1.x',
        '*',
        '1.0.0 || 2.0.0',
        '>=1.0',
        '>=1.0.0, <2.0.0',
        '',
        '   ',
        '1.0.0-',
        'banana',
        '>=',
      ]) {
        expect(
          () => ProtoVersionRange.parse(text),
          throwsA(isA<FormatException>()),
          reason:
              '`$text` is outside the grammar and must be refused, never partially understood',
        );
        expect(ProtoVersionRange.parseOrNull(text), isNull, reason: '`$text`');
      }

      // The refusal names the *offending token*, because "not a range" sends a peer looking for a
      // formatting mistake rather than at the token it actually wrote.
      final offending = <String, String>{
        r'^1.0.0': r'^1.0.0',
        '1.0.0 || 2.0.0': '||',
        '1.0.0-': '1.0.0-',
        'banana': 'banana',
      };
      for (final entry in offending.entries) {
        final error = _formatFailure(() => ProtoVersionRange.parse(entry.key));
        expect(
          error.message,
          contains(entry.value),
          reason: '`${entry.key}` must be named in its own refusal',
        );
      }

      // A date is exact or nothing, so it may not be given a precedence to be ordered by.
      final date = _formatFailure(
        () => ProtoVersionRange.parse('>=2026-07-28'),
      );
      expect(date.message, contains('no precedence'));
    });

    test('a bare version means exactly itself', () {
      // §4 states that `extension: "1.0.0"` is a range admitting exactly `1.0.0`, and that is
      // the second reason the grammar has a bare version at all.
      final exact = ProtoVersionRange.parse('1.0.0');
      expect(exact.allows(_v1_0_0), isTrue);
      expect(exact.allows(ProtoVersion(major: 1, minor: 0, patch: 1)), isFalse);
      expect(exact.allows(ProtoVersion(major: 1, minor: 1, patch: 0)), isFalse);
      expect(exact.allows(ProtoVersion(major: 2, minor: 0, patch: 0)), isFalse);
      expect(
        exact.wire,
        '1.0.0',
        reason: "the peer's own spelling, echoed back",
      );
      expect(exact.toString(), '1.0.0');
      expect(
        exact,
        ProtoVersionRange.parse('=1.0.0'),
        reason: 'one range, two spellings of it',
      );
      expect(
        ProtoVersionRange.parse('>=1.0.0 <2.0.0'),
        isNot(ProtoVersionRange.parse('<2.0.0 >=1.0.0')),
        reason:
            'a conjunction is order-independent and `==` is not, on purpose: `wire` is what the '
            'peer wrote and `==` is what this value is',
      );
      expect(
        ProtoVersionRange.parse('>=1.0.0 <2.0.0').wire,
        '>=1.0.0 <2.0.0',
        reason: "and the peer's constraint goes back out as it was written",
      );
      expect(ProtoVersionRange.v1, ProtoVersionRange.parse('>=1.0.0 <2.0.0'));
    });

    test('a conjunction must hold in full', () {
      // §4.4: every comparator must hold. One that does not is enough to exclude a version.
      expect(ProtoVersionRange.v1.allows(_v1_0_0), isTrue);
      expect(
        ProtoVersionRange.v1.allows(ProtoVersion(major: 1, minor: 5, patch: 0)),
        isTrue,
      );
      expect(
        ProtoVersionRange.v1.allows(
          ProtoVersion(major: 1, minor: 99, patch: 99),
        ),
        isTrue,
      );
      expect(
        ProtoVersionRange.v1.allows(ProtoVersion(major: 2, minor: 0, patch: 0)),
        isFalse,
      );
      expect(
        ProtoVersionRange.v1.allows(ProtoVersion(major: 0, minor: 9, patch: 9)),
        isFalse,
      );

      // Every comparator that admits `1.0.0` itself. `>1.0.0` and `<1.0.0` are the two that do
      // not, and they are asserted immediately below: a conjunction form is only worth anything
      // if each comparator is read strictly, and `>` swallowing its boundary would be a range
      // engine that quietly accepts the version it was told to exclude.
      for (final text in <String>[
        '>=1.0.0',
        '<=1.0.0',
        '<2.0.0',
        '<1.0.1',
        '=1.0.0',
      ]) {
        expect(
          ProtoVersionRange.parse(text).allows(_v1_0_0),
          isTrue,
          reason: text,
        );
      }
      expect(ProtoVersionRange.parse('>1.0.0').allows(_v1_0_0), isFalse);
      expect(ProtoVersionRange.parse('<1.0.0').allows(_v1_0_0), isFalse);
      expect(
        ProtoVersionRange.parse('>=1.0.0\t<2.0.0').allows(_v1_0_0),
        isTrue,
        reason: 'a tab between two comparators is a separator, not part of the second token',
      );
    });

    test('a pre-release sorts below its release, and build is ignored', () {
      // §4.4: comparison is semver precedence. `1.0.0-alpha.1` does not satisfy
      // `>=1.0.0 <2.0.0`, and that is the correct answer rather than an accident.
      expect(
        ProtoVersionRange.v1.allows(
          ProtoVersion(major: 1, minor: 0, patch: 0, preRelease: 'alpha.1'),
        ),
        isFalse,
        reason:
            'a peer offering a pre-release to a range starting at the release has said it is not '
            'that release, and the handshake is the cheapest place to find out',
      );
      expect(
        ProtoVersionRange.v1.allows(
          ProtoVersion(major: 1, minor: 0, patch: 1, preRelease: 'alpha.1'),
        ),
        isTrue,
        reason: 'a pre-release of a *later* patch is inside the range',
      );
      expect(
        ProtoVersionRange.parse('>=1.0.0-alpha.1').allows(_v1_0_0),
        isTrue,
      );

      final withBuild = ProtoVersion(
        major: 1,
        minor: 0,
        patch: 0,
        build: 'build.7',
      );
      expect(withBuild.toString(), '1.0.0+build.7');
      expect(
        ProtoVersionRange.parse('=1.0.0').allows(withBuild),
        isTrue,
        reason: 'build metadata is ignored in comparison, as semver requires',
      );
      expect(ProtoVersionRange.v1.allows(withBuild), isTrue);

      // And a version this package cannot parse is refused rather than coerced: a lenient
      // parser here is how `1.0` and `1.0.0` end up meaning different things on either side of
      // a socket.
      expect(ProtoVersionRange.parseOrNull('=1.0'), isNull);
      expect(ProtoVersionRange.parseOrNull('=1.0.0.0'), isNull);
      expect(ProtoVersionRange.parseOrNull('=01.0.0'), isNull);
      expect(ProtoVersion.parseOrNull('1.0.0'), isNotNull);
    });

    test('a date-shaped version is exact, and admits no ProtoVersion', () {
      // §4's `api.ports.mcp: "2026-07-28"`. Coercing it into `2026.7.28` would put two spellings
      // of one version on the same boundary, which is the defect `version.dart` exists to
      // prevent — so `allows` takes a `ProtoVersion` and admits nothing for one.
      final mcp = ProtoVersionRange.parse('2026-07-28');
      expect(mcp.wire, '2026-07-28');
      expect(
        mcp.allows(ProtoVersion(major: 2026, minor: 7, patch: 28)),
        isFalse,
      );
      expect(mcp.allows(_v1_0_0), isFalse);
      expect(mcp, ProtoVersionRange.parse('=2026-07-28'));
      expect(
        ProtoVersionRange.parse('2026-07-28 2027-01-01'),
        isNot(mcp),
        reason:
            'a conjunction of two dates is still a conjunction, not one token',
      );
    });

    test('the api block is read strictly, in both directions', () {
      // All four members are ranges and all four are required — `ports` included, because a
      // check that can be skipped by omitting its input is not a check (which is why §4.1 makes
      // `extensionApi` and `ports` mandatory). A host with no ports writes `{}`.
      final agreed = _agree(_paramsFixture());
      final api = agreed.result.api;
      expect(
        api.toJson().toMap().keys,
        unorderedEquals(<String>['protocol', 'extension', 'runtime', 'ports']),
      );

      for (final missing in <String>[
        'protocol',
        'extension',
        'runtime',
        'ports',
      ]) {
        final members = Map<String, Object?>.of(api.toJson().toMap())
          ..remove(missing);
        final violation = _refuse(
          () => HostApiVersions.fromJson(JsonMap(members)),
        );
        expect(violation.code, JsonRpcErrorCode.invalidParams, reason: missing);
        // Interpolated, so this is the path of the member that is actually missing. A raw string
        // here would compare against the literal text `$missing` and fail for every case while
        // looking like a real assertion.
        expect(
          violation.path,
          r'$.result.api.'
          '$missing',
          reason: missing,
        );
      }

      for (final bad in <Object?>[r'^1.0.0', '1.x', 1, null]) {
        final violation = _refuse(
          () => HostApiVersions.fromJson(
            JsonMap(<String, Object?>{
              ...api.toJson().toMap(),
              'extension': bad,
            }),
          ),
        );
        expect(violation.path, r'$.result.api.extension', reason: '`$bad`');
      }

      final unknownPort = _refuse(
        () => HostApiVersions.fromJson(
          JsonMap(<String, Object?>{
            ...api.toJson().toMap(),
            'ports': <String, Object?>{'Storage': '1.0.0'},
          }),
        ),
      );
      expect(
        unknownPort.path,
        r'$.result.api.ports.Storage',
        reason: 'a port name is an identifier, so a capitalised one is a manifest error',
      );
      expect(
        () => HostApiVersions(
          protocol: ProtoVersionRange.v1,
          extension: ProtoVersionRange.parse('1.0.0'),
          runtime: ProtoVersionRange.parse('1.0.0'),
          ports: <String, ProtoVersionRange>{'x' * 33: ProtoVersionRange.v1},
        ),
        throwsA(isA<ArgumentError>()),
        reason: 'a port name is at most 32 characters',
      );
      expect(
        () => InitializeParams(
          protoVersionRange: ProtoVersionRange.v1,
          moduleVersion: ProtoVersion.current,
          capabilities: const <String>['nodot'],
          extensionApi: _v1_0_0,
          ports: const <String, ProtoVersion>{},
        ),
        throwsA(isA<ArgumentError>()),
        reason:
            'a capability id needs at least one dot, so a bare token cannot be smuggled into a '
            'field a namespaced dispatcher reads',
      );
    });
  });

  group('the specification is the other half', () {
    test(r'the reserved $/ methods are the two this package defines', () {
      // [concepts.md] §2.1: a tool, an injection or a plugin MUST NOT declare a tool or an event
      // topic in a reserved namespace. So the row is a claim about this package as much as a
      // prohibition on the others.
      expect(
        _documentedControlMethods(),
        <String>[cancelRequestMethod, progressMethod],
        reason:
            '§2.1 names the control methods and records that `alteri_one_protocol` registers '
            'them',
      );
      expect(cancelRequestMethod, r'$/cancelRequest');
      expect(progressMethod, r'$/progress');
      expect(
        <String>[cancelRequestMethod, progressMethod],
        isNot(<String>[progressMethod, cancelRequestMethod]),
        reason: "the order is the document's, so a reordering is visible",
      );
    });

    test("§4's degradePolicy sentence names exactly the two wire values", () {
      expect(
        _documentedDegradePolicies(),
        DegradePolicy.values.map((policy) => policy.wireName).toList(),
        reason:
            'the values on the wire and the values in the enum are the same two, in the order '
            'the sentence states them',
      );
      expect(_documentedDegradePolicies(), <String>['refuse', 'warn+degrade']);
    });

    test("§3's wire example carries a reason this package accepts", () {
      final documented = _documentedCancelReason();
      expect(documented, 'user_interrupt');
      expect(
        CancelReason.parseOrNull(documented),
        isNotNull,
        reason:
            'the example in the specification has to be a value the reader accepts, or the '
            'document is teaching a frame this protocol refuses',
      );
      expect(
        CancelReason.userInterrupt.wire,
        documented,
        reason: "and the convenience constant is the example's own spelling",
      );
    });

    test('the negotiated limits are the table, and the fifth row is not one of them', () {
      final table = _documentedLimits();
      expect(table['frame'], SessionLimits.defaults.maxFrameBytes);
      expect(table['header'], SessionLimits.defaults.maxHeaderBytes);
      expect(table['depth'], SessionLimits.defaults.maxJsonDepth);
      expect(table['concurrent'], SessionLimits.defaults.maxConcurrentRequests);
      expect(table['queued'], defaultMaxQueuedFrames);

      expect(
        <int>[
          table['frame']!,
          table['header']!,
          table['depth']!,
          table['concurrent']!,
        ],
        isNot(contains(table['queued'])),
        reason:
            '§2 has five rows and four are negotiated. 256 queued pending responses is local '
            'per-transport policy, because the depth of one queue is not a fact two peers can '
            'agree about',
      );
      expect(
        SessionLimits.defaults.toJson().toMap().values,
        isNot(contains(table['queued'])),
      );
    });

    test("the two hard caps are the table's 64 and 32", () {
      final table = _documentedLimits();
      expect(hardMaxJsonDepth, table['depth']);
      expect(hardMaxJsonDepth, 64);
      expect(hardMaxConcurrentRequests, table['concurrent']);
      expect(hardMaxConcurrentRequests, 32);
      expect(
        hardMaxJsonDepth,
        isNot(SessionLimits.defaults.maxFrameBytes),
        reason: 'and a JSON depth is a depth, not a byte count',
      );
    });
  });
}

// -------------------------------------------------------------------------------------------
// Fixtures
// -------------------------------------------------------------------------------------------

/// `1.0.0`, spelled once. §4's example carries it for `extensionApi` and for every port.
final ProtoVersion _v1_0_0 = ProtoVersion(major: 1, minor: 0, patch: 0);

/// The `meta` every frame in this file carries: the negotiated major and the v1 manifest
/// version. `final` and not `const` because `ProtoVersion.current` is a lazily-initialised
/// `final`, and a default value has to be a constant.
final EnvelopeMeta sessionMeta = EnvelopeMeta(
  proto: ProtoMajor.of(ProtoVersion.current),
  moduleVersion: ProtoVersion.current,
);

/// [frame] encoded to framed bytes and read back the way a peer would read it.
///
/// Every correlation assertion in this file goes through here rather than handing a value to a
/// reader in memory. `params` is a `JsonMap` and `id` is a `FrameId`, so a round trip that
/// skipped the transport would test the mapping between two of our own types and never the
/// codec, the framing layer, or the fact that a notification carries its correlation id in
/// `params` at all.
AlteriOneEnvelope _throughTheWire(AlteriOneEnvelope frame) {
  final decoder = FrameDecoder();
  final decoded = decoder.addChunk(encodeFramedFrame(frame));
  expect(
    decoded,
    hasLength(1),
    reason: '${frame.type.wireName} did not frame as exactly one frame',
  );
  expect(decoder.isAtFrameBoundary, isTrue);
  return decodeEnvelope(decoded.single.text);
}

/// A `$/progress` notification for [requestId], built from the library's own type.
NotificationEnvelope _progressFrame(
  FrameId requestId,
  double progress, {
  int? total,
  String? message,
}) => ProgressEvent(
  requestId: requestId,
  progress: progress,
  total: total,
  message: message,
).toEnvelope(module: 'core', meta: sessionMeta);

/// A peer's `core.initialize` offer, carrying every member §4's example does.
///
/// The defaults are the ones §4's example uses, so a test that names a member is changing
/// exactly one thing.
InitializeParams _paramsFixture({
  ProtoVersionRange? protoVersionRange,
  ProtoVersion? moduleVersion,
  List<String> capabilities = const <String>['web.search'],
  ProtoVersion? extensionApi,
  Map<String, ProtoVersion>? ports,
  SessionLimits? limits,
}) => InitializeParams(
  protoVersionRange: protoVersionRange ?? ProtoVersionRange.v1,
  moduleVersion: moduleVersion ?? ProtoVersion.current,
  capabilities: capabilities,
  extensionApi: extensionApi ?? _v1_0_0,
  ports: ports ?? <String, ProtoVersion>{'storage': _v1_0_0},
  limits: limits,
);

/// The host side of a negotiation: its `api` block, its chosen policy and what it publishes.
HostHandshake _hostFixture({
  DegradePolicy policy = DegradePolicy.refuse,
  ProtoVersionRange? protocol,
  ProtoVersionRange? extension,
  Map<String, ProtoVersionRange>? ports,
  Set<String> capabilities = const <String>{'web.search'},
  SessionLimits limits = SessionLimits.defaults,
}) => HostHandshake(
  api: HostApiVersions(
    protocol: protocol ?? ProtoVersionRange.v1,
    extension: extension ?? ProtoVersionRange.parse('1.0.0'),
    runtime: ProtoVersionRange.parse('1.0.0'),
    ports:
        ports ??
        <String, ProtoVersionRange>{
          'storage': ProtoVersionRange.v1,
          'memory': ProtoVersionRange.v1,
        },
  ),
  degradePolicy: policy,
  capabilities: capabilities,
  limits: limits,
);

/// Runs a negotiation with this file's defaults for whatever is not named.
HandshakeOutcome _negotiate(
  InitializeParams params, {
  HostHandshake? host,
  EnvelopeMeta? meta,
}) => negotiateHandshake(
  params: params,
  meta: meta ?? sessionMeta,
  host: host ?? _hostFixture(),
);

/// The cause [params] earns, or null when the handshake was agreed.
///
/// A `switch` over the sealed [HandshakeOutcome] with no wildcard arm, so a third kind of
/// conclusion would not compile here — which is the same guarantee a dispatcher's own `switch`
/// gets.
HandshakeCause? _refusalCause(
  InitializeParams params, {
  HostHandshake? host,
  EnvelopeMeta? meta,
}) => switch (_negotiate(params, host: host, meta: meta)) {
  HandshakeRefused(:final cause) => cause,
  HandshakeAccepted() => null,
};

/// The agreed outcome for [params], failing the test when the host refused.
///
/// [expect] and [fail] are used in a helper rather than at each call site so that a test which
/// wanted an acceptance and got a refusal names the outcome instead of failing to compile on a
/// cast that is not the point being made.
HandshakeAccepted _agree(InitializeParams params, {HostHandshake? host}) {
  final outcome = _negotiate(params, host: host);
  expect(
    outcome,
    isA<HandshakeAccepted>(),
    reason: 'the host was expected to agree; it concluded $outcome',
  );
  return outcome as HandshakeAccepted;
}

/// Runs [body] and returns the [ProtocolViolation] it raised.
///
/// Fails the test when nothing is raised: a helper named for the failure that returned null
/// would let a test pass on a frame the reader quietly accepted.
ProtocolViolation _refuse(void Function() body) {
  try {
    body();
  } on ProtocolViolation catch (violation) {
    return violation;
  }
  fail('expected a ProtocolViolation, and the call returned normally');
}

/// Runs [body] and returns the [FormatException] it raised.
///
/// The same reasoning as [_refuse], for the range grammar: a null here would let a test pass on
/// a range the parser did not understand.
FormatException _formatFailure(void Function() body) {
  try {
    body();
  } on FormatException catch (error) {
    return error;
  }
  fail('expected a FormatException, and the call returned normally');
}

// -------------------------------------------------------------------------------------------
// The specification
// -------------------------------------------------------------------------------------------

/// The repository file at [relative], found by walking up from the working directory.
///
/// The acceptance command is `melos exec --scope=alteri_one_protocol -- dart test …`, and melos
/// runs it *in the package*, so a helper that opened `docs/…` relative to the working directory
/// would work when a human ran it from the root and fail in the one place it has to work. A
/// test that only passes in the way its author runs it is a test that will be skipped.
///
/// [architecture/protocol.md]: ../../../../docs/architecture/protocol.md
/// [concepts.md]: ../../../../docs/concepts.md
File _documentedFile(String relative) {
  var directory = Directory.current;
  File? found;
  while (found == null) {
    final candidate = File('${directory.path}/$relative'.replaceAll(r'\', '/'));
    if (candidate.existsSync()) found = candidate;
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  if (found == null) {
    throw StateError(
      '$relative not found above ${Directory.current.path}; this test needs the repository, '
      'and it looks for the file rather than assuming where it was run from',
    );
  }
  return found;
}

/// The five rows of [architecture/protocol.md] §2's limits table, as numbers.
///
/// Parsed rather than copied, so that editing the table without the constants is a failing test
/// rather than a documentation bug a peer finds. The frame cap is written in two forms —
/// `8 MiB (8 388 608 bytes)` — and only the bytes are compared, because that is the form the
/// code holds.
Map<String, int> _documentedLimits() {
  final found = _documentedFile('docs/architecture/protocol.md');
  final limits = <String, int>{};
  for (final line in found.readAsLinesSync()) {
    final frame = RegExp(
      r'^\|\s*Maximum frame\s*\|\s*8 MiB \(([\d\s]+) bytes\)\s*\|',
    ).firstMatch(line);
    if (frame != null) {
      limits['frame'] = int.parse(frame.group(1)!.replaceAll(' ', ''));
      continue;
    }
    final header = RegExp(r'^\|\s*Maximum header block\s*\|\s*(\d+) KiB\s*\|')
        .firstMatch(line);
    if (header != null) {
      limits['header'] = int.parse(header.group(1)!) * 1024;
      continue;
    }
    final depth = RegExp(r'^\|\s*Maximum JSON depth\s*\|\s*(\d+) levels\s*\|')
        .firstMatch(line);
    if (depth != null) {
      limits['depth'] = int.parse(depth.group(1)!);
      continue;
    }
    final concurrent = RegExp(
      r'^\|\s*Concurrent in-flight requests\s*\|\s*(\d+) per peer\s*\|',
    ).firstMatch(line);
    if (concurrent != null) {
      limits['concurrent'] = int.parse(concurrent.group(1)!);
      continue;
    }
    final queued = RegExp(
      r'^\|\s*Queued pending responses\s*\|\s*(\d+) per peer\s*\|',
    ).firstMatch(line);
    if (queued != null) {
      limits['queued'] = int.parse(queued.group(1)!);
    }
  }
  if (limits.length != 5) {
    throw StateError(
      'parsed ${limits.length} of the 5 limits from ${found.path}; the table format changed. '
      'Found: ${limits.keys.toList()}',
    );
  }
  return limits;
}

/// The `$/`-prefixed method names [concepts.md] §2.1's reserved-prefix row names.
///
/// The row, and not the two constants: the row is where the protocol says which methods are
/// reserved for this package, so a third one documented there without a constant to implement it
/// is a gap this catches.
List<String> _documentedControlMethods() {
  final found = _documentedFile('docs/concepts.md');
  for (final line in found.readAsLinesSync()) {
    if (!RegExp(r'^\|\s*`\$/` \(method\)\s*\|').hasMatch(line)) continue;
    // `` `$/` `` is the prefix itself and does not match this, so what comes out is the method
    // names and nothing else.
    final names = RegExp(r'`(\$/\w+)`')
        .allMatches(line)
        .map((match) => match.group(1)!)
        .toList();
    if (names.isEmpty) {
      throw StateError(
        'no method names on the reserved-prefix row of ${found.path}',
      );
    }
    return names;
  }
  throw StateError(
    r'the `$/` reserved-prefix row was not found in '
    '${found.path}',
  );
}

/// The wire values §4's `degradePolicy` sentence names.
///
/// §4 rather than §4.3, because §4 is where the two spellings are written down and §4.3
/// restates the rule. A value this version does not define is refused rather than defaulted, so
/// the two lists have to be the same list.
List<String> _documentedDegradePolicies() {
  final text = _documentedFile('docs/architecture/protocol.md')
      .readAsStringSync();
  final sentence = RegExp(
    r'`degradePolicy` accepts only an explicitly chosen ([^.;]+?)[.;]',
  ).firstMatch(text);
  if (sentence == null) {
    throw StateError(
      'the `degradePolicy` sentence was not found in docs/architecture/protocol.md; it is the '
      'sentence that names the two wire values',
    );
  }
  return RegExp(r'`([^`]+)`')
      .allMatches(sentence.group(1)!)
      .map((match) => match.group(1)!)
      .toList();
}

/// The `reason` §3's cancellation example carries.
///
/// Scoped to §3 rather than searched across the file, because a `reason` member somewhere else
/// in the document would be a different specification — and this is the one that has to be a
/// value the reader accepts.
String _documentedCancelReason() {
  final text = _documentedFile('docs/architecture/protocol.md')
      .readAsStringSync();
  final from = text.indexOf('## 3. Cancellation and progress');
  final to = text.indexOf('### 3.1');
  if (from < 0 || to < 0 || to < from) {
    throw StateError(
      'the §3 headings were not found in docs/architecture/protocol.md; the cancel example '
      'cannot be located without them',
    );
  }
  final reason = RegExp(r'"reason":\s*"([^"]*)"')
      .firstMatch(text.substring(from, to));
  if (reason == null) {
    throw StateError(
      'no `"reason"` in the §3 cancellation example; the wire example changed shape',
    );
  }
  return reason.group(1)!;
}
