// The envelope contract. Task 0.4.
//
// Four properties, all of them things the specification states in prose and all of them the kind
// of thing prose loses the first time somebody edits a paragraph:
//
// - every variant round-trips through JSON unchanged;
// - a notification and an event have no `id`;
// - a response carries a result or an error and never both;
// - `meta.proto` equals the negotiated major.
//
// Plus the code table, checked against the markdown it is transcribed from.
//
// The round-trip assertions are the load-bearing ones and they are written to *fail* on the
// obvious bug. `Map` and `List` compare by identity in Dart, so `expect(decoded, original)` on
// two structurally equal maps is false; a round-trip test that compares with `==` therefore
// passes for the wrong reason or fails for no reason, and neither outcome tells you whether
// the codec works. `JsonMap` implements structural equality for exactly this reason, and a test
// that compared the underlying maps would have caught nothing.
//
// No process, no socket, no network, and no `dart:io` anywhere near it: the package under test
// never imports `dart:io` and this file must not weaken that. It reads one markdown file — the
// error-code table — and that is the only I/O.
//
// The greppable acceptance string for the task is the description of the first test below:
// "sealed envelope variants round-trip and response is exclusive".

import 'dart:convert';
import 'dart:io';

import 'package:alteri_one_protocol/alteri_one_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('the round trip', () {
    test('sealed envelope variants round-trip and response is exclusive', () {
      // Every variant, encoded and decoded, equal to what went in. A variant that is missing
      // here is a variant whose wire form has never been exercised, and the four are the only
      // four `EnvelopeType` admits — so a fifth would be a compile error, not a silent gap.
      for (final original in allFixtures) {
        final decoded = decodeEnvelope(encodeFrame(original));
        expect(
          decoded,
          equals(original),
          reason:
              '${original.type.wireName} did not survive a round trip.\n'
              '  encoded: ${encodeFrame(original)}',
        );
        expect(
          decoded.runtimeType,
          original.runtimeType,
          reason:
              '${original.type.wireName} decoded as a ${decoded.runtimeType}. The discriminant '
              'and the variant have to agree or a handler will take the wrong branch',
        );
      }
    });

    test('the four variants are the four the specification names', () {
      // Sealed, so this list is not a sample. If `EnvelopeType` grew a member, the switch in
      // this file would not compile — which is the point of sealing it, and the reason the
      // round trip above cannot quietly lose a variant.
      expect(
        EnvelopeType.values.map((type) => type.wireName),
        unorderedEquals(<String>[
          'request',
          'response',
          'notification',
          'event',
        ]),
      );
      // One fixture per *type*, not one fixture in total: a response has two bodies and both
      // are worth round-tripping, so counting would be counting the wrong thing. What has to
      // hold is that no variant is untested, and that is the set of types.
      expect(
        allFixtures.map((frame) => frame.type).toSet(),
        EnvelopeType.values.toSet(),
        reason:
            'a variant with no fixture has a wire form nothing has exercised',
      );
    });

    test('encoding is a pure function of the value', () {
      // A frame encoded twice is byte-identical, and encoding does not mutate the frame. A
      // `meta` builder that appended to a shared map would pass the round trip and fail here.
      for (final fixture in allFixtures) {
        final first = encodeFrame(fixture);
        final second = encodeFrame(fixture);
        expect(
          second,
          first,
          reason: '${fixture.type.wireName} encodes differently twice',
        );
      }
    });

    test('a decoded frame does not alias the JSON it came from', () {
      // The map handed to the codec is copied and made unmodifiable on the way in. A frame that
      // aliased its caller's map is a bug that reproduces once every thousand frames, and the
      // only place it is cheap to prevent is the boundary.
      final source = <String, Object?>{
        'jsonrpc': '2.0',
        'type': 'request',
        'id': 'req_1',
        'module': 'core',
        'method': 'core/run',
        'params': {'goal': 'original'},
        'meta': {'proto': 1, 'moduleVersion': '1.0.0'},
      };
      final decoded = decodeEnvelope(jsonEncode(source));
      source['method'] = 'core/mutated';

      final request = decoded as RequestEnvelope;
      expect(
        request.method,
        'core/run',
        reason: "the frame followed the caller's map",
      );
      expect(
        // `toMap` hands out the unmodifiable view, which is the only map a caller can reach
        // the members through: `JsonMap` has no `[]=`, so a caller cannot even express the
        // edit this is checking the absence of.
        () => request.params.toMap()['goal'] = 'mutated',
        throwsUnsupportedError,
        reason:
            'a frame is handed to a transport, queued, and encoded later. A caller that can '
            'mutate it in between has changed a frame already in flight',
      );
    });
  });

  group('the id rule', () {
    test('a notification and an event have no id, and cannot be given one', () {
      // The compile-time half: there is no `id:` parameter to pass, so no caller in this
      // repository can construct one. Asserted structurally by reading the fields back.
      for (final frame in [notificationFixture, eventFixture]) {
        expect(
          frame.id,
          isNull,
          reason:
              '${frame.type.wireName} reported an id. The absence of a response to it is not '
              'an error, so an id would promise one that never comes',
        );
        expect(
          frame.toJson().toMap().containsKey('id'),
          isFalse,
          reason: '${frame.type.wireName} encoded an `id` member',
        );
      }

      // A request and a response carry one, and it is what correlates the pair.
      for (final frame in [requestFixture, responseOkFixture]) {
        expect(frame.id, isNotNull);
        expect(frame.toJson().toMap()['id'], isA<String>());
      }
    });

    test('a notification carrying an id is refused', () {
      // The wire half. A peer can send anything, so the type being right is not the whole
      // answer: the decoder has to reject the frame rather than quietly drop the id.
      //
      // The reason is asserted specifically, and that is the load-bearing part. A generic
      // "unknown member" refusal satisfies `path` and passes, and it tells the peer to stop
      // sending a field it never knew about rather than why. Deleting the codec's specific
      // `id` check leaves every other assertion in this file green — this is the one that
      // notices, which is why it does not merely assert the variant name.
      final violation = _refuse(
        _frameWith('notification', extra: {'id': 'req_1'}),
      );
      expect(
        violation.code,
        JsonRpcErrorCode.invalidRequest,
        reason:
            'an id on a notification is an invalid envelope, not a parse error',
      );
      expect(violation.path, r'$.id');
      expect(
        violation.message,
        contains('has no id'),
        reason:
            'the reason has to state the rule, not only that a field is unrecognised. "A '
            'notification has no id" tells the peer what it did; "unknown member" does not',
      );
    });

    test('an event carrying an id is refused', () {
      final violation = _refuse(_frameWith('event', extra: {'id': 'req_1'}));
      expect(violation.code, JsonRpcErrorCode.invalidRequest);
      expect(violation.path, r'$.id');
      expect(violation.message, contains('has no id'));
    });

    test('a request without an id is refused', () {
      // The other direction, and the one a decoder that only checked for a forbidden member
      // would miss. An answer that cannot be matched to its question is not an answer.
      final frame = _frameWith('request')..remove('id');
      final violation = _refuse(frame);
      expect(violation.code, JsonRpcErrorCode.invalidRequest);
      expect(violation.path, r'$.id');
      expect(violation.message, contains('correlated'));
    });

    test('a request whose id is not a non-empty string is refused', () {
      for (final bad in <Object?>[
        '',
        42,
        null,
        true,
        <String>['a'],
      ]) {
        final frame = _frameWith('request')..['id'] = bad;
        final violation = _refuse(frame);
        expect(
          violation.code,
          JsonRpcErrorCode.invalidRequest,
          reason: '`id: $bad` is not a correlation id',
        );
      }
    });
  });

  group('the response is exclusive', () {
    test('a response carrying both result and error is refused', () {
      // The property the task names. A frame with both is ambiguous — the peer has not said
      // whether the call succeeded — and a receiver that picked one would be guessing.
      final frame = _frameWith('response')
        ..remove('result')
        ..['result'] = {'status': 'completed'}
        ..['error'] = {'code': -32010, 'message': 'tool failed'};

      final violation = _refuse(frame);
      expect(violation.code, JsonRpcErrorCode.invalidRequest);
      expect(
        violation.message,
        contains('exactly one'),
        reason: 'the reason has to say what the rule is, not only that it was broken',
      );
    });

    test('a response carrying neither is refused', () {
      // The other half, and a decoder that checked only for "both" would accept it. A response
      // that answers nothing is a hung request wearing a success status.
      final frame = _frameWith('response')..remove('result');
      final violation = _refuse(frame);
      expect(violation.code, JsonRpcErrorCode.invalidRequest);
      expect(violation.message, contains('neither'));
    });

    test('the exclusivity is a type, not only a decode rule', () {
      // `ResponseBody` is sealed with exactly two cases, so a response cannot be constructed
      // with both and the compiler proves every handler is exhaustive. Read back through the
      // union rather than through a hand-built frame.
      final ResponseEnvelope ok = responseOkFixture;
      final ResponseEnvelope failed = responseErrorFixture;

      expect(ok.body, isA<ResultBody>());
      expect(ok.resultOrNull, isNotNull);
      expect(
        ok.errorOrNull,
        isNull,
        reason: 'a result and an error cannot both be present',
      );

      expect(failed.body, isA<ErrorBody>());
      expect(failed.resultOrNull, isNull);
      expect(failed.errorOrNull, isNotNull);
    });

    test('an error code outside the declared taxonomy is refused', () {
      // Including a number inside our own block that we do not define. A peer is entitled to
      // its own codes in the implementation-defined range, and this response is an AlteriOne
      // one — so an undeclared number here means the peer is speaking a protocol this host
      // does not implement, and guessing which of our codes it meant would mislabel the
      // failure in every log and every exit code derived from it.
      for (final code in <int>[
        0,
        1,
        -1,
        -31999,
        -32000,
        -32701,
        -32800,
        -32604,
      ]) {
        final frame = _frameWith('response')
          ..remove('result')
          ..['error'] = {'code': code, 'message': 'unknown'};
        final violation = _refuse(frame);
        expect(
          violation.code,
          JsonRpcErrorCode.invalidRequest,
          reason: '`$code` is not a declared AlteriOne error code',
        );
        expect(violation.path, r'$.error.code');
      }
    });
  });

  group('the proto and major invariant', () {
    test('meta.proto equals the negotiated major, and the type makes the swap impossible', () {
      final session = SessionVersionInvariant(ProtoVersion.current);

      // The stated rule, checked.
      expect(session.accepts(ProtoMajor.of(ProtoVersion.current)), isTrue);
      expect(
        session.requiredProto,
        ProtoMajor(ProtoVersion.current.major),
        reason:
            'the invariant is `meta.proto == negotiatedProtoVersion.major` — a major, not a '
            'version and not the other field',
      );

      // The pre-handshake state, which is the whole reason this is a class and not an int.
      // Before negotiation `meta.proto` is the *sender's* major and nothing has been agreed,
      // so there is no session to check against and the absence of one is the correct state.
      expect(
        session.accepts(ProtoMajor(ProtoVersion.current.major + 1)),
        isFalse,
        reason: 'a peer on a different major is not compatible, whatever it negotiates later',
      );

      // And the two fields cannot be confused, because they are two types.
      expect(
        _isDistinctType<ProtoMajor, ProtoVersion>(),
        isTrue,
        reason:
            '`meta.proto` and `meta.moduleVersion` are separate types precisely so that one '
            'cannot be passed where the other belongs — the pre-split specification\'s '
            '`negotiatedProto: "1.0"` shorthand is what that prevents',
      );
    });

    test('a frame disagreeing with the session is a -32050, not a tolerated mismatch', () {
      final session = SessionVersionInvariant(ProtoVersion.current);

      expect(() => session.require(session.requiredProto), returnsNormally);

      for (final major in [0, ProtoVersion.current.major + 1, 99]) {
        expect(
          () => session.require(ProtoMajor(major)),
          throwsA(
            isA<ProtocolViolation>()
                .having(
                  (v) => v.code,
                  'code',
                  DomainErrorCode.versionIncompatible,
                )
                .having((v) => v.path, 'path', r'$.meta.proto'),
          ),
          reason:
              'a frame declaring major $major is not part of a $session session',
        );
      }
    });

    test('a frame declaring its proto as a version string is refused', () {
      // The specific confusion the specification calls out by name. It is not a hypothetical:
      // it is the pre-split specification's own shorthand, and a peer built from it would send
      // a string where the protocol says an integer.
      final frame = _frameWith('request');
      (frame['meta']! as Map<String, Object?>)['proto'] = '1.0';

      final violation = _refuse(frame);
      expect(violation.code, JsonRpcErrorCode.invalidRequest);
      expect(violation.path, r'$.meta.proto');
      expect(
        violation.message,
        contains('negotiatedProto'),
        reason:
            'the reason should name the shorthand it is refusing, because the peer that sent '
            'it has read a document that used it',
      );
    });

    test('a frame declaring its moduleVersion as an integer is refused', () {
      // The other direction of the same confusion.
      final frame = _frameWith('request');
      (frame['meta']! as Map<String, Object?>)['moduleVersion'] = 1;

      final violation = _refuse(frame);
      expect(violation.code, JsonRpcErrorCode.invalidRequest);
      expect(violation.path, r'$.meta.moduleVersion');
    });

    test('a malformed moduleVersion is refused rather than truncated', () {
      for (final bad in <String>[
        '1.0',
        '1',
        'v1.0.0',
        '1.0.0.0',
        '',
        'latest',
      ]) {
        final frame = _frameWith('request');
        (frame['meta']! as Map<String, Object?>)['moduleVersion'] = bad;
        final violation = _refuse(frame);
        expect(
          violation.path,
          r'$.meta.moduleVersion',
          reason: '`moduleVersion: "$bad"` is not a version',
        );
      }
    });
  });

  group('the sealed union', () {
    test(
      'a frame is one of exactly four variants, and a switch is exhaustive',
      () {
        // Exhaustive over `AlteriOneEnvelope` with no wildcard arm, which the compiler enforces
        // precisely because the class is sealed. The `_variantOf` call below is therefore a
        // compile-time statement about the union as much as a runtime one.
        String describe(AlteriOneEnvelope frame) => switch (frame) {
          RequestEnvelope(:final method) => 'request $method',
          ResponseEnvelope(:final body) => 'response ${body.runtimeType}',
          NotificationEnvelope(:final method) => 'notification $method',
          EventEnvelope(:final topic) => 'event $topic',
        };

        for (final frame in allFixtures) {
          expect(
            describe(frame),
            isNotEmpty,
            reason: 'the switch had no arm for ${frame.type}',
          );
        }
      },
    );

    test('an unknown discriminant is refused', () {
      for (final bad in <Object?>[
        'Request',
        'req',
        '',
        1,
        null,
        <String>['request'],
      ]) {
        final frame = _frameWith('request')..['type'] = bad;
        final violation = _refuse(frame);
        expect(
          violation.code,
          JsonRpcErrorCode.invalidRequest,
          reason: '`type: $bad` is not one of the four',
        );
        expect(violation.path, r'$.type');
      }
    });

    test('a member the variant does not define is refused', () {
      // Strict in both directions. `result` on a request and `topic` on a response are the
      // realistic mistakes, and a lenient decoder would drop them and produce a frame that
      // round-trips differently from the one that was sent.
      final requestWithTopic = _frameWith('request')
        ..['topic'] = 'core/step_completed';
      expect(_refuse(requestWithTopic).path, r'$.topic');

      final responseWithTopic = _frameWith('response')
        ..['topic'] = 'core/step_completed';
      expect(_refuse(responseWithTopic).path, r'$.topic');

      final eventWithResult = _frameWith('event')
        ..['result'] = <String, Object?>{};
      expect(_refuse(eventWithResult).path, r'$.result');
    });

    test('a frame that is not JSON, or not an object, is a parse error', () {
      for (final payload in <String>[
        '',
        '{',
        'null',
        '[]',
        '"a string"',
        '42',
        'true',
      ]) {
        expect(
          () => decodeEnvelope(payload),
          throwsA(
            isA<ProtocolViolation>()
                .having((v) => v.code, 'code', JsonRpcErrorCode.parseError)
                .having((v) => v.path, 'path', r'$'),
          ),
          reason:
              '`$payload` is not a frame, and the difference from a malformed one is that '
              'there is nothing in it to interpret',
        );
      }
    });

    test('a frame with the wrong jsonrpc version is refused', () {
      final frame = _frameWith('request')..['jsonrpc'] = '1.0';
      final violation = _refuse(frame);
      expect(violation.code, JsonRpcErrorCode.invalidRequest);
      expect(violation.path, r'$.jsonrpc');
    });

    test('a meta carrying a member this version does not define is refused', () {
      // `meta` is inside the frame, so a lenient `meta` would be the one place a peer could
      // put something the protocol does not describe and have it dropped without a word. It is
      // also the block most likely to grow: the specification adds optional members to `meta`
      // over time, and a member this version does not know is a frame from a future one — so
      // the refusal is what makes a version bump observable instead of silent.
      for (final member in const [
        'negotiatedProtoVersion',
        'protoVersionRange',
        'traceId',
      ]) {
        final frame = _frameWith('request');
        (frame['meta']! as Map<String, Object?>)[member] = '1.0.0';

        final violation = _refuse(frame);
        expect(
          violation.code,
          JsonRpcErrorCode.invalidRequest,
          reason: '`meta.$member` is not defined by this version',
        );
        expect(violation.path, r'$.meta.' + member);
      }
    });

    test('every member EnvelopeMeta declares is one the codec accepts', () {
      // The two places that enumerate `meta` are a class and a set of strings, and nothing
      // keeps them in step. This is the assertion that keeps them in step: each field of
      // [EnvelopeMeta] is written into a frame and decoded back, so a member added to the class
      // and forgotten on the wire fails here rather than in a peer's session.
      final withEveryMember = RequestEnvelope(
        module: 'core',
        meta: EnvelopeMeta(
          proto: ProtoMajor(1),
          moduleVersion: ProtoVersion(major: 1, minor: 0, patch: 0),
          deadlineMs: 300000,
          idempotencyKey: 'run_01',
          latencyMs: 120,
        ),
        id: FrameId('req_1'),
        method: 'core/run',
      );
      final encoded = encodeFrame(withEveryMember);
      for (final member in const [
        'proto',
        'moduleVersion',
        'deadlineMs',
        'idempotencyKey',
        'latencyMs',
      ]) {
        expect(
          encoded,
          contains('"$member"'),
          reason: '`$member` was not encoded',
        );
      }
      expect(
        decodeEnvelope(encoded),
        equals(withEveryMember),
        reason: 'a `meta` member that does not survive a round trip is not on the wire',
      );
    });
  });

  group('the error taxonomy', () {
    test('the code table matches reference/error-codes.md', () {
      // The taxonomy is the table, in types. This compares the two so that editing one without
      // the other is a failing test rather than a documentation bug found by a user.
      final documented = _documentedCodes();
      final declared = <int, String>{
        for (final code in allErrorCodes) code.code: code.summary,
      };

      expect(
        declared.keys.toSet(),
        documented.keys.toSet(),
        reason:
            'the codes in the types and the codes in the table differ. '
            'added in the types: ${declared.keys.toSet().difference(documented.keys.toSet())}; '
            'added in the table: ${documented.keys.toSet().difference(declared.keys.toSet())}',
      );
      for (final entry in documented.entries) {
        expect(
          declared[entry.key],
          entry.value,
          reason: 'code ${entry.key} is documented as "${entry.value}"',
        );
      }
    });

    test('the standard and domain ranges do not overlap', () {
      // `−32768…−32000` is JSON-RPC's implementation-defined block, and AlteriOne's domain
      // codes sit inside it. A standard code inside that block would be a peer translating an
      // LSP code into a number we have since claimed.
      final standard = JsonRpcErrorCode.values.map((code) => code.code).toSet();
      final domain = DomainErrorCode.values.map((code) => code.code).toSet();

      expect(
        standard.intersection(domain),
        isEmpty,
        reason: 'a code cannot be both a standard one and a domain one',
      );
      expect(
        standard,
        <int>{-32700, -32600, -32601, -32602, -32603},
        reason:
            'the standard codes keep their standard meaning. That is the whole reason they '
            'are a separate enum from the domain ones: a peer that sends -32601 expects '
            '*method not found*',
      );
      for (final code in domain) {
        expect(
          code,
          inInclusiveRange(-32768, -32000),
          reason:
              '$code is outside the implementation-defined block. The domain range is kept '
              'contiguous on purpose — error-codes.md §1.1',
        );
      }
    });

    test('a retry policy is not a bool', () {
      // The table's "Retry" column says "with backoff", "after `Retry-After`", "one retry",
      // "per capability" and "possible for a transient cause". Collapsing those to a bool would
      // lose four obligations, so the type carries the obligation and the test pins which code
      // carries which.
      expect(
        DomainErrorCode.providerUnavailable.retry,
        RetryPolicy.withBackoff,
      );
      expect(DomainErrorCode.rateLimited.retry, RetryPolicy.afterRetryAfter);
      expect(DomainErrorCode.toolTimeout.retry, RetryPolicy.once);
      expect(DomainErrorCode.toolFailed.retry, RetryPolicy.perCapability);
      expect(
        JsonRpcErrorCode.internalError.retry,
        RetryPolicy.onTransientCause,
      );
      expect(DomainErrorCode.deadlineExceeded.retry, RetryPolicy.no);

      // The idempotency half of the rule lives on the request, not here, and this is the
      // assertion that it lives there: a request can carry the key and it round-trips.
      expect(RetryPolicy.values.where((p) => p.allowsRetry), isNotEmpty);
      expect(
        requestWithIdempotencyKeyFixture.meta.idempotencyKey,
        'run_01',
        reason:
            '"a request with a side effect may be retried only when it carries an '
            'idempotencyKey" is a property of the request. A retry policy that implied it '
            'would let a caller read a code and conclude a retry is safe',
      );
      expect(
        decodeEnvelope(encodeFrame(requestWithIdempotencyKeyFixture))
            .meta
            .idempotencyKey,
        'run_01',
      );
    });

    test('an error round-trips through a response', () {
      for (final code in allErrorCodes) {
        final response = ResponseEnvelope(
          module: 'core',
          meta: metaFixture,
          id: FrameId('req_1'),
          body: ErrorBody(
            AlteriOneError(code: code, message: 'failure: ${code.code}'),
          ),
        );
        final decoded =
            decodeEnvelope(encodeFrame(response)) as ResponseEnvelope;

        expect(
          decoded.errorOrNull!.code,
          code,
          reason: 'code ${code.code} did not survive',
        );
        expect(decoded.errorOrNull!.message, 'failure: ${code.code}');
      }
    });
  });

  group('the JSON value', () {
    test('a non-JSON value is refused at construction, not at encode time', () {
      // The reason this package has a `JsonMap` at all. A `Map<String, Object?>` would accept
      // this and every `jsonEncode` in every transport would fail on it later, on a frame a
      // peer is already waiting for.
      expect(
        () => JsonMap({'when': DateTime(2026, 9, 30)}),
        throwsA(isA<JsonTypeError>()),
      );
      expect(() => JsonMap({'fn': () => 1}), throwsA(isA<JsonTypeError>()));
      expect(
        () => JsonMap({
          'nested': {'deep': Duration.zero},
        }),
        throwsA(isA<JsonTypeError>()),
        reason: 'the check is recursive; a bad value two levels down is still a bad value',
      );
      expect(
        () => JsonList([
          1,
          'two',
          <String, Object?>{},
          [true, null],
        ]),
        returnsNormally,
        reason: 'null, bool, num, String, array and object are all JSON',
      );
    });

    test('a JsonTypeError names the path of the offending value', () {
      // `-32602` promises a JSON path, and a nested diagnostic is where that promise starts.
      try {
        JsonMap({
          'params': {
            'args': [1, DateTime(2026)],
          },
        });
        fail('expected a JsonTypeError');
      } on JsonTypeError catch (error) {
        expect(error.path, r'$.params.args[1]');
      }
    });

    test('a JsonMap is a copy, so a later edit cannot change it', () {
      final source = <String, Object?>{'goal': 'first'};
      final map = JsonMap(source);
      source['goal'] = 'second';
      expect(map['goal'], 'first');
    });
  });
}

// -------------------------------------------------------------------------------------------
// Fixtures. Every frame the tests use, built from the library's own types rather than from
// JSON literals, so a test and the wire form cannot disagree about what a variant holds.
// -------------------------------------------------------------------------------------------

final EnvelopeMeta metaFixture = EnvelopeMeta(
  proto: ProtoMajor(ProtoVersion.current.major),
  moduleVersion: ProtoVersion.current,
);

final RequestEnvelope requestFixture = RequestEnvelope(
  module: 'core',
  meta: metaFixture,
  id: FrameId('req_01f4a9c2'),
  method: 'core/run',
  params: JsonMap({
    'goal': 'Prepare a short report',
    'profile': 'companion',
    'context': JsonMap.empty,
  }),
);

final ResponseEnvelope responseOkFixture = ResponseEnvelope(
  module: 'core',
  meta: EnvelopeMeta(
    proto: ProtoMajor(ProtoVersion.current.major),
    moduleVersion: ProtoVersion.current,
    latencyMs: 120,
  ),
  id: FrameId('req_01f4a9c2'),
  body: ResultBody(JsonMap({'status': 'completed', 'answer': 'Report ready'})),
);

final ResponseEnvelope responseErrorFixture = ResponseEnvelope(
  module: 'core',
  meta: metaFixture,
  id: FrameId('req_01f4a9c2'),
  body: const ErrorBody(
    AlteriOneError(
      code: DomainErrorCode.toolFailed,
      message: 'the tool returned no answer',
    ),
  ),
);

/// A request carrying the idempotency key the specification says a retryable side effect needs.
final RequestEnvelope requestWithIdempotencyKeyFixture = RequestEnvelope(
  module: 'core',
  meta: EnvelopeMeta(
    proto: ProtoMajor(ProtoVersion.current.major),
    moduleVersion: ProtoVersion.current,
    deadlineMs: 300000,
    idempotencyKey: 'run_01',
  ),
  id: FrameId('req_01f4a9c2'),
  method: 'core/run',
);

final NotificationEnvelope notificationFixture = NotificationEnvelope(
  module: 'core',
  meta: metaFixture,
  method: r'$/progress',
  params: JsonMap({
    'requestId': 'req_01f4a9c2',
    'progress': 0.5,
    'message': 'Half the steps done',
  }),
);

final EventEnvelope eventFixture = EventEnvelope(
  module: 'core',
  meta: metaFixture,
  topic: 'core/step_completed',
  data: JsonMap({'step': 2, 'status': 'ok'}),
  traceId: 'trace_01f4a9c2',
);

/// One frame of each variant. The round trip iterates this, so it is the definition of
/// "every variant" for the test suite.
List<AlteriOneEnvelope> get allFixtures => [
  requestFixture,
  responseOkFixture,
  responseErrorFixture,
  notificationFixture,
  eventFixture,
];

// -------------------------------------------------------------------------------------------
// Helpers.
// -------------------------------------------------------------------------------------------

/// A well-formed frame of [type], as a mutable map, so a test can corrupt exactly one member.
///
/// Built as a literal rather than by encoding a fixture, so the corruption is not undone by the
/// codec: encoding a fixture and mutating the output would go through [JsonMap]'s copy, and a
/// test that could not actually corrupt the frame would prove nothing.
Map<String, Object?> _frameWith(String type, {Map<String, Object?>? extra}) {
  final frame =
      <String, Object?>{
        'jsonrpc': '2.0',
        'type': type,
        'module': 'core',
        'meta': <String, Object?>{
          'proto': ProtoVersion.current.major,
          'moduleVersion': ProtoVersion.current.toString(),
        },
      }..addAll(switch (type) {
        'request' => <String, Object?>{
          'id': 'req_1',
          'method': 'core/run',
          'params': <String, Object?>{'goal': 'x'},
        },
        'response' => <String, Object?>{
          'id': 'req_1',
          'result': <String, Object?>{'status': 'completed'},
        },
        'notification' => <String, Object?>{
          'method': r'$/progress',
          'params': <String, Object?>{'progress': 0.5},
        },
        'event' => <String, Object?>{
          'topic': 'core/step_completed',
          'data': <String, Object?>{'step': 1},
          'traceId': 'trace_1',
        },
        _ => const <String, Object?>{},
      });
  if (extra != null) frame.addAll(extra);
  return frame;
}

/// Decodes [frame] and returns the violation it produced.
///
/// Fails the test when the frame decodes: a helper named for the failure returning null would
/// let a test pass on a frame the codec quietly accepted.
ProtocolViolation _refuse(Map<String, Object?> frame) {
  try {
    decodeEnvelope(jsonEncode(frame));
  } on ProtocolViolation catch (violation) {
    return violation;
  }
  fail(
    'the codec accepted a frame it should have refused:\n${jsonEncode(frame)}',
  );
}

/// Whether [A] and [B] are two distinct types at compile time.
///
/// Stated as a type-level question with no runtime content, which is unusual and deliberate:
/// the invariant this protects is that `meta.proto` and `meta.moduleVersion` cannot be
/// interchanged, and the only honest test of that is whether the type system permits it.
bool _isDistinctType<A, B>() => A != B;

/// `<code>: <meaning>` for every row of the error-code table in `docs/reference/error-codes.md`.
///
/// Parsed from the markdown rather than restated, because a copy of a table is a second table.
///
/// The path is found by walking up from the working directory rather than assumed. The
/// acceptance command is `melos exec --scope=alteri_one_protocol -- dart test …`, and melos
/// runs it *in the package*, so a test that opened `docs/reference/error-codes.md` relative to
/// the working directory would work when run from the root by hand and fail in the one place it
/// has to work. A test that only passes in the way its author runs it is a test that will be
/// skipped.
///
/// The minus sign in the document is a Unicode `−` and the column is right-aligned, so the row
/// is matched on its shape and the number normalised to ASCII.
Map<int, String> _documentedCodes() {
  const relative = 'docs/reference/error-codes.md';
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

  final codes = <int, String>{};
  for (final line in found.readAsLinesSync()) {
    final match = RegExp(r'^\|\s*`−(\d+)`\s*\|\s*([^|]+?)\s*\|')
        .firstMatch(line);
    if (match == null) continue;
    // The sign is the Unicode `−` *outside* the capture, so the digits parse as a positive
    // number. Re-applying it is the point of the comparison: a table of unsigned codes and a
    // type of signed ones would agree on every digit and disagree on every value.
    codes[-int.parse(match.group(1)!)] = match.group(2)!;
  }
  if (codes.isEmpty) {
    throw StateError(
      'no error codes parsed from ${found.path}; the table format changed',
    );
  }
  return codes;
}
